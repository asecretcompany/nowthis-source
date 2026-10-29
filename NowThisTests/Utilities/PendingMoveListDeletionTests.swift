import Testing
import Foundation
import SwiftData

@testable import NowThis

/// `TaskList.tasks` cascades. Delete the list a task was just moved into and the
/// task goes with it — and so do its pending-move fields, the only record that
/// its old copy in the source list is still owed a DELETE. The source list's next
/// pull then re-imports that copy: the task the user deleted comes back.
@Suite("Pending moves survive deleting the destination list")
struct PendingMoveListDeletionTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    private func setUp(_ context: ModelContext) throws -> (work: TaskList, home: TaskList, task: TaskItem) {
        let work = TaskList(serverURL: "/cal/work/", name: "Work", colorHex: "#007AFF")
        let home = TaskList(serverURL: "/cal/home/", name: "Home", colorHex: "#FF9500")
        context.insert(work)
        context.insert(home)
        let task = TaskItem(uid: "uid-1", title: "Renew passport")
        context.insert(task)
        task.taskList = work
        task.remoteHref = "/cal/work/uid-1.ics"
        task.etag = "etag-1"
        task.isLocalOnly = false
        try context.save()
        TaskMover.move(task, to: home, in: context)
        try context.save()
        return (work, home, task)
    }

    private func deleteList(_ list: TaskList, in context: ModelContext) throws {
        TaskListHelpers.settlePendingMoves(beforeDeleting: list, in: context)
        context.delete(list)
        try context.save()
    }

    private func onlyTombstone(in context: ModelContext) throws -> TaskItem? {
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(all.count == 1, "examined \(all.count) tasks")
        return all.first
    }

    @Test("Before the PUT: the source copy is still owed its DELETE")
    func deletingDestinationBeforePutLeavesATombstone() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let (work, home, _) = try setUp(context)

        try deleteList(home, in: context)

        let tombstone = try onlyTombstone(in: context)
        #expect(tombstone?.isDeletedLocally == true)
        #expect(tombstone?.taskList?.id == work.id)
        #expect(tombstone?.remoteHref == "/cal/work/uid-1.ics")
        #expect(tombstone?.etag == nil, "the source copy's etag was dropped by the move; DELETE unconditionally")
    }

    @Test("After the PUT: the source copy is still owed its DELETE")
    func deletingDestinationAfterPutLeavesATombstone() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let (work, home, task) = try setUp(context)
        task.remoteHref = "/cal/home/uid-1.ics"
        task.etag = "etag-home"
        task.isDirty = false
        try context.save()

        try deleteList(home, in: context)

        let tombstone = try onlyTombstone(in: context)
        #expect(tombstone?.isDeletedLocally == true)
        #expect(tombstone?.taskList?.id == work.id)
        #expect(tombstone?.remoteHref == "/cal/work/uid-1.ics",
                "the source href, not the destination's — that one goes with the list")
    }

    @Test("Tasks without a pending move are left to the cascade")
    func ordinaryTasksAreUntouched() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let home = TaskList(serverURL: "/cal/home/", name: "Home", colorHex: "#FF9500")
        context.insert(home)
        let task = TaskItem(uid: "uid-2", title: "Water plants")
        context.insert(task)
        task.taskList = home
        try context.save()

        try deleteList(home, in: context)

        let all = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(all.isEmpty, "examined \(all.count) tasks")
    }
}
