import Testing
import Foundation
import SwiftData

@testable import NowThis

@Suite("SyncScheduler Widget Coherency")
struct SyncSchedulerWidgetReloadTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    @Test("A successful sync reloads widget timelines")
    @MainActor
    func successfulSyncReloadsWidget() async throws {
        let container = try makeContainer()

        var reloaded = false
        let scheduler = SyncScheduler(onWidgetReload: { reloaded = true })

        // No accounts configured → sync completes successfully with nothing to do.
        await scheduler.syncNow(modelContext: container.mainContext)

        #expect(reloaded, "Widget timelines should be reloaded after a successful sync")
        #expect(scheduler.lastError == nil)
    }
}

@Suite("SyncScheduler Cancellation")
struct SyncSchedulerCancellationTests {

    @Test("cancelInflightSync cancels a running foreground sync task")
    func cancelInflightSyncCancelsForegroundTask() async throws {
        let tracker = CancellationTracker()

        await MainActor.run {
            let scheduler = SyncScheduler()

            scheduler.startTrackedTask {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch is CancellationError {
                    await tracker.markCancelled()
                } catch {}
            }

            // Cancel immediately
            scheduler.cancelInflightSync()
        }

        // Give cancellation time to propagate
        try await Task.sleep(for: .milliseconds(300))

        let wasCancelled = await tracker.isCancelled
        #expect(wasCancelled, "Expected the foreground sync task to be cancelled")
    }

    @Test("cancelInflightSync is safe to call with no inflight work")
    func cancelInflightSyncNoOp() async {
        await MainActor.run {
            let scheduler = SyncScheduler()
            // Should not crash or have side effects
            scheduler.cancelInflightSync()
            #expect(!scheduler.isSyncing)
        }
    }
}

// MARK: - Test Helpers

/// Thread-safe tracker for cancellation state in tests.
private actor CancellationTracker {
    var isCancelled = false

    func markCancelled() {
        isCancelled = true
    }
}
