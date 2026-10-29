import Foundation
import Testing

@testable import NowThis

/// **The sync engine handed its reschedule to a Task nobody waits for.**
///
/// Both sync paths ended with `await MainActor.run { Task { @MainActor in await
/// refreshAllReminders(…) } }`. The inner unstructured `Task` is not part of `syncTask.value`, so
/// `BackgroundSyncManager` called `setTaskCompleted(success:)` the moment the sync returned and
/// iOS suspended the process — possibly before a single notification had been written.
///
/// And the background handler only ever did anything for `.nextcloud` accounts. A Vault-Mode user
/// has none, so `scheduleBackgroundSync()` was called for them on every backgrounding and the
/// task, when it fired, did nothing at all. That is the one periodic re-plan a local-only account
/// could have had.
@Suite("Sync rescheduling")
struct SyncReschedulingGuardTests {

    private func source(_ relativePath: String) throws -> String {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("Both sync paths await their reschedule instead of firing it off")
    func syncAwaitsItsReschedule() throws {
        let engine = try source("NowThis/Sync/SyncEngine.swift")

        let awaited = engine.components(separatedBy: "await ReminderScheduler.reconcileNow").count - 1
        #expect(awaited == 2, """
            Expected the full sync and the background sync each to await one reschedule, found
            \(awaited). Both are load-bearing: the background one runs with the BGTask's clock
            already ticking.
            """)

        #expect(!engine.contains("Task { @MainActor in"), """
            SyncEngine still hands its reschedule to an unstructured Task. Nothing awaits it, so
            BackgroundSyncManager reports the BGTask complete while it is still running and iOS
            suspends the process mid-pass.
            """)
    }

    @Test("Background refresh re-plans even when there are no accounts to sync")
    func backgroundRefreshReplansWithinItsLiveBudget() throws {
        let manager = try source("NowThis/Sync/BackgroundSyncManager.swift")

        let reconcileAt = try #require(
            manager.range(of: "await ReminderScheduler.reconcileNow")?.lowerBound, """
            The background refresh never re-plans notifications on its own. For a Vault-Mode
            account the sync loop body never runs, so nothing in the entire app schedules the
            overdue-badge notification that moves the icon while the app is closed.
            """)

        let helper = try #require(manager.range(of: "static func performRun("))
        let awaitedFlush = try #require(manager.range(of: "await flush()", range: helper.upperBound..<manager.endIndex))
        let returnCompleted = try #require(manager.range(of: "return completed", range: helper.upperBound..<manager.endIndex))
        #expect(awaitedFlush.lowerBound < returnCompleted.lowerBound, "A live run must await local recovery before reporting completion")
        #expect(manager.contains("}, flush: {"), "The BG runner must supply a flush closure for local-only accounts")

        // A rejected delivery with no opened store cannot read or re-plan SQLite data.
        // Inspect the actual sync handler's completion, not that early rejection path.
        #expect(manager.contains("try budget.checkFinalAdmission()"),
            "An expired delivery cannot begin another flush; behavioral tests cover partial progress and expiration")
        let handler = try #require(manager.range(of: "private func handleBackgroundSync("))
        let completedAt = try #require(
            manager.range(of: "setTaskCompleted", range: handler.upperBound..<manager.endIndex)?.lowerBound,
            "Anti-vacuity: the BGTask completion call is gone.")
        #expect(reconcileAt < completedAt, """
            The re-plan is issued after the BGTask is reported complete. iOS suspends the process
            at that point and the pass never finishes.
            """)
    }
}
