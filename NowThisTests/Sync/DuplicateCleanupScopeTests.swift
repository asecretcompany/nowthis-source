import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Scoping the Duplicate Sweep

/// Covers the `listID` scope on ``TaskListHelpers/cleanupDuplicateUIDs(in:listID:)``.
///
/// The sweep ran unscoped at the end of *every* `performFullSync`, fetching every
/// non-deleted `TaskItem` in the store — across every list and every account — and grouping
/// them in memory, whether or not that sync had changed anything. Syncing one account
/// should not walk another's tasks, and a sync that imported nothing should not walk any.
@Suite("Duplicate Sweep — Scope")
@MainActor
struct DuplicateCleanupScopeTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    /// Two tasks sharing a UID, the second one newer.
    private func insertDuplicatePair(
        uid: String,
        into list: TaskList,
        context: ModelContext
    ) {
        let older = TaskItem(uid: uid, title: "Older")
        older.lastModifiedDate = Date(timeIntervalSince1970: 1000)
        older.taskList = list
        context.insert(older)

        let newer = TaskItem(uid: uid, title: "Newer")
        newer.lastModifiedDate = Date(timeIntervalSince1970: 2000)
        newer.taskList = list
        context.insert(newer)
    }

    @Test("Sweeping one list leaves another list's duplicates alone")
    func scopedSweepIgnoresOtherLists() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let listA = TaskList(serverURL: "/calendars/a/", name: "A", colorHex: "#007AFF")
        let listB = TaskList(serverURL: "/calendars/b/", name: "B", colorHex: "#007AFF")
        context.insert(listA)
        context.insert(listB)
        insertDuplicatePair(uid: "dupe-a", into: listA, context: context)
        insertDuplicatePair(uid: "dupe-b", into: listB, context: context)
        try context.save()

        let removed = TaskListHelpers.cleanupDuplicateUIDs(in: context, listID: listA.id)

        #expect(removed == 1, "only list A's duplicate should go")

        let survivors = try context.fetch(FetchDescriptor<TaskItem>())
        let bTasks = survivors.filter { $0.uid == "dupe-b" }
        #expect(bTasks.count == 2,
                "another list's duplicates are not this sync's business to remove")
    }

    @Test("A scoped sweep still keeps the newest of its own duplicates")
    func scopedSweepKeepsNewest() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "/calendars/a/", name: "A", colorHex: "#007AFF")
        context.insert(list)
        insertDuplicatePair(uid: "dupe", into: list, context: context)
        try context.save()

        let removed = TaskListHelpers.cleanupDuplicateUIDs(in: context, listID: list.id)
        try context.save()

        #expect(removed == 1)

        let survivors = try context.fetch(FetchDescriptor<TaskItem>())
            .filter { $0.uid == "dupe" }
        #expect(survivors.count == 1)
        #expect(survivors.first?.title == "Newer", "the newest copy is the one that stays")
    }
}
