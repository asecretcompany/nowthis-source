import Testing
import Foundation
import SwiftData

@testable import NowThis

/// Regression cover for "changes made on the server don't reach the device":
/// a task completed in Nextcloud stayed open in NowThis, and a priority set in
/// Nextcloud arrived as "None".
///
/// The two symptoms share a shape — they are *updates to a task the device
/// already has*, not insertions — so these tests walk that path in the three
/// places it can break:
///
/// 1. the field mapping (`applyTodoData` → `TaskItem`),
/// 2. the inbound gate (`applyRemoteTask`: dirty / etag / LAST-MODIFIED),
/// 3. cross-context visibility (sync writes on a background `ModelContext`;
///    the UI reads the main context).
@Suite("Inbound server-side update propagation")
struct SyncInboundUpdatePropagationTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    private func makeList(in context: ModelContext) -> TaskList {
        let list = TaskList(serverURL: "/calendars/tasks/", name: "Tasks", colorHex: "#007AFF")
        context.insert(list)
        return list
    }

    /// A VTODO shaped like the one Nextcloud Tasks writes.
    private func vtodo(
        uid: String,
        summary: String = "Buy milk",
        lastModified: String,
        status: String = "NEEDS-ACTION",
        priority: Int? = nil,
        completed: String? = nil,
        percentComplete: Int? = nil
    ) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Nextcloud Tasks//EN",
            "BEGIN:VTODO",
            "UID:\(uid)",
            "SUMMARY:\(summary)",
            "STATUS:\(status)",
            "DTSTAMP:\(lastModified)",
            "LAST-MODIFIED:\(lastModified)"
        ]
        if let priority { lines.append("PRIORITY:\(priority)") }
        if let percentComplete { lines.append("PERCENT-COMPLETE:\(percentComplete)") }
        if let completed { lines.append("COMPLETED:\(completed)") }
        lines.append(contentsOf: ["END:VTODO", "END:VCALENDAR"])
        return lines.joined(separator: "\r\n")
    }

    // MARK: - Field mapping

    /// Nextcloud's priority control writes the full RFC-5545 1–9 range, not just
    /// the 1/5/9 tier values. Every value in 1...9 must land on a real tier —
    /// never "None". `TaskItem.priorityRaw` used to run the inbound value through
    /// `TaskPriority(rawValue:)`, which accepts only 0/1/5/9, so six of the nine
    /// priorities a server can legally send were silently discarded.
    @Test("Every RFC-5545 priority the server can send maps to a real tier", arguments: [
        (1, TaskPriority.high), (2, .high), (3, .high), (4, .high),
        (5, .medium),
        (6, .low), (7, .low), (8, .low), (9, .low)
    ])
    func serverPriorityMapsToTier(rawValue: Int, expected: TaskPriority) throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()

        let local = TaskItem(uid: "prio-\(rawValue)", title: "Buy milk")
        local.lastModifiedDate = Date(timeIntervalSince1970: 1000)
        local.etag = "etag-1"
        local.isDirty = false
        local.taskList = list
        context.insert(local)
        var uidMap: [String: TaskItem] = ["prio-\(rawValue)": local]

        let remote = CalDAVClient.RemoteTask(
            href: "/calendars/tasks/prio.ics",
            etag: "etag-2",
            icsData: vtodo(uid: "prio-\(rawValue)", lastModified: "20260805T120000Z", priority: rawValue)
        )

        try engine.testApplyRemoteTask(
            remote, taskList: list, uidMap: &uidMap, modelContext: context
        )

        #expect(
            local.priority == expected,
            "PRIORITY:\(rawValue) from the server must map to \(expected), got \(local.priority)"
        )
    }

    // MARK: - The inbound gate

    /// The plain case: a task the device already has is checked off in Nextcloud.
    /// The next pull must mark it completed locally.
    @Test("A task completed on the server is marked completed locally")
    func serverCompletionReachesTheModel() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()

        let local = TaskItem(uid: "done-1", title: "Buy milk")
        local.lastModifiedDate = Date(timeIntervalSince1970: 1000)
        local.etag = "etag-1"
        local.isDirty = false
        local.taskList = list
        context.insert(local)
        var uidMap: [String: TaskItem] = ["done-1": local]

        let remote = CalDAVClient.RemoteTask(
            href: "/calendars/tasks/done-1.ics",
            etag: "etag-2",
            icsData: vtodo(
                uid: "done-1",
                lastModified: "20260805T120000Z",
                status: "COMPLETED",
                completed: "20260805T120000Z",
                percentComplete: 100
            )
        )

        let changed = try engine.testApplyRemoteTask(
            remote, taskList: list, uidMap: &uidMap, modelContext: context
        )

        #expect(changed == true)
        #expect(local.status == .completed)
        #expect(local.completedDate != nil)
    }

    /// The same completion, with the device's `lastModifiedDate` ahead of the
    /// server's LAST-MODIFIED. That comparison spans two machines' clocks —
    /// Nextcloud stores whatever the writing client wrote — so it says nothing
    /// about which copy is newer, and gating on it dropped the completion. It
    /// dropped it *permanently*: a refused apply never stores the new etag, and
    /// nothing lowers the local timestamp, so every later pull refused it too.
    @Test("A server completion still lands when the device's timestamp is ahead")
    func serverCompletionWithBehindTimestamp() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()

        let local = TaskItem(uid: "done-2", title: "Buy milk")
        local.lastModifiedDate = Date(timeIntervalSince1970: 2_000_000_000) // ~2033, device clock
        local.etag = "etag-1"
        local.isDirty = false
        local.taskList = list
        context.insert(local)
        var uidMap: [String: TaskItem] = ["done-2": local]

        let remote = CalDAVClient.RemoteTask(
            href: "/calendars/tasks/done-2.ics",
            etag: "etag-2",
            icsData: vtodo(
                uid: "done-2",
                lastModified: "20260805T120000Z",
                status: "COMPLETED",
                completed: "20260805T120000Z",
                percentComplete: 100
            )
        )

        try engine.testApplyRemoteTask(
            remote, taskList: list, uidMap: &uidMap, modelContext: context
        )

        #expect(local.status == .completed)
    }

    /// The same holds for a priority set on the server: it is a server-side fact,
    /// not a race with the device, and a stale local timestamp must not veto it.
    @Test("A server priority change still lands when the device's timestamp is ahead")
    func serverPriorityWithBehindTimestamp() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()

        let local = TaskItem(uid: "prio-late", title: "Buy milk")
        local.lastModifiedDate = Date(timeIntervalSince1970: 2_000_000_000)
        local.priority = .none
        local.etag = "etag-1"
        local.isDirty = false
        local.taskList = list
        context.insert(local)
        var uidMap: [String: TaskItem] = ["prio-late": local]

        let remote = CalDAVClient.RemoteTask(
            href: "/calendars/tasks/prio-late.ics",
            etag: "etag-2",
            icsData: vtodo(uid: "prio-late", lastModified: "20260805T120000Z", priority: 3)
        )

        try engine.testApplyRemoteTask(
            remote, taskList: list, uidMap: &uidMap, modelContext: context
        )

        #expect(local.priority == .high)
    }

    // MARK: - Cross-context visibility

    /// The sync engine writes on a background `ModelContext`; every list in the
    /// app reads the main context. The `dataRefreshToken` rebuild assumes a fresh
    /// main-context fetch sees what the background context committed — this pins
    /// that it holds for an *update* to a row the main context already
    /// materialized, which is exactly what a server-side completion or priority
    /// change is. If this ever regresses, both symptoms return with the engine
    /// itself behaving perfectly.
    @MainActor
    @Test("A background-context update is visible to a fresh main-context fetch")
    func backgroundUpdateVisibleOnMainContext() throws {
        let container = try makeContainer()
        let mainContext = container.mainContext

        let task = TaskItem(uid: "xctx-1", title: "Buy milk")
        task.status = .needsAction
        task.priority = .none
        mainContext.insert(task)
        try mainContext.save()

        // Materialize the row on the main context, the way a visible list does.
        let materialized = try mainContext.fetch(FetchDescriptor<TaskItem>())
        #expect(materialized.first?.status == .needsAction)

        // The sync engine's background context applies the server's change.
        let bgContext = ModelContext(container)
        let remoteCopy = try bgContext.fetch(FetchDescriptor<TaskItem>()).first
        remoteCopy?.status = .completed
        remoteCopy?.priority = .high
        try bgContext.save()

        // What a rebuilt view's `@Query` would now read.
        let refetched = try mainContext.fetch(FetchDescriptor<TaskItem>())
        #expect(refetched.first?.status == .completed, "main context served a stale status after a background save")
        #expect(refetched.first?.priority == .high, "main context served a stale priority after a background save")
    }
}
