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
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: "https://fixture.invalid", username: "fixture")
        context.insert(account); list.account = account
        return list
    }

    @discardableResult
    private func task(_ uid: String,
                      under parent: TaskItem? = nil,
                      in list: TaskList,
                      context: ModelContext) throws -> TaskItem {
        let item = TaskItem(uid: uid, title: uid)
        item.remoteHref = list.serverURL + "\(uid).ics"
        item.isDirty = false
        context.insert(item)
        item.taskList = list
        item.parentTask = parent
        item.etag = uid + "-etag"; item.attachmentStateKnown = true
        try VTODOOpaqueState.empty.store(taskID: item.id, in: context)
        try SyncResourceFixture.prove(item, in: context)
        return item
    }

    /// `Trip` with two children, one of which has a child of its own — so the
    /// recursion is actually exercised rather than one level of it.
    private func trip(in list: TaskList, context: ModelContext)
    throws -> (parent: TaskItem, flight: TaskItem, pack: TaskItem, socks: TaskItem) {
        let parent = try task("trip", in: list, context: context)
        let flight = try task("flight", under: parent, in: list, context: context)
        let pack = try task("pack", under: parent, in: list, context: context)
        let socks = try task("socks", under: pack, in: list, context: context)
        return (parent, flight, pack, socks)
    }

    enum FailedCleanupRead: Sendable {
        case queuedWork, previousList, ownershipRow
    }

    @Test("A failed photo cleanup lookup preserves the task and its originals for retry",
          arguments: [FailedCleanupRead.queuedWork, .previousList, .ownershipRow])
    @MainActor
    func failedCleanupReadKeepsPhotoOwnership(_ failedRead: FailedCleanupRead) throws {
        struct ReadFailed: Error {}
        let container = try makeContainer()
        let context = container.mainContext
        let list = makeList(in: context)
        let previous = makeList(in: context)
        previous.serverURL = "/calendars/previous/"
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: "https://fixture.invalid", username: "fixture")
        context.insert(account)
        list.account = account
        previous.account = account
        let item = try task("photo", in: list, context: context)
        let photo = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        context.insert(photo)
        photo.task = item
        photo.originalFileID = "802"
        photo.folderFileID = "702"
        photo.previousOriginalFileID = "801"
        photo.previousOriginalFolderID = "701"
        photo.previousOriginalAccountID = account.id
        photo.previousOriginalListID = previous.id
        try acceptPhotoOriginal(photo, in: context)
        TaskListHelpers.markDeleted(item)
        try context.save()

        let snapshot = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: item.id, container: container))
        var reads = TaskPhotoCleanupQueue.DeletionReads()
        switch failedRead {
        case .queuedWork: reads.queuedWork = { _, _ in throw ReadFailed() }
        case .previousList: reads.previousList = { _, _ in throw ReadFailed() }
        case .ownershipRow: reads.ownershipRow = { _, _ in throw ReadFailed() }
        }
        #expect(throws: ReadFailed.self) {
            try SyncPushAcknowledgement.acknowledgeDeletion(snapshot, container: container, cleanupReads: reads)
        }
        previous.name = "Unrelated saved edit"
        try context.save()
        let fresh = ModelContext(container)
        let retained = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(retained.isDeletedLocally)
        #expect(retained.photos.first?.originalFileID == "802")
        #expect(retained.photos.first?.previousOriginalFileID == "801")
        #expect(try fresh.fetch(FetchDescriptor<SyncMetadata>()).allSatisfy { !$0.id.hasPrefix(TaskPhotoCleanupQueue.prefix) })
        #expect(try SyncPushAcknowledgement.acknowledgeDeletion(snapshot, container: container) != nil)
        let retried = ModelContext(container)
        #expect(try retried.fetchCount(FetchDescriptor<TaskItem>()) == 0)
        #expect(Set(try retried.fetch(FetchDescriptor<SyncMetadata>()).filter { $0.id.hasPrefix(TaskPhotoCleanupQueue.prefix) }.compactMap(\.syncToken)) == ["801", "802"])
    }

    @Test("Deleting a parent marks its whole subtree deleted")
    func deletingAParentMarksItsSubtree() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let t = try trip(in: list, context: context)
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
        let t = try trip(in: list, context: context)
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
        let t = try trip(in: list, context: context)
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

    @Test("A failed child DELETE preserves both tombstones while unrelated deletes succeed")
    @MainActor
    func failedChildDeleteRetainsParentAndChild() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let list = makeList(in: context)
        list.serverURL = "/tasks/"
        let host = "delete-" + UUID().uuidString.lowercased() + ".invalid"
        let baseURL = "https://" + host
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: baseURL, username: "fixture")
        context.insert(account)
        list.account = account
        list.syncCTag = "c1"
        list.lastFullPullDate = Date()
        SyncEngine.markCategoriesCaughtUp(listID: list.id)

        let parent = try task("parent", in: list, context: context)
        let child = try task("child", under: parent, in: list, context: context)
        let unrelated = try task("unrelated", in: list, context: context)
        for item in [parent, child, unrelated] {
            item.etag = item.uid + "-etag"
            item.isLocalOnly = false
        }
        TaskListHelpers.markDeleted(parent)
        TaskListHelpers.markDeleted(unrelated)
        try context.save()
        try DAVSyncScenario.seedRecentCheckpoint(for: list, in: container)

        let listPath = list.serverURL
        let accountID = account.id
        func sync(statuses: [Int]) async -> SyncOutcome {
            let configuration = ScriptedDAVProtocol.install(host: host, responses:
                DAVSyncScenario.discovery(paths: [listPath]) + statuses.map { .init(status: $0, body: "") })
            let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: configuration,
                retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
            return await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
                credentials: .init(username: "fixture", password: "fixture"), modelContainer: container,
                reconcileNotifications: false)
        }

        let partial = await sync(statuses: [403, 204, 204])
        let first = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "DELETE" }
        #expect(first.map(\.path) == ["/tasks/child.ics", "/tasks/unrelated.ics"],
                "Requests: \(ScriptedDAVProtocol.requests(host: host).map(\.method)); failures: \(partial.failures)")
        #expect(partial.status == .partial)
        #expect(partial.deletedCount == 1)
        let remaining = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(Set(remaining.map(\.uid)) == ["parent", "child"])
        #expect(remaining.allSatisfy { $0.isDeletedLocally })

        let retry = await sync(statuses: [204, 204])
        let second = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "DELETE" }
        #expect(second.map(\.path) == ["/tasks/child.ics", "/tasks/parent.ics"])
        #expect(second.map(\.ifMatch) == ["\"child-etag\"", "\"parent-etag\""])
        #expect(retry.deletedCount == 2)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 0)
    }

    enum DeleteReplay: Sendable {
        case retry, redirect
    }

    @Test("A parent DELETE is not replayed after a child is saved during backoff or redirection",
          arguments: [DeleteReplay.retry, .redirect])
    @MainActor
    func replayDoesNotDeleteParentAfterChildSaved(replay: DeleteReplay) async throws {
        let container = try makeContainer()
        let main = container.mainContext
        let list = makeList(in: main)
        list.serverURL = "/tasks/"
        list.syncCTag = "c1"
        list.lastFullPullDate = Date()
        SyncEngine.markCategoriesCaughtUp(listID: list.id)
        let host = "delete-replay-" + UUID().uuidString.lowercased() + ".invalid"
        let baseURL = "https://" + host
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: baseURL, username: "fixture")
        main.insert(account)
        list.account = account
        let parent = try task("parent", in: list, context: main)
        parent.etag = "parent-etag"
        parent.isLocalOnly = false
        TaskListHelpers.markDeleted(parent)
        try main.save()
        try DAVSyncScenario.seedRecentCheckpoint(for: list, in: container)
        let parentID = parent.id
        let accountID = account.id

        let saveChild: @MainActor @Sendable () throws -> Void = {
            let edit = ModelContext(container)
            let stored = try #require(try edit.fetch(FetchDescriptor<TaskItem>()).first { $0.id == parentID })
            let child = TaskItem(uid: "child", title: "New child")
            edit.insert(child)
            child.taskList = stored.taskList
            child.parentTask = stored
            child.parentUID = stored.uid
            try edit.save()
        }
        let gate = ScriptedDAVProtocol.Gate()
        defer { gate.release() }
        let firstResponse: ScriptedDAVProtocol.Response
        switch replay {
        case .retry:
            firstResponse = .init(status: 500, body: "")
        case .redirect:
            let redirect = try #require(URL(string: baseURL + "/tasks/redirected-parent.ics"))
            firstResponse = .init(status: 307, body: "", headers: ["Location": redirect.absoluteString],
                                  gate: gate, redirectURL: redirect)
        }
        let config = ScriptedDAVProtocol.install(host: host, responses:
            DAVSyncScenario.discovery(paths: ["/tasks/"]) + [firstResponse, .init(status: 204, body: "")])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config,
            retryPolicy: .init(maxAttempts: 2, baseDelay: 0), sleep: { _ in
                if replay == .retry { try await saveChild() }
            }))
        let operation = Task {
            await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
                credentials: .init(username: "fixture", password: "fixture"), modelContainer: container,
                reconcileNotifications: false)
        }
        if replay == .redirect {
            for _ in 0..<500 where !ScriptedDAVProtocol.requests(host: host).contains(where: { $0.method == "DELETE" }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(ScriptedDAVProtocol.requests(host: host).contains { $0.method == "DELETE" })
            try saveChild()
            gate.release()
        }
        _ = await operation.value

        let deletions = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "DELETE" }
        #expect(deletions.map(\.path) == ["/tasks/parent.ics"])
        #expect(deletions.first?.ifMatch == "\"parent-etag\"")
        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(Set(saved.map(\.uid)) == ["parent", "child"])
        #expect(saved.first { $0.uid == "parent" }?.isDeletedLocally == true)
        #expect(saved.first { $0.uid == "child" }?.parentTask?.id == parentID)
    }

    @Test("A child restored during its DELETE survives and blocks the parent DELETE")
    @MainActor
    func savedRestoreSurvivesDeletionAcknowledgement() throws {
        let container = try makeContainer()
        let main = container.mainContext
        let list = makeList(in: main)
        let parent = try task("parent", in: list, context: main)
        let parentID = parent.id
        let item = try task("restored", under: parent, in: list, context: main)
        let id = item.id
        item.etag = "sent"
        try SyncResourceFixture.prove(item, in: main)
        TaskListHelpers.markDeleted(parent)
        try main.save()
        let snapshot = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: id, container: container))

        let edit = ModelContext(container)
        let restored = try #require(try edit.fetch(FetchDescriptor<TaskItem>()).first { $0.id == id })
        restored.isDeletedLocally = false
        restored.title = "Restored title"
        try edit.save()

        #expect(try SyncPushAcknowledgement.acknowledgeDeletion(snapshot, container: container) == nil)
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first { $0.id == id })
        #expect(stored.title == "Restored title")
        #expect(!stored.isDeletedLocally)
        #expect(stored.remoteHref == nil)
        #expect(stored.etag == nil)
        #expect(stored.isDirty)
        #expect(try SyncPushAcknowledgement.deletionSnapshot(taskID: parentID, container: container) == nil)
    }

    enum ChangedIdentity: Sendable {
        case uid, href, etag, list, account
    }

    @Test("DELETE acknowledgement cannot consume a newer stored resource identity",
          arguments: [ChangedIdentity.uid, .href, .etag, .list, .account])
    @MainActor
    func newerIdentitySurvivesDeletionAcknowledgement(field: ChangedIdentity) throws {
        let container = try makeContainer()
        let main = container.mainContext
        let list = makeList(in: main)
        let item = try task("changed", in: list, context: main)
        let account = ServerAccount(displayName: "Original", serverBaseURL: "https://original.invalid", username: "sam")
        main.insert(account)
        list.account = account
        let listID = list.id
        let accountID = account.id
        let id = item.id
        item.etag = "old"
        try SyncResourceFixture.prove(item, in: main)
        TaskListHelpers.markDeleted(item)
        try main.save()

        let edit = ModelContext(container)
        let changed = try #require(try edit.fetch(FetchDescriptor<TaskItem>()).first)
        changed.etag = "sent"
        try SyncResourceFixture.prove(changed, in: edit)
        try edit.save()

        let snapshot = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: id, container: container,
            expectedListID: listID, expectedAccountID: accountID))
        #expect(snapshot.etag == "sent")
        switch field {
        case .uid: changed.uid = "new"
        case .href: changed.remoteHref = "/calendars/tasks/new.ics"
        case .etag: changed.etag = "new"
        case .list:
            let destination = makeList(in: edit)
            destination.account = changed.taskList?.account
            changed.taskList = destination
        case .account:
            let replacement = ServerAccount(displayName: "Replacement",
                serverBaseURL: "https://replacement.invalid", username: "sam")
            edit.insert(replacement)
            changed.taskList?.account = replacement
        }
        try edit.save()

        if field == .list || field == .account {
            #expect(try SyncPushAcknowledgement.deletionSnapshot(taskID: id, container: container,
                expectedListID: listID, expectedAccountID: accountID) == nil)
        }
        #expect(try SyncPushAcknowledgement.acknowledgeDeletion(snapshot, container: container) == nil)
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.isDeletedLocally)
        #expect(stored.remoteHref == (field == .href ? "/calendars/tasks/new.ics" : "/calendars/tasks/changed.ics"))
        #expect(stored.etag == (field == .etag ? "new" : "sent"))
    }

    enum NewDescendant: Sendable {
        case inserted, reparented, unsaved, unresolved
    }

    @Test("An in-flight parent DELETE leaves a newly attached child and parent intact",
          arguments: [NewDescendant.inserted, .reparented, .unsaved, .unresolved])
    @MainActor
    func newDescendantBlocksAcknowledgement(scenario: NewDescendant) throws {
        let container = try makeContainer()
        let main = container.mainContext
        main.autosaveEnabled = false
        let list = makeList(in: main)
        let parent = try task("parent", in: list, context: main)
        let id = parent.id
        parent.etag = "parent-etag"
        if scenario == .reparented { try task("child", in: list, context: main) }
        TaskListHelpers.markDeleted(parent)
        try main.save()
        let snapshot = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: id, container: container))

        if scenario == .unsaved {
            try task("child", under: parent, in: list, context: main)
        } else {
            let edit = ModelContext(container)
            let tasks = try edit.fetch(FetchDescriptor<TaskItem>())
            let editParent = try #require(tasks.first { $0.id == id })
            let editList = try #require(editParent.taskList)
            if scenario == .reparented {
                let child = try #require(tasks.first { $0.uid == "child" })
                child.parentTask = editParent
                child.parentUID = editParent.uid
            } else if scenario == .unresolved {
                let child = try task("child", in: editList, context: edit)
                child.parentUID = editParent.uid
            } else {
                try task("child", under: editParent, in: editList, context: edit)
            }
            try edit.save()
        }

        #expect(try SyncPushAcknowledgement.acknowledgeDeletion(snapshot, container: container) == nil)
        #expect(try SyncPushAcknowledgement.deletionSnapshot(taskID: id, container: container) == nil)
        if scenario == .unsaved { try main.save() }
        let stored = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(Set(stored.map(\.uid)) == ["parent", "child"])
        let retained = try #require(stored.first { $0.id == id })
        #expect(retained.isDeletedLocally)
        #expect(retained.remoteHref == "/calendars/tasks/parent.ics")
        #expect(retained.etag == "parent-etag")
        let child = try #require(stored.first { $0.uid == "child" })
        #expect(!child.isDeletedLocally)
        if scenario == .unresolved {
            #expect(child.parentUID == "parent")
        } else {
            #expect(child.parentTask?.id == id)
        }
    }

    /// Deleting a subtask is not deleting its parent. The recursion goes down
    /// only.
    @Test("Deleting a subtask leaves its parent alone")
    func deletingASubtaskLeavesTheParentAlone() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let t = try trip(in: list, context: context)
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
        let t = try trip(in: list, context: context)
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
        let t = try trip(in: list, context: context)
        try context.save()

        TaskListHelpers.markDeleted(t.parent)
        TaskListHelpers.markDeleted(t.parent)

        let queued = SyncEngine().testFindDeletedTasks(for: list, modelContext: context)
        #expect(queued.count == 4, "each task appears once")
    }
}
