import Testing
import Foundation
import SwiftData

@testable import NowThis

/// Regression cover for **a deleted task coming back, permanently.**
///
/// Deletion here is soft: the row is marked `isDeletedLocally` and stays until
/// its DELETE has been pushed. Both pull paths built their UID lookup with
/// `&& !$0.isDeletedLocally`, so a task in exactly that window was invisible to
/// the map. The server's copy then matched nothing, was inserted as a **new**
/// row, and the pending DELETE — which names the original — removed the
/// original instead. The user was left with the task still in the list and no
/// longer on the server, and deleting it again just repeated the cycle.
///
/// The pull runs before the push in a sync, and the ctag guard that would
/// normally skip the pull is bypassed by any pending upload, so this needs no
/// unusual timing: one unpushed change anywhere in the list is enough.
///
/// Two halves, and both are needed. Including soft-deleted tasks in the map is
/// what lets the remote copy be *recognised*; the guard in the appliers is what
/// stops it being applied. Without the map change the guard never fires, and
/// without the guard the map change resurrects the task's content instead.
@Suite("Sync deleted-task resurrection")
struct SyncDeletedTaskResurrectionTests {

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

    private func vtodo(uid: String, summary: String = "Buy milk") -> String {
        [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Nextcloud Tasks//EN",
            "BEGIN:VTODO",
            "UID:\(uid)",
            "SUMMARY:\(summary)",
            "STATUS:NEEDS-ACTION",
            "DTSTAMP:20260805T120000Z",
            "LAST-MODIFIED:20260805T120000Z",
            "END:VTODO",
            "END:VCALENDAR"
        ].joined(separator: "\r\n")
    }

    /// A task the user has deleted, whose DELETE has not gone out yet.
    private func awaitingDeletion(uid: String,
                                  in list: TaskList,
                                  context: ModelContext) -> TaskItem {
        let task = TaskItem(uid: uid, title: "Buy milk")
        task.etag = "etag-1"
        task.isDeletedLocally = true
        task.isDirty = true
        context.insert(task)
        task.taskList = list
        return task
    }

    private func remote(uid: String, summary: String = "Buy milk") -> CalDAVClient.RemoteTask {
        CalDAVClient.RemoteTask(href: "/calendars/tasks/\(uid).ics",
                                etag: "etag-2",
                                icsData: vtodo(uid: uid, summary: summary))
    }

    // MARK: - The map has to see it

    /// The bug's origin. A map that filters these out cannot recognise the
    /// server's copy as the task the user just deleted.
    @Test("The pull's UID map includes a task awaiting deletion")
    func uidMapIncludesTasksAwaitingDeletion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()

        let alive = TaskItem(uid: "alive-1", title: "Still here")
        context.insert(alive)
        alive.taskList = list
        _ = awaitingDeletion(uid: "doomed-1", in: list, context: context)
        try context.save()

        let map = engine.testExistingTaskMap(for: list, modelContext: context)

        #expect(map["alive-1"] != nil)
        #expect(map["doomed-1"] != nil, "a task awaiting deletion must still be recognisable")
    }

    // MARK: - The appliers have to refuse it

    @Test("The background pull does not re-create a task awaiting deletion")
    func backgroundPullDoesNotResurrect() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()

        let doomed = awaitingDeletion(uid: "doomed-2", in: list, context: context)
        try context.save()
        var uidMap = engine.testExistingTaskMap(for: list, modelContext: context)

        let changed = try engine.testApplyRemoteTask(
            remote(uid: "doomed-2", summary: "Renamed on the server"),
            taskList: list, uidMap: &uidMap, modelContext: context)
        try context.save()

        #expect(!changed, "nothing about a task on its way out is an inbound change")

        let all = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(all.count == 1, "the server's copy must not be inserted as a second row")
        #expect(doomed.isDeletedLocally, "it must stay deleted, so its DELETE still goes out")
        #expect(doomed.title == "Buy milk", "and its content must not be resurrected")
    }

    @Test("The foreground pull does not re-create a task awaiting deletion")
    func foregroundPullDoesNotResurrect() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()

        let doomed = awaitingDeletion(uid: "doomed-3", in: list, context: context)
        try context.save()
        var uidMap = engine.testExistingTaskMap(for: list, modelContext: context)

        let changed = try engine.testProcessRemoteTask(
            remote(uid: "doomed-3", summary: "Renamed on the server"),
            taskList: list, uidMap: &uidMap, modelContext: context)
        try context.save()

        #expect(!changed)
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(all.count == 1)
        #expect(doomed.isDeletedLocally)
        #expect(doomed.title == "Buy milk")
    }

    /// The guard must be narrow. A task that is merely *dirty* — an ordinary
    /// unpushed edit — is already handled by the dirty gate and must keep
    /// behaving as it did; only `isDeletedLocally` is refused outright.
    @Test("An ordinary task is still applied")
    func anOrdinaryTaskIsStillApplied() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()

        let task = TaskItem(uid: "ordinary-1", title: "Buy milk")
        task.etag = "etag-1"
        task.isDirty = false
        context.insert(task)
        task.taskList = list
        try context.save()
        var uidMap = engine.testExistingTaskMap(for: list, modelContext: context)

        let changed = try engine.testApplyRemoteTask(
            remote(uid: "ordinary-1", summary: "Renamed on the server"),
            taskList: list, uidMap: &uidMap, modelContext: context)

        #expect(changed)
        #expect(task.title == "Renamed on the server")
    }
}
