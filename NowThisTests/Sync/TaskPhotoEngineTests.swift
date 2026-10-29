import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Task photo engine HTTP and persistence", .serialized)
@MainActor
struct TaskPhotoEngineTests {
    private let localPhotoID = "AD2E616C-55C0-4F7C-A3C4-32AD464EC9E4"
    private let remotePhotoID = "BD2E616C-55C0-4F7C-A3C4-32AD464EC9E4"

    private func fixture() throws -> (ModelContainer, ServerAccount, TaskList, TaskItem) {
        let container = try ModelContainer(for: Schema(SchemaV2.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: "https://unused.invalid", username: "fixture")
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        let task = TaskItem(uid: "photo-task", title: "Local edit")
        context.insert(account); context.insert(list); context.insert(task)
        list.account = account; task.taskList = list
        task.remoteHref = "/one/photo-task.ics"; task.etag = "old"
        task.isLocalOnly = false; task.isDirty = true; task.attachmentStateKnown = true
        list.syncCTag = "c1"; list.lastFullPullDate = Date()
        SyncEngine.markCategoriesCaughtUp(listID: list.id)
        try context.save()
        return (container, account, list, task)
    }

    private func remote(photos: [TaskPhotoAttachment] = [], opaque: [String] = [], uid: String = "photo-task") -> String {
        ICalendarSerializer.serialize(uid: uid, summary: "Remote title", description: "Remote notes",
            photos: photos, opaqueAttachments: opaque)
    }

    private func run(_ container: ModelContainer, account: ServerAccount,
                     responses: [ScriptedDAVProtocol.Response]) async -> (SyncOutcome, [ScriptedDAVProtocol.RecordedRequest]) {
        let host = "photo-engine-" + UUID().uuidString.lowercased() + ".invalid"
        let configuration = ScriptedDAVProtocol.install(host: host,
            responses: DAVSyncScenario.discovery(paths: ["/one/"]) + responses)
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: configuration,
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let outcome = await engine.performFullSyncOutcome(accountID: account.id,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container, reconcileNotifications: false)
        return (outcome, ScriptedDAVProtocol.requests(host: host))
    }

    @Test("Legacy CTag-skipped title edit GETs attachments before conditional PUT")
    func legacyCatchUpBeforePut() async throws {
        let (container, account, _, task) = try fixture()
        task.attachmentStateKnown = nil; try container.mainContext.save()
        let attachment = TaskPhotoAttachment(id: remotePhotoID, previewData: TaskPhotoJPEGFixture.data)
        let opaque = "ATTACH:https://example.com/manual.pdf"
        let (outcome, requests) = await run(container, account: account, responses: [
            .init(status: 200, body: remote(photos: [attachment], opaque: [opaque]), headers: ["ETag": "remote-new"]),
            .init(status: 204, body: "", headers: ["ETag": "accepted"])])
        let writes = requests.filter { $0.method == "GET" || $0.method == "PUT" }
        #expect(writes.map(\.method) == ["GET", "PUT"])
        let put = try #require(writes.first { $0.method == "PUT" })
        #expect(put.ifMatch == "\"old\"", "Catch-up must retain the old precondition for conflict detection")
        let sent = try #require(try ICalendarParser.parseSingleVTODO(from: String(decoding: put.body, as: UTF8.self)))
        #expect(sent.summary == "Local edit")
        #expect(sent.photos == [attachment]); #expect(sent.opaqueAttachments == [opaque])
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.attachmentStateKnown == true); #expect(!stored.isDirty)
        #expect(outcome.status == .completed)
    }

    @Test("Legacy catch-up rejects a different UID without overwriting remote attachments")
    func legacyDifferentUIDNeverPuts() async throws {
        let (container, account, _, task) = try fixture()
        task.attachmentStateKnown = nil; try container.mainContext.save()
        let (outcome, requests) = await run(container, account: account, responses: [
            .init(status: 200, body: remote(uid: "different-task"), headers: ["ETag": "fresh"])])
        #expect(requests.filter { $0.method == "GET" }.count == 1)
        #expect(!requests.contains { $0.method == "PUT" })
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "Local edit"); #expect(stored.isDirty)
        #expect(stored.etag == "old"); #expect(stored.attachmentStateKnown != true)
        #expect(outcome.status == .partial)
    }

    @Test("Photo conflict rebases remote fields and retries exactly once with fresh ETag", arguments: [false, true])
    func photoConflictRetry(secondConflict: Bool) async throws {
        let (container, account, _, task) = try fixture()
        let photo = TaskPhoto(photoID: localPhotoID, previewData: TaskPhotoJPEGFixture.data)
        photo.pendingOperation = "add"; container.mainContext.insert(photo); photo.task = task
        try container.mainContext.save()
        let remotePhoto = TaskPhotoAttachment(id: remotePhotoID, previewData: TaskPhotoJPEGFixture.data)
        let (outcome, requests) = await run(container, account: account, responses: [
            .init(status: 412, body: ""),
            .init(status: 200, body: remote(photos: [remotePhoto]), headers: ["ETag": "fresh"]),
            .init(status: secondConflict ? 412 : 204, body: "", headers: ["ETag": "accepted"])])
        let puts = requests.filter { $0.method == "PUT" }
        #expect(puts.count == 2)
        #expect(requests.filter { $0.method == "GET" }.count == 1)
        let retry = try #require(puts.last)
        #expect(retry.ifMatch == "\"fresh\"")
        let sent = try #require(try ICalendarParser.parseSingleVTODO(from: String(decoding: retry.body, as: UTF8.self)))
        #expect(sent.summary == "Remote title"); #expect(sent.description == "Remote notes")
        #expect(Set(sent.photos.map(\.id)) == [localPhotoID, remotePhotoID])
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.isDirty == secondConflict)
        #expect(stored.photos.first { $0.photoID == localPhotoID }?.pendingOperation == (secondConflict ? "add" : nil))
        #expect(outcome.status == (secondConflict ? .partial : .completed))
    }

    @Test("Title-only conflict keeps existing server-wins behavior without retry")
    func noPhotoConflictDoesNotRetry() async throws {
        let (container, account, _, _) = try fixture()
        let (outcome, requests) = await run(container, account: account, responses: [
            .init(status: 412, body: ""), .init(status: 200, body: remote(), headers: ["ETag": "fresh"])])
        #expect(requests.filter { $0.method == "PUT" }.count == 1)
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "Remote title"); #expect(!stored.isDirty)
        #expect(outcome.status == .completed)
    }
    @Test("Missing discovery list revokes photos only after definitive collection denial", arguments: [403, 404, 500, 207], [false, true])
    func missingListRequiresCollectionProbe(status: Int, background: Bool) async throws {
        let (container, account, list, task) = try fixture()
        let photo = TaskPhoto(photoID: localPhotoID, previewData: TaskPhotoJPEGFixture.data)
        container.mainContext.insert(photo); photo.task = task
        try container.mainContext.save()
        let host = "photo-access-" + UUID().uuidString.lowercased() + ".invalid"
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: []) + [
                .init(status: status, body: status == 207 ? DAVSyncScenario.manifest(count: 0) : "")]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        if background {
            _ = await engine.performBackgroundSyncOutcome(accountID: account.id,
                serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
                modelContainer: container, reconcileNotifications: false)
        } else {
            _ = await engine.performFullSyncOutcome(accountID: account.id,
                serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
                modelContainer: container, reconcileNotifications: false)
        }
        let probes = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "REPORT" }
        #expect(probes.count == (background ? 0 : 1))
        if !background { #expect(probes.first?.path == "/one") }
        let fresh = ModelContext(container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskList>()).first)
        #expect((stored.photoAccessRevoked == true) == (!background && (status == 403 || status == 404)))
        #expect(stored.id == list.id)
        #expect(try fresh.fetchCount(FetchDescriptor<TaskItem>()) == 1)
    }

    @Test("Rediscovered revoked list restores access and forces pull despite matching CTag")
    func restorationForcesPull() async throws {
        let (container, account, list, task) = try fixture()
        list.photoAccessRevoked = true; task.isDirty = false
        try container.mainContext.save()
        let (outcome, requests) = await run(container, account: account, responses: [
            .init(body: DAVSyncScenario.manifest(count: 0))])
        #expect(requests.contains { $0.method == "REPORT" && $0.path == "/one" })
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskList>()).first)
        #expect(stored.photoAccessRevoked != true)
        #expect(outcome.status == .completed)
    }

    @Test("Legacy move GETs source attachments and keeps source original until destination copy exists")
    func legacyMoveCatchesUpSource() async throws {
        let (container, account, source, task) = try fixture()
        task.attachmentStateKnown = nil
        let destination = TaskList(serverURL: "/two/", name: "Fixture", colorHex: "#007AFF")
        container.mainContext.insert(destination); destination.account = account
        destination.syncCTag = "c1"; destination.lastFullPullDate = Date()
        SyncEngine.markCategoriesCaughtUp(listID: destination.id)
        TaskMover.move(task, to: destination, in: container.mainContext)
        let host = "photo-legacy-move-" + UUID().uuidString.lowercased() + ".invalid"
        account.serverBaseURL = "https://" + host
        try container.mainContext.save()
        let attachment = TaskPhotoAttachment(id: remotePhotoID, previewData: TaskPhotoJPEGFixture.data,
            originalFileID: "903", folderFileID: "899", originalRequested: true)
        let opaque = "ATTACH:https://example.com/manual.pdf"
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/", "/two/"]) + [
                .init(status: 200, body: remote(photos: [attachment], opaque: [opaque]), headers: ["ETag": "source-new"]),
                .init(status: 201, body: "", headers: ["ETag": "destination-accepted"])]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let outcome = await engine.performFullSyncOutcome(accountID: account.id,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container, reconcileNotifications: false)
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.filter { $0.method == "GET" }.map(\.path) == ["/one/photo-task.ics"])
        let put = try #require(requests.first { $0.method == "PUT" })
        #expect(put.path == "/two/photo-task.ics")
        let sent = try #require(try ICalendarParser.parseSingleVTODO(from: String(decoding: put.body, as: UTF8.self)))
        #expect(sent.summary == "Local edit"); #expect(sent.opaqueAttachments == [opaque])
        #expect(sent.photos.first?.id == remotePhotoID)
        #expect(sent.photos.first?.originalFileID == nil)
        let fresh = ModelContext(container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        let photo = try #require(stored.photos.first)
        #expect(photo.previousOriginalFileID == "903")
        #expect(photo.previousOriginalFolderID == "899")
        #expect(photo.previousOriginalListID == source.id)
        #expect(photo.previousOriginalAccountID == account.id)
        #expect(stored.pendingMoveFromHref == "/one/photo-task.ics")
        #expect(!requests.contains { $0.method == "DELETE" })
        #expect(outcome.status == .completed)
    }

    @Test("Legacy move source account comes from trusted source list and rebinding rejects stale GET")
    func legacyMoveSourceBindingIsGuarded() async throws {
        let (container, sourceAccount, source, task) = try fixture()
        let destinationAccount = ServerAccount(displayName: "Destination", serverBaseURL: "https://destination.invalid", username: "destination")
        let destination = TaskList(serverURL: "/destination/", name: "Destination", colorHex: "#007AFF")
        container.mainContext.insert(destinationAccount); container.mainContext.insert(destination)
        destination.account = destinationAccount
        task.attachmentStateKnown = nil
        TaskMover.move(task, to: destination, in: container.mainContext)
        try container.mainContext.save()
        let request = try #require(try TaskPhotoLegacyCatchUp.requestInfo(taskID: task.id,
            listID: destination.id, accountID: destinationAccount.id, container: container))
        #expect(request.href == "/one/photo-task.ics")
        #expect(request.sourceListID == source.id)
        #expect(request.sourceAccountID == sourceAccount.id)
        task.pendingMoveFromHref = "/one/new-source.ics"
        try container.mainContext.save()
        var remote = ICalendarParser.VTODOData(); remote.uid = task.uid
        remote.photos = [.init(id: remotePhotoID, previewData: TaskPhotoJPEGFixture.data)]
        let change = try TaskPhotoLegacyCatchUp.apply(remote, taskID: task.id,
            listID: destination.id, accountID: destinationAccount.id, href: request.href,
            container: container, expectedRequest: request)
        #expect(change == nil)
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.photos.isEmpty)
        #expect(stored.attachmentStateKnown != true)
        #expect(stored.pendingMoveFromHref == "/one/new-source.ics")
    }

    @Test("Foreground preserves Vault original before source DELETE and publishes Vault scope")
    func vaultOriginalPreparedBeforeSourceDelete() async throws {
        let (container, account, source, task) = try fixture()
        let vaultAccount = ServerAccount(vaultDisplayName: "Vault")
        let vault = TaskList(serverURL: "", name: "Vault", colorHex: "#007AFF")
        container.mainContext.insert(vaultAccount); container.mainContext.insert(vault)
        vault.account = vaultAccount
        let photo = TaskPhoto(photoID: localPhotoID, previewData: TaskPhotoJPEGFixture.data)
        photo.originalRequested = true; photo.originalFileID = "903"; photo.folderFileID = "899"
        container.mainContext.insert(photo); photo.task = task
        TaskMover.move(task, to: vault, in: container.mainContext)
        try container.mainContext.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TaskPhotoCache(directory: directory)
        try await cache.store(TaskPhotoJPEGFixture.data, photoID: photo.id)
        let host = "photo-vault-engine-" + UUID().uuidString.lowercased() + ".invalid"
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
                .init(status: 204, body: "")]), retryPolicy: .init(maxAttempts: 1, baseDelay: 0)),
            taskPhotoVaultMoves: TaskPhotoVaultMoves(files: EnginePhotoFiles(), cache: cache))
        let outcome = await engine.performFullSyncOutcome(accountID: account.id,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container, reconcileNotifications: false)
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.filter { $0.method == "DELETE" }.map(\.path) == ["/one/photo-task.ics"])
        #expect(!requests.contains { $0.method == "PUT" })
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskPhoto>()).first)
        #expect(stored.originalStatus == "local")
        #expect(stored.task?.taskList?.id == vault.id)
        #expect(try await cache.load(photoID: photo.id) == TaskPhotoJPEGFixture.data)
        #expect(outcome.changedListIDs.contains(vault.id))
        #expect(outcome.changedListIDs.contains(source.id))
        #expect(outcome.status == .completed)
    }

    @Test("Original links are synchronized before PUT on pull and CTag skip", arguments: [false, true])
    func originalLinkBeforePut(skipPull: Bool) async throws {
        let (container, account, list, task) = try fixture()
        if !skipPull { list.syncCTag = nil }
        let photo = TaskPhoto(photoID: localPhotoID, previewData: TaskPhotoJPEGFixture.data)
        photo.originalRequested = true; photo.originalContentType = "image/jpeg"
        photo.pendingOperation = "add"; container.mainContext.insert(photo); photo.task = task
        try container.mainContext.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TaskPhotoCache(directory: directory)
        try await cache.store(TaskPhotoJPEGFixture.data, photoID: photo.id)
        let files = EnginePhotoFiles()
        let host = "photo-original-" + UUID().uuidString.lowercased() + ".invalid"
        var responses = DAVSyncScenario.discovery(paths: ["/one/"])
        if !skipPull { responses.append(.init(body: DAVSyncScenario.manifest(count: 0))) }
        responses.append(.init(status: 204, body: "", headers: ["ETag": "accepted"]))
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)),
            taskPhotoSync: TaskPhotoSync(files: files, cache: cache))
        let outcome = await engine.performFullSyncOutcome(accountID: account.id,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container, reconcileNotifications: false)
        let put = try #require(ScriptedDAVProtocol.requests(host: host).first { $0.method == "PUT" })
        let sent = try #require(try ICalendarParser.parseSingleVTODO(from: String(decoding: put.body, as: UTF8.self)))
        #expect(sent.photos.first?.originalFileID == "901")
        #expect(sent.photos.first?.folderFileID == "900")
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskPhoto>()).first)
        #expect(stored.originalFileID == "901"); #expect(stored.pendingOperation == nil)
        #expect(outcome.changedListIDs.contains(list.id))
        #expect(await engine.consumePendingInboundRefresh())
        #expect(outcome.status == .completed)
    }

    @Test("Background defers original permissions and provisioning without upload or PUT")
    func backgroundDoesNotUploadOriginal() async throws {
        let (container, account, _, task) = try fixture()
        let photo = TaskPhoto(photoID: localPhotoID, previewData: TaskPhotoJPEGFixture.data)
        photo.originalRequested = true; photo.originalContentType = "image/jpeg"
        photo.pendingOperation = "add"; container.mainContext.insert(photo); photo.task = task
        try container.mainContext.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TaskPhotoCache(directory: directory)
        try await cache.store(TaskPhotoJPEGFixture.data, photoID: photo.id)
        let files = EnginePhotoFiles()
        let host = "photo-background-" + UUID().uuidString.lowercased() + ".invalid"
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
                .init(body: DAVSyncScenario.manifest(count: 0))]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)),
            taskPhotoSync: TaskPhotoSync(files: files, cache: cache))
        let outcome = await engine.performBackgroundSyncOutcome(accountID: account.id,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container, reconcileNotifications: false)
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskPhoto>()).first)
        #expect(stored.originalFileID == nil)
        #expect(stored.pendingOperation == "add")
        #expect(await files.inspections == 0)
        #expect(await files.uploads == 0)
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "PUT" })
        #expect(outcome.status == .completed)
    }

    @Test("Preview-only list never requests Files permission or provisioning")
    func previewsDoNotAddFilesRequests() async throws {
        let (container, account, _, task) = try fixture()
        let photo = TaskPhoto(photoID: localPhotoID, previewData: TaskPhotoJPEGFixture.data)
        photo.pendingOperation = "add"; container.mainContext.insert(photo); photo.task = task
        try container.mainContext.save()
        let files = EnginePhotoFiles()
        let host = "photo-preview-" + UUID().uuidString.lowercased() + ".invalid"
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
                .init(status: 204, body: "", headers: ["ETag": "accepted"])]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)), taskPhotoSync: TaskPhotoSync(files: files))
        let outcome = await engine.performFullSyncOutcome(accountID: account.id,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container, reconcileNotifications: false)
        #expect(await files.inspections == 0)
        #expect(await files.uploads == 0)
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND", "PUT"])
        #expect(outcome.status == .completed)
    }

}


/// Test-only Files boundary; engine assertions inspect the actual CalDAV payload and store.
private actor EnginePhotoFiles: TaskPhotoFilesTransport {
    private(set) var inspections = 0
    private(set) var uploads = 0
    func inspectCalendar(calendarHref: String, access: PhotoServerAccess) -> PhotoCalendarAccess {
        inspections += 1
        return .init(ownerID: access.username, sharees: [])
    }
    func prepareFolder(calendarHref: String, access: PhotoServerAccess) -> PhotoFolder {
        .init(fileID: "900", href: "/originals/")
    }
    func resolveFolder(fileID: String, access: PhotoServerAccess) -> PhotoFolder {
        .init(fileID: fileID, href: "/originals/")
    }
    func upload(data: Data, contentType: String, photoID: String, folder: PhotoFolder,
                access: PhotoServerAccess) -> String {
        uploads += 1
        return "901"
    }
    func download(fileID: String, access: PhotoServerAccess) throws -> Data {
        throw TaskPhotoOriginalError.unavailable
    }
    func delete(fileID: String, access: PhotoServerAccess) {}
}
