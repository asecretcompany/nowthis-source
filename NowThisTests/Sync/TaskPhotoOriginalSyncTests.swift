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
        let changes = try await sync.synchronize(listID: try #require(task.taskList?.id), access: access, container: c)
        let fresh = ModelContext(c); let stored = try #require(try fresh.fetch(FetchDescriptor<TaskPhoto>()).first)
        #expect(stored.originalFileID == "901")
        #expect(stored.folderFileID == "900")
        #expect(stored.pendingOperation == "add")
        #expect(changes.contains(task.id))
        #expect(try await cache.load(photoID: photo.id) == Data([1, 2, 3]))
        let storedTask = try #require(stored.task)
        let parsed = try #require(try ICalendarParser.parseSingleVTODO(from: SyncPushSnapshot.serialize(storedTask, stamp: Date())))
        #expect(parsed.photos.first?.originalFileID == "901")
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
    @Test func movedUncachedOriginalUsesOnlyItsBoundSourceFolder() async throws {
        let (c, task, photo, cache, url) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let source = try #require(task.taskList)
        photo.originalFileID = "903"; photo.folderFileID = "899"; photo.pendingOperation = nil
        let destination = TaskList(serverURL: "/remote.php/dav/calendars/alice/other/", name: "Other", colorHex: "#007AFF")
        c.mainContext.insert(destination); destination.account = source.account
        TaskMover.move(task, to: destination, in: c.mainContext); try c.mainContext.save()
        let files = PhotoFilesFake()
        _ = try await TaskPhotoSync(files: files, cache: cache).synchronize(listID: destination.id, access: access, container: c)
        #expect(await files.scopedDownloads == ["903|899|" + source.serverURL])
        #expect(await files.unscopedDownloads.isEmpty)
        let fresh = ModelContext(c); let stored = try #require(try fresh.fetch(FetchDescriptor<TaskPhoto>()).first)
        #expect(stored.originalFileID == "901")
        #expect(stored.previousOriginalFileID == "903")
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
    init(owner: String = "alice", failUpload: Bool = false) { self.owner = owner; self.failUpload = failUpload }
    func inspectCalendar(calendarHref: String, access: PhotoServerAccess) -> PhotoCalendarAccess { .init(ownerID: owner, sharees: []) }
    func prepareFolder(calendarHref: String, access: PhotoServerAccess) -> PhotoFolder { .init(fileID: "900", href: "https://example.com/files/alice/photos/") }
    func resolveFolder(fileID: String, access: PhotoServerAccess) -> PhotoFolder { .init(fileID: fileID, href: "https://example.com/files/alice/shared/") }
    func upload(data: Data, contentType: String, photoID: String, folder: PhotoFolder, access: PhotoServerAccess) throws -> String {
        if failUpload { throw NextcloudPhotoClient.Error.quotaExceeded }
        return "901"
    }
    var scopedDownloads: [String] = []
    var unscopedDownloads: [String] = []
    func download(fileID: String, access: PhotoServerAccess) -> Data {
        unscopedDownloads.append(fileID); return Data([1, 2, 3])
    }
    func download(fileID: String, folderFileID: String, calendarHref: String, access: PhotoServerAccess) -> Data {
        scopedDownloads.append(fileID + "|" + folderFileID + "|" + calendarHref)
        return Data([1, 2, 3])
    }
    func delete(fileID: String, access: PhotoServerAccess) {}
}
