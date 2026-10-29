import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite(.serialized)
@MainActor
struct TaskPhotoSyncTests {
    private let jpeg = TaskPhotoJPEGFixture.data
    private let first = "AD2E616C-55C0-4F7C-A3C4-32AD464EC9E4"
    private let second = "BD2E616C-55C0-4F7C-A3C4-32AD464EC9E4"

    private func fixture() throws -> (ModelContainer, TaskItem, TaskList) {
        let c = try ModelContainer(for: Schema(SchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let list = TaskList(serverURL: "/remote.php/dav/calendars/team/tasks/", name: "Team", colorHex: "#007AFF")
        let account = ServerAccount(displayName: "Cloud", serverBaseURL: "https://example.com", username: "team")
        c.mainContext.insert(account); c.mainContext.insert(list); list.account = account
        let task = TaskItem(uid: "shared-photo", title: "Local title")
        c.mainContext.insert(task); task.taskList = list
        task.remoteHref = list.serverURL + "shared-photo.ics"; task.etag = "old"; task.isLocalOnly = false
        return (c, task, list)
    }

    @Test func inboundPreviewAndOpaqueAttachmentReachStoredTask() throws {
        let (c, task, _) = try fixture()
        var data = ICalendarParser.VTODOData(); data.uid = task.uid; data.summary = "Remote"
        data.photos = [.init(id: first, previewData: jpeg)]
        data.opaqueAttachments = ["ATTACH:https://example.com/manual.pdf"]
        try SyncImportStore(context: c.mainContext).applyFields(data, to: task)
        #expect(task.photos.map(\.photoID) == [first])
        #expect(task.opaqueAttachments == data.opaqueAttachments)
        let serialized = SyncPushSnapshot.serialize(task, stamp: Date())
        let parsed = try #require(try ICalendarParser.parseSingleVTODO(from: serialized))
        #expect(parsed.photos == data.photos)
        #expect(parsed.opaqueAttachments == data.opaqueAttachments)
    }

    @Test func conflictRetainsLocalAdditionAndRemoteFieldsAndPhotos() throws {
        let (c, task, list) = try fixture()
        let local = TaskPhoto(photoID: first, previewData: jpeg)
        local.pendingOperation = "add"; c.mainContext.insert(local); local.task = task
        task.isDirty = true; try c.mainContext.save()
        let snapshot = SyncPushSnapshot(task: task, calendarPath: list.serverURL)
        var data = ICalendarParser.VTODOData(); data.uid = task.uid; data.summary = "Remote title"
        data.description = "Remote notes"; data.photos = [.init(id: second, previewData: jpeg)]
        _ = try SyncPushAcknowledgement.applyConflict(snapshot,
            resource: ParsedRemoteTask(href: snapshot.path, etag: "new", todo: data), container: c)
        let fresh = ModelContext(c)
        let updated = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(updated.title == "Remote title")
        #expect(updated.notes == "Remote notes")
        #expect(Set(updated.photos.map(\.photoID)) == [first, second])
        #expect(updated.photos.first(where: { $0.photoID == first })?.pendingOperation == "add")
        #expect(updated.isDirty)
    }

    @Test func acknowledgedRemovalQueuesOriginalCleanupAfterReferenceWrite() throws {
        let (c, task, list) = try fixture()
        let photo = TaskPhoto(photoID: first, previewData: jpeg)
        photo.originalFileID = "900"; photo.pendingOperation = "remove"
        c.mainContext.insert(photo); photo.task = task; task.isDirty = true
        try c.mainContext.save()
        let snapshot = SyncPushSnapshot(task: task, calendarPath: list.serverURL)
        try SyncPushAcknowledgement.acknowledge(snapshot, etag: "accepted", container: c)
        let fresh = ModelContext(c)
        #expect(try fresh.fetchCount(FetchDescriptor<TaskPhoto>()) == 0)
        let rows = try fresh.fetch(FetchDescriptor<SyncMetadata>())
        #expect(rows.contains(where: { $0.id.hasPrefix("taskPhotoCleanup:") && $0.syncToken == "900" }))
    }

    @Test func newerPhotoAdditionDuringPutRemainsDirty() throws {
        let (c, task, list) = try fixture()
        let photo = TaskPhoto(photoID: first, previewData: jpeg)
        photo.pendingOperation = "add"; c.mainContext.insert(photo); photo.task = task
        task.isDirty = true; try c.mainContext.save()
        let snapshot = SyncPushSnapshot(task: task, calendarPath: list.serverURL)
        _ = try TaskPhotoMutations.add(preview: jpeg, originalRequested: false,
            contentType: nil, to: task, in: c.mainContext)
        try SyncPushAcknowledgement.acknowledge(snapshot, etag: "accepted", container: c)
        let fresh = ModelContext(c)
        #expect(try fresh.fetch(FetchDescriptor<TaskItem>()).first?.isDirty == true)
    }

    @Test func moveClearsOwnerPrivateOriginalLinkButKeepsPreviewAndSource() throws {
        let (c, task, source) = try fixture()
        let photo = TaskPhoto(photoID: first, previewData: jpeg)
        photo.originalRequested = true; photo.originalFileID = "900"; photo.folderFileID = "899"
        c.mainContext.insert(photo); photo.task = task
        let destination = TaskList(serverURL: "/other/", name: "Other", colorHex: "#007AFF")
        c.mainContext.insert(destination); destination.account = source.account
        TaskMover.move(task, to: destination, in: c.mainContext)
        #expect(photo.previewData == jpeg)
        #expect(photo.originalFileID == nil)
        #expect(photo.folderFileID == nil)
        #expect(photo.previousOriginalFileID == "900")
        #expect(photo.previousOriginalListID == source.id)
    }
    @Test func unknownLegacyAttachmentsBlockOutboundRewrite() throws {
        let (c, task, list) = try fixture()
        task.attachmentStateKnown = nil; task.isDirty = true
        try c.mainContext.save()
        #expect(throws: TaskPhotoAttachmentError.self) {
            _ = try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: list.serverURL, container: c)
        }
    }
    @Test func invalidPreviewCannotBeSilentlyOmittedByPush() throws {
        let (c, task, list) = try fixture()
        let photo = TaskPhoto(previewData: Data([0xff, 0xd8, 0xff, 0xd9]))
        c.mainContext.insert(photo); photo.task = task; task.isDirty = true
        try c.mainContext.save()
        #expect(throws: TaskPhotoAttachmentError.self) {
            _ = try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: list.serverURL, container: c)
        }
    }
    @Test func concurrentSixthPhotoPreservesOperationsAndBlocksOversizedPush() throws {
        let (c, task, list) = try fixture()
        for _ in 0..<6 {
            let photo = TaskPhoto(previewData: jpeg); photo.pendingOperation = "add"
            c.mainContext.insert(photo); photo.task = task
        }
        task.isDirty = true; try c.mainContext.save()
        #expect(throws: TaskPhotoAttachmentError.self) {
            _ = try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: list.serverURL, container: c)
        }
        #expect(task.photos.count == 6)
        #expect(task.photos.allSatisfy { $0.pendingOperation == "add" })
    }
    @Test func moveRetainsSourceFolderForAuthenticatedCopy() throws {
        let (c, task, source) = try fixture()
        let photo = TaskPhoto(previewData: jpeg)
        photo.originalRequested = true; photo.originalFileID = "900"; photo.folderFileID = "899"
        c.mainContext.insert(photo); photo.task = task
        let destination = TaskList(serverURL: "/other/", name: "Other", colorHex: "#007AFF")
        c.mainContext.insert(destination); destination.account = source.account
        TaskMover.move(task, to: destination, in: c.mainContext)
        #expect(photo.previousOriginalFolderID == "899")
    }
    @Test func previewFailureHasSpecificUserGuidance() {
        #expect(SyncFailure.from(TaskPhotoAttachmentError.invalid)?.message ==
            "A task photo could not be synced because its attachment is invalid or too large. Ask the list owner to replace it.")
    }

    @Test func movedOriginalRetainsRollbackBindingUntilSourceDelete() throws {
        let (c, task, source) = try fixture()
        let photo = TaskPhoto(previewData: jpeg)
        photo.originalRequested = true; photo.originalFileID = "900"; photo.folderFileID = "899"
        c.mainContext.insert(photo); photo.task = task
        let destination = TaskList(serverURL: "/other/", name: "Other", colorHex: "#007AFF")
        c.mainContext.insert(destination); destination.account = source.account
        TaskMover.move(task, to: destination, in: c.mainContext)
        photo.originalFileID = "902"; photo.folderFileID = "901"
        try c.mainContext.save()
        let push = SyncPushSnapshot(task: task, calendarPath: destination.serverURL)
        try SyncPushAcknowledgement.acknowledge(push, etag: "dest", container: c)
        let fresh = ModelContext(c)
        let taskID = push.taskID
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
        #expect(stored.photos.first?.previousOriginalFileID == "900")
        #expect(stored.photos.first?.previousOriginalFolderID == "899")
        #expect(!((try fresh.fetch(FetchDescriptor<SyncMetadata>())).contains { $0.syncToken == "900" }))
        #expect(TaskMover.rollBackRefusedDelete(stored, in: fresh))
        #expect(stored.photos.first?.originalFileID == "900")
        #expect(stored.photos.first?.folderFileID == "899")
        let tombstone = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first { $0.isDeletedLocally })
        #expect(tombstone.photos.first?.originalFileID == "902")
    }

    @Test func moveNeverDeletesSourceBeforeOriginalCopyExists() throws {
        let (c, task, source) = try fixture()
        let photo = TaskPhoto(previewData: jpeg)
        photo.originalRequested = true; photo.originalFileID = "900"; photo.folderFileID = "899"
        c.mainContext.insert(photo); photo.task = task
        let destination = TaskList(serverURL: "/other/", name: "Other", colorHex: "#007AFF")
        c.mainContext.insert(destination); destination.account = source.account
        TaskMover.move(task, to: destination, in: c.mainContext)
        task.remoteHref = "/other/shared-photo.ics"; task.isDirty = false
        try c.mainContext.save()
        #expect(PendingMoveSweep.candidates(sourceListIDs: [source.id], in: c.mainContext).isEmpty)
        photo.originalFileID = "902"; photo.folderFileID = "901"
        #expect(PendingMoveSweep.candidates(sourceListIDs: [source.id], in: c.mainContext).isEmpty,
            "An uploaded original is not an acknowledged VTODO link")
        photo.pendingOperation = nil
        #expect(PendingMoveSweep.candidates(sourceListIDs: [source.id], in: c.mainContext).map(\.id) == [task.id])
    }
    @Test func sourceDeleteRechecksEveryCandidateAfterEarlierNetworkAwaits() async throws {
        let (c, task, source) = try fixture()
        let destination = TaskList(serverURL: "/other/", name: "Other", colorHex: "#007AFF")
        c.mainContext.insert(destination); destination.account = source.account
        let other = TaskItem(uid: "other-task", title: "Other")
        c.mainContext.insert(other); other.taskList = source; other.remoteHref = source.serverURL + "other-task.ics"
        for node in [task, other] {
            let photo = TaskPhoto(previewData: jpeg); photo.originalRequested = true
            photo.originalFileID = "900"; photo.folderFileID = "899"
            c.mainContext.insert(photo); photo.task = node
            TaskMover.move(node, to: destination, in: c.mainContext)
            node.remoteHref = "/other/" + node.uid + ".ics"; node.isDirty = false
            photo.originalFileID = "902"; photo.folderFileID = "901"; photo.pendingOperation = nil
        }
        try c.mainContext.save()
        var deleted = [String]()
        _ = await PendingMoveSweep.run([task, other], in: c.mainContext) { href in
            deleted.append(href)
            if deleted.count == 1 {
                other.photos.first?.originalFileID = nil
                other.photos.first?.pendingOperation = "add"
                other.isDirty = true; try c.mainContext.save()
            }
        }
        #expect(deleted.count == 1)
        let id = other.id; let fresh = ModelContext(c)
        #expect(try fresh.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first?.photos.first?.previousOriginalFileID == "900")
    }
    @Test func refusedSourceDeleteRollsBackUsingFreshPersistedPhotoLinks() throws {
        let (c, task, source) = try fixture()
        let photo = TaskPhoto(previewData: jpeg)
        photo.originalRequested = true; photo.originalFileID = "900"; photo.folderFileID = "899"
        c.mainContext.insert(photo); photo.task = task
        let destination = TaskList(serverURL: "/other/", name: "Other", colorHex: "#007AFF")
        c.mainContext.insert(destination); destination.account = source.account
        TaskMover.move(task, to: destination, in: c.mainContext); try c.mainContext.save()
        let taskID = task.id; let update = ModelContext(c)
        let stored = try #require(try update.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
        stored.remoteHref = "/other/" + stored.uid + ".ics"; stored.isDirty = false
        stored.photos.first?.originalFileID = "902"; stored.photos.first?.folderFileID = "901"
        stored.photos.first?.pendingOperation = nil; try update.save()
        let sent = try #require(SyncMoveSnapshot(task: stored))
        #expect(try SyncMoveAcknowledgement.rollBackRefusedDelete(sent, container: c) != nil)
        let fresh = ModelContext(c)
        let restored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
        #expect(restored.taskList?.id == source.id)
        #expect(restored.photos.first?.originalFileID == "900")
    }
    @Test func firstLegacyEditKeepsPreviouslyUnstoredRemoteAttachments() throws {
        let (c, task, list) = try fixture()
        task.attachmentStateKnown = nil; task.title = "My pending edit"; task.isDirty = true
        try c.mainContext.save()
        let accountID = try #require(list.account?.id)
        let href = try #require(try TaskPhotoLegacyCatchUp.requiredHref(taskID: task.id,
            listID: list.id, accountID: accountID, container: c))
        var data = ICalendarParser.VTODOData(); data.uid = task.uid
        data.summary = "Remote title"; data.photos = [.init(id: first, previewData: jpeg)]
        data.opaqueAttachments = ["ATTACH:https://example.com/manual.pdf"]
        _ = try TaskPhotoLegacyCatchUp.apply(data, taskID: task.id, listID: list.id,
            accountID: accountID, href: href, container: c)
        let fresh = ModelContext(c); let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "My pending edit")
        #expect(stored.photos.map(\.photoID) == [first])
        #expect(stored.opaqueAttachments == data.opaqueAttachments)
        #expect(stored.attachmentStateKnown == true)
        #expect(stored.isDirty)
        #expect(stored.etag == "old")
    }

}
