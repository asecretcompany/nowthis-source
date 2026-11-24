import Testing
import Foundation
import SwiftData

@testable import NowThis

/// `TaskList.tasks` cascades. Delete the list a task was just moved into and the
/// task goes with it — and so do its pending-move fields, the only record that
/// its old copy in the source list is still owed a DELETE. The source list's next
/// pull then re-imports that copy: the task the user deleted comes back.
@Suite("Pending moves survive deleting the destination list")
struct PendingMoveListDeletionTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    private func setUp(_ context: ModelContext) throws -> (work: TaskList, home: TaskList, task: TaskItem) {
        let work = TaskList(serverURL: "/cal/work/", name: "Work", colorHex: "#007AFF")
        let home = TaskList(serverURL: "/cal/home/", name: "Home", colorHex: "#FF9500")
        context.insert(work)
        context.insert(home)
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: "https://fixture.invalid", username: "fixture")
        context.insert(account); work.account = account; home.account = account
        let task = TaskItem(uid: "uid-1", title: "Renew passport")
        context.insert(task)
        task.taskList = work
        task.remoteHref = "/cal/work/uid-1.ics"
        task.etag = "etag-1"
        task.isLocalOnly = false
        try SyncResourceFixture.prove(task, in: context)
        try context.save()
        TaskMover.move(task, to: home, in: context)
        try context.save()
        return (work, home, task)
    }

    private func deleteList(_ list: TaskList, in context: ModelContext) throws {
        try TaskListHelpers.settlePendingMoves(beforeDeleting: list, in: context)
        context.delete(list)
        try context.save()
    }

    private func onlyTombstone(in context: ModelContext) throws -> TaskItem? {
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(all.count == 1, "examined \(all.count) tasks")
        return all.first
    }

    @Test("Before the PUT: the source copy is still owed its DELETE")
    func deletingDestinationBeforePutLeavesATombstone() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let (work, home, _) = try setUp(context)

        try deleteList(home, in: context)

        let tombstone = try onlyTombstone(in: context)
        #expect(tombstone?.isDeletedLocally == true)
        #expect(tombstone?.taskList?.id == work.id)
        #expect(tombstone?.remoteHref == "/cal/work/uid-1.ics")
        #expect(tombstone?.etag == "etag-1", "Source cleanup keeps the captured conditional revision")
    }

    @Test("After the PUT: the source copy is still owed its DELETE")
    func deletingDestinationAfterPutLeavesATombstone() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let (work, home, task) = try setUp(context)
        task.remoteHref = "/cal/home/uid-1.ics"
        task.etag = "etag-home"
        task.isDirty = false
        try context.save()

        try deleteList(home, in: context)

        let tombstone = try onlyTombstone(in: context)
        #expect(tombstone?.isDeletedLocally == true)
        #expect(tombstone?.taskList?.id == work.id)
        #expect(tombstone?.remoteHref == "/cal/work/uid-1.ics",
                "the source href, not the destination's — that one goes with the list")
    }

    @Test("Deleting a destination list clones only proven source originals")
    @MainActor
    func deletedListRetainsProvenSourcePhotoUntilTombstoneDeletion() throws {
        let container = try makeContainer(); let context = container.mainContext
        let (work, home, task) = try setUp(context)
        TaskMover.move(task, to: work, in: context)
        let sourceAccount = ServerAccount(displayName: "Source", serverBaseURL: "https://source.invalid", username: "source")
        let other = ServerAccount(displayName: "Other", serverBaseURL: "https://other.invalid", username: "other")
        context.insert(sourceAccount); context.insert(other); work.account = sourceAccount; home.account = other
        let photo = TaskPhoto(previewData: TaskPhotoJPEGFixture.data); context.insert(photo); photo.task = task
        photo.originalFileID = "901"; photo.folderFileID = "900"
        try acceptPhotoOriginal(photo, in: context)
        task.etag = "revalidated-source"
        try SyncResourceFixture.prove(task, in: context)
        TaskMover.move(task, to: home, in: context)
        try acceptPhotoOriginal(photo, fileID: "902", folderID: "910", in: context)
        try context.save()
        try deleteList(home, in: context)
        let tombstone = try #require(try onlyTombstone(in: context))
        #expect(tombstone.photos.count == 1)
        #expect(tombstone.photos.first?.originalFileID == "901")
        #expect(tombstone.photos.first?.folderFileID == "900")
        #expect(try SyncPushAcknowledgement.deletionSnapshot(taskID: tombstone.id, container: container)?.etag == "revalidated-source")
        let request = try #require(try TaskPhotoLegacyCatchUp.requestInfo(taskID: tombstone.id,
            listID: work.id, accountID: sourceAccount.id, container: container))
        let body = ICalendarSerializer.serialize(uid: tombstone.uid, summary: "Source", photos: tombstone.photoAttachments)
        let parsed = try SyncBodyValidation.parse(.init(href: "/cal/work/uid-1.ics", etag: "source-refetched", icsData: body), using: .init())
        let responseScope = try #require(TaskPhotoOwnership.Scope(list: work))
        _ = try TaskPhotoLegacyCatchUp.accept(parsed, taskID: tombstone.id, listID: work.id,
            accountID: sourceAccount.id, expectedRequest: request, responseScope: responseScope, container: container)
        let sent = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: tombstone.id, container: container))
        #expect(try SyncPushAcknowledgement.acknowledgeDeletion(sent, container: container) != nil)
        let fresh = ModelContext(container)
        let queue = try fresh.fetch(FetchDescriptor<SyncMetadata>()).filter { $0.id.hasPrefix(TaskPhotoCleanupQueue.prefix) }
        #expect(queue.count == 1)
        #expect(queue.first?.syncToken == "901" && queue.first?.lastCTag == sourceAccount.id)
        #expect(try !TaskPhotoOwnership.retains(fileID: "901", accountID: sourceAccount.id, in: fresh))
    }

    @Test("Tasks without a pending move are left to the cascade")
    func ordinaryTasksAreUntouched() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let home = TaskList(serverURL: "/cal/home/", name: "Home", colorHex: "#FF9500")
        context.insert(home)
        let task = TaskItem(uid: "uid-2", title: "Water plants")
        context.insert(task)
        task.taskList = home
        try context.save()

        try deleteList(home, in: context)

        let all = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(all.isEmpty, "examined \(all.count) tasks")
    }
    @Test func laterSourceReadFailureStagesNoCleanupOrTaskMutation() throws {
        enum ReadFailure: Error { case unavailable }
        let container = try makeContainer()
        let context = ModelContext(container); context.autosaveEnabled = false
        let (work, home, first) = try setUp(context)
        let second = TaskItem(uid: "uid-2", title: "Second move")
        context.insert(second); second.taskList = work; second.remoteHref = "/cal/work/uid-2.ics"
        second.isLocalOnly = false; second.etag = "second-baseline"
        try SyncResourceFixture.prove(second, in: context)
        TaskMover.move(second, to: home, in: context)
        for task in [first, second] { try VTODOOpaqueState.empty.store(taskID: task.id, in: context) }
        try context.save()
        var reads = 0
        #expect(throws: ReadFailure.self) {
            try TaskListHelpers.settlePendingMoves(beforeDeleting: home, in: context) { sourceID in
                reads += 1
                if reads == 2 { throw ReadFailure.unavailable }
                #expect(sourceID == work.id)
                return work
            }
        }
        #expect(reads == 2)
        #expect(!context.hasChanges)
        #expect(context.insertedModelsArray.isEmpty)
        #expect(context.deletedModelsArray.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<TaskItem>()) == 2)
        #expect([first, second].allSatisfy { !$0.isDeletedLocally && $0.taskList?.id == home.id && $0.pendingMoveFromListID == work.id })
        for task in [first, second] { #expect(try VTODOOpaqueState.load(taskID: task.id, in: context) == .empty) }
    }

}
