import Testing
import Foundation
import SwiftData

@testable import NowThis

/// The sweep DELETEs the copy a move left in its source list. It must never
/// leave the server with no copy at all, must never hard-delete the local row
/// (`pushDeletion` does, which is why it is not reused), and must stop retrying
/// once the server says the user may not remove from that list.
///
/// There is no network seam in the suite, so the decisions are pure functions
/// and the DELETE is an injected closure.
@Suite("Pending-move sweep")
struct PendingMoveSweepTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    private struct Fixture {
        let account: ServerAccount
        let vault: ServerAccount
        let work: TaskList
        let home: TaskList
        let vaultList: TaskList
    }

    private func makeFixture(in context: ModelContext) throws -> Fixture {
        let account = ServerAccount(
            displayName: "Nextcloud", serverBaseURL: "https://cloud.example.test",
            username: "sam", mode: .nextcloud
        )
        let vault = ServerAccount(vaultDisplayName: "Vault")
        context.insert(account)
        context.insert(vault)

        let work = TaskList(serverURL: "/cal/work/", name: "Work", colorHex: "#007AFF")
        let home = TaskList(serverURL: "/cal/home/", name: "Home", colorHex: "#FF9500")
        let vaultList = TaskList(serverURL: "", name: "Private", colorHex: "#34C759")
        for list in [work, home, vaultList] { context.insert(list) }
        work.account = account
        home.account = account
        vaultList.account = vault
        try context.save()
        return Fixture(account: account, vault: vault, work: work, home: home, vaultList: vaultList)
    }

    private func syncedTask(_ uid: String, in list: TaskList, context: ModelContext) throws -> TaskItem {
        let task = TaskItem(uid: uid, title: "Task \(uid)")
        context.insert(task)
        task.taskList = list
        task.remoteHref = "\(list.serverURL)\(uid).ics"
        task.etag = "etag-\(uid)"
        task.isLocalOnly = false
        try VTODOOpaqueState.empty.store(taskID: task.id, in: context)
        try SyncResourceFixture.prove(task, in: context)
        return task
    }

    /// Simulates the destination push having landed.
    private func landPut(_ task: TaskItem) throws {
        task.remoteHref = "\(task.taskList?.serverURL ?? "")\(task.uid).ics"
        task.etag = "etag-new-\(task.uid)"
        task.isDirty = false
        if let context = task.modelContext { try SyncResourceFixture.prove(task, in: context) }
    }

    // MARK: - DELETE status mapping

    @Test("A 403 on DELETE is a permission failure, not a server error")
    func deleteStatusMapping() throws {
        #expect(throws: Never.self) { try CalDAVClient.checkDeleteStatus(204) }
        #expect(throws: Never.self) { try CalDAVClient.checkDeleteStatus(200) }
        #expect(throws: Never.self, "404 is already gone — idempotent") { try CalDAVClient.checkDeleteStatus(404) }

        #expect { try CalDAVClient.checkDeleteStatus(403) } throws: { error in
            if case CalDAVError.forbidden = error { return true }
            return false
        }
        #expect { try CalDAVClient.checkDeleteStatus(412) } throws: { error in
            if case CalDAVError.conflict = error { return true }
            return false
        }
        #expect { try CalDAVClient.checkDeleteStatus(401) } throws: { error in
            if case CalDAVError.unauthorized = error { return true }
            return false
        }
        #expect { try CalDAVClient.checkDeleteStatus(500) } throws: { error in
            if case CalDAVError.serverError(statusCode: 500) = error { return true }
            return false
        }
    }

    // MARK: - Which moves are ready

    @Test("The old copy waits until the new one exists on the server")
    func waitsForTheDestinationPut() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let f = try makeFixture(in: context)

        let task = try syncedTask("uid-1", in: f.work, context: context)
        TaskMover.move(task, to: f.home, in: context)
        try context.save()

        #expect(PendingMoveSweep.candidates(sourceListIDs: [f.work.id], in: context).isEmpty,
                "deleting now would leave the server with no copy")

        try landPut(task)
        try context.save()
        let ready = PendingMoveSweep.candidates(sourceListIDs: [f.work.id], in: context)
        #expect(ready.map(\.uid) == ["uid-1"], "examined \(ready.count) candidates")
    }

    @Test("A move into the Vault is ready at once — it will never be pushed")
    func vaultDestinationIsReadyImmediately() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let f = try makeFixture(in: context)

        let task = try syncedTask("uid-v", in: f.work, context: context)
        TaskMover.move(task, to: f.vaultList, in: context)
        try context.save()

        let ready = PendingMoveSweep.candidates(sourceListIDs: [f.work.id], in: context)
        #expect(ready.map(\.uid) == ["uid-v"], "examined \(ready.count) candidates")
    }

    @Test("Only moves out of the syncing account's lists are swept, deepest first")
    func scopedToSourceListsDeepestFirst() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let f = try makeFixture(in: context)

        let parent = try syncedTask("uid-p", in: f.work, context: context)
        let child = try syncedTask("uid-c", in: f.work, context: context)
        child.parentTask = parent
        child.parentUID = parent.uid
        let unrelated = try syncedTask("uid-h", in: f.home, context: context)
        try context.save()

        TaskMover.move(parent, to: f.vaultList, in: context)
        TaskMover.move(unrelated, to: f.vaultList, in: context)
        try context.save()

        let ready = PendingMoveSweep.candidates(sourceListIDs: [f.work.id], in: context)
        #expect(ready.map(\.uid) == ["uid-c", "uid-p"], "examined \(ready.count) candidates")
    }

    // MARK: - Execution

    @Test("A swept task keeps its row and loses only the pending move")
    func successClearsFieldsAndKeepsTheRow() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let f = try makeFixture(in: context)

        var task = try syncedTask("uid-1", in: f.work, context: context)
        TaskMover.move(task, to: f.home, in: context)
        try landPut(task)
        try context.save()

        var deleted: [String] = []
        let denied = await PendingMoveSweep.run(
            PendingMoveSweep.candidates(sourceListIDs: [f.work.id], in: context),
            in: context
        ) { deleted.append($0.sourceHref) }
        try context.save()
        let committedContext = ModelContext(container)
        let taskID = task.id
        task = try #require(try committedContext.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)


        #expect(!denied)
        #expect(deleted == ["/cal/work/uid-1.ics"])
        #expect(task.pendingMoveFromHref == nil)
        #expect(task.pendingMoveFromListID == nil)
        #expect(task.remoteHref == "/cal/home/uid-1.ics")
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(all.count == 1, "examined \(all.count) tasks — the row must survive")
    }

    @Test("A failed DELETE leaves the move pending for the next sync")
    func failureLeavesFieldsSet() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let f = try makeFixture(in: context)

        let task = try syncedTask("uid-1", in: f.work, context: context)
        TaskMover.move(task, to: f.vaultList, in: context)
        try context.save()

        let denied = await PendingMoveSweep.run(
            PendingMoveSweep.candidates(sourceListIDs: [f.work.id], in: context),
            in: context
        ) { _ in throw CalDAVError.serverError(statusCode: 503) }

        #expect(!denied)
        #expect(task.pendingMoveFromHref == "/cal/work/uid-1.ics")
        #expect(task.pendingMoveFromListID == f.work.id)
    }

    @Test("A refused DELETE puts the task back where it began, and removes the new copy")
    func forbiddenDeleteRollsBack() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let f = try makeFixture(in: context)

        var task = try syncedTask("uid-1", in: f.work, context: context)
        TaskMover.move(task, to: f.home, in: context)
        try landPut(task)
        try context.save()

        let denied = await PendingMoveSweep.run(
            PendingMoveSweep.candidates(sourceListIDs: [f.work.id], in: context),
            in: context
        ) { _ in throw CalDAVError.forbidden }
        try context.save()
        let committedContext = ModelContext(container)
        let taskID = task.id
        task = try #require(try committedContext.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)


        #expect(denied)
        #expect(task.taskList?.id == f.work.id)
        #expect(task.remoteHref == "/cal/work/uid-1.ics")
        #expect(task.pendingMoveFromHref == nil, "not retried")
        #expect(!task.isDirty, "the server's copy in Work is the truth now")

        // The copy the move created in Home is owed a DELETE of its own.
        let tombstones = try context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.isDeletedLocally }
        ))
        #expect(tombstones.count == 1, "examined \(tombstones.count) tombstones")
        #expect(tombstones.first?.taskList?.id == f.home.id)
        #expect(tombstones.first?.remoteHref == "/cal/home/uid-1.ics")
    }

    @Test("A refused PUT into the destination puts the task back where it began")
    func forbiddenPutRollsBack() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let f = try makeFixture(in: context)

        let task = try syncedTask("uid-1", in: f.work, context: context)
        TaskMover.move(task, to: f.home, in: context)
        try context.save()

        #expect(TaskMover.rollBackRefusedPut(task, in: context))
        try context.save()

        #expect(task.taskList?.id == f.work.id)
        #expect(task.remoteHref == "/cal/work/uid-1.ics")
        #expect(task.pendingMoveFromHref == nil)
        #expect(task.pendingMoveFromListID == nil)
        #expect(!task.isDirty)
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(all.count == 1, "examined \(all.count) tasks — nothing was created, so nothing is owed")
    }

    @Test("A refused PUT with no move behind it is not a rollback")
    func forbiddenPutWithoutMoveIsLeftAlone() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let f = try makeFixture(in: context)

        let task = try syncedTask("uid-1", in: f.work, context: context)
        task.isDirty = true
        try context.save()

        #expect(!TaskMover.rollBackRefusedPut(task, in: context))
        #expect(task.taskList?.id == f.work.id)
        #expect(task.isDirty)
    }

    @Test("A deleted move keeps both cleanup obligations until the source DELETE succeeds",
          arguments: [false, true])
    @MainActor
    func deletedMoveRetainsSourceUntilSweep(destinationLanded: Bool) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeFixture(in: context)
        let moved = try syncedTask("moving", in: fixture.work, context: context)
        moved.attachmentStateKnown = true
        TaskMover.move(moved, to: fixture.home, in: context)
        if destinationLanded { try landPut(moved) }
        TaskListHelpers.markDeleted(moved)
        try context.save()
        let id = moved.id
        let sourceID = fixture.work.id

        #expect(try SyncPushAcknowledgement.deletionSnapshot(taskID: id, container: container) == nil)

        let failedContext = ModelContext(container)
        let candidates = PendingMoveSweep.candidates(sourceListIDs: [sourceID], in: failedContext)
        var reportedDenial = false
        let denied = await PendingMoveSweep.run(candidates, in: failedContext, onFailure: { error in
            if case CalDAVError.forbidden = error { reportedDenial = true }
        }) { snapshot in
            #expect(snapshot.sourceHref == "/cal/work/moving.ics")
            throw CalDAVError.forbidden
        }
        #expect(denied)
        #expect(reportedDenial)
        let failed = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(failed.isDeletedLocally)
        #expect(failed.taskList?.id == fixture.home.id)
        #expect(failed.pendingMoveFromHref == "/cal/work/moving.ics")
        #expect(failed.pendingMoveFromListID == sourceID)
        #expect(try SyncPushAcknowledgement.deletionSnapshot(taskID: id, container: container) == nil)

        let retryContext = ModelContext(container)
        var sent: [String] = []
        _ = await PendingMoveSweep.run(
            PendingMoveSweep.candidates(sourceListIDs: [sourceID], in: retryContext), in: retryContext
        ) { sent.append($0.sourceHref) }
        #expect(sent == ["/cal/work/moving.ics"])
        if destinationLanded {
            let deletion = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: id, container: container))
            #expect(deletion.href == "/cal/home/moving.ics")
            #expect(try SyncPushAcknowledgement.acknowledgeDeletion(deletion, container: container) != nil)
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 0)
    }

    @Test("A source DELETE cannot acknowledge a deleted move restored while the request was in flight")
    @MainActor
    func restoredMoveKeepsSourceMarker() throws {
        let container = try makeContainer()
        let main = container.mainContext
        let fixture = try makeFixture(in: main)
        let moved = try syncedTask("restored", in: fixture.work, context: main)
        moved.attachmentStateKnown = true
        TaskMover.move(moved, to: fixture.home, in: main)
        TaskListHelpers.markDeleted(moved)
        try main.save()

        let candidate = try #require(try SyncMoveSnapshot(task: moved))
        let snapshot = try #require(try SyncMoveAcknowledgement.deletionSnapshot(candidate, container: container))
        let edit = ModelContext(container)
        let restored = try #require(try edit.fetch(FetchDescriptor<TaskItem>()).first)
        restored.isDeletedLocally = false
        try edit.save()

        #expect(try SyncMoveAcknowledgement.acknowledgeDelete(snapshot, container: container) == nil)
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(!stored.isDeletedLocally)
        #expect(stored.pendingMoveFromHref == "/cal/work/restored.ics")
        #expect(stored.pendingMoveFromListID == fixture.work.id)
    }

    @Test("Deleting a moved task retains both photo originals until its cleanup is queued",
          arguments: [false, true])
    @MainActor
    func deletedMoveQueuesPhotoOriginals(destinationRepairPending: Bool) async throws {
        let container = try makeContainer()
        let main = container.mainContext
        let fixture = try makeFixture(in: main)
        fixture.work.serverURL = "/work/"
        fixture.home.serverURL = "/home/"
        for list in [fixture.work, fixture.home] {
            list.syncCTag = "c1"
            list.lastFullPullDate = Date()
            SyncEngine.markCategoriesCaughtUp(listID: list.id)
        }
        let host = "deleted-photo-move-" + UUID().uuidString.lowercased() + ".invalid"
        let baseURL = "https://" + host
        fixture.account.serverBaseURL = baseURL
        let accountID = fixture.account.id
        let moved = try syncedTask("photo-move", in: fixture.work, context: main)
        moved.attachmentStateKnown = true
        let photo = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        photo.originalRequested = true
        photo.originalFileID = "801"
        photo.folderFileID = "701"
        main.insert(photo)
        photo.task = moved
        try acceptPhotoOriginal(photo, in: main)
        TaskMover.move(moved, to: fixture.home, in: main)
        try landPut(moved)
        try acceptPhotoOriginal(photo, fileID: "802", folderID: "702", in: main)
        photo.pendingOperation = TaskPhotoOperation.add.rawValue
        if destinationRepairPending {
            var state = VTODOOpaqueState.empty
            state.destinationRepairPending = true
            try state.store(taskID: moved.id, in: main)
        }
        TaskListHelpers.markDeleted(moved)
        try main.save()
        for list in [fixture.work, fixture.home] {
            try DAVSyncScenario.seedRecentCheckpoint(for: list, in: container)
        }
        let id = moved.id
        let sourceID = fixture.work.id

        let sweep = ModelContext(container)
        var sent: [String] = []
        _ = await PendingMoveSweep.run(
            PendingMoveSweep.candidates(sourceListIDs: [sourceID], in: sweep), in: sweep
        ) { sent.append($0.sourceHref) }
        try #require(sent == ["/work/photo-move.ics"])
        let held = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(held.pendingMoveFromHref == nil)
        #expect(held.photos.first?.previousOriginalFileID == "801")
        #expect(held.photos.first?.originalFileID == "802")

        func destinationSync(_ response: ScriptedDAVProtocol.Response) -> Task<SyncOutcome, Never> {
            let config = ScriptedDAVProtocol.install(host: host, responses:
                DAVSyncScenario.discovery(paths: ["/work/", "/home/"]) + [response])
            let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config,
                retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
            return Task {
                await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
                    credentials: .init(username: "sam", password: "fixture"), modelContainer: container,
                    reconcileNotifications: false)
            }
        }
        let refused = await destinationSync(.init(status: 403, body: "")).value
        #expect(refused.status == .partial)
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "DELETE" }.map(\.path)
            == ["/home/photo-move.ics"])
        let afterFailure = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(afterFailure.isDeletedLocally)
        #expect(afterFailure.photos.first?.previousOriginalFileID == "801")
        #expect(afterFailure.photos.first?.originalFileID == "802")

        let gate = ScriptedDAVProtocol.Gate()
        defer { gate.release() }
        let operation = destinationSync(.init(status: 204, body: "", gate: gate))
        for _ in 0..<500 where !ScriptedDAVProtocol.requests(host: host).contains(where: { $0.method == "DELETE" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ScriptedDAVProtocol.requests(host: host).contains { $0.method == "DELETE" })
        let restore = ModelContext(container)
        let restored = try #require(try restore.fetch(FetchDescriptor<TaskItem>()).first)
        restored.isDeletedLocally = false
        try restore.save()
        gate.release()
        _ = await operation.value

        let final = ModelContext(container)
        let restoredOnDisk = try #require(try final.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(!restoredOnDisk.isDeletedLocally)
        #expect(restoredOnDisk.photos.first?.previousOriginalFileID == "801")
        #expect(restoredOnDisk.photos.first?.originalFileID == "802")
        #expect(try final.fetch(FetchDescriptor<SyncMetadata>()).allSatisfy { !$0.id.hasPrefix(TaskPhotoCleanupQueue.prefix) })

        TaskListHelpers.markDeleted(restoredOnDisk)
        try final.save()
        let deletion = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: id, container: container))
        #expect(try SyncPushAcknowledgement.acknowledgeDeletion(deletion, container: container) != nil)
        let work = try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>())
        let source = try #require(work.first { $0.syncToken == "801" })
        #expect(source.collectionPath == "/work/")
        #expect(source.photoFolderID == "701")
        #expect(source.lastCTag == fixture.account.id)
        let destination = try #require(work.first { $0.syncToken == "802" })
        #expect(destination.collectionPath == "/home/")
        #expect(destination.photoFolderID == "702")
        #expect(destination.lastCTag == fixture.account.id)
    }

    @Test("A deleted move's source DELETE is not retried after the task is restored")
    @MainActor
    func deletedMoveSourceRetryStopsAfterRestore() async throws {
        let container = try makeContainer()
        let main = container.mainContext
        let fixture = try makeFixture(in: main)
        fixture.work.serverURL = "/work/"
        fixture.home.serverURL = "/home/"
        for list in [fixture.work, fixture.home] {
            list.syncCTag = "c1"
            list.lastFullPullDate = Date()
            SyncEngine.markCategoriesCaughtUp(listID: list.id)
        }
        let host = "source-replay-" + UUID().uuidString.lowercased() + ".invalid"
        let baseURL = "https://" + host
        fixture.account.serverBaseURL = baseURL
        let accountID = fixture.account.id
        let moved = try syncedTask("restored", in: fixture.work, context: main)
        moved.attachmentStateKnown = true
        TaskMover.move(moved, to: fixture.home, in: main)
        TaskListHelpers.markDeleted(moved)
        try main.save()
        for list in [fixture.work, fixture.home] {
            try DAVSyncScenario.seedRecentCheckpoint(for: list, in: container)
        }

        let saveRestore: @MainActor @Sendable () throws -> Void = {
            let edit = ModelContext(container)
            let current = try #require(try edit.fetch(FetchDescriptor<TaskItem>()).first)
            current.isDeletedLocally = false
            try edit.save()
        }
        let config = ScriptedDAVProtocol.install(host: host, responses:
            DAVSyncScenario.discovery(paths: ["/work/", "/home/"]) +
            [.init(status: 500, body: ""), .init(status: 204, body: "")])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config,
            retryPolicy: .init(maxAttempts: 2, baseDelay: 0), sleep: { _ in try await saveRestore() }))
        _ = await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
            credentials: .init(username: "sam", password: "fixture"), modelContainer: container,
            reconcileNotifications: false)

        let deletions = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "DELETE" }
        #expect(deletions.map(\.path) == ["/work/restored.ics"])
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(!stored.isDeletedLocally)
        #expect(stored.pendingMoveFromHref == "/work/restored.ics")
        #expect(stored.pendingMoveFromListID == fixture.work.id)
    }

    @Test("Source success finishes a deleted Vault subtree and queues its original")
    @MainActor
    func deletedVaultSubtreeFinishesChildBeforeParent() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeFixture(in: context)
        let host = try configureSourceSync(fixture, in: container)
        let parent = try syncedTask("parent", in: fixture.work, context: context)
        let child = try syncedTask("child", in: fixture.work, context: context)
        child.parentTask = parent
        child.parentUID = parent.uid
        for node in [parent, child] { node.attachmentStateKnown = true }
        let photo = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        photo.originalRequested = true
        photo.originalFileID = "801"
        photo.folderFileID = "701"
        context.insert(photo)
        photo.task = child
        try acceptPhotoOriginal(photo, in: context)

        TaskMover.move(parent, to: fixture.vaultList, in: context)
        TaskListHelpers.markDeleted(parent)
        try context.save()

        let configuration = ScriptedDAVProtocol.install(host: host,
            responses: DAVSyncScenario.discovery(paths: ["/work/", "/home/"]) +
                [.init(status: 204, body: ""), .init(status: 204, body: "")])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: configuration,
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let outcome = await engine.performFullSyncOutcome(accountID: fixture.account.id,
            serverBaseURL: "https://" + host, credentials: .init(username: "sam", password: "fixture"),
            modelContainer: container, reconcileNotifications: false)

        let deletions = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "DELETE" }
        #expect(deletions.map(\.path) == ["/work/child.ics", "/work/parent.ics"])
        let saved = ModelContext(container)
        #expect(try saved.fetchCount(FetchDescriptor<TaskItem>()) == 0)
        #expect(outcome.deletedCount == 2)
        let work = try #require(try saved.fetch(FetchDescriptor<SyncMetadata>()).first { $0.syncToken == "801" })
        #expect(work.collectionPath == "/work/")
        #expect(work.lastCTag == fixture.account.id)
        #expect(work.photoFolderID == "701")
    }

    enum SourceChildArrival: Sendable {
        case admission, retry, redirect, acknowledgement
    }

    @Test("A surviving unresolved source child blocks the parent source DELETE",
          arguments: [SourceChildArrival.admission, .retry, .redirect, .acknowledgement])
    @MainActor
    func unresolvedSourceChildBlocksMovedParent(at arrival: SourceChildArrival) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeFixture(in: context)
        let host = try configureSourceSync(fixture, in: container)
        let baseURL = "https://" + host
        let sourceID = fixture.work.id
        let parent = try syncedTask("parent", in: fixture.work, context: context)
        parent.attachmentStateKnown = true
        TaskMover.move(parent, to: fixture.home, in: context)
        TaskListHelpers.markDeleted(parent)
        try context.save()

        let saveSourceChild: @MainActor @Sendable () throws -> Void = {
            let edit = ModelContext(container)
            let source = try #require(try edit.fetch(FetchDescriptor<TaskList>()).first { $0.id == sourceID })
            let child = TaskItem(uid: "child", title: "Unresolved child")
            edit.insert(child)
            child.taskList = source
            child.parentUID = "parent"
            child.remoteHref = "/work/child.ics"
            child.isLocalOnly = false
            child.isDirty = false
            try edit.save()
        }
        if arrival == .admission { try saveSourceChild() }

        let gate = ScriptedDAVProtocol.Gate()
        defer { gate.release() }
        let first: ScriptedDAVProtocol.Response
        switch arrival {
        case .admission: first = .init(status: 204, body: "")
        case .retry: first = .init(status: 500, body: "")
        case .redirect:
            let target = try #require(URL(string: baseURL + "/work/redirected-parent.ics"))
            first = .init(status: 307, body: "", headers: ["Location": target.absoluteString],
                          gate: gate, redirectURL: target)
        case .acknowledgement: first = .init(status: 204, body: "", gate: gate)
        }
        let configuration = ScriptedDAVProtocol.install(host: host,
            responses: DAVSyncScenario.discovery(paths: ["/work/", "/home/"]) +
                [first, .init(status: 204, body: "")])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: configuration,
            retryPolicy: .init(maxAttempts: 2, baseDelay: 0), sleep: { _ in
                if arrival == .retry { try await saveSourceChild() }
            }))
        let accountID = fixture.account.id
        let run = Task {
            await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
                credentials: .init(username: "sam", password: "fixture"), modelContainer: container,
                reconcileNotifications: false)
        }
        if arrival == .redirect || arrival == .acknowledgement {
            for _ in 0..<500 where !ScriptedDAVProtocol.requests(host: host).contains(where: { $0.method == "DELETE" }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(ScriptedDAVProtocol.requests(host: host).contains { $0.method == "DELETE" })
            try saveSourceChild()
            gate.release()
        }
        _ = await run.value

        let deletions = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "DELETE" }
        #expect(deletions.map(\.path) == (arrival == .admission ? [] : ["/work/parent.ics"]))
        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(saved.first { $0.uid == "parent" }?.pendingMoveFromHref == "/work/parent.ics")
        #expect(saved.first { $0.uid == "child" }?.parentTask == nil)
        #expect(saved.first { $0.uid == "child" }?.taskList?.id == sourceID)
    }

    @Test("Source replay and acknowledgement refuse changed photo ownership",
          arguments: [SourceChildArrival.retry, .redirect, .acknowledgement], ["currentFolder", "previousFolder", "sidecar"])
    @MainActor
    func changedPhotoOwnershipStopsSource(at arrival: SourceChildArrival, field: String) async throws {
        let container = try makeContainer(); let context = container.mainContext
        let fixture = try makeFixture(in: context); let host = try configureSourceSync(fixture, in: container)
        let baseURL = "https://" + host
        let parent = try syncedTask("parent", in: fixture.work, context: context)
        parent.attachmentStateKnown = true
        let sourcePhoto = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        context.insert(sourcePhoto); sourcePhoto.task = parent
        sourcePhoto.originalFileID = "801"; sourcePhoto.folderFileID = "701"
        try acceptPhotoOriginal(sourcePhoto, in: context)
        sourcePhoto.pendingOperation = "remove"
        TaskMover.move(parent, to: fixture.home, in: context)
        let destinationPhoto = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        context.insert(destinationPhoto); destinationPhoto.task = parent
        destinationPhoto.originalFileID = "802"; destinationPhoto.folderFileID = "702"
        try acceptPhotoOriginal(destinationPhoto, in: context)
        destinationPhoto.pendingOperation = "remove"
        TaskListHelpers.markDeleted(parent); try context.save()
        let destinationID = destinationPhoto.id
        let change: @MainActor @Sendable () throws -> Void = {
            let edit = ModelContext(container)
            let photos = try edit.fetch(FetchDescriptor<TaskPhoto>())
            switch field {
            case "currentFolder": photos.first { $0.id == destinationID }?.folderFileID = "799"
            case "previousFolder": photos.first { $0.id != destinationID }?.previousOriginalFolderID = "799"
            default:
                let row = try #require(try edit.fetch(FetchDescriptor<SyncMetadata>()).first {
                    $0.id == TaskPhotoOwnership.prefix + destinationID
                })
                row.syncToken = "unsupported ownership"
            }
            try edit.save()
        }
        let gate = ScriptedDAVProtocol.Gate(); defer { gate.release() }
        let first: ScriptedDAVProtocol.Response
        if arrival == .retry { first = .init(status: 500, body: "") }
        else if arrival == .redirect {
            let target = try #require(URL(string: baseURL + "/work/redirected-parent.ics"))
            first = .init(status: 307, body: "", headers: ["Location": target.absoluteString], gate: gate, redirectURL: target)
        } else { first = .init(status: 204, body: "", gate: gate) }
        let configuration = ScriptedDAVProtocol.install(host: host,
            responses: DAVSyncScenario.discovery(paths: ["/work/", "/home/"]) + [first, .init(status: 204, body: "")])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: configuration,
            retryPolicy: .init(maxAttempts: 2, baseDelay: 0), sleep: { _ in
                if arrival == .retry { try await change() }
            }))
        let accountID = fixture.account.id
        let run = Task { await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
            credentials: .init(username: "sam", password: "fixture"), modelContainer: container, reconcileNotifications: false) }
        if arrival != .retry {
            for _ in 0..<500 where !ScriptedDAVProtocol.requests(host: host).contains(where: { $0.method == "DELETE" }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(ScriptedDAVProtocol.requests(host: host).contains { $0.method == "DELETE" })
            try change(); gate.release()
        }
        _ = await run.value
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "DELETE" }.map(\.path) == ["/work/parent.ics"])
        let saved = ModelContext(container)
        #expect(try saved.fetch(FetchDescriptor<TaskItem>()).first?.pendingMoveFromHref == "/work/parent.ics")
        #expect(try saved.fetchCount(FetchDescriptor<TaskPhoto>()) == 2)
        #expect(try saved.fetch(FetchDescriptor<SyncMetadata>()).allSatisfy { !$0.id.hasPrefix(TaskPhotoCleanupQueue.prefix) })
    }

    @MainActor
    private func configureSourceSync(_ fixture: Fixture, in container: ModelContainer) throws -> String {
        fixture.work.serverURL = "/work/"
        fixture.home.serverURL = "/home/"
        for list in [fixture.work, fixture.home] {
            list.syncCTag = "c1"
            list.lastFullPullDate = Date()
            SyncEngine.markCategoriesCaughtUp(listID: list.id)
        }
        let host = "source-move-" + UUID().uuidString.lowercased() + ".invalid"
        fixture.account.serverBaseURL = "https://" + host
        for list in [fixture.work, fixture.home] {
            try DAVSyncScenario.seedRecentCheckpoint(for: list, in: container)
        }
        return host
    }

    @Test("Deleting a cross-account move queues a pending-removal original in its source",
          arguments: [false, true])
    @MainActor
    func deletedMoveQueuesRemovedPhotoInItsOriginalAccount(hasPreviousOriginal: Bool) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeFixture(in: context)
        let other = ServerAccount(displayName: "Other", serverBaseURL: "https://other.invalid",
                                  username: "other", mode: .nextcloud)
        context.insert(other)
        fixture.home.account = other
        let item = try syncedTask("photo", in: fixture.work, context: context)
        item.attachmentStateKnown = true

        let removal = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        context.insert(removal)
        removal.task = item
        removal.pendingOperation = TaskPhotoOperation.remove.rawValue
        removal.originalFileID = "801"
        removal.folderFileID = "701"
        if hasPreviousOriginal {
            removal.previousOriginalFileID = "800"
            removal.previousOriginalFolderID = "700"
            removal.previousOriginalAccountID = fixture.account.id
            removal.previousOriginalListID = fixture.work.id
        }
        try acceptPhotoOriginal(removal, in: context)
        TaskMover.move(item, to: fixture.home, in: context)

        let destination = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        context.insert(destination)
        destination.task = item
        destination.originalFileID = "802"
        destination.folderFileID = "702"
        try acceptPhotoOriginal(destination, in: context)
        try landPut(item)
        TaskListHelpers.markDeleted(item)
        try context.save()

        let sweep = ModelContext(container)
        var sent: [String] = []
        _ = await PendingMoveSweep.run(
            PendingMoveSweep.candidates(sourceListIDs: [fixture.work.id], in: sweep), in: sweep
        ) { sent.append($0.sourceHref) }
        try #require(sent == ["/cal/work/photo.ics"])
        let snapshot = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: item.id, container: container))
        #expect(try SyncPushAcknowledgement.acknowledgeDeletion(snapshot, container: container) != nil)

        let saved = ModelContext(container)
        let work = try saved.fetch(FetchDescriptor<SyncMetadata>()).filter {
            $0.id.hasPrefix(TaskPhotoCleanupQueue.prefix)
        }
        let sourceWork = try #require(work.first { $0.syncToken == "801" })
        #expect(sourceWork.lastCTag == fixture.account.id)
        #expect(sourceWork.collectionPath == "/cal/work/")
        #expect(sourceWork.photoFolderID == "701")
        let destinationWork = try #require(work.first { $0.syncToken == "802" })
        #expect(destinationWork.lastCTag == other.id)
        #expect(destinationWork.collectionPath == "/cal/home/")
        #expect(destinationWork.photoFolderID == "702")
        if hasPreviousOriginal {
            let previousWork = try #require(work.first { $0.syncToken == "800" })
            #expect(previousWork.lastCTag == fixture.account.id)
            #expect(previousWork.collectionPath == "/cal/work/")
            #expect(previousWork.photoFolderID == "700")
        }
    }

    @Test("A deleted legacy move keeps the source marker when original ownership is ambiguous", arguments: [false, true])
    @MainActor
    func ambiguousLegacyRemovalKeepsSourceObligation(hasPrevious: Bool) throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeFixture(in: context)
        let item = try syncedTask("ambiguous", in: fixture.home, context: context)
        item.attachmentStateKnown = true
        item.pendingMoveFromHref = "/cal/work/ambiguous.ics"
        item.pendingMoveFromListID = fixture.work.id
        try SyncResourceFixture.proveSource(item, in: context)
        let removal = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        context.insert(removal)
        removal.task = item
        removal.pendingOperation = TaskPhotoOperation.remove.rawValue
        removal.originalFileID = "801"
        removal.folderFileID = "701"
        if hasPrevious {
            removal.previousOriginalFileID = "800"; removal.previousOriginalFolderID = "700"
            removal.previousOriginalAccountID = fixture.account.id; removal.previousOriginalListID = fixture.work.id
        }
        TaskListHelpers.markDeleted(item)
        try context.save()

        #expect(throws: TaskPhotoOwnership.Failure.self) {
            _ = try SyncMoveSnapshot(task: item)
        }
        context.delete(fixture.work)
        try context.save()
        #expect(try PendingMoveSweep.clearOrphans(in: context) == 0)
        let saved = ModelContext(container)
        let retained = try #require(try saved.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(retained.pendingMoveFromHref == "/cal/work/ambiguous.ics")
        #expect(retained.photos.first?.originalFileID == "801")
        #expect(retained.photos.first?.folderFileID == "701")
    }

    // MARK: - Dangling moves

    @Test("A move whose source list no longer exists is abandoned, not kept forever")
    func orphanedMovesAreCleared() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let f = try makeFixture(in: context)

        let task = try syncedTask("uid-1", in: f.work, context: context)
        TaskMover.move(task, to: f.vaultList, in: context)
        try context.save()

        context.delete(f.work)
        try context.save()

        let cleared = try PendingMoveSweep.clearOrphans(in: context)
        #expect(cleared == 1)
        #expect(task.pendingMoveFromHref == nil)
        #expect(task.pendingMoveFromListID == nil)
        #expect(task.taskList?.id == f.vaultList.id)
    }

    @Test("A failed list fetch leaves the source marker intact after an unrelated save")
    func failedListReadKeepsPendingMoveSource() throws {
        enum ListReadError: Error { case unavailable }
        let container = try makeContainer()
        let context = ModelContext(container)
        let fixture = try makeFixture(in: context)
        let task = try syncedTask("moving", in: fixture.work, context: context)
        let unrelated = try syncedTask("unrelated", in: fixture.home, context: context)
        TaskMover.move(task, to: fixture.vaultList, in: context)
        try context.save()

        do {
            try PendingMoveSweep.clearOrphans(in: context) { throw ListReadError.unavailable }
            Issue.record("List read failure must be reported")
        } catch ListReadError.unavailable {
            // The failed read leaves the model unchanged.
        }
        unrelated.title = "Unrelated edit"
        try context.save()

        let stored = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        let moved = try #require(stored.first { $0.uid == "moving" })
        #expect(moved.pendingMoveFromHref == "/cal/work/moving.ics")
        #expect(moved.pendingMoveFromListID == fixture.work.id)
        #expect(stored.first { $0.uid == "unrelated" }?.title == "Unrelated edit")
    }
}
