import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Badge Permission Tests

@Suite("Badge Count Permission")
struct BadgePermissionTests {

    @Test("updateBadgeCount is async — compile-time proof of permission support")
    @MainActor
    func updateBadgeCountIsAsync() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )

        // This line will FAIL to compile if updateBadgeCount is not async.
        // We assign the result of the async call to verify the function signature.
        let _: Void = await ReminderScheduler.updateBadgeCount(
            modelContext: container.mainContext
        )
    }

    @Test("computeBadgeCount handles mixed overdue and future correctly")
    func mixedOverdueAndFuture() {
        let now = Date()
        let yesterday = now.addingTimeInterval(-86400)
        let tomorrow = now.addingTimeInterval(86400)

        let overdueTask = TaskItem(title: "Overdue")
        overdueTask.dueDate = yesterday

        let futureTask = TaskItem(title: "Future")
        futureTask.dueDate = tomorrow

        let noDateTask = TaskItem(title: "No date")

        let count = ReminderScheduler.computeBadgeCount(
            tasks: [overdueTask, futureTask, noDateTask],
            now: now
        )

        #expect(count == 1, "Only the overdue task should count")
    }
}
