import Foundation
import SwiftData
import Testing
import UserNotifications

@testable import NowThis

@Suite("Confirmed notification registration", .serialized)
@MainActor
struct NotificationRegistrationTests {
    @Test("Reconciliation stays alive until notification registration acknowledges")
    func completionWaitsForAddAcknowledgment() async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let task = TaskItem(title: "Acknowledged reminder")
        task.id = "registration-pending"
        task.dueDate = Date().addingTimeInterval(3_600)
        task.reminderOffset = 0
        context.insert(task)
        try context.save()

        let store = RegistrationNotificationStore()
        var finished = false
        let run = Task { @MainActor in
            await ReminderScheduler.reconcileScheduledNotifications(
                modelContext: context, store: store, badgesEnabled: false)
            finished = true
        }
        while store.addedIdentifiers.isEmpty && !finished { await Task.yield() }
        #expect(store.addedIdentifiers == ["reminder-registration-pending"])
        #expect(!finished, "An unacknowledged add must not let the lifecycle caller finish")
        store.acknowledge()
        await run.value
        #expect(finished)
    }

    @Test("A rejected replacement keeps previously registered reminders")
    func failedAddPreventsObsoleteRemoval() async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let task = TaskItem(title: "Replacement")
        task.id = "registration-failed"
        task.dueDate = Date().addingTimeInterval(3_600)
        task.reminderOffset = 0
        context.insert(task)
        try context.save()
        let store = RegistrationNotificationStore(rejectsAdds: true, pending: [
            .init(identifier: "reminder-previous", fireDate: Date().addingTimeInterval(7_200),
                  badge: nil, title: "Previously registered")
        ])

        let result = await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: context, store: store, badgesEnabled: false)
        #expect(store.addedIdentifiers == ["reminder-registration-failed"])
        #expect(store.removedIdentifiers.isEmpty,
                "Failed registration must leave the previous notification available")
        #expect(result.status == .failed)
    }

    @Test("Background reconciliation never prompts for undetermined permission")
    func backgroundNotDeterminedNeverPrompts() async throws {
        let container = try DAVSyncScenario.container()
        let store = RegistrationNotificationStore(autoAcknowledges: true)
        store.isAuthorized = false
        let result = await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: container.mainContext, store: store, policy: .background)
        #expect(result.status == .permissionDenied)
        #expect(store.authorizationPromptCount == 0)
        #expect(store.addedIdentifiers.isEmpty)
    }

    @Test("Revocation during registration preserves the previous request")
    func deniedAfterAddKeepsIncompleteOutcome() async throws {
        let container = try DAVSyncScenario.container()
        let task = TaskItem(title: "Revoked during registration")
        task.id = "revoked"
        task.dueDate = Date().addingTimeInterval(3_600)
        task.reminderOffset = 0
        container.mainContext.insert(task)
        try container.mainContext.save()
        let store = RegistrationNotificationStore(autoAcknowledges: true, revokeAfterAdd: true,
            pending: [.init(identifier: "reminder-previous", fireDate: nil, badge: nil, title: "Previous")])
        let result = await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: container.mainContext, store: store, policy: .background)
        #expect(result.status == .permissionDenied)
        #expect(store.removedIdentifiers.isEmpty)
    }

    @Test("Reconciliation does not expand nags deferred by the request budget")
    func reconcileDoesNotExpandDeferredNags() async throws {
        let container = try DAVSyncScenario.container()
        for index in 0..<60 {
            let task = TaskItem(title: "Budget \(index)")
            task.id = "budget-\(index)"
            task.dueDate = Date().addingTimeInterval(Double(index + 1) * 3_600)
            task.reminderOffset = 0
            task.isNaggingReminder = true
            container.mainContext.insert(task)
        }
        try container.mainContext.save()
        let store = RegistrationNotificationStore(autoAcknowledges: true)
        let result = await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: container.mainContext, store: store, badgesEnabled: false)
        #expect(store.addedIdentifiers.count == 60)
        #expect(store.addedIdentifiers.allSatisfy { $0.hasPrefix("reminder-") })
        #expect(result.status == .capacityLimited)
        #expect(result.deferredTaskIDs.count == 60)
    }
}

@MainActor
private final class RegistrationNotificationStore: NotificationStore {
    var addedIdentifiers: [String] = []
    var removedIdentifiers: [String] = []
    let rejectsAdds: Bool
    let autoAcknowledges: Bool
    let revokeAfterAdd: Bool
    var isAuthorized = true
    var authorizationPromptCount = 0
    var pending: [ReminderScheduler.PendingSnapshot]

    init(rejectsAdds: Bool = false, autoAcknowledges: Bool = false,
         revokeAfterAdd: Bool = false, pending: [ReminderScheduler.PendingSnapshot] = []) {
        self.rejectsAdds = rejectsAdds
        self.autoAcknowledges = autoAcknowledges
        self.revokeAfterAdd = revokeAfterAdd
        self.pending = pending
    }

    func authorizationAllowsScheduling(allowPrompt: Bool) async -> Bool {
        if !isAuthorized && allowPrompt {
            authorizationPromptCount += 1
            isAuthorized = true
        }
        return isAuthorized
    }
    func pendingSnapshots() async -> [ReminderScheduler.PendingSnapshot] { pending }

    private var acknowledgment: CheckedContinuation<Void, Error>?
    private enum Failure: Error { case rejected }

    func add(_ request: UNNotificationRequest) async throws {
        addedIdentifiers.append(request.identifier)
        if rejectsAdds { throw Failure.rejected }
        if revokeAfterAdd { isAuthorized = false }
        if !autoAcknowledges { try await withCheckedThrowingContinuation { acknowledgment = $0 } }
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(.init(identifier: request.identifier,
            fireDate: (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(),
            badge: request.content.badge?.intValue, title: request.content.userInfo["title"] as? String,
            body: request.content.body, repeats: request.trigger?.repeats,
            interval: (request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval))
    }

    func acknowledge() { acknowledgment?.resume(); acknowledgment = nil }

    func remove(identifiers: [String]) {
        removedIdentifiers += identifiers
        pending.removeAll { identifiers.contains($0.identifier) }
    }
}
