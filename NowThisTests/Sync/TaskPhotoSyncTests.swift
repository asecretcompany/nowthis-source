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
        try VTODOOpaqueState.empty.store(taskID: task.id, in: c.mainContext)
        try SyncResourceFixture.prove(task, in: c.mainContext)
        return (c, task, list)
    }

    @Test func importedRemovalIsNormalizedBeforeMoving() throws {
        let (c, task, source) = try fixture()
        var data = ICalendarParser.VTODOData(); data.uid = task.uid; data.summary = task.title
        data.photos = [.init(id: first, previewData: jpeg, originalFileID: "901", folderFileID: "900", originalRequested: true)]
        try SyncImportStore(context: c.mainContext).applyFields(data, to: task)
        let photo = try #require(task.photos.first)
        photo.pendingOperation = "remove"
        let destination = TaskList(serverURL: "/other/", name: "Other", colorHex: "#007AFF")
        c.mainContext.insert(destination); destination.account = source.account
        #expect(TaskMover.move(task, to: destination, in: c.mainContext).count == 1)
        #expect(photo.pendingOperation == "remove")
        #expect(photo.originalFileID == nil)
        #expect(photo.folderFileID == nil)
        #expect(photo.previousOriginalFileID == "901")
        #expect(photo.previousOriginalFolderID == "900")
        #expect(photo.previousOriginalListID == source.id)
    }

    @Test func ambiguousOriginalHoldsWholeSubtreeWithoutChangingMarkers() throws {
        let (c, task, source) = try fixture()
        let child = TaskItem(title: "Child"); c.mainContext.insert(child)
        child.taskList = source; child.parentTask = task; child.parentUID = task.uid
        let photo = TaskPhoto(previewData: jpeg); c.mainContext.insert(photo); photo.task = child
        photo.originalFileID = "901"; photo.folderFileID = "900"
        let destination = TaskList(serverURL: "/other/", name: "Other", colorHex: "#007AFF")
        c.mainContext.insert(destination); destination.account = source.account
        let href = task.remoteHref
        #expect(TaskMover.move(task, to: destination, in: c.mainContext).isEmpty)
        #expect(task.taskList?.id == source.id)
        #expect(child.taskList?.id == source.id)
        #expect(task.remoteHref == href)
        #expect(task.pendingMoveFromHref == nil)
        #expect(photo.originalFileID == "901")
        #expect(photo.folderFileID == "900")
    }

    @Test func unsavedOwnershipEditPreventsSourceAcknowledgement() throws {
        let (c, task, source) = try fixture()
        let photo = TaskPhoto(previewData: jpeg); c.mainContext.insert(photo); photo.task = task
        photo.originalFileID = "901"; photo.folderFileID = "900"
        try acceptPhotoOriginal(photo, in: c.mainContext)
        photo.pendingOperation = "remove"
        let destination = TaskList(serverURL: "/other/", name: "Other", colorHex: "#007AFF")
        c.mainContext.insert(destination); destination.account = source.account
        TaskMover.move(task, to: destination, in: c.mainContext)
        task.remoteHref = "/other/shared-photo.ics"
        TaskListHelpers.markDeleted(task); try c.mainContext.save()
        let candidate = try #require(try SyncMoveSnapshot(task: task))
        let sent = try #require(try SyncMoveAcknowledgement.deletionSnapshot(candidate, container: c))
        let row = try #require(try c.mainContext.fetch(FetchDescriptor<SyncMetadata>()).first {
            $0.id == TaskPhotoOwnership.prefix + photo.id
        })
        row.syncToken = "pending editor replacement"
        #expect(try SyncMoveAcknowledgement.acknowledgeDelete(sent, container: c) == nil)
        let fresh = ModelContext(c)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.pendingMoveFromListID == source.id)
        #expect(stored.photos.first?.previousOriginalFileID == "901")
    }

    @Test func ownershipReadFailureDoesNotPartiallyMoveSubtree() throws {
        struct Failed: Error {}
        let (c, task, source) = try fixture()
        let child = TaskItem(title: "Child"); c.mainContext.insert(child)
        child.taskList = source; child.parentTask = task; child.parentUID = task.uid
        let photo = TaskPhoto(previewData: jpeg); c.mainContext.insert(photo); photo.task = child
        photo.originalFileID = "901"; photo.folderFileID = "900"
        try acceptPhotoOriginal(photo, in: c.mainContext)
        let destination = TaskList(serverURL: "/other/", name: "Other", colorHex: "#007AFF")
        c.mainContext.insert(destination); destination.account = source.account
        var reads = TaskPhotoOwnership.Reads(); reads.row = { _, _ in throw Failed() }
        #expect(TaskMover.move(task, to: destination, in: c.mainContext, ownershipReads: reads).isEmpty)
        #expect(task.taskList?.id == source.id && child.taskList?.id == source.id)
        #expect(task.pendingMoveFromHref == nil)
        #expect(photo.originalFileID == "901" && photo.folderFileID == "900")
    }

    @Test func repeatedMovesRestoreSourceAndKeepEveryIntermediateBinding() throws {
        let (c, task, source) = try fixture()
        let photo = TaskPhoto(previewData: jpeg); c.mainContext.insert(photo); photo.task = task
        photo.originalFileID = "901"; photo.folderFileID = "900"
        try acceptPhotoOriginal(photo, in: c.mainContext)
        let other = ServerAccount(displayName: "Other", serverBaseURL: "https://other.invalid", username: "other")
        c.mainContext.insert(other)
        let intermediate = TaskList(serverURL: "/middle/", name: "Middle", colorHex: "#007AFF")
        let destination = TaskList(serverURL: "/last/", name: "Last", colorHex: "#007AFF")
        c.mainContext.insert(intermediate); intermediate.account = other
        c.mainContext.insert(destination); destination.account = other
        TaskMover.move(task, to: intermediate, in: c.mainContext)
        try acceptPhotoOriginal(photo, fileID: "901", folderID: "910", in: c.mainContext)
        task.remoteHref = "/middle/shared-photo.ics"; task.etag = "middle-accepted"
        try SyncResourceFixture.prove(task, in: c.mainContext)
        #expect(TaskMover.move(task, to: destination, in: c.mainContext).count == 1)
        try acceptPhotoOriginal(photo, fileID: "902", folderID: "920", in: c.mainContext)
        task.remoteHref = "/last/shared-photo.ics"; task.etag = "last-accepted"
        try SyncResourceFixture.prove(task, in: c.mainContext)
        #expect(TaskMover.move(task, to: source, in: c.mainContext).count == 1)
        #expect(photo.originalFileID == "901" && photo.folderFileID == "900")
        #expect(task.pendingMoveFromHref == nil)
        let tombstones = try c.mainContext.fetch(FetchDescriptor<TaskItem>()).filter(\.isDeletedLocally)
        #expect(tombstones.count == 2)
        let middle = try #require(tombstones.first { $0.taskList?.id == intermediate.id })
        #expect(middle.photos.first?.originalFileID == "901" && middle.photos.first?.folderFileID == "910")
        let last = try #require(tombstones.first { $0.taskList?.id == destination.id })
        #expect(last.photos.first?.originalFileID == "902" && last.photos.first?.folderFileID == "920")
        #expect(try c.mainContext.fetch(FetchDescriptor<SyncMetadata>()).allSatisfy { !$0.id.hasPrefix(TaskPhotoCleanupQueue.prefix) })
        try TaskPhotoCleanupQueue.enqueueDeletion(task, in: c.mainContext)
        let work = try c.mainContext.fetch(FetchDescriptor<SyncMetadata>()).filter { $0.id.hasPrefix(TaskPhotoCleanupQueue.prefix) }
        #expect(work.count == 3)
        #expect(work.contains { $0.syncToken == "901" && $0.lastCTag == source.account?.id && $0.photoFolderID == "900" })
        #expect(work.contains { $0.syncToken == "901" && $0.lastCTag == other.id && $0.photoFolderID == "910" })
        #expect(work.contains { $0.syncToken == "902" && $0.lastCTag == other.id && $0.photoFolderID == "920" })
    }

    @Test func reassignedAccountCannotConsumeOldOwnership() throws {
        let (c, task, source) = try fixture()
        let photo = TaskPhoto(previewData: jpeg); c.mainContext.insert(photo); photo.task = task
        photo.originalFileID = "901"; photo.folderFileID = "900"
        try acceptPhotoOriginal(photo, in: c.mainContext)
        source.account?.serverBaseURL = "https://replacement.invalid"
        #expect(throws: TaskPhotoOwnership.Failure.self) {
            try TaskPhotoCleanupQueue.enqueueDeletion(task, in: c.mainContext)
        }
        #expect(photo.originalFileID == "901")
        #expect(try c.mainContext.fetch(FetchDescriptor<SyncMetadata>()).allSatisfy { !$0.id.hasPrefix(TaskPhotoCleanupQueue.prefix) })
    }

    @Test func legacyCatchUpBindsOriginalToActualSourceRequest() throws {
        let (c, task, source) = try fixture()
        let destination = TaskList(serverURL: "/destination/", name: "Destination", colorHex: "#007AFF")
        let other = ServerAccount(displayName: "Other", serverBaseURL: "https://other.invalid", username: "other")
        c.mainContext.insert(other); c.mainContext.insert(destination); destination.account = other
        task.attachmentStateKnown = nil
        TaskMover.move(task, to: destination, in: c.mainContext); try c.mainContext.save()
        let request = try #require(try TaskPhotoLegacyCatchUp.requestInfo(taskID: task.id,
            listID: destination.id, accountID: other.id, container: c))
        #expect(request.sourceAccountID == source.account?.id)
        var data = ICalendarParser.VTODOData(); data.uid = task.uid; data.summary = task.title
        data.photos = [.init(id: first, previewData: jpeg, originalFileID: "901", folderFileID: "900", originalRequested: true)]
        #expect(try TaskPhotoLegacyCatchUp.apply(data, taskID: task.id, listID: destination.id,
            accountID: other.id, href: request.href, container: c, expectedRequest: request) != nil)
        let fresh = ModelContext(c)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.photos.first?.originalFileID == nil)
        #expect(stored.photos.first?.previousOriginalFileID == "901")
        #expect(stored.photos.first?.previousOriginalFolderID == "900")
        #expect(stored.photos.first?.previousOriginalAccountID == source.account?.id)
        try TaskPhotoCleanupQueue.enqueueDeletion(stored, in: fresh)
        let queue = try #require(try fresh.fetch(FetchDescriptor<SyncMetadata>()).first { $0.id.hasPrefix(TaskPhotoCleanupQueue.prefix) })
        #expect(queue.lastCTag == source.account?.id)
        #expect(queue.collectionPath == source.serverURL)
    }

    @Test(arguments: [false, true])
    func failedFinalSaveRetainsOriginalAndSourceObligation(vault: Bool) throws {
        struct Failed: Error {}
        let (c, task, source) = try fixture()
        let photo = TaskPhoto(previewData: jpeg); c.mainContext.insert(photo); photo.task = task
        photo.originalFileID = "901"; photo.folderFileID = "900"
        try acceptPhotoOriginal(photo, in: c.mainContext)
        if vault {
            let account = ServerAccount(vaultDisplayName: "Vault"); c.mainContext.insert(account)
            let destination = TaskList(serverURL: "", name: "Vault", colorHex: "#007AFF")
            c.mainContext.insert(destination); destination.account = account
            photo.pendingOperation = "remove"
            TaskMover.move(task, to: destination, in: c.mainContext)
        }
        TaskListHelpers.markDeleted(task); try c.mainContext.save()
        if vault {
            let candidate = try #require(try SyncMoveSnapshot(task: task))
            let sent = try #require(try SyncMoveAcknowledgement.deletionSnapshot(candidate, container: c))
            #expect(throws: Failed.self) {
                try SyncMoveAcknowledgement.acknowledgeDelete(sent, container: c, save: { _ in throw Failed() })
            }
        } else {
            let sent = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: task.id, container: c))
            #expect(throws: Failed.self) {
                try SyncPushAcknowledgement.acknowledgeDeletion(sent, container: c, save: { _ in throw Failed() })
            }
        }
        source.name = "Unrelated saved edit"; try c.mainContext.save()
        let fresh = ModelContext(c)
        let retained = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(retained.photos.count == 1)
        #expect(vault ? retained.pendingMoveFromListID == source.id : retained.photos.first?.originalFileID == "901")
        #expect(try fresh.fetch(FetchDescriptor<SyncMetadata>()).allSatisfy { !$0.id.hasPrefix(TaskPhotoCleanupQueue.prefix) })
    }

    @Test(arguments: ["malformed", "version", "identity", "duplicate"])
    func invalidOwnershipOrConflictingQueueKeepsDeletionDurable(fault: String) throws {
        let (c, task, source) = try fixture()
        let photo = TaskPhoto(previewData: jpeg); c.mainContext.insert(photo); photo.task = task
        photo.originalFileID = "901"; photo.folderFileID = "900"
        try acceptPhotoOriginal(photo, in: c.mainContext)
        let row = try #require(try c.mainContext.fetch(FetchDescriptor<SyncMetadata>()).first { $0.id == TaskPhotoOwnership.prefix + photo.id })
        switch fault {
        case "malformed": row.syncToken = "bad json"
        case "version": row.syncToken = row.syncToken?.replacingOccurrences(of: "\"version\":1", with: "\"version\":99")
        case "identity": row.syncToken = row.syncToken?.replacingOccurrences(of: photo.id, with: UUID().uuidString)
        default:
            TaskPhotoCleanupQueue.enqueue("901", folderID: "999", account: source.account, list: source, in: c.mainContext)
        }
        TaskListHelpers.markDeleted(task); try c.mainContext.save()
        let sent = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: task.id, container: c))
        #expect(throws: (any Error).self) {
            try SyncPushAcknowledgement.acknowledgeDeletion(sent, container: c)
        }
        source.name = "Unrelated saved edit"; try c.mainContext.save()
        let fresh = ModelContext(c)
        let retained = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(retained.photos.first?.originalFileID == "901")
        #expect(retained.photos.first?.folderFileID == "900")
        #expect(try fresh.fetch(FetchDescriptor<SyncMetadata>()).contains { $0.id == TaskPhotoOwnership.prefix + photo.id })
    }

    @Test(arguments: ["legacy", "inbound", "conflict"])
    func changedRequestOwnerCannotAcquireOriginalProvenance(path: String) throws {
        let (c, task, list) = try fixture()
        task.attachmentStateKnown = nil
        try c.mainContext.save()
        var data = ICalendarParser.VTODOData(); data.uid = task.uid; data.summary = task.title
        data.photos = [.init(id: first, previewData: jpeg, originalFileID: "901", folderFileID: "900", originalRequested: true)]
        let accountID = try #require(list.account?.id)
        if path == "legacy" {
            let request = try #require(try TaskPhotoLegacyCatchUp.requestInfo(taskID: task.id,
                listID: list.id, accountID: accountID, container: c))
            list.account?.serverBaseURL = "https://replacement.invalid"; try c.mainContext.save()
            #expect(try TaskPhotoLegacyCatchUp.apply(data, taskID: task.id, listID: list.id,
                accountID: accountID, href: request.href, container: c, expectedRequest: request) == nil)
        } else if path == "inbound" {
            data.uid = "new-remote-task"
            let writer = SyncInboundBatchWriter(container: c, listID: list.id, expectedAccountID: accountID)
            list.account?.username = "replacement"; try c.mainContext.save()
            #expect(throws: (any Error).self) {
                try writer.apply([ParsedRemoteTask(href: list.serverURL + "new.ics", etag: "new", todo: data)])
            }
        } else {
            task.attachmentStateKnown = true; try c.mainContext.save()
            let snapshot = try SyncPushSnapshot(task: task, calendarPath: list.serverURL)
            list.serverURL = "/replacement/"; try c.mainContext.save()
            #expect(throws: (any Error).self) {
                try SyncPushAcknowledgement.applyConflict(snapshot,
                    resource: ParsedRemoteTask(href: snapshot.path, etag: "new", todo: data), container: c)
            }
        }
        #expect(try ModelContext(c).fetchCount(FetchDescriptor<TaskPhoto>()) == 0)
    }

    @Test(arguments: [false, true])
    func differentAcceptedAttachmentCannotEraseUnprovenOriginal(removeOriginal: Bool) throws {
        let (c, task, _) = try fixture()
        let photo = TaskPhoto(photoID: first, previewData: jpeg); c.mainContext.insert(photo); photo.task = task
        photo.originalFileID = "901"; photo.folderFileID = "900"
        var data = ICalendarParser.VTODOData(); data.uid = task.uid; data.summary = task.title
        data.photos = [.init(id: first, previewData: jpeg, originalFileID: removeOriginal ? nil : "902",
            folderFileID: removeOriginal ? nil : "903", originalRequested: true)]
        #expect(throws: (any Error).self) {
            try SyncImportStore(context: c.mainContext).applyFields(data, to: task)
        }
        #expect(photo.originalFileID == "901" && photo.folderFileID == "900")
        #expect(try c.mainContext.fetch(FetchDescriptor<SyncMetadata>()).allSatisfy { !$0.id.hasPrefix(TaskPhotoOwnership.prefix) })
    }

    @Test(arguments: [false, true])
    func refusedMovePreservesNewDestinationPhotoAddition(uploadedOriginal: Bool) throws {
        let (c, task, source) = try fixture()
        let sourceAttachments: [TaskPhotoAttachment] = [.init(id: first, previewData: jpeg,
            originalFileID: "800", folderFileID: "799", originalRequested: true)]
        try TaskPhotoSyncStore.apply(sourceAttachments, opaque: [], to: task, in: c.mainContext)
        let destination = TaskList(serverURL: "/destination/", name: "Destination", colorHex: "#007AFF")
        c.mainContext.insert(destination); destination.account = source.account
        TaskMover.move(task, to: destination, in: c.mainContext)
        let photo = TaskPhoto(previewData: jpeg); c.mainContext.insert(photo); photo.task = task
        photo.pendingOperation = "add"; photo.originalRequested = uploadedOriginal
        if uploadedOriginal {
            try acceptPhotoOriginal(photo, fileID: "902", folderID: "901", in: c.mainContext)
        }
        #expect(TaskMover.rollBackRefusedPut(task, in: c.mainContext))
        #expect(task.taskList?.id == source.id)
        let restored = try #require(task.photos.first { $0.photoID == first })
        #expect(restored.originalFileID == "800" && restored.folderFileID == "799")
        #expect(restored.pendingOperation == nil, "Restoring a known source original clears its move-generated addition")
        #expect(photo.pendingOperation == "add", "A photo added at the destination has no source attachment to restore")
        #expect(photo.originalFileID == nil)
        if uploadedOriginal {
            #expect(photo.previousOriginalFileID == "902")
            #expect(photo.previousOriginalFolderID == "901")
            #expect(photo.previousOriginalListID == destination.id)
        }
        try TaskPhotoSyncStore.apply(sourceAttachments, opaque: [], to: task, in: c.mainContext)
        #expect(task.photos.count == 2)
        #expect(task.photos.contains { $0.id == photo.id && $0.pendingOperation == "add" && $0.previewData == jpeg })
        #expect(try c.mainContext.fetch(FetchDescriptor<SyncMetadata>()).allSatisfy { !$0.id.hasPrefix(TaskPhotoCleanupQueue.prefix) })
    }

    @Test func inboundPreviewAndOpaqueAttachmentReachStoredTask() throws {
        let (c, task, _) = try fixture()
        var data = ICalendarParser.VTODOData(); data.uid = task.uid; data.summary = "Remote"
        data.photos = [.init(id: first, previewData: jpeg)]
        data.opaqueAttachments = ["ATTACH:https://example.com/manual.pdf"]
        try SyncImportStore(context: c.mainContext).applyFields(data, to: task)
        #expect(task.photos.map(\.photoID) == [first])
        #expect(task.opaqueAttachments == data.opaqueAttachments)
        let serialized = try SyncPushSnapshot.serialize(task, stamp: Date())
        let parsed = try #require(try ICalendarParser.parseSingleVTODO(from: serialized))
        #expect(parsed.photos == data.photos)
        #expect(parsed.opaqueAttachments == data.opaqueAttachments)
    }

    @Test func conflictRetainsLocalAdditionAndRemoteFieldsAndPhotos() throws {
        let (c, task, list) = try fixture()
        let local = TaskPhoto(photoID: first, previewData: jpeg)
        local.pendingOperation = "add"; c.mainContext.insert(local); local.task = task
        task.isDirty = true; try c.mainContext.save()
        let snapshot = try SyncPushSnapshot(task: task, calendarPath: list.serverURL)
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
        try acceptPhotoOriginal(photo, in: c.mainContext)
        try c.mainContext.save()
        let snapshot = try SyncPushSnapshot(task: task, calendarPath: list.serverURL)
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
        let snapshot = try SyncPushSnapshot(task: task, calendarPath: list.serverURL)
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
        try acceptPhotoOriginal(photo, in: c.mainContext)
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
        try acceptPhotoOriginal(photo, in: c.mainContext)
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
        try acceptPhotoOriginal(photo, in: c.mainContext)
        TaskMover.move(task, to: destination, in: c.mainContext)
        try acceptPhotoOriginal(photo, fileID: "902", folderID: "901", in: c.mainContext)
        try c.mainContext.save()
        let push = try SyncPushSnapshot(task: task, calendarPath: destination.serverURL)
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
        try acceptPhotoOriginal(photo, in: c.mainContext)
        TaskMover.move(task, to: destination, in: c.mainContext)
        task.remoteHref = "/other/shared-photo.ics"; task.isDirty = false
        try c.mainContext.save()
        #expect(PendingMoveSweep.candidates(sourceListIDs: [source.id], in: c.mainContext).isEmpty)
        try acceptPhotoOriginal(photo, fileID: "902", folderID: "901", in: c.mainContext)
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
        try VTODOOpaqueState.empty.store(taskID: other.id, in: c.mainContext)
        for node in [task, other] {
            let photo = TaskPhoto(previewData: jpeg); photo.originalRequested = true
            photo.originalFileID = "900"; photo.folderFileID = "899"
            c.mainContext.insert(photo); photo.task = node
            try acceptPhotoOriginal(photo, in: c.mainContext)
            TaskMover.move(node, to: destination, in: c.mainContext)
            node.remoteHref = "/other/" + node.uid + ".ics"; node.isDirty = false
            try acceptPhotoOriginal(photo, fileID: "902", folderID: "901", in: c.mainContext); photo.pendingOperation = nil
        }
        try c.mainContext.save()
        var deleted = [String]()
        _ = await PendingMoveSweep.run([task, other], in: c.mainContext) { snapshot in
            deleted.append(snapshot.sourceHref)
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
        try acceptPhotoOriginal(photo, in: c.mainContext)
        TaskMover.move(task, to: destination, in: c.mainContext); try c.mainContext.save()
        let taskID = task.id; let update = ModelContext(c)
        let stored = try #require(try update.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
        stored.remoteHref = "/other/" + stored.uid + ".ics"; stored.isDirty = false
        try acceptPhotoOriginal(try #require(stored.photos.first), fileID: "902", folderID: "901", in: update)
        stored.photos.first?.pendingOperation = nil; try update.save()
        let sent = try #require(try SyncMoveSnapshot(task: stored))
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
