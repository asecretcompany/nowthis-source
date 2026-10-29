import Testing
import Foundation
import SwiftData

@testable import NowThis

/// A moved task's old copy stays on the server until the sweep DELETEs it, and
/// the pull runs before the push in every sync. Without a guard, the source
/// list's next pull finds a UID it has no row for — the row now belongs to the
/// destination — and inserts the stale copy as a second task.
///
/// Both pull paths are covered, as in `SyncDeletedTaskResurrectionTests`:
/// `applyRemoteTask` serves background refresh, `processRemoteTask` the
/// foreground sync a move itself triggers.
@Suite("Sync pending-move pull guard")
struct SyncPendingMovePullGuardTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    private func vtodo(uid: String, summary: String) -> String {
        [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Nextcloud Tasks//EN",
            "BEGIN:VTODO",
            "UID:\(uid)",
            "SUMMARY:\(summary)",
            "STATUS:NEEDS-ACTION",
            "DTSTAMP:20260922T120000Z",
            "LAST-MODIFIED:20260922T120000Z",
            "END:VTODO",
            "END:VCALENDAR"
        ].joined(separator: "\r\n")
    }

    private func remote(uid: String, in path: String, summary: String = "Renew passport") -> CalDAVClient.RemoteTask {
        CalDAVClient.RemoteTask(href: "\(path)\(uid).ics",
                                etag: "etag-server",
                                icsData: vtodo(uid: uid, summary: summary))
    }

    /// Work → Home, synced task, nothing pushed yet.
    private func movedTask(context: ModelContext) throws -> (work: TaskList, home: TaskList, task: TaskItem) {
        let work = TaskList(serverURL: "/cal/work/", name: "Work", colorHex: "#007AFF")
        let home = TaskList(serverURL: "/cal/home/", name: "Home", colorHex: "#FF9500")
        context.insert(work)
        context.insert(home)
        let task = TaskItem(uid: "uid-moved", title: "Renew passport")
        context.insert(task)
        task.taskList = work
        task.remoteHref = "/cal/work/uid-moved.ics"
        task.etag = "etag-1"
        task.isLocalOnly = false
        try context.save()

        TaskMover.move(task, to: home, in: context)
        try context.save()
        return (work, home, task)
    }

    @Test("The background pull does not re-insert a moved task's old copy")
    func backgroundPullSkipsTheStaleCopy() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let engine = SyncEngine()
        let (work, home, task) = try movedTask(context: context)

        var uidMap = engine.testExistingTaskMap(for: work, modelContext: context)
        let movedAway = engine.testPendingMoveUIDs(from: work, modelContext: context)
        let changed = try engine.testApplyRemoteTask(
            remote(uid: "uid-moved", in: "/cal/work/"),
            taskList: work, uidMap: &uidMap, movedAway: movedAway, modelContext: context)
        try context.save()

        #expect(!changed)
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(all.count == 1, "examined \(all.count) tasks — the stale copy must not become a second row")
        #expect(task.taskList?.id == home.id)
    }

    @Test("The foreground pull does not re-insert a moved task's old copy")
    func foregroundPullSkipsTheStaleCopy() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let engine = SyncEngine()
        let (work, home, task) = try movedTask(context: context)

        var uidMap = engine.testExistingTaskMap(for: work, modelContext: context)
        let movedAway = engine.testPendingMoveUIDs(from: work, modelContext: context)
        let changed = try engine.testProcessRemoteTask(
            remote(uid: "uid-moved", in: "/cal/work/"),
            taskList: work, uidMap: &uidMap, movedAway: movedAway, modelContext: context)
        try context.save()

        #expect(!changed)
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(all.count == 1, "examined \(all.count) tasks — the stale copy must not become a second row")
        #expect(task.taskList?.id == home.id)
    }

    @Test("The guard is keyed on the pending move, not on isDirty")
    func guardHoldsAfterThePushClearsIsDirty() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let engine = SyncEngine()
        let (work, _, task) = try movedTask(context: context)

        // The PUT into Home landed; the sweep has not run.
        task.remoteHref = "/cal/home/uid-moved.ics"
        task.etag = "etag-home"
        task.isDirty = false
        try context.save()

        var uidMap = engine.testExistingTaskMap(for: work, modelContext: context)
        let movedAway = engine.testPendingMoveUIDs(from: work, modelContext: context)
        try engine.testProcessRemoteTask(
            remote(uid: "uid-moved", in: "/cal/work/"),
            taskList: work, uidMap: &uidMap, movedAway: movedAway, modelContext: context)
        try context.save()

        let all = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(all.count == 1, "examined \(all.count) tasks")
        #expect(task.remoteHref == "/cal/home/uid-moved.ics", "the destination href must not be overwritten")
    }

    @Test("Other tasks in the source list still arrive")
    func guardIsNarrow() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let engine = SyncEngine()
        let (work, _, _) = try movedTask(context: context)

        var uidMap = engine.testExistingTaskMap(for: work, modelContext: context)
        let movedAway = engine.testPendingMoveUIDs(from: work, modelContext: context)
        #expect(movedAway == ["uid-moved"])

        let changed = try engine.testApplyRemoteTask(
            remote(uid: "uid-new", in: "/cal/work/", summary: "Book dentist"),
            taskList: work, uidMap: &uidMap, movedAway: movedAway, modelContext: context)
        try context.save()

        #expect(changed)
        let inWork = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.taskList?.id == work.id }
        #expect(inWork.map(\.uid) == ["uid-new"])
    }

    @Test("A list with no moves out of it guards nothing")
    func noPendingMovesMeansAnEmptySet() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let engine = SyncEngine()
        let (_, home, _) = try movedTask(context: context)

        // Home is the destination, not a source.
        #expect(engine.testPendingMoveUIDs(from: home, modelContext: context).isEmpty)
    }
}
