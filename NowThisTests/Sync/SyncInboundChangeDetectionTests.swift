import Testing
import Foundation
import SwiftData

@testable import NowThis

/// The sync engine must report whether an inbound pull actually changed local
/// data, so the UI can force its `@Query`-backed lists to re-query ONLY when the
/// server delivered something new. A SwiftData `@Query` bound to the main context
/// does not re-emit when the sync engine's background context inserts rows, so
/// the list is rebuilt on demand — but only on a *real* inbound change, otherwise
/// every routine (or push-only) sync would needlessly reset scroll/selection.
/// These tests pin the per-task change detection that gates that refresh.
@Suite("Sync inbound change detection")
struct SyncInboundChangeDetectionTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    private func vtodo(
        uid: String,
        summary: String,
        lastModified: String,
        status: String = "NEEDS-ACTION"
    ) -> String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//NowThis//Test//EN
        BEGIN:VTODO
        UID:\(uid)
        SUMMARY:\(summary)
        STATUS:\(status)
        DTSTAMP:\(lastModified)
        LAST-MODIFIED:\(lastModified)
        END:VTODO
        END:VCALENDAR
        """
    }

    private func makeList(in context: ModelContext) -> TaskList {
        let list = TaskList(serverURL: "/calendars/tasks/", name: "Tasks", colorHex: "#007AFF")
        context.insert(list)
        return list
    }

    @Test("A brand-new server task is inserted and reported as an inbound change")
    func newTaskReportsChange() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        var uidMap: [String: TaskItem] = [:]
        let engine = SyncEngine()

        let remote = CalDAVClient.RemoteTask(
            href: "/calendars/tasks/new.ics",
            etag: "etag-1",
            icsData: vtodo(uid: "srv-new-1", summary: "Server Task", lastModified: "20260629T120000Z")
        )

        let changed = try engine.testApplyRemoteTask(
            remote, taskList: list, uidMap: &uidMap, modelContext: context
        )

        #expect(changed == true)
        #expect(uidMap["srv-new-1"] != nil)
    }

    @Test("An unchanged (older remote) task is not reported as a change")
    func unchangedTaskReportsNoChange() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()

        // Local copy is already newer than the remote payload (server is behind):
        // ~2033 locally vs. 2001 on the wire below.
        let local = TaskItem(uid: "srv-1", title: "Local")
        local.lastModifiedDate = Date(timeIntervalSince1970: 2_000_000_000)
        local.isDirty = false
        local.taskList = list
        context.insert(local)
        var uidMap: [String: TaskItem] = ["srv-1": local]

        let remote = CalDAVClient.RemoteTask(
            href: "/calendars/tasks/srv-1.ics",
            etag: "etag-1",
            icsData: vtodo(uid: "srv-1", summary: "Server", lastModified: "20010101T000000Z")
        )

        let changed = try engine.testApplyRemoteTask(
            remote, taskList: list, uidMap: &uidMap, modelContext: context
        )

        #expect(changed == false)
    }

    @Test("A newer remote edit of an existing task is reported as a change")
    func newerRemoteReportsChange() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()

        let local = TaskItem(uid: "srv-2", title: "Old Title")
        local.lastModifiedDate = Date(timeIntervalSince1970: 1000)
        local.isDirty = false
        local.taskList = list
        context.insert(local)
        var uidMap: [String: TaskItem] = ["srv-2": local]

        let remote = CalDAVClient.RemoteTask(
            href: "/calendars/tasks/srv-2.ics",
            etag: "etag-2",
            icsData: vtodo(uid: "srv-2", summary: "New Title", lastModified: "20260629T120000Z")
        )

        let changed = try engine.testApplyRemoteTask(
            remote, taskList: list, uidMap: &uidMap, modelContext: context
        )

        #expect(changed == true)
        #expect(local.title == "New Title")
    }

    @Test("A server change that bumps the etag but not LAST-MODIFIED is reported as a change")
    func etagChangedWithoutTimestampReportsChange() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()

        // An already-synced task: we hold the server's etag-1 copy, last modified
        // 2026-06-29T12:00:00Z.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let stamp = utc.date(from: DateComponents(year: 2026, month: 6, day: 29, hour: 12, minute: 0, second: 0))!

        let local = TaskItem(uid: "srv-reorder", title: "Reorder Me")
        local.lastModifiedDate = stamp
        local.etag = "etag-1"
        local.isDirty = false
        local.taskList = list
        context.insert(local)
        var uidMap: [String: TaskItem] = ["srv-reorder": local]

        // The server reordered the task (new X-APPLE-SORT-ORDER → new etag) but,
        // as Nextcloud does, kept the client's LAST-MODIFIED verbatim — so the
        // timestamp is unchanged. The etag is the only signal that content moved.
        let remote = CalDAVClient.RemoteTask(
            href: "/calendars/tasks/srv-reorder.ics",
            etag: "etag-2",
            icsData: vtodo(uid: "srv-reorder", summary: "Reorder Me", lastModified: "20260629T120000Z")
        )

        let changed = try engine.testApplyRemoteTask(
            remote, taskList: list, uidMap: &uidMap, modelContext: context
        )

        #expect(changed == true, "A changed etag must count as an inbound change even when LAST-MODIFIED is unchanged")
        #expect(local.etag == "etag-2", "The new server etag must be stored locally")
    }

    @Test("A locally-dirty task is never clobbered and reports no change")
    func dirtyTaskReportsNoChange() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()

        let local = TaskItem(uid: "srv-3", title: "My Local Edit")
        local.lastModifiedDate = Date(timeIntervalSince1970: 1000)
        local.isDirty = true
        local.taskList = list
        context.insert(local)
        var uidMap: [String: TaskItem] = ["srv-3": local]

        let remote = CalDAVClient.RemoteTask(
            href: "/calendars/tasks/srv-3.ics",
            etag: "etag-3",
            icsData: vtodo(uid: "srv-3", summary: "Server Override", lastModified: "20260629T120000Z")
        )

        let changed = try engine.testApplyRemoteTask(
            remote, taskList: list, uidMap: &uidMap, modelContext: context
        )

        #expect(changed == false)
        #expect(local.title == "My Local Edit")
    }
}
