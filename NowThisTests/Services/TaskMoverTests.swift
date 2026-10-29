import Testing
import Foundation
import SwiftData

@testable import NowThis

/// Moving a task between lists is a cross-collection CalDAV operation, not a
/// field assignment: the row keeps its identity while its *server* copy has to
/// be created in the destination and removed from the source. These cover the
/// local half — what `TaskMover` records for the sync engine to act on.
@Suite("Task Mover")
struct TaskMoverTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    private func makeList(
        _ name: String,
        path: String,
        in context: ModelContext
    ) -> TaskList {
        let list = TaskList(serverURL: "https://example.test\(path)", name: name, colorHex: "#007AFF")
        list.calendarPath = path
        context.insert(list)
        return list
    }

    private func makeSyncedTask(
        uid: String,
        title: String,
        in list: TaskList,
        context: ModelContext
    ) -> TaskItem {
        let task = TaskItem(uid: uid, title: title)
        task.taskList = list
        task.remoteHref = "\(list.calendarPath ?? "")\(uid).ics"
        task.etag = "etag-\(uid)"
        task.isLocalOnly = false
        task.isDirty = false
        context.insert(task)
        return task
    }

    // MARK: - Spec §8, case 1

    @Test("A synced task records the href it must be removed from, and keeps its identity")
    func syncedTaskRecordsPendingMove() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let source = makeList("Work", path: "/cal/work/", in: context)
        let destination = makeList("Home", path: "/cal/home/", in: context)
        let task = makeSyncedTask(uid: "uid-1", title: "Renew passport", in: source, context: context)
        try context.save()

        let originalID = task.id
        let originalUID = task.uid

        TaskMover.move(task, to: destination, in: context)

        #expect(task.taskList?.id == destination.id)
        #expect(task.pendingMoveFromHref == "/cal/work/uid-1.ics")
        #expect(task.pendingMoveFromListID == source.id)
        #expect(task.remoteHref == nil, "the old href must not be reused for the PUT into the destination")
        #expect(task.etag == nil, "a create in a new collection carries no If-Match")
        #expect(task.isDirty)

        // Identity is load-bearing: deep links, notification identifiers,
        // Spotlight entries and journal associations all key off these.
        #expect(task.id == originalID)
        #expect(task.uid == originalUID)
    }

    // MARK: - Spec §8, case 2

    @Test("A task that was never pushed owes the server nothing")
    func localOnlyTaskRecordsNoPendingMove() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let source = makeList("Work", path: "/cal/work/", in: context)
        let destination = makeList("Home", path: "/cal/home/", in: context)

        let task = TaskItem(uid: "uid-local", title: "Buy milk")
        task.taskList = source
        task.isLocalOnly = true
        task.remoteHref = nil
        context.insert(task)
        try context.save()

        TaskMover.move(task, to: destination, in: context)

        #expect(task.taskList?.id == destination.id)
        #expect(task.pendingMoveFromHref == nil, "nothing was ever created on the server to delete")
        #expect(task.pendingMoveFromListID == nil)
        #expect(task.isDirty)
    }

    // MARK: - Spec §8, case 3

    @Test("The whole subtree moves, each node carrying its own href, deepest first")
    func subtreeMovesWithItsOwnHrefs() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let source = makeList("Work", path: "/cal/work/", in: context)
        let destination = makeList("Home", path: "/cal/home/", in: context)

        let parent = makeSyncedTask(uid: "uid-p", title: "Ship release", in: source, context: context)
        let child = makeSyncedTask(uid: "uid-c", title: "Write notes", in: source, context: context)
        let grandchild = makeSyncedTask(uid: "uid-g", title: "Translate notes", in: source, context: context)
        child.parentTask = parent
        child.parentUID = parent.uid
        grandchild.parentTask = child
        grandchild.parentUID = child.uid
        try context.save()

        let moved = TaskMover.move(parent, to: destination, in: context)

        #expect(moved.count == 3, "examined \(moved.count) nodes — the whole subtree must move")

        for node in [parent, child, grandchild] {
            #expect(node.taskList?.id == destination.id, "\(node.uid) should be in the destination")
        }

        // Each subtask is its own VTODO resource, so each owes its own DELETE.
        #expect(parent.pendingMoveFromHref == "/cal/work/uid-p.ics")
        #expect(child.pendingMoveFromHref == "/cal/work/uid-c.ics")
        #expect(grandchild.pendingMoveFromHref == "/cal/work/uid-g.ics")

        // Deepest first — `findDeletedTasks` documents this ordering as a
        // contract, because a hard delete cascades to children.
        #expect(moved.first?.uid == "uid-g")
        #expect(moved.last?.uid == "uid-p")

        // The hierarchy itself survives; only the collection changed.
        #expect(child.parentTask?.uid == parent.uid)
        #expect(grandchild.parentUID == child.uid)
    }

    // MARK: - Spec §8, case 4

    @Test("Moving a subtask alone promotes it, clearing both the link and the UID")
    func loneSubtaskIsDetachedFromItsParent() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let source = makeList("Work", path: "/cal/work/", in: context)
        let destination = makeList("Home", path: "/cal/home/", in: context)

        let parent = makeSyncedTask(uid: "uid-p", title: "Ship release", in: source, context: context)
        let child = makeSyncedTask(uid: "uid-c", title: "Write notes", in: source, context: context)
        child.parentTask = parent
        child.parentUID = parent.uid
        try context.save()

        TaskMover.move(child, to: destination, in: context)

        #expect(child.taskList?.id == destination.id)
        #expect(child.parentTask == nil)
        // Clearing only the relationship is not enough: resolveParentRelationships
        // re-reads parentUID on every sync and would re-link or strand it.
        #expect(child.parentUID == nil)

        // The parent is untouched — it is not part of the move.
        #expect(parent.taskList?.id == source.id)
        #expect(parent.pendingMoveFromHref == nil)
        #expect(parent.remoteHref == "/cal/work/uid-p.ics")
    }

    // MARK: - Moves that overlap an earlier one

    @Test("A second move before sync still owes the DELETE from where the task began")
    func secondMoveKeepsTheOriginalPendingHref() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let work = makeList("Work", path: "/cal/work/", in: context)
        let home = makeList("Home", path: "/cal/home/", in: context)
        let errands = makeList("Errands", path: "/cal/errands/", in: context)
        let task = makeSyncedTask(uid: "uid-1", title: "Renew passport", in: work, context: context)
        try context.save()

        TaskMover.move(task, to: home, in: context)
        TaskMover.move(task, to: errands, in: context)

        #expect(task.taskList?.id == errands.id)
        // Home never received a copy, so Work's is still the only one on the server.
        #expect(task.pendingMoveFromHref == "/cal/work/uid-1.ics")
        #expect(task.pendingMoveFromListID == work.id)
        #expect(task.remoteHref == nil)
    }

    @Test("Moving back before sync cancels the move instead of deleting the only copy")
    func moveBackBeforeSyncCancelsThePendingMove() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let work = makeList("Work", path: "/cal/work/", in: context)
        let home = makeList("Home", path: "/cal/home/", in: context)
        let task = makeSyncedTask(uid: "uid-1", title: "Renew passport", in: work, context: context)
        try context.save()

        TaskMover.move(task, to: home, in: context)
        TaskMover.move(task, to: work, in: context)

        #expect(task.taskList?.id == work.id)
        #expect(task.remoteHref == "/cal/work/uid-1.ics", "it is back where its server copy is")
        #expect(task.pendingMoveFromHref == nil, "a DELETE now would remove the task it is sitting on")
        #expect(task.pendingMoveFromListID == nil)
        #expect(task.isDirty)
    }

    @Test("Moving again after the PUT landed leaves a tombstone for the intermediate copy")
    func moveAfterPutTombstonesTheIntermediateCopy() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let work = makeList("Work", path: "/cal/work/", in: context)
        let home = makeList("Home", path: "/cal/home/", in: context)
        let errands = makeList("Errands", path: "/cal/errands/", in: context)
        let task = makeSyncedTask(uid: "uid-1", title: "Renew passport", in: work, context: context)
        try context.save()

        TaskMover.move(task, to: home, in: context)
        // The PUT into Home succeeded; the DELETE from Work has not run yet.
        task.remoteHref = "/cal/home/uid-1.ics"
        task.etag = "etag-home"
        task.isDirty = false
        try context.save()

        TaskMover.move(task, to: errands, in: context)
        try context.save()

        #expect(task.taskList?.id == errands.id)
        #expect(task.pendingMoveFromHref == "/cal/work/uid-1.ics", "Work's copy is still owed")
        #expect(task.remoteHref == nil)

        // Home's copy is owed a DELETE too. The existing deletion push sends it
        // and then removes the tombstone row.
        let tombstones = try context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.isDeletedLocally }
        ))
        #expect(tombstones.count == 1, "examined \(tombstones.count) tombstones")
        #expect(tombstones.first?.uid == "uid-1")
        #expect(tombstones.first?.taskList?.id == home.id)
        #expect(tombstones.first?.remoteHref == "/cal/home/uid-1.ics")
        #expect(tombstones.first?.id != task.id, "the moved task keeps its own identity")
    }

    @Test("A subtask already awaiting its DELETE stays behind in the source list")
    func softDeletedSubtaskIsNotMoved() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let source = makeList("Work", path: "/cal/work/", in: context)
        let destination = makeList("Home", path: "/cal/home/", in: context)
        let parent = makeSyncedTask(uid: "uid-p", title: "Ship release", in: source, context: context)
        let deleted = makeSyncedTask(uid: "uid-d", title: "Old step", in: source, context: context)
        deleted.parentTask = parent
        deleted.parentUID = parent.uid
        deleted.isDeletedLocally = true
        try context.save()

        let moved = TaskMover.move(parent, to: destination, in: context)

        #expect(moved.count == 1, "examined \(moved.count) nodes")
        // Its DELETE targets the source href; moving it would lose that href.
        #expect(deleted.taskList?.id == source.id)
        #expect(deleted.remoteHref == "/cal/work/uid-d.ics")
        #expect(deleted.pendingMoveFromHref == nil)
    }

    @Test("Moving a task to the list it is already in changes nothing")
    func moveToSameListIsANoOp() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let work = makeList("Work", path: "/cal/work/", in: context)
        let task = makeSyncedTask(uid: "uid-1", title: "Renew passport", in: work, context: context)
        try context.save()

        let moved = TaskMover.move(task, to: work, in: context)

        #expect(moved.isEmpty)
        #expect(task.remoteHref == "/cal/work/uid-1.ics")
        #expect(task.pendingMoveFromHref == nil)
        #expect(!task.isDirty)
    }
}
