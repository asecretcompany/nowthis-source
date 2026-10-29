import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Durable task photo cleanup", .serialized)
@MainActor
struct TaskPhotoCleanupRunnerTests {
    private let access = PhotoServerAccess(baseURL: "https://cleanup.invalid", username: "alice", password: "test")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func matureUnreferencedOriginalIsDeletedAndOnlyItsQueueRowIsRemoved() async throws {
        let fixture = try CleanupFixture()
        let key = try fixture.enqueue(fileID: "901", notBefore: now)
        let otherKey = try fixture.enqueue(fileID: "902", accountID: "other-account", notBefore: now)
        let metadata = SyncMetadata(id: "ordinary-sync", collectionPath: fixture.path)
        metadata.syncToken = "calendar-token"
        fixture.container.mainContext.insert(metadata)
        try fixture.container.mainContext.save()
        let files = CleanupFilesTransport()
        let scans = CleanupScanLog()

        let deleted = try await TaskPhotoCleanupRunner(files: files).run(
            accountID: fixture.accountID, access: access, container: fixture.container, now: now
        ) { path in
            await scans.append(path)
            return []
        }

        #expect(deleted == ["901"])
        #expect(await files.successfulDeletes == ["901"])
        #expect(await files.deleteScopes == [.init(fileID: "901", folderID: "900", calendarHref: fixture.path)])
        #expect(await scans.paths == [fixture.path])
        #expect(try fixture.row(key) == nil)
        #expect(try fixture.row(otherKey)?.fileID == "902")
        #expect(try fixture.row("ordinary-sync")?.fileID == "calendar-token")
    }

    @Test("Only work with a known elapsed grace period is eligible", arguments: ["future", "missing"])
    func gracePeriodIsRequired(kind: String) async throws {
        let fixture = try CleanupFixture()
        let deadline = kind == "future" ? now.addingTimeInterval(1) : nil
        let key = try fixture.enqueue(fileID: "901", notBefore: deadline)
        let before = try #require(try fixture.row(key))
        let files = CleanupFilesTransport()
        let scans = CleanupScanLog()

        let deleted = try await TaskPhotoCleanupRunner(files: files).run(
            accountID: fixture.accountID, access: access, container: fixture.container, now: now
        ) { path in await scans.append(path); return [] }

        #expect(deleted.isEmpty)
        #expect(await files.deleteRequests.isEmpty)
        #expect(await scans.paths.isEmpty)
        #expect(try fixture.row(key) == before)
    }

    @Test func callerReferenceFromAnotherListProtectsOriginal() async throws {
        let fixture = try CleanupFixture()
        let key = try fixture.enqueue(fileID: "901", notBefore: now)
        let files = CleanupFilesTransport()
        let scans = CleanupScanLog()

        let deleted = try await TaskPhotoCleanupRunner(files: files).run(
            accountID: fixture.accountID, access: access, container: fixture.container, now: now
        ) { sourcePath in
            await scans.append(sourcePath)
            // The caller returns the union from every accessible account calendar.
            return ["901"]
        }

        #expect(deleted.isEmpty)
        #expect(await scans.paths == [fixture.path])
        #expect(await files.deleteRequests.isEmpty)
        #expect(try fixture.row(key) != nil)
    }

    @Test func oldQueueRowWithoutFolderScopeRemainsDurable() async throws {
        let fixture = try CleanupFixture()
        let key = try fixture.enqueue(fileID: "901", folderID: nil, notBefore: now)
        let before = try #require(try fixture.row(key))
        let files = CleanupFilesTransport()
        let scans = CleanupScanLog()

        let deleted = try await TaskPhotoCleanupRunner(files: files).run(
            accountID: fixture.accountID, access: access, container: fixture.container, now: now
        ) { path in await scans.append(path); return [] }

        #expect(deleted.isEmpty)
        #expect(await files.deleteRequests.isEmpty)
        #expect(await files.deleteScopes.isEmpty)
        #expect(await scans.paths.isEmpty)
        #expect(try fixture.row(key) == before)
    }

    @Test func folderScopeChangedDuringScanPreventsDeletion() async throws {
        let fixture = try CleanupFixture()
        let key = try fixture.enqueue(fileID: "901", notBefore: now)
        let container = fixture.container
        let files = CleanupFilesTransport()

        let deleted = try await TaskPhotoCleanupRunner(files: files).run(
            accountID: fixture.accountID, access: access, container: container, now: now
        ) { _ in
            try await CleanupFixture.changeFolder(container: container, key: key, folderID: "999")
            return []
        }

        #expect(deleted.isEmpty)
        #expect(await files.deleteRequests.isEmpty)
        #expect(try fixture.row(key)?.folderID == "999")
    }

    @Test func folderScopeChangedDuringDeleteIsNotAcknowledged() async throws {
        let fixture = try CleanupFixture()
        let key = try fixture.enqueue(fileID: "901", notBefore: now)
        let container = fixture.container
        let files = CleanupFilesTransport(deleteHook: { _ in
            try await CleanupFixture.changeFolder(container: container, key: key, folderID: "999")
        })

        let deleted = try await TaskPhotoCleanupRunner(files: files).run(
            accountID: fixture.accountID, access: access, container: container, now: now
        ) { _ in [] }

        #expect(deleted == ["901"])
        #expect(await files.deleteScopes == [.init(fileID: "901", folderID: "900", calendarHref: fixture.path)])
        #expect(try fixture.row(key)?.folderID == "999")
    }

    @Test func everyScopeIsScannedBeforeAnyDeletionAndScanFailureRetainsAllWork() async throws {
        let fixture = try CleanupFixture()
        let first = try fixture.enqueue(fileID: "901", notBefore: now)
        let second = try fixture.enqueue(fileID: "902", path: "/tasks/second/", listID: "second-list", notBefore: now)
        let files = CleanupFilesTransport()
        let scans = CleanupScanLog()

        await #expect(throws: CleanupTestError.scanFailed) {
            try await TaskPhotoCleanupRunner(files: files).run(
                accountID: fixture.accountID, access: access, container: fixture.container, now: now
            ) { path in
                #expect(await files.deleteRequests.isEmpty)
                if await scans.append(path) == 2 { throw CleanupTestError.scanFailed }
                return []
            }
        }

        #expect(Set(await scans.paths) == [fixture.path, "/tasks/second/"])
        #expect(await files.deleteRequests.isEmpty)
        #expect(try fixture.row(first) != nil)
        #expect(try fixture.row(second) != nil)
    }

    @Test("Per-file failures retain retry work while other originals can succeed", arguments: [
        NextcloudPhotoClient.Error.forbidden, .unauthorized, .httpStatus(500)
    ])
    func failedDeleteRetainsItsRow(error: NextcloudPhotoClient.Error) async throws {
        let fixture = try CleanupFixture()
        let failed = try fixture.enqueue(fileID: "901", notBefore: now)
        let succeeded = try fixture.enqueue(fileID: "902", notBefore: now)
        let before = try #require(try fixture.row(failed))
        let files = CleanupFilesTransport(failures: ["901": error])

        let deleted = try await TaskPhotoCleanupRunner(files: files).run(
            accountID: fixture.accountID, access: access, container: fixture.container, now: now
        ) { _ in [] }

        #expect(deleted == ["902"])
        #expect(Set(await files.deleteRequests) == ["901", "902"])
        #expect(try fixture.row(failed) == before)
        #expect(try fixture.row(succeeded) == nil)
    }

    @Test func retainedFailureCanBeRetriedOnTheNextRun() async throws {
        let fixture = try CleanupFixture()
        let key = try fixture.enqueue(fileID: "901", notBefore: now)
        let files = CleanupFilesTransport(failures: ["901": .forbidden])
        let runner = TaskPhotoCleanupRunner(files: files)

        let failed = try await runner.run(accountID: fixture.accountID, access: access,
            container: fixture.container, now: now) { _ in [] }
        #expect(failed.isEmpty)
        #expect(try fixture.row(key) != nil)
        await files.clearFailures()
        let retried = try await runner.run(accountID: fixture.accountID, access: access,
            container: fixture.container, now: now) { _ in [] }

        #expect(retried == ["901"])
        #expect(await files.deleteRequests == ["901", "901"])
        #expect(try fixture.row(key) == nil)
    }

    @Test("Persisted current and previous originals remain protected", arguments: ["current", "remove", "previous"])
    func localReferencesProtectOriginal(kind: String) async throws {
        let fixture = try CleanupFixture()
        let key = try fixture.enqueue(fileID: "901", notBefore: now)
        let destination = try fixture.addList(accountID: kind == "previous" ? "destination-account" : fixture.accountID)
        try fixture.addPhoto(listID: destination,
            originalID: kind == "previous" ? "902" : "901",
            previousID: kind == "previous" ? "901" : nil,
            previousAccountID: kind == "previous" ? fixture.accountID : nil,
            operation: kind == "remove" ? "remove" : nil)
        let files = CleanupFilesTransport()

        let deleted = try await TaskPhotoCleanupRunner(files: files).run(
            accountID: fixture.accountID, access: access, container: fixture.container, now: now
        ) { _ in [] }

        #expect(deleted.isEmpty)
        #expect(await files.deleteRequests.isEmpty)
        #expect(try fixture.row(key) != nil)
    }

    @Test("File IDs in another account do not block this account's cleanup", arguments: ["current", "previous"])
    func localReferenceIdentityIncludesAccount(kind: String) async throws {
        let fixture = try CleanupFixture()
        let key = try fixture.enqueue(fileID: "901", notBefore: now)
        let destination = try fixture.addList(accountID: "other-account")
        try fixture.addPhoto(listID: destination,
            originalID: kind == "current" ? "901" : "902",
            previousID: kind == "previous" ? "901" : nil,
            previousAccountID: kind == "previous" ? "other-account" : nil)
        let files = CleanupFilesTransport()

        let deleted = try await TaskPhotoCleanupRunner(files: files).run(
            accountID: fixture.accountID, access: access, container: fixture.container, now: now
        ) { _ in [] }

        #expect(deleted == ["901"])
        #expect(try fixture.row(key) == nil)
    }

    @Test("References added during the scan are rechecked, including unsaved UI edits", arguments: [false, true])
    func localReferenceAddedDuringScanProtectsOriginal(saved: Bool) async throws {
        let fixture = try CleanupFixture()
        let key = try fixture.enqueue(fileID: "901", notBefore: now)
        let container = fixture.container
        let listID = fixture.listID
        let files = CleanupFilesTransport()
        let scans = CleanupScanLog()

        let deleted = try await TaskPhotoCleanupRunner(files: files).run(
            accountID: fixture.accountID, access: access, container: container, now: now
        ) { path in
            await scans.append(path)
            try await MainActor.run {
                try CleanupFixture.insertPhoto(container: container, listID: listID, originalID: "901", save: saved)
            }
            return []
        }

        #expect(await scans.paths == [fixture.path])
        #expect(deleted.isEmpty)
        #expect(await files.deleteRequests.isEmpty)
        #expect(try fixture.row(key) != nil)
    }

    @Test func unsavedReferenceAlreadyInTheEditorProtectsOriginal() async throws {
        let fixture = try CleanupFixture()
        let key = try fixture.enqueue(fileID: "901", notBefore: now)
        try fixture.addPhoto(listID: fixture.listID, originalID: "901", save: false)
        let files = CleanupFilesTransport()

        let deleted = try await TaskPhotoCleanupRunner(files: files).run(
            accountID: fixture.accountID, access: access, container: fixture.container, now: now
        ) { _ in [] }

        #expect(deleted.isEmpty)
        #expect(await files.deleteRequests.isEmpty)
        #expect(try fixture.row(key) != nil)
    }

    @Test func queueRowPostponedDuringScanIsNotDeleted() async throws {
        let fixture = try CleanupFixture()
        let key = try fixture.enqueue(fileID: "901", notBefore: now)
        let container = fixture.container
        let postponed = now.addingTimeInterval(86_400)
        let files = CleanupFilesTransport()

        let deleted = try await TaskPhotoCleanupRunner(files: files).run(
            accountID: fixture.accountID, access: access, container: container, now: now
        ) { _ in
            try await CleanupFixture.postpone(container: container, key: key, until: postponed)
            return []
        }

        #expect(deleted.isEmpty)
        #expect(await files.deleteRequests.isEmpty)
        #expect(try fixture.row(key)?.notBefore == postponed)
    }

    @Test func changedQueueRowSurvivesSuccessfulDeleteAcknowledgement() async throws {
        let fixture = try CleanupFixture()
        let key = try fixture.enqueue(fileID: "901", notBefore: now)
        let container = fixture.container
        let postponed = now.addingTimeInterval(86_400)
        let files = CleanupFilesTransport(deleteHook: { _ in
            try await CleanupFixture.postpone(container: container, key: key, until: postponed)
        })

        let deleted = try await TaskPhotoCleanupRunner(files: files).run(
            accountID: fixture.accountID, access: access, container: container, now: now
        ) { _ in [] }

        #expect(deleted == ["901"])
        #expect(await files.successfulDeletes == ["901"])
        #expect(try fixture.row(key)?.notBefore == postponed)
    }

    @Test func localReferenceCreatedDuringDeleteRetainsTheQueuedWork() async throws {
        let fixture = try CleanupFixture()
        let key = try fixture.enqueue(fileID: "901", notBefore: now)
        let container = fixture.container
        let listID = fixture.listID
        let files = CleanupFilesTransport(deleteHook: { _ in
            try await MainActor.run {
                try CleanupFixture.insertPhoto(container: container, listID: listID, originalID: "901", save: true)
            }
        })

        let deleted = try await TaskPhotoCleanupRunner(files: files).run(
            accountID: fixture.accountID, access: access, container: container, now: now
        ) { _ in [] }

        #expect(deleted == ["901"])
        #expect(await files.successfulDeletes == ["901"])
        #expect(try fixture.row(key) != nil)
    }

    @Test("Cancellation preserves queued work", arguments: ["scan", "delete"])
    func cancellationRetainsQueue(stage: String) async throws {
        let fixture = try CleanupFixture()
        let key = try fixture.enqueue(fileID: "901", notBefore: now)
        let files = CleanupFilesTransport(deleteHook: { _ in
            if stage == "delete" { throw CancellationError() }
        })

        await #expect(throws: CancellationError.self) {
            try await TaskPhotoCleanupRunner(files: files).run(
                accountID: fixture.accountID, access: access, container: fixture.container, now: now
            ) { _ in
                if stage == "scan" { throw CancellationError() }
                return []
            }
        }

        #expect(await files.successfulDeletes.isEmpty)
        #expect(try fixture.row(key) != nil)
    }

    @Test func oneRunBoundsCleanupAndLeavesTheRemainderDurable() async throws {
        let fixture = try CleanupFixture()
        for value in 1...101 { try fixture.enqueue(fileID: String(value), notBefore: now) }
        let files = CleanupFilesTransport()

        let deleted = try await TaskPhotoCleanupRunner(files: files).run(
            accountID: fixture.accountID, access: access, container: fixture.container, now: now
        ) { _ in [] }

        #expect(!deleted.isEmpty)
        #expect(deleted.count <= 100)
        #expect(await files.successfulDeletes.count == deleted.count)
        #expect(try fixture.queuedCount() == 101 - deleted.count)
    }
}

@Suite("Complete task photo reference scanning", .serialized)
struct TaskPhotoReferenceScannerTests {
    private let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")

    @Test func scansEveryVtodoOriginalAndConfirmsAnOrderIndependentManifest() async throws {
        let manifest = xml(resource("a") + resource("b"))
        let bodyA = "BEGIN:VCALENDAR\nVERSION:2.0\n" + todo("a", originalID: "901")
            + todo("a-recurrence", originalID: "902") + "END:VCALENDAR\n"
        let bodyB = calendar(todo("b", originalID: "901")
            .replacingOccurrences(of: "END:VTODO", with: "ATTACH;VALUE=URI:https://files.invalid/report.pdf\nEND:VTODO"))
        let (client, base, host) = client(responses: [
            .init(body: manifest),
            .init(body: xml(resource("b", content: bodyB) + resource("a", content: bodyA))),
            .init(body: xml(resource("b") + resource("a")))
        ])

        let references = try await TaskPhotoReferenceScanner.scan(client: client, baseURL: base,
            calendarPath: "/tasks/", credentials: credentials)

        #expect(references == ["901", "902"])
        #expect(ScriptedDAVProtocol.requests(host: host).count == 3)
    }

    @Test func emptyCalendarStillRequiresASecondCompleteManifest() async throws {
        let (client, base, host) = client(responses: [.init(body: xml("")), .init(body: xml(""))])

        let references = try await TaskPhotoReferenceScanner.scan(client: client, baseURL: base,
            calendarPath: "/tasks/", credentials: credentials)

        #expect(references.isEmpty)
        #expect(ScriptedDAVProtocol.requests(host: host).count == 2)
    }

    @Test func moreThanOneHundredResourcesUseBoundedBatches() async throws {
        let names = (0..<205).map(String.init)
        let manifest = xml(names.map { resource($0) }.joined())
        var responses: [ScriptedDAVProtocol.Response] = [.init(body: manifest)]
        for offset in stride(from: 0, to: names.count, by: 100) {
            let batch = names[offset..<min(offset + 100, names.count)]
            responses.append(.init(body: xml(batch.map { resource($0, content: calendar(todo($0, originalID: "901"))) }.joined())))
        }
        responses.append(.init(body: manifest))
        let (client, base, host) = client(responses: responses)

        let references = try await TaskPhotoReferenceScanner.scan(client: client, baseURL: base,
            calendarPath: "/tasks/", credentials: credentials)

        #expect(references == ["901"])
        #expect(batchSizes(host: host) == [100, 100, 5])
    }

    @Test func oversizedBatchesSplitRecursivelyUntilSingletons() async throws {
        let names = ["a", "b", "c", "d"]
        let manifest = xml(names.map { resource($0) }.joined())
        let oversized = ScriptedDAVProtocol.Response(body: String(repeating: "x", count: 1_501), headers: ["Content-Length": "1501"])
        let singletonBodies = names.enumerated().map { index, name in
            ScriptedDAVProtocol.Response(body: xml(resource(name, content: calendar(todo(name, originalID: String(901 + index))))))
        }
        let (client, base, host) = client(responses: [
            .init(body: manifest), oversized, oversized, singletonBodies[0], singletonBodies[1],
            oversized, singletonBodies[2], singletonBodies[3], .init(body: manifest)
        ], maxResponseBytes: 1_500)

        let references = try await TaskPhotoReferenceScanner.scan(client: client, baseURL: base,
            calendarPath: "/tasks/", credentials: credentials)

        #expect(references == ["901", "902", "903", "904"])
        #expect(batchSizes(host: host) == [4, 2, 1, 1, 2, 1, 1])
    }

    @Test func oversizedSingletonFailsTheCompleteScan() async {
        let (client, base, _) = client(responses: [
            .init(body: xml(resource("a"))),
            .init(body: String(repeating: "x", count: 1_501), headers: ["Content-Length": "1501"])
        ], maxResponseBytes: 1_500)

        await #expect(throws: DAVResponseLimitError.self) {
            try await TaskPhotoReferenceScanner.scan(client: client, baseURL: base,
                calendarPath: "/tasks/", credentials: credentials)
        }
    }

    @Test("Failed or partial responses never authorize deletion", arguments: ["403", "partial", "truncated", "batchETag"])
    func failedResponseAbortsScan(kind: String) async {
        let manifest = xml(resource("a") + resource("b"))
        let second: ScriptedDAVProtocol.Response
        switch kind {
        case "403": second = .init(status: 403, body: "Forbidden")
        case "partial": second = .init(body: xml(resource("a", content: calendar(todo("a", originalID: "901")))))
        case "truncated": second = .init(body: "<d:multistatus xmlns:d=\"DAV:\"><d:response>")
        default: second = .init(body: xml(resource("a", etag: "changed", content: calendar(todo("a", originalID: "901")))
            + resource("b", content: calendar(todo("b", originalID: nil)))))
        }
        let (client, base, _) = client(responses: [.init(body: manifest), second, .init(body: manifest)])

        await #expect(throws: (any Error).self) {
            try await TaskPhotoReferenceScanner.scan(client: client, baseURL: base,
                calendarPath: "/tasks/", credentials: credentials)
        }
    }

    @Test("Unparseable VTODOs and malformed NowThis attachments abort the scan", arguments: [
        "missingUID", "noVtodo", "unterminated", "invalidPhoto", "mixedMissingUID"
    ])
    func invalidContentAbortsScan(kind: String) async {
        let good = calendar(todo("a", originalID: "901"))
        let content: String
        switch kind {
        case "missingUID": content = good.replacingOccurrences(of: "UID:a\n", with: "")
        case "noVtodo": content = "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:a\nEND:VEVENT\nEND:VCALENDAR\n"
        case "unterminated": content = good.replacingOccurrences(of: "END:VTODO\n", with: "")
        case "invalidPhoto": content = good.replacingOccurrences(of: TaskPhotoJPEGFixture.data.base64EncodedString(), with: "not-base64")
        default: content = calendar(todo("a", originalID: "901") + "BEGIN:VTODO\nSUMMARY:Missing identity\nEND:VTODO\n")
        }
        let manifest = xml(resource("a"))
        let (client, base, _) = client(responses: [
            .init(body: manifest), .init(body: xml(resource("a", content: content))), .init(body: manifest)
        ])

        await #expect(throws: (any Error).self) {
            try await TaskPhotoReferenceScanner.scan(client: client, baseURL: base,
                calendarPath: "/tasks/", credentials: credentials)
        }
    }

    @Test("Manifest changes or a failed final check abort the scan", arguments: ["etag", "added", "removed", "403"])
    func finalManifestMustMatch(kind: String) async {
        let manifest = xml(resource("a"))
        let final: ScriptedDAVProtocol.Response
        switch kind {
        case "etag": final = .init(body: xml(resource("a", etag: "changed")))
        case "added": final = .init(body: xml(resource("a") + resource("b")))
        case "removed": final = .init(body: xml(""))
        default: final = .init(status: 403, body: "Forbidden")
        }
        let (client, base, _) = client(responses: [
            .init(body: manifest), .init(body: xml(resource("a", content: calendar(todo("a", originalID: nil))))), final
        ])

        await #expect(throws: (any Error).self) {
            try await TaskPhotoReferenceScanner.scan(client: client, baseURL: base,
                calendarPath: "/tasks/", credentials: credentials)
        }
    }

    private func todo(_ uid: String, originalID: String?) -> String {
        let attachment = originalID.map {
            "ATTACH;FMTTYPE=image/jpeg;ENCODING=BASE64;VALUE=BINARY;X-NOWTHIS-PHOTO-ID=10000000-0000-4000-8000-000000000001;X-NOWTHIS-ORIGINAL-ID=\($0):\(TaskPhotoJPEGFixture.data.base64EncodedString())\n"
        } ?? ""
        return "BEGIN:VTODO\nUID:\(uid)\nSUMMARY:Fixture\n\(attachment)END:VTODO\n"
    }

    private func calendar(_ body: String) -> String { "BEGIN:VCALENDAR\nVERSION:2.0\n\(body)END:VCALENDAR\n" }
    private func resource(_ name: String, etag: String = "revision", content: String? = nil) -> String {
        let data = content.map { "<c:calendar-data><![CDATA[\($0)]]></c:calendar-data>" } ?? ""
        return "<d:response><d:href>/tasks/\(name).ics</d:href><d:propstat><d:prop><d:getetag>\(etag)</d:getetag>\(data)</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }
    private func xml(_ body: String) -> String {
        "<d:multistatus xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\">\(body)</d:multistatus>"
    }
    private func client(responses: [ScriptedDAVProtocol.Response], maxResponseBytes: Int = DAVResponseLimit.defaultMaxBytes) -> (CalDAVClient, String, String) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let configuration = ScriptedDAVProtocol.install(host: host, responses: responses)
        return (CalDAVClient(configuration: configuration, retryPolicy: .init(maxAttempts: 1, baseDelay: 0),
            maxResponseBytes: maxResponseBytes), "https://" + host, host)
    }
    private func batchSizes(host: String) -> [Int] {
        ScriptedDAVProtocol.requests(host: host).compactMap { request in
            let body = String(decoding: request.body, as: UTF8.self)
            guard body.contains("calendar-multiget") else { return nil }
            return body.components(separatedBy: "<d:href>").count - 1
        }
    }
}

private enum CleanupTestError: Error, Equatable { case scanFailed, unexpectedFilesOperation }

private actor CleanupScanLog {
    private(set) var paths: [String] = []
    @discardableResult func append(_ path: String) -> Int { paths.append(path); return paths.count }
}

private actor CleanupFilesTransport: TaskPhotoFilesTransport {
    struct DeleteScope: Sendable, Equatable {
        let fileID: String
        let folderID: String
        let calendarHref: String
    }
    private var failures: [String: NextcloudPhotoClient.Error]
    private let deleteHook: (@Sendable (String) async throws -> Void)?
    private(set) var deleteRequests: [String] = []
    private(set) var successfulDeletes: [String] = []
    private(set) var deleteScopes: [DeleteScope] = []

    init(failures: [String: NextcloudPhotoClient.Error] = [:], deleteHook: (@Sendable (String) async throws -> Void)? = nil) {
        self.failures = failures
        self.deleteHook = deleteHook
    }
    func clearFailures() { failures.removeAll() }
    func delete(fileID: String, folderFileID: String, calendarHref: String, access: PhotoServerAccess) async throws {
        deleteScopes.append(.init(fileID: fileID, folderID: folderFileID, calendarHref: calendarHref))
        try await delete(fileID: fileID, access: access)
    }
    func delete(fileID: String, access: PhotoServerAccess) async throws {
        deleteRequests.append(fileID)
        if let error = failures[fileID] { throw error }
        try await deleteHook?(fileID)
        successfulDeletes.append(fileID)
    }
    func inspectCalendar(calendarHref: String, access: PhotoServerAccess) throws -> PhotoCalendarAccess { throw CleanupTestError.unexpectedFilesOperation }
    func prepareFolder(calendarHref: String, access: PhotoServerAccess) throws -> PhotoFolder { throw CleanupTestError.unexpectedFilesOperation }
    func resolveFolder(fileID: String, access: PhotoServerAccess) throws -> PhotoFolder { throw CleanupTestError.unexpectedFilesOperation }
    func upload(data: Data, contentType: String, photoID: String, folder: PhotoFolder, access: PhotoServerAccess) throws -> String { throw CleanupTestError.unexpectedFilesOperation }
    func download(fileID: String, access: PhotoServerAccess) throws -> Data { throw CleanupTestError.unexpectedFilesOperation }
}

@MainActor
private struct CleanupFixture {
    let container: ModelContainer
    let accountID = "cleanup-account"
    let listID = "cleanup-list"
    let path = "/remote.php/dav/calendars/alice/tasks/"

    struct Work: Equatable {
        let id: String
        let path: String
        let fileID: String?
        let folderID: String?
        let accountID: String?
        let notBefore: Date?
    }

    init() throws {
        container = try ModelContainer(for: Schema(SchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let account = ServerAccount(id: accountID, displayName: "Cloud", serverBaseURL: "https://cleanup.invalid", username: "alice")
        let list = TaskList(id: listID, serverURL: path, name: "Source", colorHex: "#007AFF")
        context.insert(account)
        context.insert(list)
        list.account = account
        try context.save()
    }

    @discardableResult
    func enqueue(fileID: String, path: String? = nil, accountID: String? = nil, listID: String? = nil,
                 folderID: String? = "900", notBefore: Date?) throws -> String {
        let account = accountID ?? self.accountID
        let key = "taskPhotoCleanup:" + account + ":" + (listID ?? self.listID) + ":" + fileID
        let row = SyncMetadata(id: key, collectionPath: path ?? self.path)
        row.syncToken = fileID
        row.photoFolderID = folderID
        row.lastCTag = account
        row.lastFullSync = notBefore
        container.mainContext.insert(row)
        try container.mainContext.save()
        return key
    }

    func row(_ key: String) throws -> Work? {
        let context = ModelContext(container)
        guard let row = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first else { return nil }
        return Work(id: row.id, path: row.collectionPath, fileID: row.syncToken, folderID: row.photoFolderID,
            accountID: row.lastCTag, notBefore: row.lastFullSync)
    }

    func queuedCount() throws -> Int {
        try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>()).filter { $0.id.hasPrefix("taskPhotoCleanup:") }.count
    }

    func addList(accountID: String) throws -> String {
        let context = container.mainContext
        let account = try context.fetch(FetchDescriptor<ServerAccount>(predicate: #Predicate { $0.id == accountID })).first
            ?? ServerAccount(id: accountID, displayName: "Destination", serverBaseURL: "https://cleanup.invalid", username: "bob")
        if account.modelContext == nil { context.insert(account) }
        let list = TaskList(serverURL: "/tasks/destination/", name: "Destination", colorHex: "#007AFF")
        context.insert(list)
        list.account = account
        try context.save()
        return list.id
    }

    func addPhoto(listID: String, originalID: String, previousID: String? = nil, previousAccountID: String? = nil,
                  operation: String? = nil, save: Bool = true) throws {
        try Self.insertPhoto(container: container, listID: listID, originalID: originalID,
            previousID: previousID, previousAccountID: previousAccountID, operation: operation, save: save)
    }

    static func insertPhoto(container: ModelContainer, listID: String, originalID: String,
                            previousID: String? = nil, previousAccountID: String? = nil,
                            operation: String? = nil, save: Bool) throws {
        let context = container.mainContext
        let list = try #require(try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first)
        let task = TaskItem(title: "Local photo operation")
        context.insert(task)
        task.taskList = list
        let photo = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        photo.originalFileID = originalID
        photo.folderFileID = "900"
        photo.previousOriginalFileID = previousID
        photo.previousOriginalAccountID = previousAccountID
        photo.previousOriginalListID = previousID == nil ? nil : "cleanup-list"
        photo.pendingOperation = operation
        context.insert(photo)
        photo.task = task
        if save { try context.save() }
    }

    static func postpone(container: ModelContainer, key: String, until date: Date) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let row = try #require(try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first)
        row.lastFullSync = date
        try context.save()
    }

    static func changeFolder(container: ModelContainer, key: String, folderID: String) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let row = try #require(try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first)
        row.photoFolderID = folderID
        try context.save()
    }
}
