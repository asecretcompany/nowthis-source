import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Task photo engine HTTP and persistence", .serialized)
@MainActor
struct TaskPhotoEngineTests {
    private let localPhotoID = "AD2E616C-55C0-4F7C-A3C4-32AD464EC9E4"
    private let remotePhotoID = "BD2E616C-55C0-4F7C-A3C4-32AD464EC9E4"

    private func fixture(host: String = "unused.invalid") throws -> (ModelContainer, ServerAccount, TaskList, TaskItem) {
        let container = try ModelContainer(for: Schema(SchemaV2.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: "https://" + host, username: "fixture")
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        let task = TaskItem(uid: "photo-task", title: "Local edit")
        context.insert(account); context.insert(list); context.insert(task)
        list.account = account; task.taskList = list
        task.remoteHref = "/one/photo-task.ics"; task.etag = "old"
        task.isLocalOnly = false; task.isDirty = true; task.attachmentStateKnown = true
        list.syncCTag = "c1"; list.lastFullPullDate = Date()
        SyncEngine.markCategoriesCaughtUp(listID: list.id)
        try VTODOOpaqueState.empty.store(taskID: task.id, in: context)
        try SyncResourceFixture.prove(task, in: context)
        try context.save()
        return (container, account, list, task)
    }

    private func remote(photos: [TaskPhotoAttachment] = [], opaque: [String] = [], uid: String = "photo-task") -> String {
        ICalendarSerializer.serialize(uid: uid, summary: "Remote title", description: "Remote notes",
            photos: photos, opaqueAttachments: opaque)
    }

    private func run(_ container: ModelContainer, account: ServerAccount,
                     responses: [ScriptedDAVProtocol.Response]) async throws -> (SyncOutcome, [ScriptedDAVProtocol.RecordedRequest]) {
        let host = "photo-engine-" + UUID().uuidString.lowercased() + ".invalid"
        account.serverBaseURL = "https://" + host
        for task in try container.mainContext.fetch(FetchDescriptor<TaskItem>()) {
            try SyncResourceFixture.prove(task, in: container.mainContext)
            try SyncResourceFixture.proveSource(task, etag: "old", in: container.mainContext)
        }
        try container.mainContext.save()
        for list in account.taskLists {
            try DAVSyncScenario.seedRecentCheckpoint(for: list, in: container)
        }
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
        let (outcome, requests) = try await run(container, account: account, responses: [
            .init(status: 200, body: remote(photos: [attachment], opaque: [opaque]), headers: ["ETag": "old"]),
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
        let (outcome, requests) = try await run(container, account: account, responses: [
            .init(status: 200, body: remote(uid: "different-task"), headers: ["ETag": "fresh"])])
        #expect(requests.filter { $0.method == "GET" }.count == 1)
        #expect(!requests.contains { $0.method == "PUT" })
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "Local edit"); #expect(stored.isDirty)
        #expect(stored.etag == "old"); #expect(stored.attachmentStateKnown != true)
        #expect(outcome.status == .partial)
    }


    @Test("Missing sidecar GETs before PUT even with known photos; failures never PUT", arguments: ["success", "http", "uid", "parse"])
    func opaqueCatchUpBeforePut(scenario: String) async throws {
        let (container, account, _, task) = try fixture()
        try VTODOOpaqueState.remove(tasks: [task], in: container.mainContext)
        task.reminderOffset = 60
        let localPhoto = TaskPhoto(photoID: localPhotoID, previewData: TaskPhotoJPEGFixture.data)
        container.mainContext.insert(localPhoto); localPhoto.task = task
        try container.mainContext.save()
        let raw = "BEGIN:VTODO\nUID:\(scenario == "uid" ? "different" : task.uid)\nSUMMARY:Remote\nCLASS:PRIVATE\nBEGIN:VALARM\nTRIGGER:-PT15M\nACTION:EMAIL\nDESCRIPTION:Server reminder\nEND:VALARM\n\(scenario == "parse" ? "BEGIN:VALARM" : "")\nEND:VTODO"
        var responses: [ScriptedDAVProtocol.Response] = [.init(status: scenario == "http" ? 500 : 200, body: raw, headers: ["ETag": "old"])]
        if scenario == "success" { responses.append(.init(status: 204, body: "", headers: ["ETag": "accepted"])) }
        let (outcome, requests) = try await run(container, account: account, responses: responses)
        let writes = requests.filter { $0.method == "GET" || $0.method == "PUT" }
        #expect(writes.map(\.method) == (scenario == "success" ? ["GET", "PUT"] : ["GET"]))
        let fresh = ModelContext(container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "Local edit"); #expect(stored.reminderOffset == 60)
        #expect(stored.photos.map(\.photoID) == [localPhotoID])
        if scenario == "success" {
            let put = try #require(writes.last)
            let sent = try #require(try ICalendarParser.parseSingleVTODO(from: String(decoding: put.body, as: UTF8.self)))
            #expect(sent.opaqueProperties == ["CLASS:PRIVATE"])
            #expect(sent.alarmTriggerSeconds == 60)
            #expect(!String(decoding: put.body, as: UTF8.self).contains("ACTION:EMAIL"))
            #expect(try VTODOOpaqueState.load(taskID: task.id, in: fresh)?.baselineReminderOffset == 60)
            #expect(!stored.isDirty)
        } else {
            #expect(stored.isDirty)
            #expect(try VTODOOpaqueState.load(taskID: task.id, in: fresh) == nil)
        }
        #expect(outcome.status == (scenario == "success" ? .completed : .partial))
    }

    @Test("Legacy Vault move GET precedes source DELETE; catch-up failure preserves source", arguments: [false, true])
    func legacyVaultMovePreservesOpaqueBeforeDelete(fail: Bool) async throws {
        let (container, account, _, task) = try fixture()
        try VTODOOpaqueState.remove(tasks: [task], in: container.mainContext)
        let vaultAccount = ServerAccount(vaultDisplayName: "Vault")
        let vault = TaskList(serverURL: "", name: "Vault", colorHex: "#007AFF")
        container.mainContext.insert(vaultAccount); container.mainContext.insert(vault); vault.account = vaultAccount
        for photo in task.photos where photo.originalFileID != nil { try acceptPhotoOriginal(photo, in: container.mainContext) }
        TaskMover.move(task, to: vault, in: container.mainContext)
        let host = "opaque-vault-" + UUID().uuidString.lowercased() + ".invalid"
        account.serverBaseURL = "https://" + host
        for task in try container.mainContext.fetch(FetchDescriptor<TaskItem>()) {
            try SyncResourceFixture.prove(task, in: container.mainContext)
            try SyncResourceFixture.proveSource(task, etag: "old", in: container.mainContext)
        }
        try container.mainContext.save()
        for list in account.taskLists {
            try DAVSyncScenario.seedRecentCheckpoint(for: list, in: container)
        }
        var responses = DAVSyncScenario.discovery(paths: ["/one/"])
        responses.append(.init(status: fail ? 500 : 200, body: "BEGIN:VTODO\nUID:photo-task\nSUMMARY:Remote\nCLASS:PRIVATE\nEND:VTODO", headers: ["ETag": "old"]))
        if !fail { responses.append(.init(status: 204, body: "")) }
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: "https://" + host,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container, reconcileNotifications: false)
        let requests = ScriptedDAVProtocol.requests(host: host).filter { ["GET", "PUT", "DELETE"].contains($0.method) }
        #expect(requests.map(\.method) == (fail ? ["GET"] : ["GET", "DELETE"]))
        #expect(requests.allSatisfy { $0.path == "/one/photo-task.ics" })
        let fresh = ModelContext(container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "Local edit"); #expect(stored.taskList?.id == vault.id)
        #expect((stored.pendingMoveFromHref != nil) == fail)
        #expect(try VTODOOpaqueState.load(taskID: task.id, in: fresh)?.opaqueProperties == (fail ? nil : ["CLASS:PRIVATE"]))
    }

    @Test("Photo conflict rebases remote fields and retries exactly once with fresh ETag", arguments: [false, true])
    func photoConflictRetry(secondConflict: Bool) async throws {
        let (container, account, _, task) = try fixture()
        let photo = TaskPhoto(photoID: localPhotoID, previewData: TaskPhotoJPEGFixture.data)
        photo.pendingOperation = "add"; container.mainContext.insert(photo); photo.task = task
        try container.mainContext.save()
        let remotePhoto = TaskPhotoAttachment(id: remotePhotoID, previewData: TaskPhotoJPEGFixture.data)
        let (outcome, requests) = try await run(container, account: account, responses: [
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
        let (outcome, requests) = try await run(container, account: account, responses: [
            .init(status: 412, body: ""), .init(status: 200, body: remote(), headers: ["ETag": "fresh"])])
        #expect(requests.filter { $0.method == "PUT" }.count == 1)
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "Remote title"); #expect(!stored.isDirty)
        #expect(outcome.status == .completed)
    }
    @Test("Missing discovery list revokes photos only after definitive collection denial", arguments: [403, 404, 500, 207], [false, true])
    func missingListRequiresCollectionProbe(status: Int, background: Bool) async throws {
        let host = "photo-access-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, list, task) = try fixture(host: host)
        let photo = TaskPhoto(photoID: localPhotoID, previewData: TaskPhotoJPEGFixture.data)
        photo.originalRequested = true; photo.originalFileID = "901"; photo.folderFileID = "900"
        container.mainContext.insert(photo); photo.task = task
        try container.mainContext.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TaskPhotoCache(directory: directory)
        let photoID = photo.id
        let bytes = Data([1, 2, 3])
        try await cache.store(bytes, photoID: photoID)
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: []) + [
                .init(status: status, body: status == 207 ? DAVSyncScenario.manifest(count: 0) : "")]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)), taskPhotoCache: cache)
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
        let denied = !background && (status == 403 || status == 404)
        #expect((stored.photoAccessRevoked == true) == denied)
        #expect(try await cache.load(photoID: photoID) == (denied ? nil : bytes))
        #expect(stored.id == list.id)
        #expect(try fresh.fetchCount(FetchDescriptor<TaskItem>()) == 1)
    }

    @Test("Rediscovered revoked list restores access and forces pull despite matching CTag")
    func restorationForcesPull() async throws {
        let (container, account, list, task) = try fixture()
        list.photoAccessRevoked = true; task.isDirty = false
        try container.mainContext.save()
        let (outcome, requests) = try await run(container, account: account, responses: [
            .init(body: DAVSyncScenario.manifest(count: 0))])
        #expect(requests.contains { $0.method == "REPORT" && $0.path == "/one" })
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskList>()).first)
        #expect(stored.photoAccessRevoked != true)
        #expect(outcome.status == .completed)
    }

    enum PhotoProbe: Sendable {
        case missingDenied, missingRestored, pullDenied, backgroundPullDenied

        var isMissing: Bool { self == .missingDenied || self == .missingRestored }
        var reportCount: Int { isMissing ? 1 : 2 }
    }

    enum Rebinding: Sendable { case account, collection, server, username, mode }

    @Test("An old collection response leaves the newly bound list's access and checkpoint alone",
          arguments: [PhotoProbe.missingDenied, .missingRestored, .pullDenied, .backgroundPullDenied],
                     [Rebinding.account, .collection, .server, .username, .mode])
    func oldPhotoProbeCannotChangeReboundList(probe: PhotoProbe, rebinding: Rebinding) async throws {
        let host = "photo-rebound-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, list, task) = try fixture(host: host)
        let photo = TaskPhoto(photoID: localPhotoID, previewData: TaskPhotoJPEGFixture.data)
        photo.originalRequested = true; photo.originalFileID = "901"; photo.folderFileID = "900"
        container.mainContext.insert(photo); photo.task = task
        try container.mainContext.save()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TaskPhotoCache(directory: directory)
        let photoID = photo.id
        let bytes = Data([1, 2, 3])
        try await cache.store(bytes, photoID: photoID)

        let gate = ScriptedDAVProtocol.Gate()
        let restoring = probe == .missingRestored
        let responses = DAVSyncScenario.discovery(paths: probe.isMissing ? [] : ["/one/"])
            + (probe.isMissing ? [] : [.init(status: 404, body: "")])
            + [.init(status: restoring ? 207 : 403,
                     body: restoring ? DAVSyncScenario.manifest(count: 0) : "", gate: gate)]
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)), taskPhotoCache: cache)
        let listID = list.id
        let accountID = account.id
        let baseURL = account.serverBaseURL
        let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
        let run = Task {
            if probe == .backgroundPullDenied {
                return await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
                    credentials: credentials, modelContainer: container, reconcileNotifications: false)
            }
            return await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
                credentials: credentials, modelContainer: container, reconcileNotifications: false)
        }
        defer { run.cancel(); gate.release() }
        let deadline = ContinuousClock.now + .seconds(5)
        func reports() -> [ScriptedDAVProtocol.RecordedRequest] {
            ScriptedDAVProtocol.requests(host: host).filter { $0.method == "REPORT" }
        }
        while reports().count < probe.reportCount && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let request = try #require(reports().last)
        try #require(reports().count == probe.reportCount)
        #expect(request.path == "/one")
        #expect(request.basicAuthUsername == "fixture")

        let writer = ModelContext(container)
        let rebound = try #require(try writer.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first)
        let currentAccount = try #require(rebound.account)
        switch rebinding {
        case .account:
            let replacement = ServerAccount(displayName: "Replacement", serverBaseURL: baseURL, username: "fixture")
            writer.insert(replacement); rebound.account = replacement
        case .collection: rebound.serverURL = "/replacement/"
        case .server: currentAccount.serverBaseURL = baseURL + "/replacement"
        case .username: currentAccount.username = "replacement"
        case .mode: currentAccount.mode = .vault
        }
        let integrity = Date(timeIntervalSince1970: 1_800_000_000)
        rebound.photoAccessRevoked = restoring
        rebound.syncCTag = "replacement-ctag"
        rebound.lastFullPullDate = integrity
        try writer.save()
        try DAVSyncScenario.seedRecentCheckpoint(for: rebound, in: container, ctag: "replacement-ctag", at: integrity)
        let newAccount = try #require(rebound.account)
        let scope = SyncCollectionPuller.Scope(accountID: newAccount.id, listID: listID, historyScope: "0")
        let key = SyncImportCheckpoint.identity(accountID: newAccount.id, listID: listID,
            baseURL: newAccount.serverBaseURL, username: newAccount.username, months: 0)

        gate.release()
        let outcome = await run.value
        let fresh = ModelContext(container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first)
        #expect(stored.photoAccessRevoked == restoring)
        #expect(stored.syncCTag == "replacement-ctag")
        #expect(stored.lastFullPullDate == integrity)
        let checkpoint = try SyncImportCheckpoint.read(id: key, scope: scope, in: fresh)
        #expect(checkpoint?.ctag == "replacement-ctag")
        #expect(checkpoint?.lastIntegrity == integrity)
        #expect(try await cache.load(photoID: photoID) == bytes)
        #expect(!outcome.changedListIDs.contains(listID))
        #expect(outcome.failures.isEmpty)
        #expect(await engine.consumePendingInboundRefresh() == false)
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
        for task in try container.mainContext.fetch(FetchDescriptor<TaskItem>()) {
            try SyncResourceFixture.prove(task, in: container.mainContext)
            try SyncResourceFixture.proveSource(task, etag: "old", in: container.mainContext)
        }
        try container.mainContext.save()
        for list in [source, destination] {
            try DAVSyncScenario.seedRecentCheckpoint(for: list, in: container)
        }
        let attachment = TaskPhotoAttachment(id: remotePhotoID, previewData: TaskPhotoJPEGFixture.data,
            originalFileID: "903", folderFileID: "899", originalRequested: true)
        let opaque = "ATTACH:https://example.com/manual.pdf"
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/", "/two/"]) + [
                .init(status: 200, body: remote(photos: [attachment], opaque: [opaque]), headers: ["ETag": "old"]),
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
        #expect(throws: SyncResourceState.Hold.self) {
            try TaskPhotoLegacyCatchUp.apply(remote, taskID: task.id,
                listID: destination.id, accountID: destinationAccount.id, href: request.href,
                container: container, expectedRequest: request)
        }
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.photos.isEmpty)
        #expect(stored.attachmentStateKnown != true)
        #expect(stored.pendingMoveFromHref == "/one/new-source.ics")
    }

    @Test("A deferred source account keeps an uncached moved original pending", arguments: [false, true])
    func deferredSourceHoldsOriginalDownload(credentialBusy: Bool) async throws {
        let host = "photo-source-wait-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, sourceAccount, source, task) = try fixture(host: host)
        let context = container.mainContext
        let destinationAccount = ServerAccount(displayName: "Destination", serverBaseURL: sourceAccount.serverBaseURL,
            username: "fixture")
        let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        context.insert(destinationAccount)
        context.insert(destination)
        destination.account = destinationAccount

        let photo = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        photo.originalRequested = true
        photo.originalContentType = "image/jpeg"
        photo.originalFileID = "903"
        photo.folderFileID = "899"
        context.insert(photo)
        photo.task = task
        try acceptPhotoOriginal(photo, in: context)
        try #require(TaskMover.move(task, to: destination, in: context).count == 1)
        try context.save()
        let originalStatus = photo.originalStatus
        try #require(photo.previousOriginalAccountID == sourceAccount.id)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = PhotoFilesFake(owner: "fixture")
        let sourceKeychain = TestAccountKeychain()
        let sourceID = sourceAccount.id
        try await sourceKeychain.manager.save(password: "source", for: sourceID)
        let photos = TaskPhotoSync(files: files, cache: TaskPhotoCache(directory: directory),
                                  keychainManager: sourceKeychain.manager)
        let sourceDelay: [ScriptedDAVProtocol.Response] = credentialBusy ? [] : [
            .init(status: 429, body: "", headers: ["Retry-After": "1800"])
        ]
        let responses = sourceDelay
            + DAVSyncScenario.discovery(paths: ["/two/"])
            + [.init(body: DAVSyncScenario.manifest(count: 0, path: "/two/")),
               .init(status: 201, body: "", headers: ["ETag": "after"])]
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses)), taskPhotoSync: photos)
        let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
        let gate = AccountWriteGate()
        defer { gate.resume() }
        var heldCredentialRead: Task<AccountCredentialAdmission, any Error>?
        if credentialBusy {
            sourceKeychain.beforeRead(sourceID, action: gate.pause)
            heldCredentialRead = Task {
                try await AccountManager.admitCredentials(accountID: sourceID, container: container,
                                                           keychainManager: sourceKeychain.manager)
            }
            await gate.waitUntilPaused()
        } else {
            let first = await engine.performBackgroundSyncOutcome(accountID: sourceAccount.id,
                serverBaseURL: sourceAccount.serverBaseURL, credentials: credentials, modelContainer: container,
                reconcileNotifications: false)
            #expect(first.failures.first?.category == .busy)
        }
        let destinationID = destinationAccount.id
        let outcome = await engine.performFullSyncOutcome(accountID: destinationID,
            serverBaseURL: destinationAccount.serverBaseURL, credentials: credentials, modelContainer: container,
            reconcileNotifications: false)
        gate.resume()
        _ = try await heldCredentialRead?.value
        if credentialBusy {
            #expect(outcome.status == .partial)
            #expect(outcome.failures.isEmpty)
            let fresh = ModelContext(container)
            let savedAccount = try fresh.fetch(FetchDescriptor<ServerAccount>(
                predicate: #Predicate { $0.id == destinationID })).first
            #expect(savedAccount?.lastSyncDate == nil)
        }

        #expect(await files.scopedDownloads.isEmpty)
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.contains { $0.method == "PUT" && $0.path == "/two/photo-task.ics" })
        #expect(!requests.contains { $0.method == "DELETE" })
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskPhoto>()).first)
        #expect(saved.originalFileID == nil)
        #expect(saved.originalStatus == originalStatus)
        #expect(saved.previousOriginalFileID == "903")
        #expect(saved.previousOriginalListID == source.id)
    }

    @Test("Foreground preserves Vault original before source DELETE and publishes Vault scope")
    func vaultOriginalPreparedBeforeSourceDelete() async throws {
        let host = "photo-vault-engine-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, source, task) = try fixture(host: host)
        let vaultAccount = ServerAccount(vaultDisplayName: "Vault")
        let vault = TaskList(serverURL: "", name: "Vault", colorHex: "#007AFF")
        container.mainContext.insert(vaultAccount); container.mainContext.insert(vault)
        vault.account = vaultAccount
        let photo = TaskPhoto(photoID: localPhotoID, previewData: TaskPhotoJPEGFixture.data)
        photo.originalRequested = true; photo.originalFileID = "903"; photo.folderFileID = "899"
        container.mainContext.insert(photo); photo.task = task
        for photo in task.photos where photo.originalFileID != nil { try acceptPhotoOriginal(photo, in: container.mainContext) }
        TaskMover.move(task, to: vault, in: container.mainContext)
        try container.mainContext.save()
        try DAVSyncScenario.seedRecentCheckpoint(for: source, in: container)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TaskPhotoCache(directory: directory)
        try await cache.store(TaskPhotoJPEGFixture.data, photoID: photo.id)
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

    @Test("Original links are synchronized before PUT on pull and CTag skip", arguments: [599.0, 600.0])
    func originalLinkBeforePut(age: TimeInterval) async throws {
        let (container, account, list, task) = try fixture()
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
        account.serverBaseURL = "https://" + host
        try SyncResourceFixture.prove(task, in: container.mainContext)
        try container.mainContext.save()
        let now = Date()
        let scope = SyncCollectionPuller.Scope(accountID: account.id, listID: list.id, historyScope: "0")
        let key = SyncImportCheckpoint.identity(accountID: account.id, listID: list.id,
            baseURL: account.serverBaseURL, username: account.username, months: 0)
        let checkpoint = SyncCollectionPuller.Checkpoint(scope: scope, ctag: "c1",
            lastIntegrity: now.addingTimeInterval(-age), hasCompletedBaseline: true)
        try SyncImportCheckpoint.commit(checkpoint, id: key, collectionPath: list.serverURL, container: container)
        var responses = DAVSyncScenario.discovery(paths: ["/one/"])
        if age >= 600 { responses.append(.init(body: DAVSyncScenario.manifest(count: 0))) }
        responses.append(.init(status: 204, body: "", headers: ["ETag": "accepted"]))
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)),
            taskPhotoSync: TaskPhotoSync(files: files, cache: cache), now: { now })
        let outcome = await engine.performFullSyncOutcome(accountID: account.id,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container, reconcileNotifications: false)
        let requests = ScriptedDAVProtocol.requests(host: host)
        let expected = age < 600 ? ["PROPFIND", "PROPFIND", "PROPFIND", "PUT"]
            : ["PROPFIND", "PROPFIND", "PROPFIND", "REPORT", "PUT"]
        #expect(requests.map(\.method) == expected)
        let put = try #require(requests.first { $0.method == "PUT" })
        #expect(put.ifMatch == "\"old\"")
        let committed = try SyncImportCheckpoint.read(id: key, scope: scope, in: ModelContext(container))
        #expect(committed?.lastIntegrity == (age < 600 ? checkpoint.lastIntegrity : now))
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
        let host = "photo-background-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, _, task) = try fixture(host: host)
        let photo = TaskPhoto(photoID: localPhotoID, previewData: TaskPhotoJPEGFixture.data)
        photo.originalRequested = true; photo.originalContentType = "image/jpeg"
        photo.pendingOperation = "add"; container.mainContext.insert(photo); photo.task = task
        try container.mainContext.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TaskPhotoCache(directory: directory)
        try await cache.store(TaskPhotoJPEGFixture.data, photoID: photo.id)
        let files = EnginePhotoFiles()
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
        let host = "photo-preview-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, list, task) = try fixture(host: host)
        let photo = TaskPhoto(photoID: localPhotoID, previewData: TaskPhotoJPEGFixture.data)
        photo.pendingOperation = "add"; container.mainContext.insert(photo); photo.task = task
        try container.mainContext.save()
        try DAVSyncScenario.seedRecentCheckpoint(for: list, in: container)
        let files = EnginePhotoFiles()
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
