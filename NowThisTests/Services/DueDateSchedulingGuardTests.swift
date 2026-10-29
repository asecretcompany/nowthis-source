import Foundation
import Testing

@testable import NowThis

/// **The app icon badge was a side effect of a successful CalDAV sync.**
///
/// The only thing that moves a badge while the app is closed is a notification that is already
/// pending and carries `content.badge`. The only producer of those is `scheduleOverdueBadge`,
/// whose only caller is the bulk reconcile, whose only callers were `SyncEngine.performFullSync`
/// and `performBackgroundSync` — both reached only for accounts where `mode == .nextcloud`.
///
/// So: a Vault-Mode user never scheduled one in the app's entire lifetime, and neither did a task
/// created by Siri or dragged to a new day in the calendar. The user created a task with a due
/// date, the due date passed, and the badge showed nothing until they next opened the app —
/// which is exactly when it was too late to be useful.
///
/// Scheduling has to follow the local write, not the sync. Every path that puts a due date on a
/// task must say so.
@Suite("Due-date writes reschedule notifications")
struct DueDateSchedulingGuardTests {
    @Test("Detail title and status edits use the save boundary before any dismissal route")
    func detailEditCallbacksDoNotDependOnDone() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let source = try String(contentsOf: root.appendingPathComponent(
            "NowThis/Views/Tasks/TaskDetailView.swift"), encoding: .utf8)
        #expect(source.contains(".onChange(of: task.title) { _, _ in reminderEditDidChange() }"))
        #expect(source.contains(".onChange(of: task.status) { _, _ in reminderEditDidChange() }"))
        #expect(source.contains("Self.saveReminderEdit(task, in: modelContext)"))
    }

    /// Files that write a due date but correctly leave the rescheduling to someone else.
    private static let exempt = [
        // Already reconciles at the end of every sync, in both directions.
        "NowThis/Sync/",
        // Parses into detached model objects that are never the live task.
        "NowThis/Parser/",
        "NowThis/Models/",
        // The scheduler itself.
        "NowThis/Services/ReminderScheduler.swift",
        // Pure logic with no ModelContext of its own: it advances a recurring task's due date
        // and its callers own the reschedule that follows.
        "NowThis/Utilities/TaskCompletionLogic.swift",
        // Compiled only in the isolated Performance configuration; the app's awaited
        // launch/run reconciliation covers the prepared fixture, never a user store.
        "NowThis/Utilities/PerformanceLaunchFixture.swift",
    ]

    @Test("Every path that writes a task's due date asks the scheduler to re-plan")
    func dueDateWritesReschedule() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let appRoot = root.appendingPathComponent("NowThis")
        let walker = try #require(
            FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))

        var writers: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if Self.exempt.contains(where: { relative.hasPrefix($0) }) { continue }

            let source = try String(contentsOf: url, encoding: .utf8)
            // An assignment to a live task, not a read into a snapshot.
            guard source.contains("task.dueDate = ") else { continue }
            writers.append(relative)

            // Either trigger satisfies this: the coalesced one for UI paths, the awaited one
            // for the intents, whose container does not outlive `perform()`.
            let replans = source.contains("ReminderScheduler.requestReconcile")
                || source.contains("ReminderScheduler.reconcileNow")
            #expect(replans, """
                \(relative) writes a task's due date but never asks ReminderScheduler to re-plan.
                Nothing carrying `content.badge` gets registered for that task, so the app icon
                badge cannot move when the due date passes — it stays wrong until the app is next
                opened. Before this guard existed, only a successful CalDAV sync ever scheduled
                one, and a Vault-Mode account never syncs at all.
                """)
        }

        // A scanner that examines zero files reports success.
        #expect(writers.count >= 9, """
            Expected at least 9 due-date write sites, found \(writers.count): \(writers).
            The scan has gone stale — widen it rather than lowering the floor.
            """)
    }

    /// An App Intent builds a throwaway `ModelContainer` with `SharedModelContainer.create()` and
    /// holds it only for the body of `perform()`. `requestReconcile` returns immediately and does
    /// its work 400ms later, by which point that container — and the store behind it — is gone.
    /// The intents must therefore await the pass instead of coalescing it.
    @Test("App Intents await their re-plan rather than deferring it past their container")
    func intentsAwaitTheirReplan() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()

        for file in [
            "NowThis/Intents/CreateTaskIntent.swift",
            "NowThis/Intents/QuickAddTaskIntent.swift",
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(source.contains("SharedModelContainer.create"), """
                Scanning the wrong file: \(file) does not build its own container, so this rule
                does not apply to it.
                """)
            #expect(source.contains("await ReminderScheduler.reconcileNow"), """
                \(file) defers its re-plan past the life of the container it created. The pass
                runs 400ms after `perform()` returns and fetches through a context whose container
                has been released — so a task added by Siri schedules nothing, which is the exact
                path this change set out to fix.
                """)
            #expect(!source.contains("ReminderScheduler.requestReconcile"), """
                \(file) still uses the coalesced trigger. It also shares one static slot with the
                running app, so an intent firing while the app is open cancels the app's own
                pending pass.
                """)
        }
    }

    /// The completion paths advance a recurring task's due date through `TaskCompletionLogic`,
    /// which is exempt above precisely because these callers are responsible for it.
    @Test("The completion paths re-plan after advancing a recurrence")
    func completionPathsReschedule() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()

        for file in [
            "NowThis/Views/Tasks/TaskRowView.swift",
            "NowThis/Views/Kanban/KanbanBoardView.swift",
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(source.contains("ReminderScheduler.cancelReminder"),
                    "Scanning the wrong file: \(file) is not a completion path.")
            // Either trigger satisfies this: the coalesced one for UI paths, the awaited one
            // for the intents, whose container does not outlive `perform()`.
            let replans = source.contains("ReminderScheduler.requestReconcile")
                || source.contains("ReminderScheduler.reconcileNow")
            #expect(replans, """
                \(file) completes tasks. Completing a recurring task advances its due date to the
                next occurrence, and nothing schedules a notification for that occurrence unless
                this path asks for a re-plan. Updating the badge alone is not enough: the badge
                set here is only correct until the app is closed.
                """)
        }
    }
}
