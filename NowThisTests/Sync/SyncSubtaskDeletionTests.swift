import Testing
import Foundation
import SwiftData

@testable import NowThis

/// Regression cover for **deleting a parent orphaning its subtasks on the
/// server, and the next pull bringing them back as top-level tasks.**
///
/// Deletion is soft — the row is flagged `isDeletedLocally` and waits for its
/// DELETE — but only the task the user actually swiped was ever flagged.
/// `findDeletedTasks` returns exactly the flagged rows, so only the parent's
/// DELETE went out. SwiftData's cascade then removed the children locally when
/// the parent was hard-deleted, while their copies sat untouched on the server,
/// and the next pull re-created them with no parent to attach to.
///
/// So the user lost two subtasks locally, gained two unrelated top-level tasks,
/// and the server was left holding both.
///
/// ## Why order matters
///
/// `pushDeletion` hard-deletes each task after its DELETE succeeds, and that
/// hard delete cascades. Push the parent first and the children are gone from
/// the context before their own DELETEs are sent — the same orphaning, just
/// arrived at differently. Children go first, deepest first, so every DELETE
/// that has been sent belongs to a row that no longer has anything under it.
@Suite("Sync subtask deletion")
struct SyncSubtaskDeletionTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    private func makeList(in context: ModelContext) -> TaskList {
        let list = TaskList(serverURL: "/calendars/tasks/", name: "Tasks", colorHex: "#007AFF")
        context.insert(list)
        return list
    }

    @discardableResult
    private func task(_ uid: String,
                      under parent: TaskItem? = nil,
                      in list: TaskList,
                      context: ModelContext) -> TaskItem {
        let item = TaskItem(uid: uid, title: uid)
        item.remoteHref = "/calendars/tasks/\(uid).ics"
        item.isDirty = false
        context.insert(item)
        item.taskList = list
        item.parentTask = parent
        return item
    }

    /// `Trip` with two children, one of which has a child of its own — so the
    /// recursion is actually exercised rather than one level of it.
    private func trip(in list: TaskList, context: ModelContext)
    -> (parent: TaskItem, flight: TaskItem, pack: TaskItem, socks: TaskItem) {
        let parent = task("trip", in: list, context: context)
        let flight = task("flight", under: parent, in: list, context: context)
        let pack = task("pack", under: parent, in: list, context: context)
        let socks = task("socks", under: pack, in: list, context: context)
        return (parent, flight, pack, socks)
    }

    @Test("Deleting a parent marks its whole subtree deleted")
    func deletingAParentMarksItsSubtree() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let t = trip(in: list, context: context)
        try context.save()

        TaskListHelpers.markDeleted(t.parent)

        for item in [t.parent, t.flight, t.pack, t.socks] {
            #expect(item.isDeletedLocally, "\(item.uid) must be marked deleted")
            #expect(item.isDirty, "\(item.uid) must be queued for its own DELETE")
        }
    }

    @Test("Every task in the deleted subtree is queued for pushing")
    func wholeSubtreeIsQueuedForPushing() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let t = trip(in: list, context: context)
        try context.save()

        TaskListHelpers.markDeleted(t.parent)
        try context.save()

        let queued = SyncEngine().testFindDeletedTasks(for: list, modelContext: context)
        #expect(Set(queued) == ["trip", "flight", "pack", "socks"])
    }

    /// The ordering guarantee, stated as the invariant rather than as one
    /// expected array: no task may be pushed before something beneath it.
    @Test("A child is always pushed before its parent")
    func childrenArePushedBeforeParents() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let t = trip(in: list, context: context)
        try context.save()

        TaskListHelpers.markDeleted(t.parent)
        try context.save()

        let order = SyncEngine().testFindDeletedTasks(for: list, modelContext: context)
        func position(_ uid: String) throws -> Int {
            try #require(order.firstIndex(of: uid), "\(uid) missing from the push order")
        }

        #expect(try position("socks") < position("pack"))
        #expect(try position("pack") < position("trip"))
        #expect(try position("flight") < position("trip"))
    }

    /// Deleting a subtask is not deleting its parent. The recursion goes down
    /// only.
    @Test("Deleting a subtask leaves its parent alone")
    func deletingASubtaskLeavesTheParentAlone() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let t = trip(in: list, context: context)
        try context.save()

        TaskListHelpers.markDeleted(t.pack)
        try context.save()

        #expect(t.pack.isDeletedLocally)
        #expect(t.socks.isDeletedLocally, "the subtask's own child still goes with it")
        #expect(!t.parent.isDeletedLocally)
        #expect(!t.flight.isDeletedLocally)
    }

    /// The caller needs the ids to cancel notifications with. A subtask's
    /// reminders are as real as its parent's, and the row offering the delete
    /// only ever knew its own.
    @Test("Marking returns every id it marked, so their reminders can be cancelled")
    func markingReturnsTheSubtreesIDs() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let t = trip(in: list, context: context)
        try context.save()

        let marked = TaskListHelpers.markDeleted(t.parent)

        #expect(Set(marked) == Set([t.parent, t.flight, t.pack, t.socks].map(\.id)))
        #expect(marked.count == 4, "no id appears twice")
    }

    /// A task already on its way out must not be re-marked and re-dirtied on a
    /// second pass — and a cycle in the tree, however it got there, must not
    /// hang the walk.
    @Test("Marking an already-deleted subtree terminates")
    func markingTwiceTerminates() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let t = trip(in: list, context: context)
        try context.save()

        TaskListHelpers.markDeleted(t.parent)
        TaskListHelpers.markDeleted(t.parent)

        let queued = SyncEngine().testFindDeletedTasks(for: list, modelContext: context)
        #expect(queued.count == 4, "each task appears once")
    }
}
