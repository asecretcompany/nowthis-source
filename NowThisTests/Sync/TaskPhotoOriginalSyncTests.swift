import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite(.serialized)
@MainActor
struct TaskPhotoOriginalSyncTests {
    private let access = PhotoServerAccess(baseURL: "https://example.com", username: "alice", password: "test")
    private func fixture(owner: String = "alice", folderID: String? = nil) throws -> (ModelContainer, TaskItem, TaskPhoto, TaskPhotoCache, URL) {
        let c = try ModelContainer(for: Schema(SchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let account = ServerAccount(displayName: "Cloud", serverBaseURL: "https://example.com", username: "alice")
        let list = TaskList(serverURL: "/remote.php/dav/calendars/alice/tasks/", name: "Team", colorHex: "#007AFF")
        c.mainContext.insert(account); c.mainContext.insert(list); list.account = account
        let task = TaskItem(title: "Check equipment"); c.mainContext.insert(task); task.taskList = list
        let photo = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        photo.originalRequested = true; photo.originalContentType = "image/jpeg"
        photo.pendingOperation = "add"; photo.folderFileID = folderID
        c.mainContext.insert(photo); photo.task = task; try c.mainContext.save()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (c, task, photo, TaskPhotoCache(directory: url), url)
    }

    @Test func successfulUploadProducesPendingVtodoLinkAndRetainsOriginal() async throws {
        let (c, task, photo, cache, url) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        try await cache.store(Data([1, 2, 3]), photoID: photo.id)
        let sync = TaskPhotoSync(files: PhotoFilesFake(), cache: cache)
        let outcome = try await sync.synchronize(listID: try #require(task.taskList?.id), access: access, container: c)
        let fresh = ModelContext(c); let stored = try #require(try fresh.fetch(FetchDescriptor<TaskPhoto>()).first)
        #expect(stored.originalFileID == "901")
        #expect(stored.folderFileID == "900")
        #expect(stored.pendingOperation == "add")
        #expect(outcome.changedTaskIDs.contains(task.id))
        #expect(try await cache.load(photoID: photo.id) == Data([1, 2, 3]))
        let storedTask = try #require(stored.task)
        let parsed = try #require(try ICalendarParser.parseSingleVTODO(from: try SyncPushSnapshot.serialize(storedTask, stamp: Date())))
        #expect(parsed.photos.first?.originalFileID == "901")
    }
    @Test func uploadAfterMoveWithoutPreviousOriginalKeepsDestinationOwnershipOnRemoval() async throws {
        let (c, task, photo, cache, url) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let source = try #require(task.taskList)
        task.remoteHref = source.serverURL + "original.ics"; task.etag = "source-baseline"; task.isLocalOnly = false
        try SyncResourceFixture.prove(task, in: c.mainContext)
        try VTODOOpaqueState.empty.store(taskID: task.id, in: c.mainContext)
        let other = ServerAccount(displayName: "Other", serverBaseURL: access.baseURL, username: "alice")
        let destination = TaskList(serverURL: "/destination/", name: "Destination", colorHex: "#007AFF")
        c.mainContext.insert(other); c.mainContext.insert(destination); destination.account = other
        TaskMover.move(task, to: destination, in: c.mainContext); try c.mainContext.save()
        try await cache.store(Data([1, 2, 3]), photoID: photo.id)
        _ = try await TaskPhotoSync(files: PhotoFilesFake(), cache: cache)
            .synchronize(listID: destination.id, access: access, container: c)
        let edit = ModelContext(c)
        let stored = try #require(try edit.fetch(FetchDescriptor<TaskItem>()).first)
        let uploaded = try #require(stored.photos.first)
        #expect(uploaded.previousOriginalFileID == nil)
        #expect(uploaded.originalFileID == "901" && uploaded.folderFileID == "900")
        uploaded.pendingOperation = "remove"
        stored.remoteHref = "/destination/original.ics"; stored.etag = "destination-accepted"
        try SyncResourceFixture.prove(stored, in: edit)
        TaskListHelpers.markDeleted(stored); try edit.save()
        let candidate = try #require(try SyncMoveSnapshot(task: stored))
        let sent = try #require(try SyncMoveAcknowledgement.deletionSnapshot(candidate, container: c))
        #expect(try SyncMoveAcknowledgement.acknowledgeDelete(sent, container: c) != nil)
        let deletion = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: task.id, container: c))
        #expect(try SyncPushAcknowledgement.acknowledgeDeletion(deletion, container: c) != nil)
        let work = try ModelContext(c).fetch(FetchDescriptor<SyncMetadata>()).filter { $0.id.hasPrefix(TaskPhotoCleanupQueue.prefix) }
        #expect(work.count == 1)
        #expect(work.first?.lastCTag == other.id)
        #expect(work.first?.collectionPath == "/destination/")
        #expect(work.first?.photoFolderID == "900")
    }

    @Test func failedUploadRetainsLocalOriginalAndVisiblePendingState() async throws {
        let (c, task, photo, cache, url) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        try await cache.store(Data([1, 2, 3]), photoID: photo.id)
        _ = try await TaskPhotoSync(files: PhotoFilesFake(failUpload: true), cache: cache)
            .synchronize(listID: try #require(task.taskList?.id), access: access, container: c)
        let fresh = ModelContext(c); let stored = try #require(try fresh.fetch(FetchDescriptor<TaskPhoto>()).first)
        #expect(stored.originalFileID == nil)
        #expect(stored.originalStatus == "unavailable")
        #expect(try await cache.load(photoID: photo.id) == Data([1, 2, 3]))
    }
    @Test(arguments: [false, true])
    func movedUncachedOriginalUsesOnlyItsBoundSourceFolder(otherAccount: Bool) async throws {
        let (c, task, photo, cache, url) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let source = try #require(task.taskList)
        let sourceAccount = try #require(source.account)
        let sourceID = sourceAccount.id
        let sourcePassword = otherAccount ? "source-only" : "test"
        photo.originalFileID = "903"; photo.folderFileID = "899"; photo.pendingOperation = nil
        let destination = TaskList(serverURL: "/remote.php/dav/calendars/alice/other/", name: "Other", colorHex: "#007AFF")
        c.mainContext.insert(destination)
        if otherAccount {
            let other = ServerAccount(displayName: "Other", serverBaseURL: access.baseURL, username: "alice")
            c.mainContext.insert(other)
            destination.account = other
        } else {
            destination.account = sourceAccount
        }
        try acceptPhotoOriginal(photo, in: c.mainContext)
        TaskMover.move(task, to: destination, in: c.mainContext); try c.mainContext.save()
        let files = PhotoFilesFake()
        let keychain = DAVSyncScenario.keychain(accountID: sourceID, password: sourcePassword)
        _ = try await TaskPhotoSync(files: files, cache: cache, keychainManager: keychain)
            .synchronize(listID: destination.id, access: access, container: c)
        #expect(await files.scopedDownloads == ["903|899|" + source.serverURL])
        #expect(await files.scopedAccess.first?.baseURL == access.baseURL)
        #expect(await files.scopedAccess.first?.password == sourcePassword)
        #expect(await files.unscopedDownloads.isEmpty)
        let fresh = ModelContext(c); let stored = try #require(try fresh.fetch(FetchDescriptor<TaskPhoto>()).first)
        #expect(stored.originalFileID == "901")
        #expect(stored.previousOriginalFileID == "903")
    }

    @Test("A moved original stays pending when its source account changes after snapshot", arguments: [false, true])
    func sourceRebindAfterCopySnapshot(rebound: Bool) async throws {
        let (container, task, photo, cache, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let source = try #require(task.taskList)
        let sourceAccount = try #require(source.account)
        let sourceID = sourceAccount.id
        let sourceURL = "https://original-source.invalid"
        sourceAccount.serverBaseURL = sourceURL
        photo.originalFileID = "903"; photo.folderFileID = "899"; photo.pendingOperation = nil
        try acceptPhotoOriginal(photo, in: context)

        let destinationAccount = ServerAccount(displayName: "Destination", serverBaseURL: access.baseURL, username: "alice")
        let destination = TaskList(serverURL: "/remote.php/dav/calendars/alice/other/", name: "Other", colorHex: "#007AFF")
        context.insert(destinationAccount)
        context.insert(destination)
        destination.account = destinationAccount
        try #require(TaskMover.move(task, to: destination, in: context).count == 1)
        let unrelated = TaskItem(title: "Another original")
        context.insert(unrelated)
        unrelated.taskList = destination
        let unrelatedPhoto = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        unrelatedPhoto.originalRequested = true
        unrelatedPhoto.originalContentType = "image/jpeg"
        unrelatedPhoto.pendingOperation = "add"
        context.insert(unrelatedPhoto)
        unrelatedPhoto.task = unrelated
        try context.save()
        try await cache.store(Data([4, 5, 6]), photoID: unrelatedPhoto.id)
        let originalStatus = photo.originalStatus
        let movedID = photo.id
        let ownershipID = TaskPhotoOwnership.prefix + movedID
        let ownership = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == ownershipID })
        let retained = try #require(context.fetch(ownership).first?.syncToken)
        let keychain = TestAccountKeychain()
        try await keychain.manager.save(password: "previous-source", for: sourceID)

        let entered = AsyncStream<Void>.makeStream()
        let gate = ScriptedDAVProtocol.Gate()
        defer { gate.release() }
        let files = PhotoFilesFake(onPrepareFolder: {
            entered.continuation.yield()
            entered.continuation.finish()
            await gate.wait()
        })
        let sync = TaskPhotoSync(files: files, cache: cache, keychainManager: keychain.manager)
        let destinationID = destination.id
        let copy = Task { try await sync.synchronize(listID: destinationID, access: access, container: container) }
        for await _ in entered.stream { break }
        if rebound {
            let manager = AccountManager(modelContext: ModelContext(container), keychainManager: keychain.manager)
            try await manager.updateNextcloudAccount(accountID: sourceID, serverURL: "https://replacement-source.invalid",
                                                     password: "replacement-source")
        }
        gate.release()
        let outcome = try await copy.value
        let fresh = ModelContext(container)
        let stored = try #require(fresh.fetch(FetchDescriptor<TaskPhoto>(predicate: #Predicate { $0.id == movedID })).first)
        #expect(outcome.changedTaskIDs.contains(unrelated.id))
        #expect(await files.uploads.contains(unrelatedPhoto.photoID))
        #expect(stored.previousOriginalFileID == "903")
        #expect(stored.previousOriginalFolderID == "899")
        #expect(stored.previousOriginalAccountID == sourceID)
        #expect(stored.previousOriginalListID == source.id)

        if rebound {
            #expect(await files.scopedDownloads.isEmpty)
            #expect(await files.uploads == [unrelatedPhoto.photoID])
            #expect(outcome.changedTaskIDs == [unrelated.id])
            #expect(outcome.credentialsDeferred)
            #expect(try await cache.load(photoID: movedID) == nil)
            #expect(stored.originalFileID == nil)
            #expect(stored.originalStatus == originalStatus)
            #expect(try fresh.fetch(ownership).first?.syncToken == retained)
        } else {
            #expect(await files.scopedAccess.first?.baseURL == sourceURL)
            #expect(await files.scopedAccess.first?.password == "previous-source")
            #expect(await files.uploads.contains(photo.photoID))
            #expect(try await cache.load(photoID: movedID) == Data([1, 2, 3]))
            #expect(stored.originalFileID == "901")
            #expect(!outcome.credentialsDeferred)
        }
    }

    @Test func shareeWithoutFolderWaitsForOwnerAndKeepsPreview() async throws {
        let (c, task, photo, cache, url) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        try await cache.store(Data([1, 2, 3]), photoID: photo.id)
        _ = try await TaskPhotoSync(files: PhotoFilesFake(owner: "bob"), cache: cache)
            .synchronize(listID: try #require(task.taskList?.id), access: access, container: c)
        let fresh = ModelContext(c); let stored = try #require(try fresh.fetch(FetchDescriptor<TaskPhoto>()).first)
        #expect(stored.originalStatus == "waiting")
        #expect(stored.originalFileID == nil)
        #expect(!stored.previewData.isEmpty)
    }
}

actor PhotoFilesFake: TaskPhotoFilesTransport {
    let owner: String
    let failUpload: Bool
    let onPrepareFolder: @Sendable () async -> Void
    init(owner: String = "alice", failUpload: Bool = false, onPrepareFolder: @escaping @Sendable () async -> Void = {}) {
        self.owner = owner
        self.failUpload = failUpload
        self.onPrepareFolder = onPrepareFolder
    }
    func inspectCalendar(calendarHref: String, access: PhotoServerAccess) -> PhotoCalendarAccess { .init(ownerID: owner, sharees: []) }
    func prepareFolder(calendarHref: String, access: PhotoServerAccess) async -> PhotoFolder {
        await onPrepareFolder()
        return .init(fileID: "900", href: "https://example.com/files/alice/photos/")
    }
    func resolveFolder(fileID: String, access: PhotoServerAccess) -> PhotoFolder { .init(fileID: fileID, href: "https://example.com/files/alice/shared/") }
    func upload(data: Data, contentType: String, photoID: String, folder: PhotoFolder, access: PhotoServerAccess) throws -> String {
        if failUpload { throw NextcloudPhotoClient.Error.quotaExceeded }
        uploads.append(photoID)
        return "901"
    }
    private(set) var uploads: [String] = []
    var scopedDownloads: [String] = []
    var scopedAccess: [PhotoServerAccess] = []
    var unscopedDownloads: [String] = []
    func download(fileID: String, access: PhotoServerAccess) -> Data {
        unscopedDownloads.append(fileID); return Data([1, 2, 3])
    }
    func download(fileID: String, folderFileID: String, calendarHref: String, access: PhotoServerAccess) -> Data {
        scopedDownloads.append(fileID + "|" + folderFileID + "|" + calendarHref)
        scopedAccess.append(access)
        return Data([1, 2, 3])
    }
    func delete(fileID: String, access: PhotoServerAccess) {}
}
