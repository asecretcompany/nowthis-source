import Foundation
import SwiftData
import Testing
import UserNotifications

@testable import NowThis

@Suite("Serialized reminder reconciliation", .serialized)
@MainActor
struct ReminderReconciliationCoordinatorTests {
    private func fixture(_ id: String = "edited") throws -> (ModelContainer, TaskItem) {
        let container = try DAVSyncScenario.container()
        let task = TaskItem(title: "Old title")
        task.id = id; task.dueDate = Date().addingTimeInterval(3_600); task.reminderOffset = 0
        container.mainContext.insert(task)
        ReminderSchedulingJournal.enqueue(in: container.mainContext)
        try container.mainContext.save()
        return (container, task)
    }

    @Test("A new pass waits for an older registration, then repairs its stale content")
    func staleAddIsRepairedBeforeNewPassFinishes() async throws {
        let (container, task) = try fixture()
        let coordinator = ReminderReconciliationCoordinator()
        let store = CoordinatorNotificationStore(pausesFirstAdd: true)
        let worker = ControlledReminderWorker(container: container)
        let old = Task { await coordinator.reconcile(modelContext: container.mainContext,
            policy: .background, store: store, worker: worker, badgesEnabled: false) }
        await store.waitUntilAddStarted()
        task.title = "New title"
        ReminderSchedulingJournal.enqueue(in: container.mainContext)
        try container.mainContext.save()
        var newestFinished = false
        let newest = Task {
            let result = await coordinator.reconcile(modelContext: container.mainContext,
                policy: .background, store: store, worker: worker, badgesEnabled: false)
            newestFinished = true
            return result
        }
        await worker.waitForProjectionCount(2)
        await Task.yield()
        #expect(!newestFinished)
        #expect(store.addedIdentifiers.count == 1)
        store.releaseAdd()
        _ = await old.value
        let result = await newest.value
        #expect(result.status == .confirmed)
        #expect(store.pending["reminder-edited"]?.title == "New title")
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    @Test("Completion queued during registration cannot leave a resurrected request")
    func completionDuringAddCannotRestoreReminder() async throws {
        let (container, task) = try fixture("completed")
        let coordinator = ReminderReconciliationCoordinator()
        let store = CoordinatorNotificationStore(pausesFirstAdd: true)
        let worker = ControlledReminderWorker(container: container)
        let run = Task { await coordinator.reconcile(modelContext: container.mainContext,
            policy: .background, store: store, worker: worker, badgesEnabled: false) }
        await store.waitUntilAddStarted()
        task.status = .completed
        ReminderSchedulingJournal.enqueue(in: container.mainContext)
        try container.mainContext.save()
        coordinator.invalidate(taskIDs: [task.id])
        let cancellation = Task { await coordinator.cancel(taskIDs: [task.id], store: store) }
        await Task.yield()
        store.releaseAdd()
        _ = await run.value
        await cancellation.value
        #expect(store.pending["reminder-completed"] == nil)
    }

    @Test("A full queue frees only obsolete owned capacity before adding")
    func fullQueueFreesOnlyObsoleteOwnedSlots() async throws {
        let (container, _) = try fixture("replacement")
        let store = fullStore()
        let result = await ReminderReconciliationCoordinator().reconcile(
            modelContext: container.mainContext, policy: .background, store: store,
            worker: ControlledReminderWorker(container: container), badgesEnabled: false)
        #expect(result.status == .confirmed)
        #expect(store.events.first?.hasPrefix("remove:") == true)
        #expect(store.pending.keys.sorted() == ["foreign-request", "reminder-replacement"])
        #expect(!store.removedIdentifiers.contains("foreign-request"))
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    @Test("A failed refill retains both the ticket and other valid owned requests")
    func failedRefillKeepsTicket() async throws {
        let (container, _) = try fixture("replacement")
        let store = fullStore()
        store.rejectsAdds = true
        let result = await ReminderReconciliationCoordinator().reconcile(
            modelContext: container.mainContext, policy: .background, store: store,
            worker: ControlledReminderWorker(container: container), badgesEnabled: false)
        #expect(result.status == .failed)
        #expect(store.removedIdentifiers.count == 1)
        #expect(store.pending.count == 63)
        #expect(try !ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    @Test("A ticket committed during readback prevents the older acknowledgment")
    func newTicketDuringReadbackPreventsAcknowledgment() async throws {
        let (container, _) = try fixture()
        let store = CoordinatorNotificationStore()
        var newer: String?
        store.onRead = { count in
            guard count == 2 else { return }
            let context = ModelContext(container)
            newer = ReminderSchedulingJournal.enqueue(in: context)
            try! context.save()
        }
        let result = await ReminderReconciliationCoordinator().reconcile(
            modelContext: container.mainContext, policy: .background, store: store,
            worker: ControlledReminderWorker(container: container), badgesEnabled: false)
        #expect(result.status == .superseded)
        let newerID = try #require(newer)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).contains(newerID))
    }

    @Test("A calendar fire date that passes during projection is not reported registered")
    func deadlinePassesDuringProjection() async throws {
        let (container, task) = try fixture()
        task.dueDate = Date().addingTimeInterval(1)
        try container.mainContext.save()
        let worker = ControlledReminderWorker(container: container, pausesProjection: true)
        let store = CoordinatorNotificationStore()
        let run = Task { await ReminderReconciliationCoordinator().reconcile(
            modelContext: container.mainContext, policy: .background, store: store,
            worker: worker, badgesEnabled: false) }
        await worker.waitUntilProjectionStarted()
        try await Task.sleep(for: .milliseconds(1_200))
        await worker.releaseProjection()
        let result = await run.value
        #expect(result.confirmedCount == 0)
        #expect(result.expiredTaskIDs == [task.id])
        #expect(store.pending.isEmpty)
    }

    @Test("Denied permission leaves work pending without an automatic retry loop")
    func permissionRevocationDoesNotBusyLoop() async throws {
        let (container, _) = try fixture()
        let store = CoordinatorNotificationStore()
        store.authorized = false
        let result = await ReminderReconciliationCoordinator().reconcile(
            modelContext: container.mainContext, policy: .background, store: store,
            worker: ControlledReminderWorker(container: container), badgesEnabled: false)
        #expect(result.status == .permissionDenied)
        #expect(store.authorizationChecks == 1)
        #expect(store.addedIdentifiers.isEmpty)
        #expect(try !ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    @Test("Containers addressing the same center share one mutation domain")
    func distinctContainersShareNotificationDomain() async throws {
        let (first, _) = try fixture("domain")
        let (second, latestTask) = try fixture("domain")
        latestTask.title = "Latest container"
        try second.mainContext.save()
        let store = CoordinatorNotificationStore(pausesFirstAdd: true)
        store.domain = "test-center-" + UUID().uuidString
        let firstWorker = ControlledReminderWorker(container: first)
        let older = Task { await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: first.mainContext, store: store, badgesEnabled: false,
            worker: firstWorker, policy: .background) }
        await store.waitUntilAddStarted()
        var newestFinished = false
        let newer = Task {
            try await ReminderScheduler.scheduleReminder(for: latestTask, store: store)
            newestFinished = true
        }
        await Task.yield()
        #expect(!newestFinished)
        store.releaseAdd()
        _ = await older.value
        try await newer.value
        #expect(store.pending["reminder-domain"]?.title == "Latest container")
        #expect(store.addedIdentifiers.count == 2)
    }

    @Test("The single-task scheduling API cannot bypass an older queued write")
    func singleTaskHelperSharesMutationQueue() async throws {
        let (container, task) = try fixture("single")
        let store = CoordinatorNotificationStore(pausesFirstAdd: true)
        let worker = ControlledReminderWorker(container: container)
        let older = Task { await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: container.mainContext, store: store, badgesEnabled: false,
            worker: worker, policy: .background) }
        await store.waitUntilAddStarted()
        task.title = "Latest single task"
        try container.mainContext.save()
        var helperFinished = false
        let newer = Task {
            try await ReminderScheduler.scheduleReminder(for: task, store: store)
            helperFinished = true
        }
        await Task.yield()
        #expect(!helperFinished)
        store.releaseAdd()
        _ = await older.value
        try await newer.value
        #expect(store.pending["reminder-single"]?.title == "Latest single task")
        #expect(store.addedIdentifiers.count == 2)
    }

    @Test("Disabling a nag invalidates an older pass before it adds the repeat")
    func nagCancellationSharesMutationQueue() async throws {
        let (container, task) = try fixture("partial")
        task.isNaggingReminder = true
        try container.mainContext.save()
        let store = CoordinatorNotificationStore(pausesFirstAdd: true)
        store.domain = "partial-center-" + UUID().uuidString
        let worker = ControlledReminderWorker(container: container)
        let run = Task { await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: container.mainContext, store: store, badgesEnabled: false,
            worker: worker, policy: .background) }
        await store.waitUntilAddStarted()
        task.isNaggingReminder = false
        ReminderSchedulingJournal.enqueue(in: container.mainContext)
        try container.mainContext.save()
        ReminderScheduler.cancelNagReminder(for: task.id, store: store)
        await Task.yield()
        store.releaseAdd()
        _ = await run.value
        #expect(!store.addedIdentifiers.contains("nag-partial"))
        #expect(store.pending["nag-partial"] == nil)
    }

    private func fullStore() -> CoordinatorNotificationStore {
        var pending: [ReminderScheduler.PendingSnapshot] = (0..<63).map {
            .init(identifier: "reminder-obsolete-\($0)",
                  fireDate: Date().addingTimeInterval(Double($0 + 2) * 3_600), badge: nil, title: "Old")
        }
        pending.append(.init(identifier: "foreign-request", fireDate: nil, badge: nil, title: nil))
        return CoordinatorNotificationStore(pending: pending)
    }
}

@MainActor
final class CoordinatorNotificationStore: NotificationStore {
    enum Failure: Error { case rejected, full }
    var pending: [String: ReminderScheduler.PendingSnapshot]
    var addedIdentifiers: [String] = []
    var removedIdentifiers: [String] = []
    var events: [String] = []
    var authorized = true
    var rejectsAdds = false
    var authorizationChecks = 0
    var readCount = 0
    var onRead: ((Int) -> Void)?
    var domain: String?
    var coordinationDomain: String? { domain }
    private let pausesFirstAdd: Bool
    private var hasPaused = false
    private var addGate: CheckedContinuation<Void, Never>?
    private var addWaiters: [CheckedContinuation<Void, Never>] = []

    init(pausesFirstAdd: Bool = false, pending: [ReminderScheduler.PendingSnapshot] = []) {
        self.pausesFirstAdd = pausesFirstAdd
        self.pending = Dictionary(pending.map { ($0.identifier, $0) }, uniquingKeysWith: { _, last in last })
    }

    func authorizationAllowsScheduling(allowPrompt: Bool) async -> Bool {
        authorizationChecks += 1
        return authorized
    }

    func pendingSnapshots() async -> [ReminderScheduler.PendingSnapshot] {
        readCount += 1
        let result = Array(pending.values)
        onRead?(readCount)
        return result
    }

    func add(_ request: UNNotificationRequest) async throws {
        addedIdentifiers.append(request.identifier)
        events.append("add:" + request.identifier)
        if pausesFirstAdd && !hasPaused {
            hasPaused = true
            addWaiters.forEach { $0.resume() }; addWaiters.removeAll()
            await withCheckedContinuation { addGate = $0 }
        }
        if rejectsAdds { throw Failure.rejected }
        if pending[request.identifier] == nil && pending.count >= 64 { throw Failure.full }
        pending[request.identifier] = .init(identifier: request.identifier,
            fireDate: (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(),
            badge: request.content.badge?.intValue, title: request.content.userInfo["title"] as? String,
            body: request.content.body, repeats: request.trigger?.repeats,
            interval: (request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval)
    }

    func remove(identifiers: [String]) {
        removedIdentifiers += identifiers
        events += identifiers.map { "remove:" + $0 }
        identifiers.forEach { pending.removeValue(forKey: $0) }
    }

    func waitUntilAddStarted() async {
        if hasPaused { return }
        await withCheckedContinuation { addWaiters.append($0) }
    }

    func releaseAdd() { addGate?.resume(); addGate = nil }
}

actor ControlledReminderWorker: ReminderProjectionWorking {
    private let base: ReminderProjectionWorker
    private let pausesProjection: Bool
    private var started = false
    private var projectionGate: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var count = 0

    init(container: ModelContainer, pausesProjection: Bool = false) {
        base = ReminderProjectionWorker(container: container)
        self.pausesProjection = pausesProjection
    }

    func project(_ request: ReminderProjectionRequest) async -> ReminderProjectionResult? {
        started = true
        startWaiters.forEach { $0.resume() }; startWaiters.removeAll()
        if pausesProjection { await withCheckedContinuation { projectionGate = $0 } }
        let result = await base.project(request)
        count += 1
        let ready = countWaiters.filter { $0.0 <= count }
        countWaiters.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
        return result
    }

    func waitForProjectionCount(_ desired: Int) async {
        if count >= desired { return }
        await withCheckedContinuation { countWaiters.append((desired, $0)) }
    }

    func waitUntilProjectionStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseProjection() { projectionGate?.resume(); projectionGate = nil }
}
