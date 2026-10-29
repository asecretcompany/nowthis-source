import Foundation
import SwiftData
import Testing
import UserNotifications

@testable import NowThis

/// **The sweep removes before it knows what to put back.**
///
/// `refreshAllReminders` cancels every `reminder-`/`overdue-`/`nag-` request, *then* fetches the
/// tasks — through a `guard let … else { return }` that walks away leaving the user with nothing
/// pending at all. Ordering the writes the other way round, and comparing against what is already
/// there, makes the pass safe to run as often as we like. That matters because the fix for the
/// missing due-date badge runs it on every local edit and on backgrounding, not just after a sync.
@Suite("Notification reconcile ordering")
@MainActor
struct ReconcileOrderingTests {

    /// Records the order of every call the reconcile makes, so the test can assert on sequence
    /// rather than on end state — the destructive window is invisible in end state alone.
    @MainActor
    final class RecordingNotificationStore: NotificationStore {
        enum Event: Equatable {
            case readPending
            case add(String)
            case remove([String])
        }

        private(set) var events: [Event] = []
        var stored: [ReminderScheduler.PendingSnapshot]
        var isAuthorized: Bool

        init(stored: [ReminderScheduler.PendingSnapshot] = [], isAuthorized: Bool = true) {
            self.stored = stored
            self.isAuthorized = isAuthorized
        }

        func authorizationAllowsScheduling(allowPrompt: Bool) async -> Bool { isAuthorized }

        func pendingSnapshots() async -> [ReminderScheduler.PendingSnapshot] {
            events.append(.readPending)
            return stored
        }

        func add(_ request: UNNotificationRequest) async throws {
            events.append(.add(request.identifier))
        }

        func remove(identifiers: [String]) {
            events.append(.remove(identifiers))
        }

        var addedIdentifiers: [String] {
            events.compactMap { event -> String? in
                if case let .add(identifier) = event { return identifier }
                return nil
            }
        }

        var removedIdentifiers: [String] {
            events.flatMap { event -> [String] in
                if case let .remove(identifiers) = event { return identifiers }
                return []
            }
        }
    }

    /// Saved models belong to the projection worker. It must turn them into Sendable values
    /// without suspending, and the main-actor scheduler must consume only those values.
    @Test("Saved task reads stay isolated and become values before any suspension")
    func noSuspensionAfterTheFetch() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("NowThis/Services/ReminderScheduler.swift"),
            encoding: .utf8)
        let worker = try String(
            contentsOf: root.appendingPathComponent("NowThis/Services/ReminderProjection.swift"),
            encoding: .utf8)
        let coordinator = try String(
            contentsOf: root.appendingPathComponent("NowThis/Services/ReminderReconciliationCoordinator.swift"),
            encoding: .utf8)

        let start = try #require(
            source.range(of: "static func reconcileScheduledNotifications")?.lowerBound,
            "Anti-vacuity: the guarded scheduler entry point moved.")
        let end = try #require(
            source.range(of: "/// Re-schedules all reminders", range: start..<source.endIndex)?.lowerBound,
            "Anti-vacuity: the marker bounding notification reconciliation moved.")
        let body = String(source[start..<end])
        #expect(body.contains("await coordinator"), "The facade must await the serialized owner.")
        #expect(coordinator.contains("await projectionWorker.project(request)"),
                "The scheduler must await the isolated saved-state projection.")
        #expect(!body.contains("modelContext.fetch"),
                "Notification reconciliation must not fetch live tasks on the main actor.")

        let workerStart = try #require(worker.range(of: "func project(_ request:")?.lowerBound)
        let workerEnd = try #require(
            worker.range(of: "/// Rejects results", range: workerStart..<worker.endIndex)?.lowerBound)
        let workerBody = String(worker[workerStart..<workerEnd])
        let fetchAt = try #require(workerBody.range(of: "context.fetch")?.lowerBound,
                                  "Anti-vacuity: the saved-state worker no longer fetches tasks.")
        let tail = workerBody[fetchAt...]
        #expect(tail.contains("saved.map(ReminderTaskInput.init(task:))"),
                "Fetched models must be copied into immutable reminder inputs.")
        #expect(!tail.contains("await"),
                "A saved model cannot survive a suspension before its values are copied.")
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(SchemaV2.models)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test("Every notification is written before anything is cancelled")
    func addsPrecedeRemovals() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = TaskItem(title: "Pay the invoice")
        task.dueDate = Date().addingTimeInterval(3600)
        context.insert(task)

        // A leftover from a task that no longer exists — so the pass has both work to add and
        // work to cancel, and the order between them is observable.
        let store = RecordingNotificationStore(stored: [
            ReminderScheduler.PendingSnapshot(
                identifier: "reminder-gone", fireDate: nil, badge: nil, title: nil)
        ])

        await ReminderScheduler.reconcileScheduledNotifications(modelContext: context, store: store, badgesEnabled: true)

        let firstAdd = try #require(
            store.events.firstIndex { if case .add = $0 { true } else { false } },
            "The task's overdue-badge notification was never scheduled.")
        let firstRemove = try #require(
            store.events.firstIndex { if case .remove = $0 { true } else { false } },
            "The stale leftover was never cancelled.")

        #expect(firstAdd < firstRemove, """
            Cancellation ran before scheduling: \(store.events). Between those two calls the user
            has fewer pending notifications than they should, and any early return in between
            leaves them with none.
            """)
        #expect(store.addedIdentifiers == ["overdue-\(task.id)"])
        #expect(store.removedIdentifiers == ["reminder-gone"])
    }

    @Test("Reconciling twice touches nothing the second time")
    func secondPassIsANoOp() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = TaskItem(title: "Renew the domain")
        task.dueDate = Date().addingTimeInterval(7200)
        context.insert(task)

        let first = RecordingNotificationStore()
        await ReminderScheduler.reconcileScheduledNotifications(modelContext: context, store: first, badgesEnabled: true)
        #expect(first.addedIdentifiers == ["overdue-\(task.id)"], "First pass must schedule it.")

        // Feed the first pass's own output back in as what iOS now holds.
        let plan = ReminderScheduler.planNotifications(
            tasks: [task], now: Date(), maxCount: 60, badgesEnabled: true)
        let second = RecordingNotificationStore(stored: plan.map {
            ReminderScheduler.PendingSnapshot(
                identifier: $0.identifier, fireDate: $0.fireDate, badge: $0.badge, title: $0.title)
        })

        await ReminderScheduler.reconcileScheduledNotifications(modelContext: context, store: second, badgesEnabled: true)

        #expect(second.addedIdentifiers.isEmpty, """
            The second pass rewrote \(second.addedIdentifiers) although nothing changed. Running
            this on every edit would churn the pending set constantly.
            """)
        #expect(second.removedIdentifiers.isEmpty)
    }

    @Test("A pass that is not allowed to schedule cancels nothing")
    func deniedAuthorizationCancelsNothing() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = TaskItem(title: "Book the flights")
        task.dueDate = Date().addingTimeInterval(3600)
        context.insert(task)

        let store = RecordingNotificationStore(
            stored: [ReminderScheduler.PendingSnapshot(
                identifier: "overdue-stale", fireDate: nil, badge: nil, title: nil)],
            isAuthorized: false)

        await ReminderScheduler.reconcileScheduledNotifications(modelContext: context, store: store, badgesEnabled: true)

        #expect(store.addedIdentifiers.isEmpty)
        #expect(store.removedIdentifiers.isEmpty, """
            With notifications denied the pass can schedule nothing, so it must also cancel
            nothing — otherwise re-granting permission would find an empty pending set with no
            pass having run to refill it.
            """)
    }
}
