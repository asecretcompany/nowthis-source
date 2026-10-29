import Foundation
import Testing
#if !SYNC_COLLECTION_PULLER_STANDALONE
@testable import NowThis
#endif

@Suite("Durable bounded collection pulls")
struct SyncCollectionPullerTests {
    private static let date = Date(timeIntervalSince1970: 1000)
    private let scope = SyncCollectionPuller.Scope(accountID: "source", listID: "list", historyScope: "all")
    private let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")

    private func calendar(supported: Bool = true, ctag: String = "c1", token: String = "discovery") -> CalDAVClient.RemoteCalendar {
        .init(href: "/tasks/", displayName: "Tasks", ctag: ctag, color: "", syncToken: token,
              supportsSyncCollection: supported, deletedAtRaw: "")
    }

    private func baseline(token: String? = "old", age: TimeInterval = 0) -> SyncCollectionPuller.Checkpoint {
        .init(scope: scope, token: token, ctag: "c1", lastIntegrity: Self.date.addingTimeInterval(-age),
              hasCompletedBaseline: true)
    }

    private func resources(_ count: Int) -> [CalDAVClient.RemoteResource] {
        (0..<count).map { .init(href: "/tasks/\($0).ics", etag: "e1") }
    }

    private func run(_ transport: PullFixtureTransport, store: PullFixtureStore,
                     calendar: CalDAVClient.RemoteCalendar? = nil,
                     checkpoint: SyncCollectionPuller.Checkpoint? = nil,
                     eligible: Bool = true, forceIntegrity: Bool = false, forceBodies: Bool = false) async throws -> SyncCollectionPuller.Checkpoint? {
        let puller = SyncCollectionPuller(transport: transport, now: { Self.date })
        return try await puller.pull(baseURL: "https://fixture.invalid", calendar: calendar ?? self.calendar(),
            credentials: credentials, scope: scope, checkpoint: checkpoint, knownETags: await store.known,
            checkpointEligible: eligible, forceIntegrity: forceIntegrity, forceBodies: forceBodies,
            callbacks: store.callbacks)
    }

    @Test("First 10,000 bodies are applied serially in batches of 100, then absence, then discovery checkpoint")
    func bootstrap10k() async throws {
        let manifest = resources(10_000)
        let transport = PullFixtureTransport(manifest: manifest)
        let store = PullFixtureStore()
        let result = try await run(transport, store: store)
        let batches = await transport.batches
        #expect(batches.count == 100)
        #expect(batches.allSatisfy { $0.count == 100 })
        #expect(await store.known.count == 10_000)
        #expect(await store.events.suffix(2) == ["manifest:10000", "checkpoint:discovery"])
        #expect(result?.token == "discovery")
        #expect(result?.hasCompletedBaseline == true)
        #expect(result?.lastIntegrity == Self.date)
        #expect(await transport.tokens.isEmpty)
    }

    @Test("No-op and one-change delta over 10,000 resources download zero or one body", arguments: [false, true])
    func delta10k(changed: Bool) async throws {
        let manifest = resources(10_000)
        let transport = PullFixtureTransport(manifest: manifest, pages: [.page(.init(
            resources: changed ? [.init(href: manifest[0].href, etag: "e2")] : [],
            deletedHrefs: [], nextToken: "next", hasMore: false))])
        let store = PullFixtureStore(known: Dictionary(uniqueKeysWithValues: manifest.map { ($0.href, $0.etag) }))
        let result = try await run(transport, store: store, checkpoint: baseline())
        #expect(await transport.manifestCalls == 0)
        #expect(await transport.batches.flatMap { $0 }.count == (changed ? 1 : 0))
        #expect(await transport.tokens == ["old"])
        #expect(await store.manifests.isEmpty)
        #expect(result?.token == "next")
    }

    @Test("Interrupted bootstrap resumes from durable href/ETags and revalidates manifest")
    func interruptedResume() async throws {
        let manifest = resources(205)
        let transport = PullFixtureTransport(manifest: manifest, failBatch: 2)
        let store = PullFixtureStore()
        await #expect(throws: PullFixtureError.failed) { try await run(transport, store: store) }
        #expect(await store.known.count == 100)
        #expect(await store.manifests.isEmpty)
        #expect(await store.checkpoints.isEmpty)
        let resumed = PullFixtureTransport(manifest: manifest)
        _ = try await run(resumed, store: store)
        #expect(await resumed.batches.map { $0.count } == [100, 5])
        #expect(await resumed.manifestCalls == 1)
        #expect(await store.known.count == 205)
    }

    @Test("A discovery token alone cannot bypass a completed local baseline")
    func incompleteBaseline() async throws {
        var checkpoint = baseline()
        checkpoint.hasCompletedBaseline = false
        let transport = PullFixtureTransport(manifest: resources(1))
        let store = PullFixtureStore()
        _ = try await run(transport, store: store, checkpoint: checkpoint)
        #expect(await transport.manifestCalls == 1)
        #expect(await transport.tokens.isEmpty)
    }

    @Test("Account, list, and history scope must all match", arguments: ["account", "list", "history"])
    func mismatchedScope(kind: String) async throws {
        var identity = scope
        switch kind {
        case "account": identity = .init(accountID: UUID().uuidString, listID: scope.listID, historyScope: "all")
        case "list": identity = .init(accountID: scope.accountID, listID: UUID().uuidString, historyScope: "all")
        default: identity.historyScope = "three-months"
        }
        let checkpoint = SyncCollectionPuller.Checkpoint(scope: identity, token: "wrong", ctag: "c1",
            lastIntegrity: Self.date, hasCompletedBaseline: true)
        let transport = PullFixtureTransport(manifest: resources(1))
        _ = try await run(transport, store: PullFixtureStore(), checkpoint: checkpoint)
        #expect(await transport.tokens.isEmpty)
        #expect(await transport.manifestCalls == 1)
    }

    @Test("Empty delta can delete the final task; durability precedes token", arguments: [false, true])
    func emptyDeltaFinalDeletion(deleted: Bool) async throws {
        let transport = PullFixtureTransport(pages: [.page(.init(resources: [],
            deletedHrefs: deleted ? ["/tasks/last.ics"] : [], nextToken: "next", hasMore: false))])
        let store = PullFixtureStore(known: ["/tasks/last.ics": "e1"])
        _ = try await run(transport, store: store, checkpoint: baseline())
        #expect(await store.events == (deleted ? ["delete:1", "checkpoint:next"] : ["checkpoint:next"]))
        #expect(await store.known.count == (deleted ? 0 : 1))
        #expect(await store.manifests.isEmpty)
    }

    @Test("507 continuation checkpoints each durable page and retains it when a later page fails")
    func continuedDeltaFailure() async throws {
        let transport = PullFixtureTransport(pages: [
            .page(.init(resources: [.init(href: "/tasks/a.ics", etag: "e2")], deletedHrefs: [], nextToken: "page1", hasMore: true)),
            .failure(.failed)
        ])
        let store = PullFixtureStore()
        await #expect(throws: PullFixtureError.failed) { try await run(transport, store: store, checkpoint: baseline()) }
        #expect(await transport.tokens == ["old", "page1"])
        #expect(await store.events == ["bodies:1", "checkpoint:page1"])
        let checkpoint = try #require(await store.checkpoints.last)
        let resumed = PullFixtureTransport(pages: [.page(.init(resources: [], deletedHrefs: [], nextToken: "final", hasMore: false))])
        _ = try await run(resumed, store: store, checkpoint: checkpoint)
        #expect(await resumed.tokens == ["page1"])
        #expect(await store.checkpoints.last?.token == "final")
    }

    @Test("All continuation pages are consumed serially")
    func continuedDeltaSuccess() async throws {
        let transport = PullFixtureTransport(pages: [
            .page(.init(resources: [], deletedHrefs: ["/tasks/a.ics"], nextToken: "page1", hasMore: true)),
            .page(.init(resources: [.init(href: "/tasks/b.ics", etag: "e2")], deletedHrefs: [], nextToken: "final", hasMore: false))
        ])
        let store = PullFixtureStore()
        _ = try await run(transport, store: store, checkpoint: baseline())
        #expect(await transport.tokens == ["old", "page1"])
        #expect(await store.events == ["delete:1", "checkpoint:page1", "bodies:1", "checkpoint:final"])
    }

    @Test("Invalid token invalidates its cursor and falls back to a complete manifest")
    func invalidToken() async throws {
        let transport = PullFixtureTransport(manifest: resources(1), pages: [.failure(.invalidToken)])
        let store = PullFixtureStore()
        _ = try await run(transport, store: store, checkpoint: baseline())
        #expect(await transport.manifestCalls == 1)
        #expect(await store.events == ["checkpoint:nil", "bodies:1", "manifest:1", "checkpoint:discovery"])
    }

    @Test("Permission, auth, top-level 507, and network failures preserve cursor and never fall back", arguments: ["permission", "auth", "507", "network"])
    func rejectedDelta(kind: String) async {
        let failure: PullFixtureError = kind == "permission" ? .permission : kind == "auth" ? .auth : kind == "507" ? .limit507 : .failed
        let transport = PullFixtureTransport(pages: [.failure(failure)])
        let store = PullFixtureStore()
        await #expect(throws: (any Error).self) { try await run(transport, store: store, checkpoint: baseline()) }
        #expect(await transport.manifestCalls == 0)
        #expect(await store.events.isEmpty)
    }

    @Test("Unsupported capability clears token and uses CTag until the 600 second integrity interval", arguments: [0.0, 599.0, 600.0])
    func ctagFallback(age: TimeInterval) async throws {
        let transport = PullFixtureTransport(manifest: resources(1))
        let store = PullFixtureStore(known: ["/tasks/0.ics": "e1"])
        let result = try await run(transport, store: store, calendar: calendar(supported: false), checkpoint: baseline(age: age))
        #expect(await transport.manifestCalls == (age >= 600 ? 1 : 0))
        #expect(await transport.batches.isEmpty)
        #expect(await transport.tokens.isEmpty)
        #expect(result?.token == nil)
    }

    @Test("Periodic token integrity, changed CTag, and forced integrity fetch manifests without unchanged bodies", arguments: ["periodic", "ctag", "force"])
    func manifestIntegrity(kind: String) async throws {
        let transport = PullFixtureTransport(manifest: resources(10_000))
        let store = PullFixtureStore(known: Dictionary(uniqueKeysWithValues: resources(10_000).map { ($0.href, $0.etag) }))
        _ = try await run(transport, store: store,
            calendar: calendar(supported: kind != "ctag", ctag: kind == "ctag" ? "c2" : "c1"),
            checkpoint: baseline(age: kind == "periodic" ? 600 : 0), forceIntegrity: kind == "force")
        #expect(await transport.manifestCalls == 1)
        #expect(await transport.batches.isEmpty)
        #expect(await store.manifests.first?.count == 10_000)
    }

    @Test("Category catch-up forces complete bodies even for unchanged ETags")
    func forceBodies() async throws {
        let transport = PullFixtureTransport(manifest: resources(101))
        let store = PullFixtureStore(known: Dictionary(uniqueKeysWithValues: resources(101).map { ($0.href, $0.etag) }))
        _ = try await run(transport, store: store, checkpoint: baseline(), forceBodies: true)
        #expect(await transport.manifestCalls == 1)
        #expect(await transport.batches.map { $0.count } == [100, 1])
    }

    @Test("History ineligible pulls use manifests and never read or write a checkpoint")
    func ineligibleHistory() async throws {
        let transport = PullFixtureTransport(manifest: resources(1))
        let store = PullFixtureStore()
        let result = try await run(transport, store: store, checkpoint: baseline(), eligible: false)
        #expect(await transport.manifestCalls == 1)
        #expect(await transport.tokens.isEmpty)
        #expect(await store.checkpoints.isEmpty)
        #expect(result == nil)
    }

    @Test("ETag changing between manifest and body prevents absence and checkpoint")
    func etagRace() async {
        let transport = PullFixtureTransport(manifest: resources(1), wrongETag: true)
        let store = PullFixtureStore()
        await #expect(throws: SyncCollectionPuller.PullError.etagChanged(href: "/tasks/0.ics")) {
            try await run(transport, store: store)
        }
        #expect(await store.events.isEmpty)
    }

    @Test("Missing, duplicate, and unexpected batch members cannot reconcile absence", arguments: ["omit", "duplicate", "extra"])
    func incompleteBatch(kind: String) async {
        let transport = PullFixtureTransport(manifest: resources(2), badBatch: kind)
        let store = PullFixtureStore()
        await #expect(throws: SyncCollectionPuller.PullError.incompleteBatch) { try await run(transport, store: store) }
        #expect(await store.events.isEmpty)
    }

    @Test("Durable callback failure never advances cursor", arguments: ["bodies", "delete", "manifest", "checkpoint"])
    func callbackFailure(kind: String) async {
        let transport = PullFixtureTransport(manifest: resources(1), pages: [.page(.init(
            resources: [.init(href: "/tasks/a.ics", etag: "e2")], deletedHrefs: ["/tasks/b.ics"], nextToken: "next", hasMore: false))])
        let store = PullFixtureStore(failOn: kind)
        await #expect(throws: PullFixtureError.failed) {
            try await run(transport, store: store, checkpoint: kind == "manifest" ? nil : baseline())
        }
        #expect(await store.checkpoints.isEmpty)
        if kind == "bodies" { #expect(await store.events.isEmpty) }
        if kind == "delete" { #expect(await store.events == ["bodies:1"]) }
        if kind == "manifest" { #expect(await store.events == ["bodies:1"]) }
    }

    @Test("Cancellation after first durable batch never reconciles or checkpoints")
    func cancelledBootstrap() async throws {
        let gate = PullFixtureGate()
        let transport = PullFixtureTransport(manifest: resources(201), gate: gate)
        let store = PullFixtureStore()
        let operation = Task { try await run(transport, store: store) }
        await gate.waitUntilEntered()
        operation.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await store.known.count == 100)
        #expect(await store.manifests.isEmpty)
        #expect(await store.checkpoints.isEmpty)
    }

    @Test("Only response limits and supported 507 batch limits split adaptively", arguments: ["bytes", "507", "retry507"])
    func splitLimits(kind: String) async throws {
        let transport = PullFixtureTransport(manifest: resources(5), batchLimit: 2, limitKind: kind)
        let store = PullFixtureStore()
        _ = try await run(transport, store: store)
        #expect(await transport.batches.map { $0.count } == [5, 2, 3, 1, 2])
        #expect(await store.events == ["bodies:2", "bodies:1", "bodies:2", "manifest:5", "checkpoint:discovery"])
    }

    @Test("A single oversized resource fails partial and cannot finish the scan")
    func singleOversize() async {
        let transport = PullFixtureTransport(manifest: resources(3), batchLimit: 0)
        let store = PullFixtureStore()
        await #expect(throws: (any Error).self) { try await run(transport, store: store) }
        #expect(await transport.batches.map { $0.count } == [3, 1])
        #expect(await store.events.isEmpty)
    }

    @Test("Permission errors in a body batch never trigger splitting")
    func permissionBatch() async {
        let transport = PullFixtureTransport(manifest: resources(5), batchPermissionDenied: true)
        let store = PullFixtureStore()
        await #expect(throws: (any Error).self) { try await run(transport, store: store) }
        #expect(await transport.batches.map { $0.count } == [5])
        #expect(await store.events.isEmpty)
    }
    @Test("A baseline commits its pre-manifest discovery token so later deltas replay concurrent changes")
    func discoveryTokenReplay() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        func resource(_ etag: String, body: Bool = false) -> String {
            "<d:response><d:href>/tasks/a.ics</d:href><d:propstat><d:prop><d:getetag>\(etag)</d:getetag>"
                + (body ? "<c:calendar-data>BEGIN:VCALENDAR</c:calendar-data>" : "")
                + "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
        }
        func xml(_ responses: String, token: String = "") -> String {
            "<d:multistatus xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\">\(responses)"
                + (token.isEmpty ? "" : "<d:sync-token>\(token)</d:sync-token>") + "</d:multistatus>"
        }
        let client = CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host, responses: [
            .init(body: xml(resource("e1"))), .init(body: xml(resource("e1", body: true))),
            .init(body: xml(resource("e2"), token: "concurrent")), .init(body: xml(resource("e2", body: true)))
        ]), retryPolicy: .init(maxAttempts: 1, baseDelay: 0))
        let puller = SyncCollectionPuller(client: client, now: { Self.date })
        let store = PullFixtureStore()
        let checkpoint = try await puller.pull(baseURL: "https://" + host, calendar: calendar(token: "before-scan"),
            credentials: credentials, scope: scope, checkpoint: nil, knownETags: [:], callbacks: store.callbacks)
        #expect(checkpoint?.token == "before-scan")
        let result = try await puller.pull(baseURL: "https://" + host, calendar: calendar(token: "after-scan"),
            credentials: credentials, scope: scope, checkpoint: checkpoint, knownETags: await store.known, callbacks: store.callbacks)
        #expect(result?.token == "concurrent")
        #expect(await store.known["/tasks/a.ics"] == "e2")
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.count == 4)
        let deltaBody = String(decoding: try #require(requests.dropFirst(2).first).body, as: UTF8.self)
        #expect(deltaBody.contains("<d:sync-token>before-scan</d:sync-token>"))
        #expect(await store.events == ["bodies:1", "manifest:1", "checkpoint:before-scan", "bodies:1", "checkpoint:concurrent"])
    }

    @Test("An oversized final resource preserves earlier durable split batches but not the delta token")
    func partialOversizeDelta() async {
        let page = CalDAVClient.SyncDeltaPage(resources: resources(5), deletedHrefs: ["/tasks/old.ics"],
            nextToken: "unfinished", hasMore: false)
        let transport = PullFixtureTransport(pages: [.page(page)], batchLimit: 2, oversizedHref: "/tasks/4.ics")
        let store = PullFixtureStore()
        await #expect(throws: DAVResponseLimitError.self) { try await run(transport, store: store, checkpoint: baseline()) }
        #expect(await store.known.count == 4)
        #expect(await store.events == ["bodies:2", "bodies:1", "bodies:1"])
        #expect(await store.checkpoints.isEmpty)
        #expect(await store.manifests.isEmpty)
    }

    @Test("Concurrent calls cannot overlap network or durable callbacks")
    func concurrentCalls() async throws {
        let gate = PullFixtureGate()
        let transport = PullFixtureTransport(manifest: resources(101), gate: gate)
        let puller = SyncCollectionPuller(transport: transport, now: { Self.date })
        let store = PullFixtureStore()
        let operation = Task {
            try await puller.pull(baseURL: "https://fixture.invalid", calendar: calendar(), credentials: credentials,
                scope: scope, checkpoint: nil, knownETags: [:], callbacks: store.callbacks)
        }
        await gate.waitUntilEntered()
        await #expect(throws: SyncCollectionPuller.PullError.alreadyRunning) {
            try await puller.pull(baseURL: "https://fixture.invalid", calendar: calendar(), credentials: credentials,
                scope: scope, checkpoint: nil, knownETags: [:], callbacks: store.callbacks)
        }
        await gate.release()
        _ = try await operation.value
        #expect(await transport.manifestCalls == 1)
        #expect(await store.events == ["bodies:100", "bodies:1", "manifest:101", "checkpoint:discovery"])
    }

    @Test("Stalled, cyclic, or tokenless continuation pages cannot advance their cursor", arguments: ["stalled", "cyclic", "missing"])
    func invalidContinuation(kind: String) async {
        var pages: [PullFixtureTransport.Page] = []
        if kind == "cyclic" {
            pages.append(.page(.init(resources: [], deletedHrefs: [], nextToken: "first", hasMore: true)))
        }
        pages.append(.page(.init(resources: [], deletedHrefs: [], nextToken: kind == "missing" ? "" : "old", hasMore: true)))
        let transport = PullFixtureTransport(pages: pages)
        let store = PullFixtureStore()
        await #expect(throws: SyncCollectionPuller.PullError.invalidContinuation) {
            try await run(transport, store: store, checkpoint: baseline())
        }
        #expect(await store.events == (kind == "cyclic" ? ["checkpoint:first"] : []))
        #expect(await transport.manifestCalls == 0)
    }

    @Test("A failed manifest never looks like an empty complete manifest", arguments: ["permission", "failure", "limit"])
    func failedManifest(kind: String) async {
        let transport = PullFixtureTransport(manifestFailure: kind)
        let store = PullFixtureStore()
        await #expect(throws: (any Error).self) { try await run(transport, store: store) }
        #expect(await store.events.isEmpty)
        #expect(await transport.batches.isEmpty)
    }

    @Test("Delta body ETag races do not apply tombstones or commit the page")
    func deltaETagRace() async {
        let transport = PullFixtureTransport(pages: [.page(.init(resources: resources(1),
            deletedHrefs: ["/tasks/old.ics"], nextToken: "unfinished", hasMore: false))], wrongETag: true)
        let store = PullFixtureStore()
        await #expect(throws: SyncCollectionPuller.PullError.etagChanged(href: "/tasks/0.ics")) {
            try await run(transport, store: store, checkpoint: baseline())
        }
        #expect(await store.events.isEmpty)
    }

}

private enum PullFixtureError: Error {
    case failed, invalidToken, permission, auth, limit507
}

private actor PullFixtureTransport: SyncCollectionPullTransport {
    enum Page {
        case page(CalDAVClient.SyncDeltaPage)
        case failure(PullFixtureError)
    }
    var manifest: [CalDAVClient.RemoteResource]
    var pages: [Page]
    var bodyETags: [String: String]
    var manifestCalls = 0
    var batches: [[String]] = []
    var tokens: [String] = []
    let failBatch: Int?
    let wrongETag: Bool
    let badBatch: String?
    let gate: PullFixtureGate?
    let batchLimit: Int?
    let limitKind: String
    let batchPermissionDenied: Bool
    let oversizedHref: String?
    let manifestFailure: String?

    init(manifest: [CalDAVClient.RemoteResource] = [], pages: [Page] = [], failBatch: Int? = nil,
         wrongETag: Bool = false, badBatch: String? = nil, gate: PullFixtureGate? = nil,
         batchLimit: Int? = nil, limitKind: String = "bytes", batchPermissionDenied: Bool = false,
         oversizedHref: String? = nil, manifestFailure: String? = nil) {
        self.manifest = manifest
        self.bodyETags = Dictionary(uniqueKeysWithValues: manifest.map { ($0.href, $0.etag) })
        self.pages = pages
        self.failBatch = failBatch
        self.wrongETag = wrongETag
        self.badBatch = badBatch
        self.gate = gate
        self.batchLimit = batchLimit
        self.limitKind = limitKind
        self.batchPermissionDenied = batchPermissionDenied
        self.oversizedHref = oversizedHref
        self.manifestFailure = manifestFailure
    }

    func fetchTaskManifest(baseURL: String, calendarPath: String,
                           credentials: CalDAVClient.Credentials) async throws -> [CalDAVClient.RemoteResource] {
        manifestCalls += 1
        if let manifestFailure {
            if manifestFailure == "permission" { throw CalDAVError.forbidden }
            if manifestFailure == "limit" { throw DAVResponseLimitError() }
            throw PullFixtureError.failed
        }
        return manifest
    }

    func fetchTaskBatch(baseURL: String, calendarPath: String, hrefs: [String],
                        credentials: CalDAVClient.Credentials) async throws -> [CalDAVClient.RemoteTask] {
        batches.append(hrefs)
        if let gate, batches.count == 2 { await gate.enterAndWait() }
        if batches.count == failBatch { throw PullFixtureError.failed }
        if batchPermissionDenied { throw CalDAVError.forbidden }
        if let oversizedHref, hrefs.contains(oversizedHref) { throw DAVResponseLimitError() }
        if let batchLimit, hrefs.count > batchLimit {
            if limitKind == "507" { throw CalDAVError.serverError(statusCode: 507) }
            if limitKind == "retry507" { throw HTTPRetryError(statusCode: 507, retryAfter: nil) }
            throw DAVResponseLimitError()
        }
        var bodies = hrefs.map { href in
            let etag = bodyETags[href] ?? "e2"
            return CalDAVClient.RemoteTask(href: href, etag: wrongETag ? "raced" : etag,
                icsData: "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:\(href)\r\nEND:VTODO\r\nEND:VCALENDAR")
        }
        if badBatch == "omit" { bodies.removeLast() }
        if badBatch == "duplicate", let first = bodies.first { bodies.append(first) }
        if badBatch == "extra" { bodies.append(.init(href: "/tasks/extra.ics", etag: "e1", icsData: "ics")) }
        return bodies
    }

    func fetchSyncDelta(baseURL: String, calendarPath: String, syncToken: String,
                        credentials: CalDAVClient.Credentials) async throws -> CalDAVClient.SyncDeltaPage {
        tokens.append(syncToken)
        guard !pages.isEmpty else { throw PullFixtureError.failed }
        switch pages.removeFirst() {
        case .page(let page):
            for resource in page.resources { bodyETags[resource.href] = resource.etag }
            for href in page.deletedHrefs { bodyETags.removeValue(forKey: href) }
            return page
        case .failure(let error):
            switch error {
            case .invalidToken: throw CalDAVSyncError.invalidSyncToken
            case .permission: throw CalDAVError.forbidden
            case .auth: throw CalDAVError.unauthorized
            case .limit507: throw CalDAVError.serverError(statusCode: 507)
            default: throw error
            }
        }
    }
}

private actor PullFixtureStore {
    var known: [String: String]
    var events: [String] = []
    var manifests: [[CalDAVClient.RemoteResource]] = []
    var checkpoints: [SyncCollectionPuller.Checkpoint] = []
    let failOn: String?

    init(known: [String: String] = [:], failOn: String? = nil) {
        self.known = known
        self.failOn = failOn
    }

    nonisolated var callbacks: SyncCollectionPuller.Callbacks {
        .init(applyBodies: { try await self.apply($0) }, deleteExplicit: { try await self.delete($0) },
              reconcileCompleteManifest: { try await self.reconcile($0) }, commitCheckpoint: { try await self.commit($0) })
    }

    func apply(_ bodies: [CalDAVClient.RemoteTask]) throws {
        if failOn == "bodies" { throw PullFixtureError.failed }
        for body in bodies { known[body.href] = body.etag }
        events.append("bodies:\(bodies.count)")
    }

    func delete(_ hrefs: [String]) throws {
        if failOn == "delete" { throw PullFixtureError.failed }
        for href in hrefs { known.removeValue(forKey: href) }
        events.append("delete:\(hrefs.count)")
    }

    func reconcile(_ manifest: [CalDAVClient.RemoteResource]) throws {
        if failOn == "manifest" { throw PullFixtureError.failed }
        manifests.append(manifest)
        events.append("manifest:\(manifest.count)")
    }

    func commit(_ checkpoint: SyncCollectionPuller.Checkpoint) throws {
        if failOn == "checkpoint" { throw PullFixtureError.failed }
        checkpoints.append(checkpoint)
        events.append("checkpoint:\(checkpoint.token ?? "nil")")
    }
}

private actor PullFixtureGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiters.append($0) } }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
