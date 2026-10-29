import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Background photo maintenance policy", .serialized)
@MainActor
struct BackgroundSyncPhotoPolicyTests {
    private let photoID = "BD2E616C-55C0-4F7C-A3C4-32AD464EC9E4"

    private func fixture() throws -> (ModelContainer, ServerAccount, TaskList, TaskItem) {
        let container = try ModelContainer(for: Schema(SchemaV2.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: "https://unused.invalid", username: "fixture")
        let list = TaskList(id: "photo-list", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        let task = TaskItem(uid: "photo-task", title: "Local edit")
        context.insert(account); context.insert(list); context.insert(task)
        list.account = account; task.taskList = list
        task.remoteHref = "/one/photo-task.ics"; task.etag = "old"
        task.isLocalOnly = false; task.isDirty = true
        list.syncCTag = "c1"; list.lastFullPullDate = Date()
        SyncEngine.markCategoriesCaughtUp(listID: list.id)
        try context.save()
        return (container, account, list, task)
    }

    // A return to TaskPhotoSync/probe/prune in the background branch adds observable work.
    @Test func backgroundSkipsBroadPhotoMaintenance() async throws {
        let (container, account, _, task) = try fixture()
        let photo = TaskPhoto(photoID: photoID, previewData: TaskPhotoJPEGFixture.data)
        photo.originalRequested = true; photo.originalStatus = "pending"; photo.pendingOperation = "add"
        container.mainContext.insert(photo); photo.task = task
        let missing = TaskList(serverURL: "/missing/", name: "Missing", colorHex: "#007AFF")
        container.mainContext.insert(missing); missing.account = account; missing.photoAccessRevoked = true
        try container.mainContext.save()
        let files = BackgroundPhotoFiles()
        let host = "background-photo-policy-" + UUID().uuidString.lowercased() + ".invalid"
        // Legacy list CTag fields do not establish the authoritative import baseline.
        // Supply the required complete task inventory, retaining this dirty task by ETag.
        let manifest = DAVSyncScenario.multistatus(DAVSyncScenario.prop(
            "/one/photo-task.ics", "<d:getetag>old</d:getetag>"))
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
                .init(body: manifest)]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)), taskPhotoSync: TaskPhotoSync(files: files))
        let outcome = await engine.performBackgroundSyncOutcome(accountID: account.id,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container, reconcileNotifications: false)
        #expect(outcome.status == .completed)
        #expect(await files.calls.isEmpty)
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND", "REPORT"])
        #expect(requests.filter { $0.method == "REPORT" }.map(\.path) == ["/one"])
        let fresh = ModelContext(container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskPhoto>()).first)
        #expect(stored.originalStatus == "pending")
        #expect(stored.pendingOperation == "add")
        #expect(stored.folderFileID == nil)
        #expect(try fresh.fetch(FetchDescriptor<TaskList>()).first { $0.id == missing.id }?.photoAccessRevoked == true)
        #expect(try fresh.fetch(FetchDescriptor<SyncMetadata>()).filter { $0.photoFolderID != nil }.isEmpty)
    }

    // An account with no discovered lists must not prune the original cache either.
    @Test func backgroundLeavesOldUnattachedCachedOriginals() async throws {
        let (container, account, _, _) = try fixture()
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TaskPhotoCache(directory: directory)
        try await cache.store(TaskPhotoJPEGFixture.data, photoID: id)
        let path = directory.appendingPathComponent(id.lowercased())
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: path.path)
        let host = "background-no-prune-" + UUID().uuidString.lowercased() + ".invalid"
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: [])),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)), taskPhotoCache: cache)
        _ = await engine.performBackgroundSyncOutcome(accountID: account.id,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container, reconcileNotifications: false)
        let retained = try await cache.load(photoID: id)
        try await cache.remove(photoID: id)
        #expect(retained == TaskPhotoJPEGFixture.data)
    }

    @Test func taskPhotoMetadataStillImports() async throws {
        let (container, account, list, task) = try fixture()
        task.isDirty = false; list.syncCTag = nil; list.lastFullPullDate = nil
        try container.mainContext.save()
        let attachment = TaskPhotoAttachment(id: photoID, previewData: TaskPhotoJPEGFixture.data,
            originalFileID: "901", folderFileID: "900", originalRequested: true)
        let calendar = ICalendarSerializer.serialize(uid: "photo-task", summary: "Remote photo", photos: [attachment])
        let host = "background-photo-import-" + UUID().uuidString.lowercased() + ".invalid"
        let manifest = DAVSyncScenario.multistatus(DAVSyncScenario.prop("/one/photo-task.ics", "<d:getetag>new</d:getetag>"))
        let body = DAVSyncScenario.multistatus(DAVSyncScenario.prop("/one/photo-task.ics",
            "<d:getetag>new</d:getetag><c:calendar-data>" + calendar + "</c:calendar-data>"))
        let files = BackgroundPhotoFiles()
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
                .init(body: manifest), .init(body: body)]), retryPolicy: .init(maxAttempts: 1, baseDelay: 0)),
            taskPhotoSync: TaskPhotoSync(files: files))
        let outcome = await engine.performBackgroundSyncOutcome(accountID: account.id,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container, reconcileNotifications: false)
        #expect(outcome.status == .completed)
        let fresh = ModelContext(container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "Remote photo")
        #expect(stored.photos.map(\.attachment) == [attachment])
        #expect(await files.calls.isEmpty)
    }

    @Test(arguments: [403, 404])
    func actualCollectionDenialStillRevokesPhotoAccess(status: Int) async throws {
        let (container, account, list, _) = try fixture()
        list.syncCTag = nil; list.lastFullPullDate = nil
        try container.mainContext.save()
        let host = "background-denial-" + UUID().uuidString.lowercased() + ".invalid"
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
                .init(status: status, body: ""), .init(status: status, body: "")]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await engine.performBackgroundSyncOutcome(accountID: account.id,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container, reconcileNotifications: false)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskList>()).first?.photoAccessRevoked == true)
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "REPORT" }.count == 2)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 1)
    }
}

private actor BackgroundPhotoFiles: TaskPhotoFilesTransport {
    private(set) var calls: [String] = []
    func inspectCalendar(calendarHref: String, access: PhotoServerAccess) throws -> PhotoCalendarAccess {
        calls.append("inspect"); throw TaskPhotoOriginalError.unavailable
    }
    func prepareFolder(calendarHref: String, access: PhotoServerAccess) throws -> PhotoFolder {
        calls.append("provision"); throw TaskPhotoOriginalError.unavailable
    }
    func resolveFolder(fileID: String, access: PhotoServerAccess) throws -> PhotoFolder {
        calls.append("resolve"); throw TaskPhotoOriginalError.unavailable
    }
    func upload(data: Data, contentType: String, photoID: String, folder: PhotoFolder,
                access: PhotoServerAccess) throws -> String {
        calls.append("upload"); throw TaskPhotoOriginalError.unavailable
    }
    func download(fileID: String, access: PhotoServerAccess) throws -> Data {
        calls.append("download"); throw TaskPhotoOriginalError.unavailable
    }
    func delete(fileID: String, access: PhotoServerAccess) { calls.append("delete") }
}
