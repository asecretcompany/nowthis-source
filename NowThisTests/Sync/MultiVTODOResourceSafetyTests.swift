import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Multi-VTODO resource safety", .serialized)
@MainActor
struct MultiVTODOResourceSafetyTests {
    static func body(exceptionFirst: Bool = false, missingSiblingUID: Bool = false) -> String {
        let master = "BEGIN:VTODO\nUID:series\nSUMMARY:Master\nRRULE:FREQ=DAILY\nEND:VTODO"
        let exception = "BEGIN:VTODO\n" + (missingSiblingUID ? "" : "UID:series\n")
            + "RECURRENCE-ID:20261111T120000Z\nSUMMARY:Exception\nEND:VTODO"
        return "BEGIN:VCALENDAR\nVERSION:2.0\n" + (exceptionFirst ? exception + "\n" + master : master + "\n" + exception) + "\nEND:VCALENDAR"
    }

    @Test("Sibling components never become an editable first component", arguments: [false, true])
    func siblingIsNotEditable(exceptionFirst: Bool) throws {
        let parsed = try SyncBodyValidation.parse(.init(href: "/one/series.ics", etag: "e1",
            icsData: Self.body(exceptionFirst: exceptionFirst)), using: .init())
        #expect(parsed.todo == nil)
    }

    @Test("A missing-UID sibling cannot disappear from shape admission")
    func missingSiblingUID() throws {
        let parsed = try SyncBodyValidation.parse(.init(href: "/one/series.ics", etag: "e1",
            icsData: Self.body(missingSiblingUID: true)), using: .init())
        #expect(parsed.todo == nil)
    }

    @Test("An old opaque sidecar cannot authorize a subtree move to Vault")
    func oldSidecarDoesNotAuthorizeMove() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        _ = try DAVSyncScenario.account(in: container)
        let account = try #require(try context.fetch(FetchDescriptor<ServerAccount>()).first)
        let list = TaskList(serverURL: "/one/", name: "Source", colorHex: "#007AFF")
        list.account = account; context.insert(list)
        let destination = TaskList(serverURL: "", name: "Vault", colorHex: "#007AFF")
        context.insert(destination)
        let task = TaskItem(uid: "series", title: "Keep local edit")
        task.taskList = list; task.remoteHref = "/one/series.ics"; task.etag = "e0"
        task.isLocalOnly = false; task.attachmentStateKnown = true
        context.insert(task)
        try VTODOOpaqueState.empty.store(taskID: task.id, in: context)
        try context.save()
        #expect(TaskMover.move(task, to: destination, in: context).isEmpty)
        #expect(task.taskList?.id == list.id)
        #expect(task.remoteHref == "/one/series.ics")
        #expect(task.etag == "e0")
        #expect(task.pendingMoveFromHref == nil)
    }

    @Test("Unsupported pull preserves a dirty edit and allows an ordinary resource", arguments: [false, true])
    func engineHoldsUnsupportedWrite(exceptionFirst: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let host = "shape-" + UUID().uuidString.lowercased() + ".invalid"
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let account = try #require(try context.fetch(FetchDescriptor<ServerAccount>()).first)
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        list.account = account; context.insert(list)
        SyncEngine.markCategoriesCaughtUp(listID: list.id)
        let task = TaskItem(uid: "series", title: "Keep local edit")
        task.taskList = list; task.remoteHref = "/one/series.ics"; task.etag = "e0"
        task.isDirty = true; task.isLocalOnly = false; task.attachmentStateKnown = true
        context.insert(task)
        try VTODOOpaqueState.empty.store(taskID: task.id, in: context)
        try context.save()
        let ordinary = "BEGIN:VCALENDAR\nBEGIN:VTODO\nUID:ordinary\nSUMMARY:Unrelated task\nEND:VTODO\nEND:VCALENDAR"
        let manifest = DAVSyncScenario.multistatus(DAVSyncScenario.prop("/one/series.ics", "<d:getetag>e1</d:getetag>")
            + DAVSyncScenario.prop("/one/ordinary.ics", "<d:getetag>o1</d:getetag>"))
        let bodies = DAVSyncScenario.multistatus(DAVSyncScenario.prop("/one/series.ics", "<d:getetag>e1</d:getetag><c:calendar-data>" + Self.body(exceptionFirst: exceptionFirst) + "</c:calendar-data>")
            + DAVSyncScenario.prop("/one/ordinary.ics", "<d:getetag>o1</d:getetag><c:calendar-data>" + ordinary + "</c:calendar-data>"))
        let configuration = ScriptedDAVProtocol.install(host: host, responses:
            DAVSyncScenario.discovery(paths: ["/one/"]) + [.init(body: manifest), .init(body: bodies),
                .init(status: 204, body: "", headers: ["ETag": "destructive-write"])])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: configuration, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        let stored = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        let held = try #require(stored.first { $0.uid == "series" })
        #expect(held.title == "Keep local edit")
        #expect(held.isDirty)
        #expect(held.etag == "e0")
        #expect(stored.contains { $0.uid == "ordinary" && $0.title == "Unrelated task" })
        let writes = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "PUT" || $0.method == "DELETE" }
        #expect(writes.isEmpty, "An unsupported body must not be reduced to one VTODO")
        withExtendedLifetime(container) {}
    }
    private func remoteFixture(host: String, known: Bool = true, dirty: Bool = true) throws -> (ModelContainer, ServerAccount, TaskList, TaskItem) {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        _ = try DAVSyncScenario.account(in: container, host: host)
        let account = try #require(try context.fetch(FetchDescriptor<ServerAccount>()).first)
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        list.account = account; context.insert(list)
        list.syncCTag = "c1"; list.lastFullPullDate = Date()
        SyncEngine.markCategoriesCaughtUp(listID: list.id)
        let task = TaskItem(uid: "series", title: "Local edit")
        task.taskList = list; task.remoteHref = "/one/series.ics"; task.etag = "e1"
        task.isLocalOnly = false; task.isDirty = dirty; task.attachmentStateKnown = true
        context.insert(task)
        try VTODOOpaqueState.empty.store(taskID: task.id, in: context)
        if known { try SyncResourceFixture.prove(task, in: context) }
        try context.save()
        try DAVSyncScenario.seedRecentCheckpoint(for: list, in: container)
        return (container, account, list, task)
    }

    @Test("412 refetch preserves unsupported body and dirty baseline without a second PUT", arguments: [false, true])
    func unsupportedConflict(exceptionFirst: Bool) async throws {
        let host = "shape-conflict-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, list, task) = try remoteFixture(host: host)
        let config = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
            .init(status: 412, body: ""),
            .init(body: Self.body(exceptionFirst: exceptionFirst), headers: ["ETag": "e2"])])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: "https://" + host,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        let fresh = ModelContext(container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.id == task.id && stored.title == "Local edit" && stored.etag == "e1" && stored.isDirty)
        let responseScope = try #require(TaskPhotoOwnership.Scope(list: list))
        let record = try #require(try SyncResourceState.read(scope: responseScope, href: "/one/series.ics", in: fresh))
        #expect(record.shape == .unsupported && record.etag == "e2")
        #expect(record.originalBody == Self.body(exceptionFirst: exceptionFirst))
        let writes = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "PUT" }
        #expect(writes.count == 1 && writes.first?.ifMatch == "\"e1\"")
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "DELETE" })
        withExtendedLifetime(container) {}
    }

    @Test("Clean legacy same-ETag move hold fetches through CTag and token shortcuts", arguments: [false, true])
    func cleanLegacyRevalidation(unsupported: Bool) async throws {
        let host = "shape-legacy-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, list, task) = try remoteFixture(host: host, known: false, dirty: false)
        let context = container.mainContext
        let destination = TaskList(serverURL: "", name: "Vault", colorHex: "#007AFF")
        context.insert(destination); try context.save()
        let key = SyncImportCheckpoint.identity(accountID: account.id, listID: list.id,
            baseURL: account.serverBaseURL, username: account.username, months: 0)
        let scope = SyncCollectionPuller.Scope(accountID: account.id, listID: list.id, historyScope: "0")
        try SyncImportCheckpoint.commit(.init(scope: scope, token: "existing-token", ctag: "c1",
            lastIntegrity: Date(), hasCompletedBaseline: true), id: key, collectionPath: list.serverURL, container: container)
        var scheduled = 0
        let errors = ErrorState()
        #expect(!MoveDestinations.perform(task, toListID: destination.id, in: context, errorState: errors, revalidate: { scheduled += 1 }))
        #expect(scheduled == 1 && errors.isPresented)
        #expect(task.taskList?.id == list.id && task.pendingMoveFromHref == nil && task.etag == "e1")
        let body = unsupported ? Self.body() : "BEGIN:VTODO\nUID:series\nSUMMARY:Remote\nEND:VTODO"
        let manifest = DAVSyncScenario.multistatus(DAVSyncScenario.prop("/one/series.ics", "<d:getetag>e1</d:getetag>"))
        let bodies = DAVSyncScenario.multistatus(DAVSyncScenario.prop("/one/series.ics", "<d:getetag>e1</d:getetag><c:calendar-data>" + body + "</c:calendar-data>"))
        let config = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [.init(body: manifest), .init(body: bodies)])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "REPORT" }.count == 2)
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "PUT" || $0.method == "DELETE" })
        #expect(MoveDestinations.perform(task, toListID: destination.id, in: context, errorState: errors, revalidate: { scheduled += 1 }) == !unsupported)
        #expect(scheduled == 1, "Unsupported classification does not schedule a sync loop")
        withExtendedLifetime(container) {}
    }

    @Test("Shape proof does not cross ETag, resource, or request identity")
    func staleProofNeverAdmits() throws {
        let (container, account, list, task) = try remoteFixture(host: "scope.invalid")
        let context = container.mainContext
        #expect(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: list.serverURL, container: container) != nil)
        task.etag = "e2"; try context.save()
        #expect(throws: SyncResourceState.Hold.self) { try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: list.serverURL, container: container) }
        task.etag = "e1"; account.username = "other"; try context.save()
        #expect(throws: SyncResourceState.Hold.self) { try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: list.serverURL, container: container) }
        account.username = "fixture"; task.remoteHref = "/one/other.ics"; try context.save()
        #expect(throws: SyncResourceState.Hold.self) { try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: list.serverURL, container: container) }
    }

    @Test("Source cleanup sends source E1 rather than destination E9 and retains a 412 move", arguments: [false, true])
    func sourceETagIsIndependent(conflict: Bool) async throws {
        let host = "shape-source-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, source, task) = try remoteFixture(host: host)
        let context = container.mainContext
        let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        destination.account = account; context.insert(destination)
        #expect(TaskMover.move(task, to: destination, in: context).count == 1)
        task.remoteHref = "/two/series.ics"; task.etag = "e9"; task.isDirty = false
        try SyncResourceFixture.prove(task, in: context); try context.save()
        let config = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
            .init(status: conflict ? 412 : 204, body: "")])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        let deletes = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "DELETE" }
        #expect(deletes.count == 1 && deletes.first?.path == "/one/series.ics" && deletes.first?.ifMatch == "\"e1\"")
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.etag == "e9" && stored.taskList?.id == destination.id)
        #expect((stored.pendingMoveFromListID == source.id) == conflict)
        withExtendedLifetime(container) {}
    }

    @Test("Unknown deleted Vault source is fetched before cleanup readiness", arguments: [false, true])
    func deletedLegacySourceRevalidates(unsupported: Bool) async throws {
        let host = "shape-deleted-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, source, task) = try remoteFixture(host: host, known: false)
        let context = container.mainContext
        let vaultAccount = ServerAccount(vaultDisplayName: "Vault")
        let vault = TaskList(serverURL: "", name: "Vault", colorHex: "#007AFF")
        context.insert(vaultAccount); context.insert(vault); vault.account = vaultAccount
        task.pendingMoveFromHref = task.remoteHref; task.pendingMoveFromListID = source.id
        task.taskList = vault; task.remoteHref = nil; task.etag = nil
        task.isDeletedLocally = true; task.attachmentStateKnown = nil
        try context.save()
        let body = unsupported ? Self.body() : "BEGIN:VTODO\nUID:series\nSUMMARY:Source\nEND:VTODO"
        let config = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
            .init(body: body, headers: ["ETag": "source-etag"]), .init(status: 204, body: "")])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        let operations = ScriptedDAVProtocol.requests(host: host).filter { ["GET", "PUT", "DELETE"].contains($0.method) }
        #expect(operations.map(\.method) == (unsupported ? ["GET"] : ["GET", "DELETE"]))
        let tasks = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        if unsupported {
            let held = try #require(tasks.first)
            #expect(held.isDeletedLocally && held.pendingMoveFromHref == "/one/series.ics")
            #expect(held.attachmentStateKnown != true)
        } else { #expect(tasks.isEmpty) }
        withExtendedLifetime(container) {}
    }

    @Test("A late PUT without an ETag revalidates its cleanup tombstone before DELETE")
    func latePutWithoutETagNeedsFetch() async throws {
        let host = "shape-late-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, source, task) = try remoteFixture(host: host, known: false)
        let context = container.mainContext
        task.remoteHref = nil; task.etag = nil; task.isLocalOnly = true
        try context.save()
        let snapshot = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: source.serverURL, container: container))
        let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        destination.account = account; context.insert(destination); task.taskList = destination; try context.save()
        try SyncPushAcknowledgement.acknowledge(snapshot, etag: "", container: container)
        let cleanup = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first { $0.isDeletedLocally })
        #expect(throws: SyncResourceState.Hold.self) { try SyncPushAcknowledgement.deletionSnapshot(taskID: cleanup.id, container: container) }
        // Missing proof also overrides the normal pull shortcuts, then catch-up
        // adopts an exact GET revision solely for this deletion obligation.
        let manifest = DAVSyncScenario.multistatus(DAVSyncScenario.prop(snapshot.path, "<d:getetag>server-e2</d:getetag>"))
        let bodies = DAVSyncScenario.multistatus(DAVSyncScenario.prop(snapshot.path, "<d:getetag>server-e2</d:getetag><c:calendar-data>" + snapshot.payload + "</c:calendar-data>"))
        let config = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
            .init(body: manifest), .init(body: bodies),
            .init(body: snapshot.payload, headers: ["ETag": "server-e2"]), .init(status: 204, body: "")])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        let operations = ScriptedDAVProtocol.requests(host: host).filter { ["GET", "PUT", "DELETE"].contains($0.method) }
        #expect(operations.map(\.method) == ["GET", "DELETE"])
        #expect(operations.last?.ifMatch == "\"server-e2\"")
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).allSatisfy { !$0.isDeletedLocally })
        withExtendedLifetime(container) {}
    }

    @Test("Late source PUT advances only its source proof and preserves newer destination additions")
    func lateSourceAcknowledgementKeepsDestinationEdits() throws {
        let (container, account, source, task) = try remoteFixture(host: "late-source.invalid")
        let context = container.mainContext
        let original = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        context.insert(original); original.task = task
        original.originalFileID = "901"; original.folderFileID = "900"
        try acceptPhotoOriginal(original, in: context)
        try context.save()
        let snapshot = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: source.serverURL, container: container))
        let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        destination.account = account; context.insert(destination)
        #expect(TaskMover.move(task, to: destination, in: context).count == 1)
        task.title = "New destination edit"
        let addition = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        context.insert(addition); addition.task = task; addition.pendingOperation = "add"
        try context.save()
        try SyncPushAcknowledgement.acknowledge(snapshot, etag: "source-e2", container: container)
        let fresh = ModelContext(container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "New destination edit" && stored.isDirty && stored.taskList?.id == destination.id)
        #expect(stored.remoteHref == nil && stored.etag == nil && stored.pendingMoveFromHref == "/one/series.ics")
        #expect(stored.photos.first { $0.id == addition.id }?.pendingOperation == "add")
        #expect(stored.photos.first { $0.id == original.id }?.previousOriginalFileID == "901")
        #expect(try SyncResourceState.sourceProof(stored, in: fresh)?.etag == "source-e2")
    }

    @Test("Unsupported observations persist before dirty, deleted, same-ETag and pending UI filters", arguments: ["dirty", "deleted", "same", "pending"])
    func observationPrecedesTaskFilters(kind: String) throws {
        let (container, _, list, task) = try remoteFixture(host: "filters.invalid", known: false, dirty: kind == "dirty")
        let context = container.mainContext
        if kind == "deleted" { task.isDeletedLocally = true; try context.save() }
        if kind == "pending" { task.title = "Unsaved local edit"; task.isDirty = true }
        let resource = try SyncBodyValidation.parse(.init(href: "/one/series.ics", etag: "e1", icsData: Self.body()), using: .init())
        _ = try SyncInboundBatchWriter(container: container, listID: list.id).apply([resource])
        let scope = try #require(TaskPhotoOwnership.Scope(list: list))
        let record = try #require(try SyncResourceState.read(scope: scope, href: resource.href, in: ModelContext(container)))
        #expect(record.originalBody == Self.body() && record.shape == .unsupported)
        #expect(task.title == (kind == "pending" ? "Unsaved local edit" : "Local edit"))
    }

    @Test("A failed import transaction cannot leave an unsupported observation after an unrelated save")
    func failedBatchDoesNotLeakObservation() throws {
        let (container, _, list, _) = try remoteFixture(host: "transaction.invalid", known: false)
        let unsupported = try SyncBodyValidation.parse(.init(href: "/one/series.ics", etag: "e1", icsData: Self.body()), using: .init())
        var bad = ICalendarParser.VTODOData(); bad.uid = "bad"; bad.summary = "Bad"; bad.opaqueProperties = ["END:VTODO"]
        let writer = SyncInboundBatchWriter(container: container, listID: list.id)
        #expect(throws: VTODOOpaqueState.StateError.self) {
            try writer.apply([unsupported, ParsedRemoteTask(href: "/one/bad.ics", etag: "bad", todo: bad)])
        }
        let other = ModelContext(container); other.insert(Tag(name: "Unrelated save")); try other.save()
        let scope = try #require(TaskPhotoOwnership.Scope(list: list))
        #expect(try SyncResourceState.read(scope: scope, href: unsupported.href, in: ModelContext(container)) == nil)
    }

    @Test("Missing-ETag source acknowledgement revalidates only its emitted body", arguments: [false, true])
    func sourceWithoutETagRevalidation(changed: Bool) async throws {
        let host = "shape-source-empty-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, source, task) = try remoteFixture(host: host)
        let context = container.mainContext
        let snapshot = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: source.serverURL, container: container))
        let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        destination.account = account; context.insert(destination)
        #expect(TaskMover.move(task, to: destination, in: context).count == 1)
        task.title = "Newer destination edit"; try context.save()
        try SyncPushAcknowledgement.acknowledge(snapshot, etag: "", container: container)
        let initial = ModelContext(container)
        let before = try #require(try initial.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(throws: SyncResourceState.Hold.self) { try SyncResourceState.sourceProof(before, in: initial) }
        let returned = changed ? snapshot.payload.replacingOccurrences(of: "SUMMARY:Local edit", with: "SUMMARY:Changed elsewhere") : snapshot.payload.replacingOccurrences(of: "SUMMARY:Local edit", with: "SUMMARY:Local\r\n  edit")
        let config = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
            .init(body: returned, headers: ["ETag": "source-e2"])])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "GET" }.count == 1)
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "PUT" || $0.method == "DELETE" })
        let fresh = ModelContext(container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "Newer destination edit" && stored.isDirty && stored.pendingMoveFromHref == "/one/series.ics")
        if changed {
            #expect(throws: SyncResourceState.Hold.self) { try SyncResourceState.sourceProof(stored, in: fresh) }
            let retry = try #require(try TaskPhotoLegacyCatchUp.requestInfo(taskID: stored.id, listID: destination.id,
                accountID: account.id, container: container))
            let matching = try SyncBodyValidation.parse(.init(href: snapshot.path, etag: "later-matching", icsData: snapshot.payload), using: .init())
            _ = try TaskPhotoLegacyCatchUp.accept(matching, taskID: stored.id, listID: destination.id,
                accountID: account.id, expectedRequest: retry, responseScope: try #require(retry.photoScope), container: container)
            let retryContext = ModelContext(container)
            let retried = try #require(try retryContext.fetch(FetchDescriptor<TaskItem>()).first)
            #expect(try SyncResourceState.sourceProof(retried, in: retryContext)?.etag == "later-matching")
        }
        else { #expect(try SyncResourceState.sourceProof(stored, in: fresh)?.etag == "source-e2") }
        withExtendedLifetime(container) {}
    }

    @Test("Corrupt, future and wrong-resource proof never authorizes a write", arguments: ["garbage", "future", "href"])
    func invalidProofIsHeld(kind: String) throws {
        let (container, _, list, task) = try remoteFixture(host: "corrupt.invalid")
        let context = container.mainContext
        let scope = try #require(TaskPhotoOwnership.Scope(list: list))
        let key = try SyncResourceState.key(scope: scope, href: "/one/series.ics")
        let row = try #require(try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first)
        if kind == "garbage" { row.syncToken = "broken" }
        else {
            let data = try #require(row.syncToken?.data(using: .utf8))
            var fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            if kind == "future" { fields["version"] = 999 }
            else { fields["href"] = "/one/different.ics" }
            row.syncToken = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        }
        try context.save()
        #expect(throws: SyncResourceState.Hold.self) {
            try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: list.serverURL, container: container)
        }
        #expect(try SyncResourceState.needsClassification(list: list, in: ModelContext(container)) == ["/one/series.ics"])
    }

    @Test("Suspended empty-ETag source GET cannot advance changed marker, binding or baseline", arguments: ["marker", "binding", "baseline"])
    func suspendedSourceRecoveryIsGuarded(change: String) async throws {
        let host = "shape-suspended-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, source, task) = try remoteFixture(host: host)
        let context = container.mainContext
        let scope = try #require(TaskPhotoOwnership.Scope(list: source))
        let snapshot = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: source.serverURL, container: container))
        let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        destination.account = account; context.insert(destination)
        #expect(TaskMover.move(task, to: destination, in: context).count == 1)
        try context.save()
        try SyncPushAcknowledgement.acknowledge(snapshot, etag: "", container: container)
        let gate = ScriptedDAVProtocol.Gate(); defer { gate.release() }
        let config = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
            .init(body: snapshot.payload, headers: ["ETag": "stale-get"], gate: gate)])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let operation = Task { await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: "https://" + host,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container) }
        for _ in 0..<500 where !ScriptedDAVProtocol.requests(host: host).contains(where: { $0.method == "GET" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ScriptedDAVProtocol.requests(host: host).contains { $0.method == "GET" })
        if change == "marker" { task.pendingMoveFromHref = "/one/new-source.ics" }
        else if change == "binding" { account.username = "other" }
        else {
            let newer = SyncResourceState(scope: scope, href: "/one/series.ics", etag: "newer-baseline", shape: .singleTask, originalBody: nil)
            try newer.store(in: context, key: SyncResourceState.movePrefix + task.id)
        }
        task.title = "Preserve newer edit"; try context.save()
        gate.release(); _ = await operation.value
        let fresh = ModelContext(container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "Preserve newer edit" && stored.isDirty && stored.pendingMoveFromHref != nil)
        #expect(try SyncResourceState.read(scope: scope, href: "/one/series.ics", in: fresh)?.etag == "")
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "PUT" || $0.method == "DELETE" })
        withExtendedLifetime(container) {}
    }

    @Test("Task requests reject same-origin redirects to a sibling with the same ETag", arguments: ["GET", "PUT", "DELETE"])
    func siblingRedirectDoesNotInheritProof(method: String) async throws {
        let host = "shape-redirect-" + UUID().uuidString.lowercased() + ".invalid"
        let sibling = try #require(URL(string: "https://" + host + "/one/sibling.ics"))
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: 307, body: "", redirectURL: sibling),
            .init(status: 200, body: "BEGIN:VTODO\nUID:sibling\nSUMMARY:Other resource\nEND:VTODO", headers: ["ETag": "e1"])])
        let client = CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0))
        var rejected = false
        do {
            let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
            if method == "GET" { _ = try await client.fetchTask(baseURL: "https://" + host, taskPath: "/one/series.ics", credentials: credentials) }
            else if method == "PUT" { _ = try await client.putTask(baseURL: "https://" + host, taskPath: "/one/series.ics", icsData: "private task", etag: "e1", credentials: credentials) }
            else { try await client.deleteTask(baseURL: "https://" + host, taskPath: "/one/series.ics", etag: "e1", credentials: credentials) }
        } catch { rejected = true }
        #expect(rejected)
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.path) == ["/one/series.ics"])
    }

    @Test("Ordinary deletion rejects an unsaved account rebind")
    func unsavedDeletionScopeIsHeld() throws {
        let (container, account, _, task) = try remoteFixture(host: "delete-scope.invalid")
        task.isDeletedLocally = true; try container.mainContext.save()
        let snapshot = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: task.id, container: container))
        account.username = "new-account"
        #expect(throws: (any Error).self) { try SyncPushAcknowledgement.validateDeletion(snapshot, container: container) }
        #expect(task.isDeletedLocally && task.remoteHref == "/one/series.ics")
    }

    @Test("Missing or unreadable move capture cannot adopt a replacement resource observation", arguments: ["absent", "corrupt", "future"])
    func genericObservationCannotBecomeSourceCapture(kind: String) async throws {
        let host = "shape-capture-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, source, task) = try remoteFixture(host: host, known: false)
        let context = container.mainContext
        let vaultAccount = ServerAccount(vaultDisplayName: "Vault")
        let vault = TaskList(serverURL: "", name: "Vault", colorHex: "#007AFF")
        context.insert(vaultAccount); context.insert(vault); vault.account = vaultAccount
        task.pendingMoveFromHref = task.remoteHref; task.pendingMoveFromListID = source.id
        task.taskList = vault; task.remoteHref = nil; task.etag = nil
        if kind != "absent" {
            let row = SyncMetadata(id: SyncResourceState.movePrefix + task.id, collectionPath: "")
            row.syncToken = kind == "corrupt" ? "broken" : "{\"version\":999}"
            context.insert(row)
        }
        let replacement = "BEGIN:VTODO\nUID:replacement\nSUMMARY:Another task\nEND:VTODO"
        let parsed = try SyncBodyValidation.parse(.init(href: "/one/series.ics", etag: "e2", icsData: replacement), using: .init())
        let scope = try #require(TaskPhotoOwnership.Scope(list: source))
        try SyncResourceState.observe(parsed, scope: scope, in: context); try context.save()
        let config = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
            .init(status: 200, body: replacement, headers: ["ETag": "e2"]), .init(status: 204, body: "")])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "PUT" || $0.method == "DELETE" })
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.pendingMoveFromHref == "/one/series.ics" && stored.taskList?.id == vault.id)
        withExtendedLifetime(container) {}
    }

    @Test("Deleting a destination transfers the exact captured source revision or fingerprint", arguments: [false, true])
    func destinationDeletionTransfersSourceObligation(emptyETag: Bool) throws {
        let (container, account, source, task) = try remoteFixture(host: "source-transfer.invalid")
        let context = container.mainContext
        let snapshot = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: source.serverURL, container: container))
        let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        context.insert(destination); destination.account = account
        #expect(TaskMover.move(task, to: destination, in: context).count == 1)
        try context.save()
        if emptyETag { try SyncPushAcknowledgement.acknowledge(snapshot, etag: "", container: container) }
        let captured = try #require(try SyncResourceState.read(key: SyncResourceState.movePrefix + task.id, in: ModelContext(container)))
        try TaskListHelpers.settlePendingMoves(beforeDeleting: destination, in: context)
        context.delete(destination); try context.save()
        let tombstone = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(tombstone.isDeletedLocally && tombstone.taskList?.id == source.id)
        #expect(tombstone.etag == (emptyETag ? "" : "e1"))
        #expect(try SyncResourceState.read(key: SyncResourceState.cleanupPrefix + tombstone.id, in: ModelContext(container)) == captured)
        let request = try #require(try TaskPhotoLegacyCatchUp.requestInfo(taskID: tombstone.id,
            listID: source.id, accountID: account.id, container: container))
        let changed = snapshot.payload.replacingOccurrences(of: "SUMMARY:Local edit", with: "SUMMARY:Changed source")
        let parsed = try SyncBodyValidation.parse(.init(href: "/one/series.ics", etag: "e2", icsData: changed), using: .init())
        let scope = try #require(TaskPhotoOwnership.Scope(list: source))
        if emptyETag {
            #expect(throws: SyncResourceState.Hold.self) {
                try TaskPhotoLegacyCatchUp.accept(parsed, taskID: tombstone.id, listID: source.id,
                    accountID: account.id, expectedRequest: request, responseScope: scope, container: container)
            }
        } else {
            _ = try TaskPhotoLegacyCatchUp.accept(parsed, taskID: tombstone.id, listID: source.id,
                accountID: account.id, expectedRequest: request, responseScope: scope, container: container)
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.etag == (emptyETag ? "" : "e1"))
        if !emptyETag {
            #expect(try SyncPushAcknowledgement.deletionSnapshot(taskID: tombstone.id, container: container)?.etag == "e1")
        }
    }

    @Test("Fingerprint folding consumes only original adjacent line breaks")
    func fingerprintDoesNotEraseBlankLine() {
        #expect(SyncResourceState.fingerprint("SUMMARY:Local\r\n edit") == SyncResourceState.fingerprint("SUMMARY:Localedit"))
        #expect(SyncResourceState.fingerprint("SUMMARY:Local\r\n\r\n \tedit") != SyncResourceState.fingerprint("SUMMARY:Localedit"))
    }

    @Test("A held live child blocks parent source cleanup")
    func heldChildBlocksLiveParent() async throws {
        let (container, _, source, parent) = try remoteFixture(host: "held-child.invalid")
        let context = container.mainContext
        let child = TaskItem(uid: "child", title: "Child")
        context.insert(child); child.taskList = source; child.parentTask = parent; child.parentUID = parent.uid
        child.remoteHref = "/one/child.ics"; child.etag = "c1"; child.isLocalOnly = false; child.attachmentStateKnown = true
        try VTODOOpaqueState.empty.store(taskID: child.id, in: context)
        try SyncResourceFixture.prove(child, in: context)
        let vault = TaskList(serverURL: "", name: "Vault", colorHex: "#007AFF"); context.insert(vault)
        #expect(TaskMover.move(parent, to: vault, in: context).count == 2)
        try context.save()
        let scope = try #require(TaskPhotoOwnership.Scope(list: source))
        let parsed = try SyncBodyValidation.parse(.init(href: "/one/child.ics", etag: "c2", icsData: Self.body()), using: .init())
        try SyncResourceState.observe(parsed, scope: scope, in: context); try context.save()
        let fresh = ModelContext(container)
        var deletes: [String] = []
        _ = await PendingMoveSweep.run(PendingMoveSweep.candidates(sourceListIDs: [source.id], in: fresh), in: fresh) { deletes.append($0.sourceHref) }
        #expect(deletes.isEmpty)
    }

    @Test("Successful recreation acknowledges the actual generated target observation")
    func recreationAcknowledgesOldObservedPath() throws {
        let (container, _, list, task) = try remoteFixture(host: "recreate.invalid")
        let context = container.mainContext
        task.isDeletedLocally = true; try context.save()
        let deletion = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: task.id, container: container))
        task.isDeletedLocally = false; try context.save()
        _ = try SyncPushAcknowledgement.acknowledgeDeletion(deletion, container: container)
        let snapshot = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: list.serverURL, container: container))
        #expect(snapshot.etag == nil && snapshot.originalHref == nil)
        try SyncPushAcknowledgement.acknowledge(snapshot, etag: "created", container: container)
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.remoteHref == "/one/series.ics" && stored.etag == "created" && !stored.isDirty)
    }

    @Test("A scoped 404 completes legacy cleanup without a destructive request", arguments: [false, true])
    func missingLegacyResourceCompletesCleanup(moved: Bool) async throws {
        let host = "shape-absent-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, source, task) = try remoteFixture(host: host, known: false)
        let context = container.mainContext
        task.isDeletedLocally = true
        if moved {
            let vault = TaskList(serverURL: "", name: "Vault", colorHex: "#007AFF"); context.insert(vault)
            let vaultAccount = ServerAccount(vaultDisplayName: "Vault"); context.insert(vaultAccount); vault.account = vaultAccount
            task.pendingMoveFromHref = task.remoteHref; task.pendingMoveFromListID = source.id
            task.taskList = vault; task.remoteHref = nil; task.etag = nil
        }
        try context.save()
        let responses = DAVSyncScenario.discovery(paths: ["/one/"]) + (moved ? [] : [.init(body: DAVSyncScenario.multistatus(""))]) + [.init(status: 404, body: "")]
        let config = ScriptedDAVProtocol.install(host: host, responses: responses)
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 0)
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "DELETE" || $0.method == "PUT" })
    }

    @Test("Delayed permission refusal cannot roll back into rebound source or destination", arguments: ["PUT", "DELETE"], ["source", "destination"])
    func delayedRefusalKeepsReboundMove(method: String, rebound: String) async throws {
        let (container, account, source, task) = try remoteFixture(host: "refusal.invalid")
        let context = container.mainContext
        let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        context.insert(destination); destination.account = account
        #expect(TaskMover.move(task, to: destination, in: context).count == 1)
        if method == "DELETE" {
            task.remoteHref = "/two/series.ics"; task.etag = "d1"; task.isDirty = false
            try SyncResourceFixture.prove(task, in: context)
        }
        try context.save()
        let worker = ModelContext(container)
        let saved = try #require(try worker.fetch(FetchDescriptor<TaskItem>()).first)
        let put = method == "PUT" ? try SyncPushSnapshot(task: saved, calendarPath: destination.serverURL) : nil
        let deletion = method == "DELETE" ? try SyncMoveSnapshot(task: saved) : nil
        await Task.yield() // The response follows a separately saved binding change.
        if rebound == "source" { source.serverURL = "/rebound-source/" }
        else { destination.serverURL = "/rebound-destination/" }
        try context.save()
        if let put { #expect(throws: (any Error).self) { try SyncPushAcknowledgement.rollBackRefusedMove(put, container: container) } }
        if let deletion { #expect((try? SyncMoveAcknowledgement.rollBackRefusedDelete(deletion, container: container)) == nil) }
        let rows = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(rows.count == 1 && rows.first?.taskList?.id == destination.id && rows.first?.pendingMoveFromHref == "/one/series.ics")
    }

    private struct ObservationSaveFailure: Error {}

    @Test("Engine delta receipts and token follow the durable shape save", arguments: [false, true])
    func engineDeltaCommitsOnlyDurableObservation(failSave: Bool) async throws {
        let host = "shape-delta-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, list, task) = try remoteFixture(host: host, dirty: false)
        let scope = SyncCollectionPuller.Scope(accountID: account.id, listID: list.id, historyScope: "0")
        let key = SyncImportCheckpoint.identity(accountID: account.id, listID: list.id,
            baseURL: account.serverBaseURL, username: account.username, months: 0)
        try SyncImportCheckpoint.commit(.init(scope: scope, token: "old", ctag: "c1", lastIntegrity: Date(), hasCompletedBaseline: true),
            id: key, collectionPath: list.serverURL, container: container)
        var discovery = DAVSyncScenario.discovery(paths: ["/one/"])
        discovery[2].body = discovery[2].body.replacingOccurrences(of: "<cs:getctag>",
            with: "<d:supported-report-set><d:supported-report><d:report><d:sync-collection/></d:report></d:supported-report></d:supported-report-set><d:sync-token>discovery</d:sync-token><cs:getctag>")
        let page = DAVSyncScenario.multistatus(DAVSyncScenario.prop("/one/series.ics", "<d:getetag>e2</d:getetag>")
            + "<d:response><d:href>/one/</d:href><d:status>HTTP/1.1 507 Insufficient Storage</d:status></d:response><d:sync-token>page1</d:sync-token>")
        let body = DAVSyncScenario.multistatus(DAVSyncScenario.prop("/one/series.ics", "<d:getetag>e2</d:getetag><c:calendar-data>" + Self.body() + "</c:calendar-data>"))
        let configuration = ScriptedDAVProtocol.install(host: host, responses: discovery + [
            .init(body: page), .init(body: body), .init(status: 503, body: "later page unavailable")])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: configuration, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)),
            inboundSave: { context in
                if failSave { throw ObservationSaveFailure() }
                try context.save()
            })
        _ = await engine.performBackgroundSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container, reconcileNotifications: false)
        let resourceScope = try #require(TaskPhotoOwnership.Scope(list: list))
        #expect(try SyncResourceState.read(scope: resourceScope, href: "/one/series.ics", in: ModelContext(container))?.shape == (failSave ? .singleTask : .unsupported))
        #expect(try SyncImportCheckpoint.read(id: key, scope: scope, in: ModelContext(container))?.token == (failSave ? "old" : "page1"))
        #expect(try SyncImportCheckpoint.accountedETags(id: key, container: container)["/one/series.ics"] == (failSave ? nil : "e2"))
        let final = DAVSyncScenario.multistatus("<d:sync-token>final</d:sync-token>")
        _ = ScriptedDAVProtocol.install(host: host, responses: discovery + (failSave ? [.init(body: page), .init(body: body)] : []) + [.init(body: final)])
        let retry = SyncEngine(calDAVClient: CalDAVClient(configuration: configuration, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let outcome = await retry.performBackgroundSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container, reconcileNotifications: false)
        #expect(outcome.status == .completed)
        #expect(try SyncImportCheckpoint.read(id: key, scope: scope, in: ModelContext(container))?.token == "final")
        let report = try #require(ScriptedDAVProtocol.requests(host: host).first { $0.method == "REPORT" })
        #expect(String(decoding: report.body, as: UTF8.self).contains("<d:sync-token>" + (failSave ? "old" : "page1") + "</d:sync-token>"))
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.id == task.id)
    }

    @Test("Late PUT advances an existing exact source tombstone", arguments: ["accepted-e2", ""])
    func latePutAdvancesExistingCleanup(etag: String) throws {
        let (container, account, source, task) = try remoteFixture(host: "existing-cleanup.invalid")
        let context = container.mainContext
        let snapshot = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: source.serverURL, container: container))
        let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        context.insert(destination); destination.account = account
        #expect(TaskMover.move(task, to: destination, in: context).count == 1)
        try context.save()
        try TaskListHelpers.settlePendingMoves(beforeDeleting: destination, in: context)
        context.delete(destination); try context.save()
        let cleanupID = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.id)
        try SyncPushAcknowledgement.acknowledge(snapshot, etag: etag, container: container)
        let fresh = ModelContext(container)
        let cleanup = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(cleanup.id == cleanupID && cleanup.isDeletedLocally && cleanup.etag == etag)
        let capture = try #require(try SyncResourceState.read(key: SyncResourceState.cleanupPrefix + cleanupID, in: fresh))
        #expect(capture.etag == etag)
        #expect(capture.expectedBodyDigest == (etag.isEmpty ? SyncResourceState.fingerprint(snapshot.payload) : nil))
        #expect(cleanup.attachmentStateKnown == true)
    }

    @Test("Supported replacement UID holds an active older conditional baseline")
    func replacementUIDBlocksRetainedBaseline() throws {
        let (container, _, list, task) = try remoteFixture(host: "replacement.invalid")
        let resource = try SyncBodyValidation.parse(.init(href: "/one/series.ics", etag: "e2",
            icsData: "BEGIN:VTODO\nUID:replacement\nSUMMARY:Different task\nEND:VTODO"), using: .init())
        _ = try SyncInboundBatchWriter(container: container, listID: list.id).apply([resource])
        #expect(throws: SyncResourceState.Hold.self) {
            try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: list.serverURL, container: container)
        }
        let original = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first { $0.id == task.id })
        #expect(original.title == "Local edit" && original.etag == "e1" && original.isDirty)
    }

    @Test("An observed source body retries after the pending main-context edit saves")
    func pendingEditDoesNotConsumeSourceRecovery() throws {
        let (container, account, source, task) = try remoteFixture(host: "pending-recovery.invalid")
        let context = container.mainContext
        let snapshot = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: source.serverURL, container: container))
        let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        context.insert(destination); destination.account = account
        #expect(TaskMover.move(task, to: destination, in: context).count == 1)
        try context.save()
        try SyncPushAcknowledgement.acknowledge(snapshot, etag: "", container: container)
        let request = try #require(try TaskPhotoLegacyCatchUp.requestInfo(taskID: task.id, listID: destination.id,
            accountID: account.id, container: container))
        let scope = try #require(request.photoScope)
        let parsed = try SyncBodyValidation.parse(.init(href: snapshot.path, etag: "e2", icsData: snapshot.payload), using: .init())
        task.title = "Unsaved newer title"
        _ = try TaskPhotoLegacyCatchUp.accept(parsed, taskID: task.id, listID: destination.id,
            accountID: account.id, expectedRequest: request, responseScope: scope, container: container)
        let first = ModelContext(container)
        #expect(try SyncResourceState.read(scope: scope, href: snapshot.path, in: first)?.etag == "e2")
        #expect(try SyncResourceState.read(key: SyncResourceState.movePrefix + task.id, in: first)?.etag == "")
        try context.save()
        let retry = try #require(try TaskPhotoLegacyCatchUp.requestInfo(taskID: task.id, listID: destination.id,
            accountID: account.id, container: container))
        _ = try TaskPhotoLegacyCatchUp.accept(parsed, taskID: task.id, listID: destination.id,
            accountID: account.id, expectedRequest: retry, responseScope: scope, container: container)
        let fresh = ModelContext(container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "Unsaved newer title" && stored.isDirty)
        #expect(try SyncResourceState.sourceProof(stored, in: fresh)?.etag == "e2")
    }

    @Test("Empty-ACK recovery rejects missing or mismatched capture UID", arguments: [false, true])
    func emptyCaptureUIDMustMatch(missing: Bool) throws {
        let (container, account, source, task) = try remoteFixture(host: "capture-uid.invalid")
        let context = container.mainContext
        let snapshot = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: source.serverURL, container: container))
        let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        context.insert(destination); destination.account = account
        #expect(TaskMover.move(task, to: destination, in: context).count == 1)
        try context.save()
        try SyncPushAcknowledgement.acknowledge(snapshot, etag: "", container: container)
        let corrupt = ModelContext(container)
        let key = SyncResourceState.movePrefix + task.id
        var capture = try #require(try SyncResourceState.read(key: key, in: corrupt))
        capture.uid = missing ? nil : "different-task"
        try capture.store(in: corrupt, key: key); try corrupt.save()
        let request = try #require(try TaskPhotoLegacyCatchUp.requestInfo(taskID: task.id,
            listID: destination.id, accountID: account.id, container: container))
        let parsed = try SyncBodyValidation.parse(.init(href: snapshot.path, etag: "e2", icsData: snapshot.payload), using: .init())
        let scope = try #require(request.photoScope)
        #expect(throws: SyncResourceState.Hold.self) {
            try TaskPhotoLegacyCatchUp.accept(parsed, taskID: task.id, listID: destination.id,
                accountID: account.id, expectedRequest: request, responseScope: scope, container: container)
        }
        #expect(try SyncResourceState.read(key: key, in: ModelContext(container)) == capture)
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.pendingMoveFromHref == snapshot.path && stored.taskList?.id == destination.id && stored.isDirty)
    }

    @Test("Legacy relative task members use the collection proof target on the wire", arguments: ["GET", "PUT", "DELETE", "MOVE"])
    func relativeMemberUsesScopedWireTarget(method: String) async throws {
        let host = "relative-member-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, _, task) = try remoteFixture(host: host)
        let context = container.mainContext
        task.remoteHref = "series.ics"
        if method == "DELETE" { task.isDeletedLocally = true }
        if method == "MOVE" {
            let vaultAccount = ServerAccount(vaultDisplayName: "Vault"); context.insert(vaultAccount)
            let vault = TaskList(serverURL: "", name: "Vault", colorHex: "#007AFF"); context.insert(vault); vault.account = vaultAccount
            #expect(TaskMover.move(task, to: vault, in: context).count == 1)
        }
        if method == "GET" {
            task.attachmentStateKnown = nil
            try VTODOOpaqueState.remove(tasks: [task], in: context)
        }
        try context.save()
        let sourceBody = "BEGIN:VTODO\nUID:series\nSUMMARY:Scoped source\nEND:VTODO"
        // Both /series.ics and /one/series.ics could have E1. Proof must select
        // the collection member before the first request, without a redirect.
        let responses: [ScriptedDAVProtocol.Response] = (method == "GET" ? [.init(status: 200, body: sourceBody, headers: ["ETag": "e1"])] : [])
            + [.init(status: 204, body: "", headers: ["ETag": "e2"])]
        let config = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + responses)
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        let requests = ScriptedDAVProtocol.requests(host: host).filter { ["GET", "PUT", "DELETE"].contains($0.method) }
        #expect(requests.contains { $0.method == (method == "MOVE" ? "DELETE" : method) })
        #expect(requests.allSatisfy { $0.path == "/one/series.ics" })
        #expect(requests.filter { $0.method != "GET" }.allSatisfy { $0.ifMatch == "\"e1\"" })
    }

    @Test("A live parent holds source cleanup for an ordinary unsupported child tombstone")
    func ordinarySourceChildHoldsLiveParent() async throws {
        let (container, _, source, parent) = try remoteFixture(host: "ordinary-child.invalid")
        let context = container.mainContext
        let child = TaskItem(uid: "child", title: "Deleted child")
        context.insert(child); child.taskList = source; child.parentTask = parent; child.parentUID = parent.uid
        child.remoteHref = "/one/child.ics"; child.etag = "child-e1"; child.isLocalOnly = false
        child.attachmentStateKnown = true; child.isDeletedLocally = true
        try VTODOOpaqueState.empty.store(taskID: child.id, in: context)
        try SyncResourceFixture.prove(child, in: context)
        let unsupported = try SyncBodyValidation.parse(.init(href: "/one/child.ics", etag: "child-e2", icsData: Self.body()), using: .init())
        try SyncResourceState.observe(unsupported, scope: try #require(TaskPhotoOwnership.Scope(list: source)), in: context)
        let vault = TaskList(serverURL: "", name: "Vault", colorHex: "#007AFF"); context.insert(vault)
        #expect(TaskMover.move(parent, to: vault, in: context).count == 1)
        try context.save()
        let fresh = ModelContext(container)
        var requests: [String] = []
        _ = await PendingMoveSweep.run(PendingMoveSweep.candidates(sourceListIDs: [source.id], in: fresh), in: fresh) {
            requests.append($0.sourceHref)
        }
        #expect(requests.isEmpty)
        let stored = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(stored.first { $0.id == parent.id }?.pendingMoveFromHref == "/one/series.ics")
        #expect(stored.first { $0.id == child.id }?.taskList?.id == source.id)
    }

    @Test("Deleted move keeps source and accepted destination cleanup independent", arguments: [false, true])
    func destinationACKDoesNotReplaceSourceCapture(emptyETag: Bool) async throws {
        let host = "two-obligations-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, source, task) = try remoteFixture(host: host)
        let context = container.mainContext
        let photo = TaskPhoto(previewData: TaskPhotoJPEGFixture.data); context.insert(photo); photo.task = task
        photo.originalFileID = "901"; photo.folderFileID = "900"
        try acceptPhotoOriginal(photo, in: context)
        let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        context.insert(destination); destination.account = account
        #expect(TaskMover.move(task, to: destination, in: context).count == 1)
        try acceptPhotoOriginal(photo, fileID: "902", folderID: "910", in: context)
        try context.save()
        let sent = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: destination.serverURL, container: container))
        task.isDeletedLocally = true; try context.save()
        try SyncPushAcknowledgement.acknowledge(sent, etag: emptyETag ? "" : "destination-e9", container: container)
        let first = ModelContext(container)
        let stored = try #require(try first.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(try SyncResourceState.sourceProof(stored, in: first)?.etag == "e1")
        #expect(try SyncPushAcknowledgement.deletionSnapshot(taskID: task.id, container: container) == nil)
        let config = ScriptedDAVProtocol.install(host: host, responses: [.init(status: 204, body: "")]
            + (emptyETag ? [.init(status: 200, body: sent.payload, headers: ["ETag": "destination-e9"])] : [])
            + [.init(status: 204, body: "")])
        let client = CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0))
        _ = await PendingMoveSweep.run(PendingMoveSweep.candidates(sourceListIDs: [source.id], in: first), in: first) { snapshot in
            try await client.deleteTask(baseURL: account.serverBaseURL, taskPath: snapshot.sourceProof.href,
                etag: snapshot.sourceProof.etag, credentials: .init(username: "fixture", password: "fixture")) {
                    try await SyncMoveAcknowledgement.validateDeletion(snapshot, container: container)
                }
        }
        let afterSource = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(afterSource.pendingMoveFromHref == nil && afterSource.isDeletedLocally)
        #expect(afterSource.photos.first?.previousOriginalFileID == "901" && afterSource.photos.first?.originalFileID == "902")
        if emptyETag {
            let request = try #require(try TaskPhotoLegacyCatchUp.requestInfo(taskID: task.id, listID: destination.id,
                accountID: account.id, container: container))
            let remote = try await client.fetchTask(baseURL: account.serverBaseURL, taskPath: request.href,
                credentials: .init(username: "fixture", password: "fixture"))
            _ = try TaskPhotoLegacyCatchUp.accept(try SyncBodyValidation.parse(remote, using: .init()), taskID: task.id,
                listID: destination.id, accountID: account.id, expectedRequest: request,
                responseScope: try #require(request.photoScope), container: container)
        }
        let deletion = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: task.id, container: container))
        #expect(deletion.etag == "destination-e9")
        try await client.deleteTask(baseURL: account.serverBaseURL, taskPath: try #require(deletion.href), etag: deletion.etag,
            credentials: .init(username: "fixture", password: "fixture")) {
                try await SyncPushAcknowledgement.validateDeletion(deletion, container: container)
            }
        _ = try SyncPushAcknowledgement.acknowledgeDeletion(deletion, container: container)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 0)
        let deletes = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "DELETE" }
        #expect(deletes.map(\.path) == ["/one/series.ics", "/two/series.ics"])
        #expect(deletes.map(\.ifMatch) == ["\"e1\"", "\"destination-e9\""])
        let queue = try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>()).filter { $0.id.hasPrefix(TaskPhotoCleanupQueue.prefix) }
        #expect(queue.count == 2)
    }

    @Test("Retained source revision cannot authorize a UI move or new destination copy", arguments: [false, true])
    func retainedSourceCannotCreateDestination(alreadyMoved: Bool) async throws {
        let host = "retained-source-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, source, task) = try remoteFixture(host: host)
        let context = container.mainContext
        let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        context.insert(destination); destination.account = account
        destination.syncCTag = "c1"; destination.lastFullPullDate = Date()
        SyncEngine.markCategoriesCaughtUp(listID: destination.id)
        try DAVSyncScenario.seedRecentCheckpoint(for: destination, in: container)
        if alreadyMoved { #expect(TaskMover.move(task, to: destination, in: context).count == 1) }
        try context.save()
        let newer = try SyncBodyValidation.parse(.init(href: "/one/series.ics", etag: "e2",
            icsData: "BEGIN:VTODO\nUID:series\nSUMMARY:Newer source\nX-PROVIDER:keep\nEND:VTODO"), using: .init())
        _ = try SyncInboundBatchWriter(container: container, listID: source.id).apply([newer])
        if !alreadyMoved {
            #expect(TaskMover.move(task, to: destination, in: context).isEmpty)
            #expect(task.taskList?.id == source.id && task.pendingMoveFromHref == nil && task.remoteHref == "/one/series.ics")
        } else {
            #expect(throws: SyncResourceState.Hold.self) {
                try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: destination.serverURL, container: container)
            }
            let config = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/", "/two/"]) + [
                .init(status: 201, body: "", headers: ["ETag": "unwanted-copy"]), .init(status: 412, body: "")])
            let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
            _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
                credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
            #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "PUT" || $0.method == "DELETE" })
            let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
            #expect(stored.isDirty && stored.remoteHref == nil && stored.pendingMoveFromHref == "/one/series.ics")
        }
    }

    @Test("An ETag-less source GET stays eligible after retaining attachments")
    func sourceGETWithoutETagRetriesWithUnchangedCTag() async throws {
        let host = "source-get-etag-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, _, task) = try remoteFixture(host: host)
        let context = container.mainContext
        let vaultAccount = ServerAccount(vaultDisplayName: "Vault"); context.insert(vaultAccount)
        let vault = TaskList(serverURL: "", name: "Vault", colorHex: "#007AFF"); context.insert(vault); vault.account = vaultAccount
        #expect(TaskMover.move(task, to: vault, in: context).count == 1)
        task.attachmentStateKnown = nil
        try VTODOOpaqueState.remove(tasks: [task], in: context); try context.save()
        let body = "BEGIN:VTODO\nUID:series\nSUMMARY:Source\nEND:VTODO"
        let config = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [.init(status: 200, body: body)])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "DELETE" })
        _ = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
            .init(status: 200, body: body, headers: ["ETag": "e1"]), .init(status: 204, body: "")])
        _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        let requests = ScriptedDAVProtocol.requests(host: host).filter { ["GET", "DELETE"].contains($0.method) }
        #expect(requests.map(\.method) == ["GET", "DELETE"])
        #expect(requests.last?.ifMatch == "\"e1\"")
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.pendingMoveFromHref == nil)
    }

    @Test("Retained conditional deletion preserves normal deltas and unchanged-CTag shortcuts")
    func retainedConditionalRevisionDoesNotForceIntegrity() async throws {
        let host = "retained-delta-" + UUID().uuidString.lowercased() + ".invalid"
        let (container, account, list, task) = try remoteFixture(host: host)
        task.isDeletedLocally = true; try container.mainContext.save()
        let remote = CalDAVClient.RemoteTask(href: "/one/series.ics", etag: "e2", icsData: "BEGIN:VTODO\nUID:series\nSUMMARY:Remote newer\nEND:VTODO")
        _ = try SyncInboundBatchWriter(container: container, listID: list.id).apply([try SyncBodyValidation.parse(remote, using: .init())])
        let scope = SyncCollectionPuller.Scope(accountID: account.id, listID: list.id, historyScope: "0")
        let key = SyncImportCheckpoint.identity(accountID: account.id, listID: list.id, baseURL: account.serverBaseURL, username: account.username, months: 0)
        try SyncImportCheckpoint.markAccounted([remote], id: key, container: container)
        try SyncImportCheckpoint.commit(.init(scope: scope, token: "observed", ctag: "c1", lastIntegrity: Date(), hasCompletedBaseline: true),
            id: key, collectionPath: list.serverURL, container: container)
        var discovery = DAVSyncScenario.discovery(paths: ["/one/"])
        discovery[2].body = discovery[2].body.replacingOccurrences(of: "<cs:getctag>c1</cs:getctag>",
            with: "<d:supported-report-set><d:supported-report><d:report><d:sync-collection/></d:report></d:supported-report></d:supported-report-set><d:sync-token>server</d:sync-token><cs:getctag>c2</cs:getctag>")
        let page = DAVSyncScenario.multistatus(DAVSyncScenario.prop("/one/ordinary.ics", "<d:getetag>o1</d:getetag>") + "<d:sync-token>page2</d:sync-token>")
        let bodies = DAVSyncScenario.multistatus(DAVSyncScenario.prop("/one/ordinary.ics", "<d:getetag>o1</d:getetag><c:calendar-data>BEGIN:VTODO\nUID:ordinary\nSUMMARY:Unrelated\nEND:VTODO</c:calendar-data>"))
        let config = ScriptedDAVProtocol.install(host: host, responses: discovery + [.init(body: page), .init(body: bodies), .init(status: 412, body: "")])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        let firstReport = try #require(ScriptedDAVProtocol.requests(host: host).first { $0.method == "REPORT" })
        #expect(String(decoding: firstReport.body, as: UTF8.self).contains("sync-collection"))
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).contains { $0.uid == "ordinary" })
        // Advertised sync-collection deliberately polls an empty delta even with
        // unchanged CTag. It must not become an integrity manifest or body fetch.
        _ = ScriptedDAVProtocol.install(host: host, responses: discovery + [
            .init(body: DAVSyncScenario.multistatus("<d:sync-token>page3</d:sync-token>")), .init(status: 412, body: "")])
        _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        let requests = ScriptedDAVProtocol.requests(host: host)
        let reports = requests.filter { $0.method == "REPORT" }
        #expect(reports.count == 1 && reports.allSatisfy { String(decoding: $0.body, as: UTF8.self).contains("sync-collection") })
        #expect(!requests.contains { $0.method == "PROPFIND" && $0.path == "/one/" })
        #expect(requests.filter { $0.method == "DELETE" }.map(\.ifMatch) == ["\"e1\""])
        let ctagOnly = DAVSyncScenario.discovery(paths: ["/one/"]).map { response in
            var result = response
            result.body = result.body.replacingOccurrences(of: "<cs:getctag>c1</cs:getctag>", with: "<cs:getctag>c2</cs:getctag>")
            return result
        }
        _ = ScriptedDAVProtocol.install(host: host, responses: ctagOnly + [.init(status: 412, body: "")])
        _ = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        let ctagRequests = ScriptedDAVProtocol.requests(host: host)
        #expect(!ctagRequests.contains { $0.method == "REPORT" || ($0.method == "PROPFIND" && $0.path == "/one/") })
        #expect(ctagRequests.filter { $0.method == "DELETE" }.map(\.ifMatch) == ["\"e1\""])
    }


    @Test("Canonical late source ACK advances only its existing raw obligation", arguments: ["relative", "absolute"], [false, true])
    func aliasedLateSourceACK(style: String, transferred: Bool) async throws {
        for returnedETag in ["e2", ""] {
            let host = "alias-ack-" + UUID().uuidString.lowercased() + ".invalid"
            let (container, account, source, task) = try remoteFixture(host: host)
            let context = container.mainContext
            let rawHref = style == "relative" ? "series.ics" : account.serverBaseURL + "/one/series.ics"
            task.remoteHref = rawHref
            let photo = TaskPhoto(previewData: TaskPhotoJPEGFixture.data); context.insert(photo); photo.task = task
            photo.originalFileID = "901"; photo.folderFileID = "900"
            try acceptPhotoOriginal(photo, in: context)
            try context.save()
            let sent = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: source.serverURL, container: container))
            let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
            context.insert(destination); destination.account = account
            #expect(TaskMover.move(task, to: destination, in: context).count == 1)
            if !transferred { try acceptPhotoOriginal(photo, fileID: "902", folderID: "910", in: context) }
            try context.save()
            if transferred {
                try TaskListHelpers.settlePendingMoves(beforeDeleting: destination, in: context)
                context.delete(destination); try context.save()
            }
            let before = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
            let obligationID = before.id
            try SyncPushAcknowledgement.acknowledge(sent, etag: returnedETag, container: container)
            let fresh = ModelContext(container)
            let rows = try fresh.fetch(FetchDescriptor<TaskItem>())
            #expect(rows.count == 1, "The same source must not become a second cleanup row")
            let stored = try #require(rows.first { $0.id == obligationID })
            #expect((transferred ? stored.remoteHref : stored.pendingMoveFromHref) == rawHref)
            let captureKey = (transferred ? SyncResourceState.cleanupPrefix : SyncResourceState.movePrefix) + obligationID
            let capture = try #require(try SyncResourceState.read(key: captureKey, in: fresh))
            #expect(capture.etag == returnedETag && capture.href == sent.path && capture.uid == sent.uid)
            #expect(capture.expectedBodyDigest == (returnedETag.isEmpty ? SyncResourceState.fingerprint(sent.payload) : nil))
            if !transferred {
                #expect(stored.photos.first?.previousOriginalFileID == "901")
                #expect(stored.photos.first?.originalFileID == "902")
                #expect(stored.remoteHref == nil && stored.isDirty)
                var earlyDeletes: [String] = []
                _ = await PendingMoveSweep.run(PendingMoveSweep.candidates(sourceListIDs: [source.id], in: fresh), in: fresh) {
                    earlyDeletes.append($0.sourceProof.href)
                }
                for row in rows where row.isDeletedLocally {
                    if let deletion = try SyncPushAcknowledgement.deletionSnapshot(taskID: row.id, container: container) {
                        earlyDeletes.append(try #require(deletion.resourceProof).href)
                    }
                }
                #expect(earlyDeletes.isEmpty, "No source deletion before destination acceptance")
            }
            let config = ScriptedDAVProtocol.install(host: host, responses:
                (returnedETag.isEmpty ? [.init(status: 200, body: sent.payload, headers: ["ETag": "e2"])] : [])
                + (transferred ? [] : [.init(status: 201, body: "", headers: ["ETag": "destination-e9"])])
                + [.init(status: 204, body: "")])
            let client = CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0))
            if returnedETag.isEmpty {
                let request = try #require(try TaskPhotoLegacyCatchUp.requestInfo(taskID: obligationID,
                    listID: transferred ? source.id : destination.id, accountID: account.id, container: container))
                let scope = try #require(request.photoScope)
                let remote = try await client.fetchTask(baseURL: account.serverBaseURL,
                    taskPath: SyncResourceState.canonical(request.href, scope: scope), credentials: .init(username: "fixture", password: "fixture"))
                _ = try TaskPhotoLegacyCatchUp.accept(try SyncBodyValidation.parse(remote, using: .init()), taskID: obligationID,
                    listID: transferred ? source.id : destination.id, accountID: account.id,
                    expectedRequest: request, responseScope: scope, container: container)
            }
            if transferred {
                let deletion = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: obligationID, container: container))
                #expect(deletion.etag == "e2")
                try await client.deleteTask(baseURL: account.serverBaseURL, taskPath: try #require(deletion.resourceProof).href,
                    etag: deletion.etag, credentials: .init(username: "fixture", password: "fixture")) {
                        try await SyncPushAcknowledgement.validateDeletion(deletion, container: container)
                    }
                _ = try SyncPushAcknowledgement.acknowledgeDeletion(deletion, container: container)
            } else {
                let destinationSent = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id,
                    calendarPath: destination.serverURL, container: container))
                let destinationScope = try #require(destinationSent.photoScope)
                let etag = try await client.putTask(baseURL: account.serverBaseURL, taskPath: destinationSent.path,
                    icsData: destinationSent.payload, etag: destinationSent.etag, credentials: .init(username: "fixture", password: "fixture")) {
                        try await SyncPushAcknowledgement.validateWrite(destinationSent, container: container, responseScope: destinationScope)
                    }
                try SyncPushAcknowledgement.acknowledge(destinationSent, etag: etag, container: container)
                let ready = ModelContext(container)
                _ = await PendingMoveSweep.run(PendingMoveSweep.candidates(sourceListIDs: [source.id], in: ready), in: ready) { snapshot in
                    try await client.deleteTask(baseURL: account.serverBaseURL, taskPath: snapshot.sourceProof.href,
                        etag: snapshot.sourceProof.etag, credentials: .init(username: "fixture", password: "fixture")) {
                            try await SyncMoveAcknowledgement.validateDeletion(snapshot, container: container)
                        }
                }
            }
            let writes = ScriptedDAVProtocol.requests(host: host).filter { ["PUT", "DELETE"].contains($0.method) }
            #expect(writes.map(\.method) == (transferred ? ["DELETE"] : ["PUT", "DELETE"]))
            #expect(writes.last?.path == "/one/series.ics" && writes.last?.ifMatch == "\"e2\"")
        }
    }

    @Test("Classification reads scale with proof batches, not the offline edit backlog")
    func classificationBatchesOnlyMismatchedCaptures() throws {
        let (container, _, list, _) = try remoteFixture(host: "classification-reads.invalid")
        let context = container.mainContext
        let scope = try #require(TaskPhotoOwnership.Scope(list: list))
        for index in 0..<325 {
            let task = TaskItem(uid: "backlog-\(index)", title: "Offline edit")
            context.insert(task); task.taskList = list; task.remoteHref = "/one/\(task.uid).ics"
            task.etag = "e1"; task.isDirty = true; task.isDeletedLocally = index % 2 == 0
            let state = SyncResourceState(scope: scope, href: task.remoteHref!, etag: index < 200 ? "e1" : "e2",
                shape: .singleTask, originalBody: nil, uid: task.uid)
            try state.store(in: context)
            if index >= 200 {
                let capture = SyncResourceState(scope: scope, href: state.href, etag: "e1",
                    shape: .singleTask, originalBody: nil, uid: task.uid)
                try capture.store(in: context, key: SyncResourceState.cleanupPrefix + task.id)
            }
        }
        try context.save()
        var reads = 0
        let needed = try SyncResourceState.needsClassification(list: list, in: ModelContext(container)) { container in
            reads += 1
            return ModelContext(container)
        }
        #expect(needed.isEmpty)
        #expect(reads <= 6, "326 generic proofs (four batches) + 125 mismatched captures (two batches)")
        let exact = TaskList(serverURL: "/exact/", name: "Exact", colorHex: "#007AFF")
        context.insert(exact); exact.account = list.account
        for index in 0..<100 {
            let task = TaskItem(uid: "exact-\(index)", title: "Offline")
            context.insert(task); task.taskList = exact; task.remoteHref = "/exact/\(task.uid).ics"
            task.etag = "e1"; task.isDirty = true
            try SyncResourceFixture.prove(task, in: context)
        }
        try context.save(); reads = 0
        #expect(try SyncResourceState.needsClassification(list: exact, in: ModelContext(container)) { container in
            reads += 1; return ModelContext(container)
        }.isEmpty)
        #expect(reads == 1, "Exact revisions need no per-task context or capture lookup")
    }

    @Test("Source descendant reads exclude unrelated collection rows and remain fresh")
    func sourceDescendantReadsAreTargeted() throws {
        let (container, _, source, parent) = try remoteFixture(host: "descendant-reads.invalid")
        let context = container.mainContext
        for index in 0..<250 {
            let unrelated = TaskItem(uid: "unrelated-\(index)", title: "Other task")
            context.insert(unrelated); unrelated.taskList = source; unrelated.remoteHref = "/one/\(unrelated.uid).ics"
        }
        let vault = TaskList(serverURL: "", name: "Vault", colorHex: "#007AFF"); context.insert(vault)
        #expect(TaskMover.move(parent, to: vault, in: context).count == 1)
        try context.save()
        func check() throws -> (Bool, [Int]) {
            let fresh = ModelContext(container)
            let id = parent.id
            let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
            var fetched: [Int] = []
            let held = try SyncMoveAcknowledgement.hasRemainingSourceDescendant(of: stored, sourceListID: source.id,
                in: fresh, main: context, didFetch: { fetched.append($0) })
            return (held, fetched)
        }
        let leaf = try check()
        #expect(!leaf.0 && leaf.1.reduce(0, +) == 0)
        let bridge = TaskItem(uid: "bridge", title: "Already delivered")
        context.insert(bridge); bridge.taskList = vault; bridge.parentTask = parent; bridge.parentUID = parent.uid
        let descendant = TaskItem(uid: "descendant", title: "Held source child")
        context.insert(descendant); descendant.taskList = source; descendant.parentTask = bridge; descendant.parentUID = bridge.uid
        descendant.remoteHref = "/one/descendant.ics"; descendant.isDeletedLocally = true
        try context.save()
        let deep = try check()
        #expect(deep.0 && deep.1.reduce(0, +) <= 4 && deep.1.allSatisfy { $0 <= 100 })
        descendant.remoteHref = nil; try context.save()
        #expect(try check().0 == false)
        let pendingGrandchild = TaskItem(uid: "pending-grandchild", title: "Unsaved descendant")
        context.insert(pendingGrandchild); pendingGrandchild.taskList = source; pendingGrandchild.parentUID = bridge.uid
        pendingGrandchild.remoteHref = "/one/pending-grandchild.ics"
        #expect(try check().0, "Unsaved unresolved links are checked below delivered intermediate children")
        context.delete(pendingGrandchild); try context.save()
        let unresolved = TaskItem(uid: "unresolved", title: "Held unresolved source child")
        context.insert(unresolved); unresolved.taskList = source; unresolved.parentUID = parent.uid
        unresolved.remoteHref = "/one/unresolved.ics"; unresolved.isDeletedLocally = true
        #expect(try check().0, "Unsaved main-context UID links hold admission")
        try context.save()
        let linked = try check()
        #expect(linked.0 && linked.1.reduce(0, +) <= 3)
        // Another collection's unresolved UID is not this source's descendant.
        unresolved.taskList = TaskList(serverURL: "/other/", name: "Other", colorHex: "#007AFF")
        try context.save()
        #expect(try check().0 == false)
        let otherParent = TaskItem(uid: "different-parent", title: "Stale local parent")
        context.insert(otherParent); otherParent.taskList = unresolved.taskList
        unresolved.taskList = source; unresolved.parentTask = otherParent
        try context.save()
        #expect(try check().0, "The server parent UID still names the source even if local resolution disagrees")
        unresolved.taskList = otherParent.taskList; try context.save()
        for index in 0..<125 {
            let delivered = TaskItem(uid: "delivered-\(index)", title: "Delivered child")
            context.insert(delivered); delivered.taskList = vault; delivered.parentTask = parent; delivered.parentUID = parent.uid
            if index == 124 {
                let held = TaskItem(uid: "deep-page", title: "Held grandchild")
                context.insert(held); held.taskList = source; held.remoteHref = "/one/deep-page.ics"
                held.parentTask = delivered; held.parentUID = delivered.uid
            }
        }
        try context.save()
        let paged = try check()
        #expect(paged.0 && paged.1.allSatisfy { $0 <= 100 })
        #expect(paged.1.reduce(0, +) < 300, "Only subtree rows, including any repeated UID matches, are materialized")
    }


    @Test("Canonical source identity does not bypass raw marker or captured operation freshness", arguments: ["pending-alias", "saved-alias", "revision", "uid", "account"])
    func aliasedACKKeepsFreshOperationGuards(change: String) throws {
        let (container, account, source, task) = try remoteFixture(host: "alias-freshness.invalid")
        let context = container.mainContext
        task.remoteHref = "series.ics"; try context.save()
        let sent = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: source.serverURL, container: container))
        let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        context.insert(destination); destination.account = account
        #expect(TaskMover.move(task, to: destination, in: context).count == 1)
        try context.save()
        let key = SyncResourceState.movePrefix + task.id
        let original = try #require(try SyncResourceState.read(key: key, in: context))
        var expected = original
        if change == "pending-alias" || change == "saved-alias" {
            task.pendingMoveFromHref = "/one/series.ics"
        } else if change == "revision" {
            expected = SyncResourceState(scope: original.scope, href: original.href, etag: "later-operation",
                shape: .singleTask, originalBody: nil, uid: original.uid)
            try expected.store(in: context, key: key)
        } else if change == "uid" { task.uid = "replacement" }
        else { account.username = "other" }
        if change != "pending-alias" { try context.save() }
        if change == "account" {
            #expect(throws: SyncResourceState.Hold.self) { try SyncPushAcknowledgement.acknowledge(sent, etag: "old-ack", container: container) }
        } else { try SyncPushAcknowledgement.acknowledge(sent, etag: "old-ack", container: container) }
        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<TaskItem>()) == 1)
        #expect(try SyncResourceState.read(key: key, in: fresh) == expected)
        #expect(task.pendingMoveFromHref == (change.contains("alias") ? "/one/series.ics" : "series.ics"))
    }

}
