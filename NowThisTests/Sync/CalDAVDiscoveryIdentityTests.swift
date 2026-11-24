import Foundation
import Testing
import SwiftData
@testable import NowThis

@Suite(.serialized) struct CalDAVDiscoveryIdentityTests {
    @Test func equivalentAbsoluteAndRootRelativeKeepStorageIdentity() throws {
        let url = try #require(URL(string: "https://example.test/remote.php/dav/calendars/u/tasks/"))
        let address = DAVDiscoveryAddress(rawHref: url.absoluteString, requestURL: url)
        let matched = try CalDAVDiscovery.matchExistingList(discovered: address, existing: [
            (storageHref: "/remote.php/dav/calendars/u/tasks/", requestURL: url)
        ])
        #expect(matched == "/remote.php/dav/calendars/u/tasks/")
    }

    @Test func ambiguousAliasesAreRejected() throws {
        let url = try #require(URL(string: "https://example.test/calendars/tasks/"))
        let address = DAVDiscoveryAddress(rawHref: url.absoluteString, requestURL: url)
        #expect(throws: (any Error).self) {
            try CalDAVDiscovery.matchExistingList(discovered: address, existing: [
                (storageHref: "/calendars/tasks/", requestURL: url),
                (storageHref: url.absoluteString, requestURL: url)
            ])
        }
    }

    @Test func defaultPortAndHostCaseKeepStorageIdentity() throws {
        let discovered = try #require(URL(string: "https://example.com:443/calendars/A%2FB/"))
        let stored = try #require(URL(string: "https://EXAMPLE.com/calendars/A%2FB/"))
        let match = try CalDAVDiscovery.matchExistingList(
            discovered: .init(rawHref: discovered.absoluteString, requestURL: discovered),
            existing: [(storageHref: "/calendars/A%2FB/", requestURL: stored)])
        #expect(match == "/calendars/A%2FB/")
    }

    @Test func equivalentAuthoritiesAreAmbiguousAcrossExistingRows() throws {
        let discovered = try #require(URL(string: "https://example.com:443/calendars/A%2FB/"))
        let first = try #require(URL(string: "https://EXAMPLE.com/calendars/A%2FB/"))
        let second = try #require(URL(string: "https://example.com:443/calendars/A%2FB/"))
        #expect(throws: (any Error).self) {
            try CalDAVDiscovery.matchExistingList(
                discovered: .init(rawHref: discovered.absoluteString, requestURL: discovered),
                existing: [(storageHref: "/calendars/A%2FB/", requestURL: first),
                           (storageHref: second.absoluteString, requestURL: second)])
        }
    }

    @Test func escapedSlashAndPathCaseRemainDistinct() throws {
        let url = try #require(URL(string: "https://example.test/calendars/A%2FB/"))
        let address = DAVDiscoveryAddress(rawHref: url.absoluteString, requestURL: url)
        let other = try #require(URL(string: "https://example.test/calendars/a/b/"))
        #expect(try CalDAVDiscovery.matchExistingList(discovered: address, existing: [(storageHref: other.absoluteString, requestURL: other)]) == nil)
    }
    @Test("Ambiguous aliases fail before reconciliation", arguments: [false, true])
    @MainActor func ambiguousAliasesNeverReconcileAbsence(background: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let host = "identity-" + UUID().uuidString.lowercased() + ".invalid"
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let account = try #require(container.mainContext.fetch(FetchDescriptor<ServerAccount>()).first)
        let first = TaskList(id: "first", serverURL: "/one/", name: "First", colorHex: "#007AFF")
        let second = TaskList(id: "second", serverURL: "https://" + host + "/one/", name: "Second", colorHex: "#007AFF")
        first.account = account; second.account = account
        container.mainContext.insert(first); container.mainContext.insert(second); try container.mainContext.save()
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"])),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        do {
            if background {
                try await engine.performBackgroundSync(accountID: accountID, serverBaseURL: "https://" + host,
                    credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
            } else {
                try await engine.performFullSync(accountID: accountID, serverBaseURL: "https://" + host,
                    credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
            }
            Issue.record("Ambiguous identity must fail")
        } catch {}
        let lists = try ModelContext(container).fetch(FetchDescriptor<TaskList>())
        #expect(Set(lists.map(\.id)) == ["first", "second"])
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { ["PUT", "MKCALENDAR", "DELETE", "REPORT"].contains($0.method) })
    }

    @Test("Failed discovery leaves local lists intact", arguments: [false, true])
    @MainActor func failedDiscoveryNeverDeletesLists(background: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let host = "failure-" + UUID().uuidString.lowercased() + ".invalid"
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let account = try #require(container.mainContext.fetch(FetchDescriptor<ServerAccount>()).first)
        let list = TaskList(id: "kept", serverURL: "/one/", name: "Local", colorHex: "#007AFF")
        list.account = account; container.mainContext.insert(list); try container.mainContext.save()
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: [.init(status: 503, body: "unavailable")]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        do {
            if background {
                try await engine.performBackgroundSync(accountID: accountID, serverBaseURL: "https://" + host,
                    credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
            } else {
                try await engine.performFullSync(accountID: accountID, serverBaseURL: "https://" + host,
                    credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
            }
            Issue.record("Discovery must fail")
        } catch {}
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskList>()).map(\.id) == ["kept"])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<SyncMetadata>()) == 0)
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { ["PUT", "MKCALENDAR", "DELETE"].contains($0.method) })
    }
    @Test("Equivalent discovery keeps list, task, receipt and pending move identities")
    @MainActor func absoluteAndRootRelativeCollectionKeepExistingIdentity() async throws {
        let container = try DAVSyncScenario.container()
        let host = "equivalence-" + UUID().uuidString.lowercased() + ".invalid"
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let base = "https://" + host
        let context = container.mainContext
        let account = try #require(context.fetch(FetchDescriptor<ServerAccount>()).first)
        let list = TaskList(id: "stable-list", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        list.account = account; list.syncCTag = "c1"; list.lastFullPullDate = Date()
        context.insert(list)
        SyncEngine.markCategoriesCaughtUp(listID: list.id)
        let source = TaskList(id: "source", serverURL: "/source/", name: "Source", colorHex: "#007AFF")
        source.account = account; context.insert(source)
        let task = TaskItem(id: "stable-task", uid: "local", title: "Unsynced edit")
        task.taskList = list; task.isDirty = true; task.isLocalOnly = false
        task.remoteHref = "/one/local.ics"; task.etag = "e1"
        task.pendingMoveFromHref = "/source/local.ics"; task.pendingMoveFromListID = "source"
        context.insert(task); try context.save()
        let checkpointID = SyncImportCheckpoint.identity(accountID: accountID, listID: list.id, baseURL: base, username: "fixture", months: 0)
        let scope = SyncCollectionPuller.Scope(accountID: accountID, listID: list.id, historyScope: "0")
        try SyncImportCheckpoint.commit(.init(scope: scope, token: nil, ctag: "c1", lastIntegrity: Date(), hasCompletedBaseline: true), id: checkpointID, collectionPath: "/one/", container: container)
        let receipt = CalDAVClient.RemoteTask(href: "/one/local.ics", etag: "e1", icsData: "")
        try SyncImportCheckpoint.markAccounted([receipt], id: checkpointID, container: container)
        let discovery = DAVSyncScenario.discovery(paths: [base + "/one/"])
        // The failed write deliberately leaves the edit and pending move for a later retry.
        let config = ScriptedDAVProtocol.install(host: host, responses: discovery + [.init(status: 503, body: "unavailable")])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: base,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container, reconcileNotifications: false)
        let bgConfig = ScriptedDAVProtocol.install(host: host, responses: discovery + [.init(body: DAVSyncScenario.manifest(count: 0))])
        let bgEngine = SyncEngine(calDAVClient: CalDAVClient(configuration: bgConfig, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await bgEngine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: base,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container, reconcileNotifications: false)
        let read = ModelContext(container)
        let lists = try read.fetch(FetchDescriptor<TaskList>())
        #expect(lists.count == 2)
        let retained = try #require(lists.first { $0.id == "stable-list" })
        #expect(retained.serverURL == "/one/")
        let saved = try #require(read.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(saved.id == "stable-task"); #expect(saved.title == "Unsynced edit"); #expect(saved.isDirty)
        #expect(saved.pendingMoveFromHref == "/source/local.ics"); #expect(saved.pendingMoveFromListID == "source")
        #expect(try SyncImportCheckpoint.accountedETags(id: checkpointID, container: container)[receipt.href] == "e1")
        let retainedCheckpoint = try #require(try SyncImportCheckpoint.read(id: checkpointID, scope: scope, in: read))
        #expect(retainedCheckpoint.hasCompletedBaseline)
        #expect(retainedCheckpoint.token == nil)
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "REPORT" }.allSatisfy { $0.path == "/one" })
    }
    @Test("Background replay retains identity, receipt and cursor")
    @MainActor func successfulReceiptReplay() async throws {
        let container = try DAVSyncScenario.container()
        let host = "replay-" + UUID().uuidString.lowercased() + ".invalid"
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let base = "https://" + host
        let context = container.mainContext
        let account = try #require(context.fetch(FetchDescriptor<ServerAccount>()).first)
        let list = TaskList(id: "stable-list", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        list.account = account; context.insert(list)
        let task = TaskItem(id: "stable-task", uid: "local", title: "Local")
        task.taskList = list; task.remoteHref = "/one/local.ics"; task.etag = "e1"; task.isLocalOnly = false
        context.insert(task); try SyncResourceFixture.prove(task, in: context); try context.save()
        let key = SyncImportCheckpoint.identity(accountID: accountID, listID: list.id, baseURL: base, username: "fixture", months: 0)
        let scope = SyncCollectionPuller.Scope(accountID: accountID, listID: list.id, historyScope: "0")
        let receipt = CalDAVClient.RemoteTask(href: "/one/local.ics", etag: "e1", icsData: "")
        try SyncImportCheckpoint.markAccounted([receipt], id: key, container: container)
        let manifest = DAVSyncScenario.multistatus(DAVSyncScenario.prop(receipt.href, "<d:getetag>e1</d:getetag>"))
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host,
            responses: DAVSyncScenario.discovery(paths: [base + "/one/"]) + [.init(body: manifest)]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let outcome = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: base,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container, reconcileNotifications: false)
        #expect(outcome.status == .completed)
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<TaskList>()).map(\.serverURL) == ["/one/"])
        #expect(try read.fetch(FetchDescriptor<TaskItem>()).map(\.id) == ["stable-task"])
        #expect(try SyncImportCheckpoint.accountedETags(id: key, container: container) == [receipt.href: "e1"])
        #expect(try BackgroundSyncCursor.load(scope: "lists:" + accountID, in: read) == "/one/")
        #expect(try SyncImportCheckpoint.read(id: key, scope: scope, in: read) != nil)
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "REPORT" }.map(\.path) == ["/one"])
    }

    @Test("An empty home leaves background drafts intact")
    @MainActor func emptyHomeDoesNotEraseLocalDrafts() async throws {
        let container = try DAVSyncScenario.container()
        let host = "empty-home-" + UUID().uuidString.lowercased() + ".invalid"
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let account = try #require(container.mainContext.fetch(FetchDescriptor<ServerAccount>()).first)
        let list = TaskList(id: "draft", serverURL: "", name: "Draft", colorHex: "#007AFF")
        list.account = account; container.mainContext.insert(list)
        let task = TaskItem(id: "draft-task", title: "Keep this")
        task.taskList = list; container.mainContext.insert(task); try container.mainContext.save()
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host,
            responses: DAVSyncScenario.discovery(paths: [])), retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let outcome = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container, reconcileNotifications: false)
        #expect(outcome.status == .completed)
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<TaskList>()).map(\.id) == ["draft"])
        #expect(try read.fetch(FetchDescriptor<TaskItem>()).map(\.id) == ["draft-task"])
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { ["PUT", "MKCALENDAR", "DELETE"].contains($0.method) })
    }

    @Test("Read-only discovery does not write to the collection")
    @MainActor func readOnlyListNeverGetsProbeWrites() async throws {
        let container = try DAVSyncScenario.container()
        let host = "readonly-" + UUID().uuidString.lowercased() + ".invalid"
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        var discovery = DAVSyncScenario.discovery(paths: ["/one/"])
        discovery[discovery.count - 1].body = discovery.last!.body.replacingOccurrences(of: "<d:displayname>Fixture</d:displayname>", with: "<d:displayname>Fixture</d:displayname><d:current-user-privilege-set><d:privilege><d:read/></d:privilege></d:current-user-privilege-set>")
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host,
            responses: discovery + [.init(body: DAVSyncScenario.manifest(count: 0))]), retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let outcome = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container, reconcileNotifications: false)
        #expect(outcome.status == .completed)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskList>()).first?.isReadOnly == true)
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { ["PUT", "MKCALENDAR", "DELETE"].contains($0.method) })
    }
    @Test("Repeated absolute discovery after reopening the store keeps one list")
    @MainActor func reopeningStoreDoesNotDuplicateList() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("identity.store"))
        let host = "reopen-" + UUID().uuidString.lowercased() + ".invalid"
        let base = "https://" + host
        func openStore() throws -> ModelContainer {
            try ModelContainer(for: Schema(SchemaV2.models), configurations: configuration)
        }
        func run(_ container: ModelContainer, accountID: String) async -> SyncOutcome {
            let responses = DAVSyncScenario.discovery(paths: [base + "/one/"]) + [.init(body: DAVSyncScenario.manifest(count: 0))]
            let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host, responses: responses),
                retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
            return await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: base,
                credentials: .init(username: "fixture", password: "fixture"), modelContainer: container, reconcileNotifications: false)
        }
        let accountID: String
        do {
            let store = try openStore()
            let account = ServerAccount(displayName: "Fixture", serverBaseURL: base, username: "fixture")
            let list = TaskList(id: "stable", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
            store.mainContext.insert(account); store.mainContext.insert(list); list.account = account
            accountID = account.id; try store.mainContext.save()
            #expect(await run(store, accountID: accountID).status == .completed)
        }
        let reopened = try openStore()
        #expect(await run(reopened, accountID: accountID).status == .completed)
        let lists = try ModelContext(reopened).fetch(FetchDescriptor<TaskList>())
        #expect(lists.count == 1); #expect(lists.first?.id == "stable"); #expect(lists.first?.serverURL == "/one/")
    }
    @Test("Move cleanup still targets the stored source after absolute discovery")
    @MainActor func successfulMoveCleanupUsesOriginalSource() async throws {
        let container = try DAVSyncScenario.container()
        let host = "move-identity-" + UUID().uuidString.lowercased() + ".invalid"
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let context = container.mainContext
        let account = try #require(context.fetch(FetchDescriptor<ServerAccount>()).first)
        let source = TaskList(id: "source", serverURL: "/source/", name: "Fixture", colorHex: "#007AFF")
        let destination = TaskList(id: "destination", serverURL: "/destination/", name: "Fixture", colorHex: "#007AFF")
        for list in [source, destination] {
            list.account = account; list.syncCTag = "c1"; list.lastFullPullDate = Date()
            context.insert(list); SyncEngine.markCategoriesCaughtUp(listID: list.id)
        }
        let task = TaskItem(id: "moved", uid: "moved", title: "Moved")
        task.taskList = destination; task.remoteHref = "/destination/moved.ics"; task.etag = "dest-etag"
        task.isLocalOnly = false; task.isDirty = false
        task.pendingMoveFromHref = "/source/moved.ics"; task.pendingMoveFromListID = source.id
        context.insert(task); try VTODOOpaqueState.empty.store(taskID: task.id, in: context)
        task.attachmentStateKnown = true
        try SyncResourceFixture.prove(task, in: context)
        try SyncResourceFixture.proveSource(task, in: context)
        try context.save()
        for list in [source, destination] {
            try DAVSyncScenario.seedRecentCheckpoint(for: list, in: container)
        }
        let base = "https://" + host
        let discovery = DAVSyncScenario.discovery(paths: [base + "/source/", base + "/destination/"])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host,
            responses: discovery + [.init(status: 204, body: "")]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let outcome = await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: base,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container, reconcileNotifications: false)
        #expect(outcome.status == .completed)
        let read = ModelContext(container)
        let saved = try #require(read.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(saved.id == "moved"); #expect(saved.pendingMoveFromHref == nil); #expect(saved.pendingMoveFromListID == nil)
        #expect(Set(try read.fetch(FetchDescriptor<TaskList>()).map(\.serverURL)) == ["/source/", "/destination/"])
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "DELETE" }.map(\.path) == ["/source/moved.ics"])
    }
}

@MainActor
extension CalDAVDiscoveryIdentityTests {
    private var bangPath: String {
        "/nowthis-787ead74dff1728e3b0773cbdb93a956b9fc9c41254a4e5b9941e3f06766894f/"
    }

    @Test("New list identities survive creation and rediscovery beside an unrelated name slug")
    func newListPathsAndAssociationsAreDistinct() async throws {
        let host = "create-identity-" + UUID().uuidString.lowercased() + ".invalid"
        let base = "https://" + host
        let container = try DAVSyncScenario.container()
        let account = try makeCreationAccount(base: base, container: container)
        let lists = [
            ("create-bang", "A!", bangPath),
            ("create-query", "A?", "/nowthis-96d94e55f3075c8085869286f90d55320319abdbd05cf46f3cd51d9afee80664/"),
            ("create-symbol", "📌", "/nowthis-0be76e30b7be76be4fcb80c94491abc603cba4bec21691b5055d59292a4665fe/")
        ]
        for (id, name, _) in lists {
            let list = TaskList(id: id, serverURL: "", name: name, colorHex: "#007AFF")
            list.account = account
            let task = TaskItem(id: id + "-task", title: name)
            task.taskList = list
            container.mainContext.insert(list)
            container.mainContext.insert(task)
        }
        try container.mainContext.save()

        let paths = lists.map { $0.2 } + ["/a/"]
        var listing = try #require(DAVSyncScenario.discovery(paths: paths).last)
        for (_, name, path) in lists {
            listing.body = listing.body.replacingOccurrences(of: "<d:href>" + path + "</d:href><d:propstat><d:prop><d:displayname>Fixture", with: "<d:href>" + path + "</d:href><d:propstat><d:prop><d:displayname>" + name)
        }
        let outcome = await runCreationSync(host: host, accountID: account.id, container: container,
            responses: DAVSyncScenario.discovery(paths: ["/a/"]) + Array(repeating: .init(status: 201, body: ""), count: 3)
                + [listing] + paths.map { .init(body: DAVSyncScenario.manifest(count: 0, path: $0)) })
        #expect(outcome.status == .completed)
        let writes = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "MKCALENDAR" }
        #expect(writes.count == 3)
        #expect(Set(writes.map { $0.url.absoluteString }) == Set(lists.map { base + $0.2 }))
        let read = ModelContext(container)
        let saved = try read.fetch(FetchDescriptor<TaskList>())
        #expect(saved.count == 4)
        #expect(saved.first { $0.serverURL == base + "/a/" }?.name == "Fixture")
        let tasks = try read.fetch(FetchDescriptor<TaskItem>())
        for (id, name, path) in lists {
            #expect(saved.first { $0.id == id }?.serverURL == base + path)
            #expect(saved.first { $0.id == id }?.name == name)
            #expect(tasks.first { $0.id == id + "-task" }?.taskList?.id == id)
        }
    }

    @Test("Lost creation reply binds only with exact successful private provenance", arguments: [
        "verified", "precondition", "visible", "missing", "mismatch", "foreign", "denied", "duplicate",
        "other-href", "trashed", "alias", "nested-multistatus", "invalid-version"
    ])
    func lostCreateReplyRequiresProvenance(proof: String) async throws {
        let host = "create-retry-" + UUID().uuidString.lowercased() + ".invalid"
        let base = "https://" + host
        let container = try DAVSyncScenario.container()
        let account = try makeCreationAccount(base: base, container: container)
        let context = container.mainContext
        let list = TaskList(id: "create-bang", serverURL: "", name: "Fixture", colorHex: "#007AFF")
        list.account = account
        list.isMetadataDirty = true
        context.insert(list)
        try context.save()

        let empty = DAVSyncScenario.discovery(paths: [])
        let visible = DAVSyncScenario.discovery(paths: [bangPath])
        let first = await runCreationSync(host: host, accountID: account.id, container: container,
            responses: empty + [.init(body: "", errorCode: .networkConnectionLost), try #require(visible.last)])
        #expect(first.status == .partial)
        let firstWrite = try #require(ScriptedDAVProtocol.requests(host: host).first { $0.method == "MKCALENDAR" })
        #expect(firstWrite.url.absoluteString == base + bangPath)
        let body = String(decoding: firstWrite.body, as: UTF8.self)
        let marker = body.components(separatedBy: "<n:creation-id>").dropFirst().first?
            .components(separatedBy: "</n:creation-id>").first
        #expect(marker?.isEmpty == false)
        let firstSaved = try ModelContext(container).fetch(FetchDescriptor<TaskList>())
        #expect(firstSaved.map(\.id) == [list.id])
        #expect(firstSaved.first?.serverURL == "")

        let background = await runCreationSync(host: host, accountID: account.id, container: container,
            responses: visible, background: true)
        #expect(background.status == .partial)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskList>()).map(\.id) == [list.id])
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "REPORT" })

        let proven = ["verified", "precondition", "visible"].contains(proof)
        if proven {
            list.name = "Renamed"
            try context.save()
        }
        if proof == "alias" {
            let claimant = TaskList(id: "already-bound", serverURL: bangPath, name: "Existing", colorHex: "#007AFF")
            claimant.account = account
            context.insert(claimant)
            try context.save()
        }
        let markerValue = proof == "mismatch" ? "unrelated" : marker ?? "absent-in-original-request"
        let markerNamespace = proof == "foreign" ? "urn:unrelated" : "https://nowthis.app/ns/caldav"
        let markerXML = "<n:creation-id xmlns:n=\"" + markerNamespace + "\">" + markerValue + "</n:creation-id>"
        let attributes = "<d:displayname>Fixture</d:displayname><d:resourcetype><c:calendar/></d:resourcetype><c:supported-calendar-component-set><c:comp name=\"VTODO\"/></c:supported-calendar-component-set>"
        var properties = attributes
        if proof != "missing" { properties += markerXML }
        if proof == "duplicate" { properties += markerXML }
        if proof == "trashed" { properties += "<x:deleted-at xmlns:x=\"http://nextcloud.com/ns\">yesterday</x:deleted-at>" }
        var probe = DAVSyncScenario.prop(proof == "other-href" ? "/unrelated/" : bangPath, properties)
        if proof == "denied" {
            probe = DAVSyncScenario.prop(bangPath, attributes).replacingOccurrences(of: "</d:response>", with:
                "<d:propstat><d:prop>" + markerXML + "</d:prop><d:status>HTTP/1.1 403 Forbidden</d:status></d:propstat></d:response>")
        }
        if proof == "nested-multistatus" { probe = "<d:multistatus>" + probe + "</d:multistatus>" }
        if proof == "invalid-version" {
            probe = probe.replacingOccurrences(of: "HTTP/1.1", with: "HTTP/not-a-version")
        }
        var responses = proof == "visible" || proof == "alias" ? visible : empty
        if proof != "visible" && proof != "alias" {
            responses.append(.init(status: proof == "precondition" ? 412 : 405, body: ""))
        }
        if proof != "alias" { responses.append(.init(body: DAVSyncScenario.multistatus(probe))) }
        if proven {
            responses.append(.init(body: DAVSyncScenario.multistatus(DAVSyncScenario.prop(bangPath,
                "<d:displayname/><x:calendar-color xmlns:x=\"http://apple.com/ns/ical/\"/>"))))
        }
        var refreshed = try #require(visible.last)
        if proven { refreshed.body = refreshed.body.replacingOccurrences(of: ">Fixture<", with: ">Renamed<") }
        responses.append(refreshed)
        responses.append(.init(body: DAVSyncScenario.manifest(count: 0, path: bangPath)))
        let second = await runCreationSync(host: host, accountID: account.id, container: container, responses: responses)
        let requests = ScriptedDAVProtocol.requests(host: host)
        if let retry = requests.first(where: { $0.method == "MKCALENDAR" }) {
            #expect(retry.url == firstWrite.url)
            #expect(String(decoding: retry.body, as: UTF8.self).contains("<n:creation-id>" + (marker ?? "") + "</n:creation-id>"))
        }
        if proof == "visible" || proof == "alias" { #expect(!requests.contains { $0.method == "MKCALENDAR" }) }
        let read = ModelContext(container)
        let saved = try read.fetch(FetchDescriptor<TaskList>())
        let original = try #require(saved.first { $0.id == list.id })
        #expect(saved.count == (proof == "alias" ? 2 : 1))
        #expect(original.serverURL == (proven ? base + bangPath : ""))
        #expect(second.status == (proven ? .completed : .partial))
        if proven {
            #expect(requests.contains { $0.method == "PROPPATCH" && String(decoding: $0.body, as: UTF8.self).contains(">Renamed<") })
            #expect(original.name == "Renamed")
            #expect(!original.isMetadataDirty)
        } else {
            #expect(original.isMetadataDirty)
            #expect(!requests.contains { $0.method == "PROPPATCH" })
            if proof == "alias" { #expect(saved.first { $0.id == "already-bound" }?.serverURL == bangPath) }
        }
    }

    @Test("An accepted create binds the list and keeps a concurrent saved rename pending")
    func acceptedCreateKeepsNewerMetadataPending() async throws {
        let host = "create-race-" + UUID().uuidString.lowercased() + ".invalid"
        let base = "https://" + host
        let container = try DAVSyncScenario.container()
        let account = try makeCreationAccount(base: base, container: container)
        let list = TaskList(id: "create-bang", serverURL: "", name: "Fixture", colorHex: "#007AFF")
        list.account = account
        let context = container.mainContext
        context.insert(list)
        try context.save()

        let gate = ScriptedDAVProtocol.Gate()
        defer { gate.release() }
        let listing = try #require(DAVSyncScenario.discovery(paths: [bangPath]).last)
        let responses = DAVSyncScenario.discovery(paths: []) + [
            .init(status: 201, body: "", gate: gate), listing,
            .init(body: DAVSyncScenario.manifest(count: 0, path: bangPath))
        ]
        let run = Task { await runCreationSync(host: host, accountID: account.id, container: container, responses: responses) }
        for _ in 0..<500 where ScriptedDAVProtocol.requests(host: host).last?.method != "MKCALENDAR" {
            try await Task.sleep(for: .milliseconds(10))
        }
        let write = try #require(ScriptedDAVProtocol.requests(host: host).last { $0.method == "MKCALENDAR" })
        #expect(String(decoding: write.body, as: UTF8.self).contains(">Fixture<"))
        list.name = "Newer"
        list.isMetadataDirty = true
        try context.save()
        gate.release()

        #expect(await run.value.status == .partial)
        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskList>())
        #expect(saved.map(\.id) == [list.id])
        #expect(saved.first?.serverURL == base + bangPath)
        #expect(saved.first?.name == "Newer")
        #expect(saved.first?.isMetadataDirty == true)
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "PROPPATCH" })
    }

    @Test("Changing account settings during discovery stops writes to the former account", arguments: [true, false])
    func accountChangeSupersedesDiscoveredWrite(draft: Bool) async throws {
        let host = "changed-account-" + UUID().uuidString.lowercased() + ".invalid"
        let container = try DAVSyncScenario.container()
        let account = try makeCreationAccount(base: "https://" + host, container: container)
        let list = TaskList(id: "create-bang", serverURL: draft ? "" : bangPath, name: "Local", colorHex: "#007AFF")
        list.account = account
        list.isMetadataDirty = true
        let context = container.mainContext
        context.insert(list)
        try context.save()

        let gate = ScriptedDAVProtocol.Gate()
        defer { gate.release() }
        var responses = DAVSyncScenario.discovery(paths: draft ? [] : [bangPath])
        responses[2].gate = gate
        let run = Task { await runCreationSync(host: host, accountID: account.id, container: container, responses: responses) }
        for _ in 0..<500 where ScriptedDAVProtocol.requests(host: host).count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ScriptedDAVProtocol.requests(host: host).count == 3)
        account.serverBaseURL = "https://replacement.invalid"
        try context.save()
        gate.release()

        #expect(await run.value.status == .cancelled)
        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskList>())
        #expect(saved.map(\.id) == [list.id])
        #expect(saved.first?.serverURL == (draft ? "" : bangPath))
        #expect(saved.first?.isMetadataDirty == true)
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "MKCALENDAR" || $0.method == "PROPPATCH" })
    }

    private func makeCreationAccount(base: String, container: ModelContainer) throws -> ServerAccount {
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: base, username: "fixture")
        container.mainContext.insert(account)
        try container.mainContext.save()
        return account
    }

    private func runCreationSync(host: String, accountID: String, container: ModelContainer,
                                 responses: [ScriptedDAVProtocol.Response], background: Bool = false) async -> SyncOutcome {
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
        if background {
            return await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
                credentials: credentials, modelContainer: container, reconcileNotifications: false)
        }
        return await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
    }
}
