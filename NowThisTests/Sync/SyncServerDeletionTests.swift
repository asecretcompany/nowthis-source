import Testing
import Foundation
import SwiftData

@testable import NowThis

/// Cover for **a task deleted on the server never going away here.**
///
/// The pull could add and update but never delete: `uidMap` was only ever read
/// for matching, and nothing compared the local set against the fetched one. A
/// task deleted in the Nextcloud web UI stayed on the device forever, holding
/// an etag and an href for a resource that now 404s.
///
/// ## Why this is the dangerous one
///
/// Every other fix in this file's neighbourhood adds or preserves data. This
/// one deletes it, on the strength of an *absence* — and an absence is exactly
/// what a short read, a filtered fetch, or a half-finished request also looks
/// like. Getting the question wrong does not produce a bug report, it produces
/// a user whose tasks are gone.
///
/// So the rules below are all refusals, and each is a test:
///
/// - **The fetch is unfiltered, and reconciliation uses it whole.**
///   `fetchAllTasks` issues a `calendar-query` for every VTODO with no
///   time-range, so `remoteTasks` is the complete server set.
///   `filterCompletedByWindow` narrows what gets *applied*, not what was
///   fetched — so the reconciliation reads the full set and the user's older
///   completed history is never a candidate. Reading the filtered subset
///   instead would delete exactly that history on the first run.
/// - **Nothing that was never on the server.** A task with no `remoteHref`, or
///   flagged `isLocalOnly`, is absent remotely because it has not been pushed
///   yet, not because it was deleted.
/// - **Nothing with unpushed edits.** A dirty task is about to be pushed, which
///   re-creates it on the server. Deleting it would throw away the user's edit
///   to win a race against our own upload.
/// - **Nothing already on its way out.** `isDeletedLocally` belongs to the
///   deletion push, which still owes the server its DELETE.
/// - **No parent of a subtask the server still has.** The local delete
///   cascades, so removing such a parent would take a live child with it.
/// - **Nothing at all, if the server reports an empty list.** A fetch that
///   returns nothing is indistinguishable from a list the user emptied, and
///   the two want opposite handling. This refuses, deliberately: a genuinely
///   emptied list stays until the user clears it here as well. That is the
///   cheap failure, and the other one is unrecoverable.
@Suite("Sync server-side deletion")
struct SyncServerDeletionTests {

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

    /// A task that has been pushed and is in sync — the only shape that is ever
    /// a deletion candidate.
    @discardableResult
    private func synced(_ uid: String,
                        under parent: TaskItem? = nil,
                        in list: TaskList,
                        context: ModelContext) -> TaskItem {
        let item = TaskItem(uid: uid, title: uid)
        item.remoteHref = "/calendars/tasks/\(uid).ics"
        item.etag = "etag-1"
        item.isDirty = false
        item.isLocalOnly = false
        context.insert(item)
        item.taskList = list
        item.parentTask = parent
        return item
    }

    private func uids(_ tasks: [TaskItem]) -> Set<String> {
        Set(tasks.map(\.uid))
    }

    // MARK: - The one case that deletes

    @Test("A synced task the server no longer has is removed")
    func aTaskGoneFromTheServerIsRemoved() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)

        let kept = synced("kept", in: list, context: context)
        let gone = synced("gone", in: list, context: context)
        try context.save()

        let doomed = SyncEngine.tasksDeletedOnServer(local: [kept, gone],
                                                     remoteUIDs: ["kept"])

        #expect(uids(doomed) == ["gone"])
    }

    // MARK: - The refusals

    @Test("A task that has never been pushed is not a deletion")
    func aNeverPushedTaskIsKept() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)

        let fresh = synced("fresh", in: list, context: context)
        fresh.remoteHref = nil
        fresh.isLocalOnly = true
        let alsoFresh = synced("also-fresh", in: list, context: context)
        alsoFresh.remoteHref = nil
        try context.save()

        let doomed = SyncEngine.tasksDeletedOnServer(local: [fresh, alsoFresh],
                                                     remoteUIDs: ["something-else"])

        #expect(doomed.isEmpty, "absent because it was never uploaded, not because it was deleted")
    }

    @Test("A task with unpushed edits is not a deletion")
    func aDirtyTaskIsKept() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)

        let edited = synced("edited", in: list, context: context)
        edited.isDirty = true
        try context.save()

        let doomed = SyncEngine.tasksDeletedOnServer(local: [edited], remoteUIDs: ["other"])

        #expect(doomed.isEmpty, "the push that follows re-creates it; deleting races our own upload")
    }

    @Test("A task already awaiting its DELETE is left to the deletion push")
    func aTaskAwaitingDeletionIsKept() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)

        let doomedAlready = synced("doomed", in: list, context: context)
        doomedAlready.isDeletedLocally = true
        doomedAlready.isDirty = true
        try context.save()

        let doomed = SyncEngine.tasksDeletedOnServer(local: [doomedAlready], remoteUIDs: ["other"])

        #expect(doomed.isEmpty)
    }

    @Test("A parent is kept while the server still has one of its subtasks")
    func aParentOfALiveSubtaskIsKept() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)

        let parent = synced("parent", in: list, context: context)
        let child = synced("child", under: parent, in: list, context: context)
        try context.save()

        let doomed = SyncEngine.tasksDeletedOnServer(local: [parent, child],
                                                     remoteUIDs: ["child"])

        #expect(doomed.isEmpty, "the local delete cascades and would take the live child with it")
    }

    /// When the whole subtree is gone from the server, the whole subtree goes —
    /// deepest first, so each delete removes a leaf and the cascade never
    /// reaches a row that is itself still in the list.
    @Test("A whole subtree the server has dropped goes, deepest first")
    func aWholeDeadSubtreeGoesDeepestFirst() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)

        let parent = synced("parent", in: list, context: context)
        let child = synced("child", under: parent, in: list, context: context)
        let grandchild = synced("grandchild", under: child, in: list, context: context)
        let survivor = synced("survivor", in: list, context: context)
        try context.save()

        let doomed = SyncEngine.tasksDeletedOnServer(local: [parent, child, grandchild, survivor],
                                                     remoteUIDs: ["survivor"])

        #expect(uids(doomed) == ["parent", "child", "grandchild"])
        let order = doomed.map(\.uid)
        let positions = ["parent", "child", "grandchild"].compactMap { order.firstIndex(of: $0) }
        #expect(positions == positions.sorted(by: >),
                "deepest first, so no delete lands on a row a cascade already removed: \(order)")
    }

    @Test("An empty server response deletes nothing at all")
    func anEmptyRemoteSetIsRefused() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)

        let a = synced("a", in: list, context: context)
        let b = synced("b", in: list, context: context)
        try context.save()

        let doomed = SyncEngine.tasksDeletedOnServer(local: [a, b], remoteUIDs: [])

        #expect(doomed.isEmpty, """
            An empty fetch and a list the user emptied look identical, and they want opposite \
            handling. Refusing leaves a genuinely emptied list until the user clears it here \
            too; the other way round loses everything.
            """)
    }

    // MARK: - Reading the UIDs out of the fetch

    private func remote(_ ics: String) -> CalDAVClient.RemoteTask {
        CalDAVClient.RemoteTask(href: "/calendars/tasks/x.ics", etag: "e", icsData: ics)
    }

    private func vtodo(uidLine: String) -> String {
        ["BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VTODO", uidLine,
         "SUMMARY:Task", "END:VTODO", "END:VCALENDAR"].joined(separator: "\r\n")
    }

    @Test("A UID is read from a fetched resource")
    func aUIDIsRead() {
        let found = SyncEngine.remoteUIDSet([remote(vtodo(uidLine: "UID:abc-123"))])
        #expect(found == ["abc-123"])
    }

    /// RFC 5545 folds lines past 75 octets, and Nextcloud emits folded UIDs for
    /// the long ones it generates. Reading the raw line would yield a truncated
    /// UID, whose local counterpart then matches nothing and is deleted — the
    /// exact failure this whole suite exists to prevent, arriving through the
    /// one line of it that looks like string handling rather than sync logic.
    @Test("A folded UID is read whole")
    func aFoldedUIDIsReadWhole() {
        let long = "5f3a9c1e-7b2d-4e8a-9c6f-1a2b3c4d5e6f-cccccccccccccccccccc"
        let folded = "UID:5f3a9c1e-7b2d-4e8a-9c6f-1a2b3c4d5e6f-cccccccccc\r\n cccccccccc"
        let found = SyncEngine.remoteUIDSet([remote(vtodo(uidLine: folded))])
        #expect(found == [long], "got \(found ?? []) — a truncated UID deletes the task it names")
    }

    @Test("A UID carrying parameters is read")
    func aUIDWithParametersIsRead() {
        let found = SyncEngine.remoteUIDSet([remote(vtodo(uidLine: "UID;X-THING=1:abc-123"))])
        #expect(found == ["abc-123"])
    }

    /// The safe failure. One unreadable resource means the set is short by one,
    /// and a short set is indistinguishable from a deletion.
    @Test("One unreadable resource abandons the whole reconciliation")
    func oneUnreadableResourceAbandonsIt() {
        let good = remote(vtodo(uidLine: "UID:fine"))
        let bad = remote("BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nSUMMARY:No UID\r\nEND:VTODO\r\nEND:VCALENDAR")
        #expect(SyncEngine.remoteUIDSet([good, bad]) == nil)
        #expect(SyncEngine.remoteUIDSet([good]) == ["fine"], "and the readable case still works")
    }

    /// Anti-vacuity: a rule set that returned nothing for every input would pass
    /// every refusal above.
    @Test("The rules can still delete when every refusal is inapplicable")
    func theRulesAreNotUniversallyRefusing() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)

        let tasks = (1...5).map { synced("t\($0)", in: list, context: context) }
        try context.save()

        let doomed = SyncEngine.tasksDeletedOnServer(local: tasks, remoteUIDs: ["t1"])

        #expect(uids(doomed) == ["t2", "t3", "t4", "t5"])
    }
}
