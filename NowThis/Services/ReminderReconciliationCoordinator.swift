import Foundation
import SwiftData
import UserNotifications
import CryptoKit

@MainActor
final class ReminderReconciliationCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private enum Failure: Error {
        case interrupted(ReminderReconciliationOutcome.Status)
        case verification
    }
    private var generation: UInt64 = 0
    private var applying = false
    private var waiters: [Waiter] = []

    func reconcile(modelContext: ModelContext, policy: ReminderReconcilePolicy,
                   store: any NotificationStore, worker: any ReminderProjectionWorking,
                   badgesEnabled: Bool = NotificationPreferences.isBadgeEnabled,
                   allDayReminderMinutes: Int = TaskDefaultsPreferences.allDayReminderMinutes) async -> ReminderReconciliationOutcome {
        generation &+= 1
        let expected = generation
        var outcome = ReminderReconciliationOutcome(status: .confirmed)
        let overlay: ReminderTaskOverlay
        do {
            overlay = try BackgroundRunBudget.protectingCurrent { ReminderTaskOverlay(modelContext: modelContext) }
        } catch { outcome.status = .cancelled; return outcome }
        let request = ReminderProjectionRequest(now: Date(), calendar: .current,
            allDayReminderMinutes: allDayReminderMinutes,
            maxCount: 60, badgesEnabled: badgesEnabled, overlay: overlay)
        let projectionWorker = worker
        do {
            try check(expected, policy)
            guard await store.authorizationAllowsScheduling(allowPrompt: policy.allowsPermissionPrompt) else {
                outcome.status = .permissionDenied; return outcome
            }
            try check(expected, policy)
            // Projection is concurrent; only OS mutations are serialized. A paused old
            // projection cannot prevent a newer edit from taking ownership.
            guard let projected = await projectionWorker.project(request) else {
                outcome.status = .failed; return outcome
            }
            try check(expected, policy)
            try await acquire()
            defer { release() }
            try check(expected, policy)
            let pending = await store.pendingSnapshots()
            try check(expected, policy)
            let plan = await makePlan(projected.tasks, request: request, pending: pending)
            try check(expected, policy)
            outcome.requestedCount = plan.requests.count
            outcome.deferredTaskIDs = plan.deferredTaskIDs
            outcome.expiredTaskIDs = plan.expiredTaskIDs
            let verified = try await apply(plan, pending: pending, expected: expected,
                                           policy: policy, store: store, calendar: request.calendar)
            outcome.confirmedCount = plan.requests.count
            try check(expected, policy)

            // Read authoritative saved state without replaying the captured overlay.
            // A widget can save completion/deletion while an older add is suspended;
            // its newer ticket makes that save authoritative for this repair pass.
            let savedRequest = ReminderProjectionRequest(now: request.now, calendar: request.calendar,
                allDayReminderMinutes: request.allDayReminderMinutes, maxCount: request.maxCount,
                badgesEnabled: request.badgesEnabled,
                overlay: ReminderTaskOverlay(upserts: [], deletedIDs: []))
            guard let fresh = await ReminderProjectionWorker(container: modelContext.container).project(savedRequest) else {
                outcome.status = .failed; return outcome
            }
            try check(expected, policy)
            let hasNewSavedWork = fresh.ticketIDs != projected.ticketIDs
            // With no concurrent save, retain the foreground overlay. Applying it here
            // never saves or refreshes the caller's models, and cannot acknowledge edits.
            let currentTasks = hasNewSavedWork ? fresh.tasks : request.overlay.applying(to: fresh.tasks)
            let currentPlan = await makePlan(currentTasks, request: request, pending: verified)
            try check(expected, policy)
            if currentPlan.requests != plan.requests {
                // A separate-process widget may have completed or advanced the task.
                // Repair its new state before returning; its ticket remains pending.
                _ = try await apply(currentPlan, pending: verified, expected: expected,
                                    policy: policy, store: store, calendar: request.calendar)
                outcome.confirmedCount = currentPlan.requests.count
                outcome.expiredTaskIDs.formUnion(currentPlan.expiredTaskIDs)
                outcome.status = .superseded
                return outcome
            }
            guard fresh.ticketIDs == projected.ticketIDs, projected.overlayIsSaved else {
                outcome.status = .superseded; return outcome
            }
            if ReminderSchedulingJournal.isAvailable(in: modelContext.container) {
                try BackgroundRunBudget.protectingCurrent {
                    let acknowledgment = ModelContext(modelContext.container)
                    acknowledgment.autosaveEnabled = false
                    guard try ReminderSchedulingJournal.capture(in: acknowledgment) == projected.ticketIDs else {
                        throw Failure.interrupted(.superseded)
                    }
                    try check(expected, policy)
                    let earliest = plan.deferredRequests.compactMap { entry -> Date? in
                        switch entry.trigger {
                        case .calendar(let date): return date
                        case .hourly: return Date().addingTimeInterval(3_600)
                        }
                    }.min()
                    try ReminderSchedulingJournal.acknowledge(projected.ticketIDs,
                        planDigest: digest(plan.requests), deferredTaskIDs: plan.deferredTaskIDs,
                        earliestDeferredFireDate: earliest, in: acknowledgment)
                    try acknowledgment.save()
                }
            }
            outcome.status = plan.deferredTaskIDs.isEmpty ? .confirmed : .capacityLimited
        } catch Failure.interrupted(let status) {
            outcome.status = status
        } catch {
            outcome.status = policy.shouldStop ? .cancelled : .failed
        }
        return outcome
    }

    func invalidate(taskIDs: Set<String>) { generation &+= 1 }

    func cancel(taskIDs: Set<String>, store: any NotificationStore) async {
        invalidate(taskIDs: taskIDs)
        await applyCancellation(taskIDs: taskIDs, store: store)
    }

    func requestCancellation(taskIDs: Set<String>, store: any NotificationStore) {
        requestRemoval(identifiers: taskIDs.sorted().flatMap(NotificationIdentifiers.all(forTaskID:)), store: store)
    }

    func requestRemoval(identifiers: [String], store: any NotificationStore) {
        invalidate(taskIDs: [])
        Task { await applyRemoval(identifiers: identifiers, store: store) }
    }

    func withMutation<Value>(_ operation: @MainActor () async throws -> Value) async throws -> Value {
        generation &+= 1
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func applyCancellation(taskIDs: Set<String>, store: any NotificationStore) async {
        await applyRemoval(identifiers: taskIDs.sorted().flatMap(NotificationIdentifiers.all(forTaskID:)), store: store)
    }

    private func applyRemoval(identifiers: [String], store: any NotificationStore) async {
        do {
            try await acquire()
            defer { release() }
            guard !Task.isCancelled else { return }
            store.remove(identifiers: identifiers)
        } catch { /* A cancelled owner leaves durable recovery work for the next scope. */ }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !applying { applying = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                self.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func release() {
        if waiters.isEmpty { applying = false }
        else { waiters.removeFirst().continuation.resume() }
    }

    private func check(_ expected: UInt64, _ policy: ReminderReconcilePolicy) throws {
        if policy.shouldStop { throw Failure.interrupted(.cancelled) }
        if generation != expected { throw Failure.interrupted(.superseded) }
    }

    private func makePlan(_ tasks: [ReminderTaskInput], request: ReminderProjectionRequest,
                      pending: [ReminderScheduler.PendingSnapshot]) async -> ReminderRequestPlan {
        let foreignCount = pending.filter { !owned($0.identifier) }.count
        let work = Task.detached {
            ReminderNotificationPlanner.planRequests(tasks: tasks, now: Date(), maxRequests: request.maxCount,
                foreignPendingCount: foreignCount, badgesEnabled: request.badgesEnabled,
                allDayReminderMinutes: request.allDayReminderMinutes, calendar: request.calendar)
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    private func apply(_ plan: ReminderRequestPlan, pending: [ReminderScheduler.PendingSnapshot],
                       expected: UInt64, policy: ReminderReconcilePolicy, store: any NotificationStore,
                       calendar: Calendar) async throws -> [ReminderScheduler.PendingSnapshot] {
        var present = Dictionary(pending.map { ($0.identifier, $0) }, uniquingKeysWith: { _, last in last })
        let desiredIDs = Set(plan.requests.map(\.identifier))
        let additions = plan.requests.filter { !matches($0, present[$0.identifier]) }
        let obsolete = pending.filter { owned($0.identifier) && !desiredIDs.contains($0.identifier) }
            .sorted {
                let left = $0.fireDate ?? .distantFuture, right = $1.fireDate ?? .distantFuture
                return left == right ? $0.identifier < $1.identifier : left > right
            }
        let newCount = additions.filter { present[$0.identifier] == nil }.count
        let mustFree = newCount == 0 ? 0 : max(0, pending.count + newCount - 64)
        try check(expected, policy)
        if mustFree > 0 {
            guard obsolete.count >= mustFree else { throw Failure.verification }
            store.remove(identifiers: obsolete.prefix(mustFree).map(\.identifier))
            let freed = await store.pendingSnapshots()
            try check(expected, policy)
            present = Dictionary(freed.map { ($0.identifier, $0) }, uniquingKeysWith: { _, last in last })
            guard present.count + newCount <= 64 else { throw Failure.verification }
        }
        for entry in additions {
            try check(expected, policy)
            if case .calendar(let fire) = entry.trigger, fire <= Date() { throw Failure.verification }
            try await store.add(notification(entry, calendar: calendar))
            try check(expected, policy)
        }
        guard await store.authorizationAllowsScheduling(allowPrompt: false) else {
            throw Failure.interrupted(.permissionDenied)
        }
        try check(expected, policy)
        let remaining = obsolete.map(\.identifier).filter { present[$0] != nil }
        if !remaining.isEmpty { store.remove(identifiers: remaining) }
        let verified = await store.pendingSnapshots()
        try check(expected, policy)
        let snapshots = Dictionary(verified.map { ($0.identifier, $0) }, uniquingKeysWith: { _, last in last })
        guard Set(verified.filter { owned($0.identifier) }.map(\.identifier)) == desiredIDs,
              plan.requests.allSatisfy({ matches($0, snapshots[$0.identifier]) }) else { throw Failure.verification }
        return verified
    }

    private func owned(_ id: String) -> Bool { NotificationIdentifiers.allPrefixes.contains { id.hasPrefix($0) } }

    private func matches(_ request: PlannedReminderRequest, _ pending: ReminderScheduler.PendingSnapshot?) -> Bool {
        guard let pending, pending.title == request.title, pending.badge == request.badge else { return false }
        if let body = pending.body, body != request.body { return false }
        switch request.trigger {
        case .calendar(let date):
            guard let fire = pending.fireDate, abs(fire.timeIntervalSince(date)) < 1 else { return false }
            return pending.repeats != true
        case .hourly:
            return pending.fireDate == nil && pending.repeats != false
                && (pending.interval == nil || pending.interval == 3_600)
        }
    }

    private func notification(_ request: PlannedReminderRequest, calendar: Calendar) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        switch request.kind {
        case .reminder: content.title = "⏰ " + request.title
        case .nag: content.title = "🔔 " + request.title
        case .overdue: content.title = request.title
        }
        content.body = request.body; content.sound = .default
        content.userInfo = ["taskID": request.taskID, "title": request.title]
        if let badge = request.badge { content.badge = NSNumber(value: badge) }
        let trigger: UNNotificationTrigger
        switch request.trigger {
        case .calendar(let date):
            trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: date), repeats: false)
        case .hourly: trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3_600, repeats: true)
        }
        return UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger)
    }

    private func digest(_ requests: [PlannedReminderRequest]) -> String {
        let encoded = requests.sorted { $0.identifier < $1.identifier }.map { entry in
            let trigger: String
            switch entry.trigger {
            case .calendar(let date): trigger = String(date.timeIntervalSince1970)
            case .hourly: trigger = "hourly"
            }
            return [entry.identifier, entry.title, entry.body, trigger, entry.badge.map(String.init) ?? "nil"]
                .map { "\($0.utf8.count):\($0)" }.joined()
        }.joined()
        return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
