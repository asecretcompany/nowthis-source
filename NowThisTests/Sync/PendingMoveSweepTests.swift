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

    private func syncedTask(_ uid: String, in list: TaskList, context: ModelContext) -> TaskItem {
        let task = TaskItem(uid: uid, title: "Task \(uid)")
        context.insert(task)
        task.taskList = list
        task.remoteHref = "\(list.serverURL)\(uid).ics"
        task.etag = "etag-\(uid)"
        task.isLocalOnly = false
        return task
    }

    /// Simulates the destination push having landed.
    private func landPut(_ task: TaskItem) {
        task.remoteHref = "\(task.taskList?.serverURL ?? "")\(task.uid).ics"
        task.etag = "etag-new-\(task.uid)"
        task.isDirty = false
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

        let task = syncedTask("uid-1", in: f.work, context: context)
        TaskMover.move(task, to: f.home, in: context)
        try context.save()

        #expect(PendingMoveSweep.candidates(sourceListIDs: [f.work.id], in: context).isEmpty,
                "deleting now would leave the server with no copy")

        landPut(task)
        try context.save()
        let ready = PendingMoveSweep.candidates(sourceListIDs: [f.work.id], in: context)
        #expect(ready.map(\.uid) == ["uid-1"], "examined \(ready.count) candidates")
    }

    @Test("A move into the Vault is ready at once — it will never be pushed")
    func vaultDestinationIsReadyImmediately() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let f = try makeFixture(in: context)

        let task = syncedTask("uid-v", in: f.work, context: context)
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

        let parent = syncedTask("uid-p", in: f.work, context: context)
        let child = syncedTask("uid-c", in: f.work, context: context)
        child.parentTask = parent
        child.parentUID = parent.uid
        let unrelated = syncedTask("uid-h", in: f.home, context: context)
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

        var task = syncedTask("uid-1", in: f.work, context: context)
        TaskMover.move(task, to: f.home, in: context)
        landPut(task)
        try context.save()

        var deleted: [String] = []
        let denied = await PendingMoveSweep.run(
            PendingMoveSweep.candidates(sourceListIDs: [f.work.id], in: context),
            in: context
        ) { href in deleted.append(href) }
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

        let task = syncedTask("uid-1", in: f.work, context: context)
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

        var task = syncedTask("uid-1", in: f.work, context: context)
        TaskMover.move(task, to: f.home, in: context)
        landPut(task)
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

        let task = syncedTask("uid-1", in: f.work, context: context)
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

        let task = syncedTask("uid-1", in: f.work, context: context)
        task.isDirty = true
        try context.save()

        #expect(!TaskMover.rollBackRefusedPut(task, in: context))
        #expect(task.taskList?.id == f.work.id)
        #expect(task.isDirty)
    }

    // MARK: - Dangling moves

    @Test("A move whose source list no longer exists is abandoned, not kept forever")
    func orphanedMovesAreCleared() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let f = try makeFixture(in: context)

        let task = syncedTask("uid-1", in: f.work, context: context)
        TaskMover.move(task, to: f.vaultList, in: context)
        try context.save()

        context.delete(f.work)
        try context.save()

        let cleared = PendingMoveSweep.clearOrphans(in: context)
        #expect(cleared == 1)
        #expect(task.pendingMoveFromHref == nil)
        #expect(task.pendingMoveFromListID == nil)
        #expect(task.taskList?.id == f.vaultList.id)
    }
}
