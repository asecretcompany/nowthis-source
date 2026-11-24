import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("SyncEngine large import integration", .serialized)
@MainActor
struct SyncLargeImportIntegrationTests {
    private let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")

    @Test("List discovery can succeed while the server blocks the task download")
    func methodNotAllowedAfterConnectionTest() async throws {
        let container = try DAVSyncScenario.container()
        let host = fixtureHost()
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let engine = makeEngine(host: host, responses: discovery(ctag: "c1") + [
            .init(body: DAVSyncScenario.manifest(count: 1)),
            .init(body: DAVSyncScenario.tasks(count: 1))
        ])
        let first = await run(engine, background: false, accountID: accountID, host: host, container: container)
        try #require(first.status == .completed && first.importedCount == 1)

        let listing = discovery(ctag: "c2")
        let config = ScriptedDAVProtocol.install(host: host, responses: listing + listing + [
            .init(status: 405, body: "")
        ])
        let connected = try await ServerURLValidator.testConnection(baseURL: "https://" + host,
            username: credentials.username, password: credentials.password, configuration: config)
        try #require(connected)
        let result = await run(engine, background: false, accountID: accountID, host: host, container: container)
        #expect(ScriptedDAVProtocol.requests(host: host).last?.method == "REPORT")
        #expect(result.status == .partial)
        let failure = try #require(result.failures.first)
        #expect(failure.httpStatusCode == 405)
        #expect(failure.message == SyncFailure.discoveryMessage(.methodNotAllowed))
        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(saved.map(\.uid) == ["fixture-0"])
    }

    // A foreground run proves the 10k case without the background runner's 25-second budget.
    // The background case still crosses two full batches and a final partial batch.
    @Test("Real engine imports exact counts, downloads no bodies for a no-op and one for one change",
          arguments: [false, true])
    func boundedImportAndIncrementalBodies(background: Bool) async throws {
        let count = background ? 201 : 10_000
        let container = try DAVSyncScenario.container()
        let host = fixtureHost()
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        var initial = discovery(ctag: "c1") + [.init(body: DAVSyncScenario.manifest(count: count))]
        for start in stride(from: 0, to: count, by: 100) {
            initial.append(.init(body: DAVSyncScenario.tasks(count: min(100, count - start), startIndex: start)))
        }
        let engine = makeEngine(host: host, responses: initial)
        let progress = await recordProgress(engine)
        defer { progress.cancel() }
        let first = await run(engine, background: background, accountID: accountID, host: host, container: container)

        #expect(first.status == .completed)
        #expect(first.failures.isEmpty)
        #expect(first.importedCount == count)
        #expect(first.updatedCount == 0)
        #expect(first.deletedCount == 0)
        #expect(first.pendingOutboundCount == 0)
        let read = ModelContext(container)
        let lists = try read.fetch(FetchDescriptor<TaskList>())
        #expect(lists.count == 1)
        let list = try #require(lists.first)
        #expect(first.changedListIDs == [list.id])
        let tasks = try read.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == count)
        #expect(Set(tasks.map(\.uid)) == Set((0..<count).map { "fixture-\($0)" }))
        #expect(Set(tasks.map(\.id)).count == count)
        #expect(tasks.allSatisfy { !$0.isDirty && !$0.isLocalOnly && $0.taskList?.id == list.id })
        let originalIDs = Set(tasks.map(\.id))
        let baselineCheckpoint = try #require(try checkpoint(accountID: accountID, listID: list.id,
            host: host, container: container))
        #expect(baselineCheckpoint.hasCompletedBaseline)
        #expect(baselineCheckpoint.ctag == "c1")
        let initialRequests = ScriptedDAVProtocol.requests(host: host)
        try expectDiscovery(initialRequests)
        let batches = reports(initialRequests, containing: "calendar-multiget")
        #expect(batches.count == (background ? 3 : 100))
        #expect(reports(initialRequests, containing: "calendar-query").count == 1)
        #expect(initialRequests.count == (background ? 7 : 104))
        let requested = try batches.flatMap(requestedHrefs)
        #expect(requested.count == count)
        #expect(Set(requested) == Set((0..<count).map { "/one/\($0).ics" }))
        for batch in batches {
            let hrefs = try requestedHrefs(batch)
            #expect(!hrefs.isEmpty && hrefs.count <= 100)
            #expect(batch.path == "/one")
            #expect(batch.ifMatch == nil)
        }
        try expectProgress(await progress.value, accountID: accountID, listID: list.id,
            completed: count, total: count, finished: true)
        #expect(await engine.pendingInboundRefresh)

        // An unconsumed refresh from the import must survive an unchanged run.
        _ = ScriptedDAVProtocol.install(host: host, responses: discovery(ctag: "c1"))
        let noOpProgress = await recordProgress(engine)
        defer { noOpProgress.cancel() }
        let noOp = await run(engine, background: background, accountID: accountID, host: host, container: container)
        #expect(noOp.status == .completed)
        #expect(noOp.importedCount == 0 && noOp.updatedCount == 0 && noOp.deletedCount == 0)
        #expect(noOp.changedListIDs.isEmpty)
        let noOpRequests = ScriptedDAVProtocol.requests(host: host)
        try expectDiscovery(noOpRequests)
        #expect(noOpRequests.count == 3)
        #expect(noOpRequests.allSatisfy { $0.method == "PROPFIND" })
        #expect((await noOpProgress.value).contains { $0 == nil })
        #expect(await engine.consumePendingInboundRefresh())
        #expect(!(await engine.consumePendingInboundRefresh()))
        #expect(try checkpoint(accountID: accountID, listID: list.id, host: host, container: container) == baselineCheckpoint)

        let changedIndex = count - 1
        let changedETag = "e\(changedIndex)-changed"
        let manifest = DAVSyncScenario.manifest(count: count).replacingOccurrences(
            of: "<d:getetag>e\(changedIndex)</d:getetag>", with: "<d:getetag>\(changedETag)</d:getetag>")
        let body = DAVSyncScenario.tasks(count: 1, startIndex: changedIndex)
            .replacingOccurrences(of: "<d:getetag>e\(changedIndex)</d:getetag>",
                with: "<d:getetag>\(changedETag)</d:getetag>")
            .replacingOccurrences(of: "Moon bakery delivery \(changedIndex)", with: "One changed delivery")
        _ = ScriptedDAVProtocol.install(host: host, responses: discovery(ctag: "c2")
            + [.init(body: manifest), .init(body: body)])
        let changedProgress = await recordProgress(engine)
        defer { changedProgress.cancel() }
        let changed = await run(engine, background: background, accountID: accountID, host: host, container: container)
        #expect(changed.status == .completed)
        #expect(changed.importedCount == 0)
        #expect(changed.updatedCount == 1)
        #expect(changed.deletedCount == 0)
        #expect(changed.changedListIDs == [list.id])
        let changedRequests = ScriptedDAVProtocol.requests(host: host)
        try expectDiscovery(changedRequests)
        #expect(changedRequests.count == 5)
        #expect(reports(changedRequests, containing: "calendar-query").count == 1)
        let changedBatches = reports(changedRequests, containing: "calendar-multiget")
        #expect(changedBatches.count == 1)
        #expect(try changedBatches.flatMap(requestedHrefs) == ["/one/\(changedIndex).ics"])
        let finalTasks = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(finalTasks.count == count)
        #expect(Set(finalTasks.map(\.id)) == originalIDs)
        let updated = try #require(finalTasks.first { $0.uid == "fixture-\(changedIndex)" })
        #expect(updated.title == "One changed delivery")
        #expect(updated.etag == changedETag)
        try expectProgress(await changedProgress.value, accountID: accountID, listID: list.id,
            completed: 1, total: 1, finished: true)
        #expect(await engine.consumePendingInboundRefresh())
        #expect(!(await engine.consumePendingInboundRefresh()))
        withExtendedLifetime(container) {}
    }

    @Test("Equal CTag cannot suppress a wider completed-history scope", arguments: [false, true])
    func unchangedCTagWidensHistory(background: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let host = fixtureHost()
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let manifest = DAVSyncScenario.manifest(count: 2)
        let oldCompletion = "STATUS:COMPLETED\nCOMPLETED:20000101T120000Z\n"
        let initialBodies = DAVSyncScenario.tasks(count: 2).replacingOccurrences(
            of: "SUMMARY:Moon bakery delivery 0\n", with: "SUMMARY:Moon bakery delivery 0\n" + oldCompletion)
        let oldBody = DAVSyncScenario.tasks(count: 1).replacingOccurrences(
            of: "SUMMARY:Moon bakery delivery 0\n", with: "SUMMARY:Moon bakery delivery 0\n" + oldCompletion)
        let engine = makeEngine(host: host, responses: discovery(ctag: "c1")
            + [.init(body: manifest), .init(body: initialBodies)])

        let narrow = await run(engine, background: background, accountID: accountID,
            host: host, container: container, months: 3)
        try #require(narrow.status == .completed && narrow.importedCount == 1)
        let initialRequests = ScriptedDAVProtocol.requests(host: host)
        try expectDiscovery(initialRequests)
        #expect(initialRequests.map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND", "REPORT", "REPORT"])
        #expect(initialRequests.dropFirst(3).map(\.path) == ["/one", "/one"])
        let initialReader = ModelContext(container)
        let listID = try #require(try initialReader.fetch(FetchDescriptor<TaskList>()).first?.id)
        let initialTasks = try initialReader.fetch(FetchDescriptor<TaskItem>())
        try #require(initialTasks.count == 1)
        let active = try #require(initialTasks.first)
        let activeID = active.id
        try #require(active.uid == "fixture-1")
        let narrowCheckpoint = try #require(try checkpoint(accountID: accountID, listID: listID,
            host: host, container: container, months: 3))
        try #require(narrowCheckpoint.hasCompletedBaseline && narrowCheckpoint.ctag == "c1")
        let narrowID = checkpointID(accountID: accountID, listID: listID, host: host, months: 3)
        let wideID = checkpointID(accountID: accountID, listID: listID, host: host)
        #expect(try SyncImportCheckpoint.accountedETags(id: narrowID, container: container) == [
            "/one/0.ics": "e0", "/one/1.ics": "e1"
        ])
        #expect(try checkpoint(accountID: accountID, listID: listID, host: host, container: container) == nil)

        _ = ScriptedDAVProtocol.install(host: host, responses: discovery(ctag: "c1")
            + [.init(body: manifest), .init(body: oldBody)])
        let wide = await run(engine, background: background, accountID: accountID,
            host: host, container: container, months: 0)
        #expect(wide.status == .completed && wide.failures.isEmpty)
        #expect(wide.importedCount == 1 && wide.updatedCount == 0 && wide.deletedCount == 0)
        #expect(wide.changedListIDs == [listID])
        let requests = ScriptedDAVProtocol.requests(host: host)
        try expectDiscovery(requests)
        #expect(requests.map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND", "REPORT", "REPORT"])
        #expect(requests.dropFirst(3).map(\.path) == ["/one", "/one"])
        let reportsInOrder = requests.dropFirst(3).map { String(decoding: $0.body, as: UTF8.self) }
        #expect(reportsInOrder.first?.contains("<c:calendar-query") == true)
        #expect(reportsInOrder.last?.contains("<c:calendar-multiget") == true)
        #expect(try reports(requests, containing: "calendar-multiget").flatMap(requestedHrefs) == ["/one/0.ics"])

        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(Set(saved.map(\.uid)) == ["fixture-0", "fixture-1"])
        #expect(saved.first { $0.uid == "fixture-1" }?.id == activeID)
        let history = saved.first { $0.uid == "fixture-0" }
        #expect(history?.status == .completed && history?.etag == "e0")
        #expect(history?.taskList?.id == listID && history?.isDirty == false)
        let wideCheckpoint = try checkpoint(accountID: accountID, listID: listID, host: host, container: container)
        #expect(wideCheckpoint?.hasCompletedBaseline == true && wideCheckpoint?.ctag == "c1")
        #expect(try SyncImportCheckpoint.accountedETags(id: wideID, container: container)["/one/0.ics"] == "e0")
        #expect(try checkpoint(accountID: accountID, listID: listID, host: host, container: container, months: 3) == nil)

        _ = ScriptedDAVProtocol.install(host: host, responses: discovery(ctag: "c1"))
        let unchanged = await run(engine, background: background, accountID: accountID,
            host: host, container: container, months: 0)
        #expect(unchanged.status == .completed && unchanged.changedListIDs.isEmpty)
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND"])
        #expect(try checkpoint(accountID: accountID, listID: listID, host: host, container: container) == wideCheckpoint)
        withExtendedLifetime(container) {}
    }

    @Test("Canonical receipt cannot mask missing shape for a same-ETag legacy href",
          arguments: ["relative", "absolute", "canonical"], [false, true])
    func sameETagReceiptStillRevalidatesLegacyShape(spelling: String, supportsToken: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let host = fixtureHost()
        let baseURL = "https://" + host
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let otherID = try DAVSyncScenario.account(in: container, host: host)
        let context = container.mainContext
        let accounts = try context.fetch(FetchDescriptor<ServerAccount>())
        let account = try #require(accounts.first { $0.id == accountID })
        let other = try #require(accounts.first { $0.id == otherID })
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        let otherList = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        context.insert(list); list.account = account
        context.insert(otherList); otherList.account = other
        list.syncCTag = "c1"; list.lastFullPullDate = Date()
        SyncEngine.markCategoriesCaughtUp(listID: list.id)

        let href = "/one/series.ics"
        let rawHref = switch spelling {
        case "relative": "series.ics"
        case "absolute": baseURL + href
        default: href
        }
        let task = TaskItem(uid: "series", title: "Saved title")
        context.insert(task); task.taskList = list
        task.remoteHref = rawHref; task.etag = "same"; task.isLocalOnly = false
        try VTODOOpaqueState.empty.store(taskID: task.id, in: context)
        let foreign = TaskItem(uid: task.uid, title: "Independent account")
        context.insert(foreign); foreign.taskList = otherList
        foreign.remoteHref = href; foreign.etag = "same"; foreign.isLocalOnly = false
        let shapeScope = try #require(TaskPhotoOwnership.Scope(list: list))
        let foreignScope = try #require(TaskPhotoOwnership.Scope(list: otherList))
        let foreignProof = SyncResourceState(scope: foreignScope, href: href, etag: "same",
            shape: .unsupported, originalBody: "Previously held unsupported body", uid: nil)
        try foreignProof.store(in: context)
        try context.save()

        let key = checkpointID(accountID: accountID, listID: list.id, host: host)
        let foreignKey = checkpointID(accountID: otherID, listID: otherList.id, host: host)
        let scope = SyncCollectionPuller.Scope(accountID: accountID, listID: list.id, historyScope: "0")
        let previous = SyncCollectionPuller.Checkpoint(scope: scope, token: supportsToken ? "old" : nil,
            ctag: "c1", lastIntegrity: Date().addingTimeInterval(-30), hasCompletedBaseline: true)
        try SyncImportCheckpoint.commit(previous, id: key, collectionPath: list.serverURL, container: container)
        let foreignCheckpoint = SyncCollectionPuller.Checkpoint(
            scope: .init(accountID: otherID, listID: otherList.id, historyScope: "0"),
            token: "foreign-token", ctag: "foreign", lastIntegrity: previous.lastIntegrity, hasCompletedBaseline: true)
        try SyncImportCheckpoint.commit(foreignCheckpoint, id: foreignKey,
            collectionPath: otherList.serverURL, container: container)
        try SyncImportCheckpoint.markAccounted([.init(href: href, etag: "same", icsData: "")], id: key, container: container)
        try SyncImportCheckpoint.markAccounted([.init(href: href, etag: "same", icsData: "")], id: foreignKey, container: container)

        try #require(SyncResourceState.canonical(rawHref, scope: shapeScope) == href)
        try #require(SyncResourceState.read(scope: shapeScope, href: href, in: ModelContext(container)) == nil)
        try #require(SyncImportCheckpoint.accountedETags(id: key, container: container) == [href: "same"])
        let member = "<d:getetag>same</d:getetag>"
        let body = "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VTODO\nUID:series\nSUMMARY:Saved title\nEND:VTODO\nEND:VCALENDAR"
        let engine = makeEngine(host: host, responses: discovery(ctag: "c1", token: supportsToken ? "observed" : nil)
            + [.init(body: DAVSyncScenario.multistatus(DAVSyncScenario.prop(href, member))),
               .init(body: DAVSyncScenario.multistatus(DAVSyncScenario.prop(href, member + "<c:calendar-data>" + body + "</c:calendar-data>")))])

        let outcome = await run(engine, background: false, accountID: accountID, host: host, container: container)
        #expect(outcome.status == .completed && outcome.failures.isEmpty)
        #expect(outcome.importedCount == 0 && outcome.deletedCount == 0 && outcome.pendingOutboundCount == 0)
        #expect(outcome.updatedCount == (spelling == "canonical" ? 0 : 1))
        #expect(outcome.changedListIDs == (spelling == "canonical" ? [] : [list.id]))
        let requests = ScriptedDAVProtocol.requests(host: host)
        try expectDiscovery(requests)
        #expect(requests.map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND", "REPORT", "REPORT"])
        #expect(requests.dropFirst(3).map(\.path) == ["/one", "/one"])
        let reportsInOrder = requests.dropFirst(3).map { String(decoding: $0.body, as: UTF8.self) }
        #expect(reportsInOrder.first?.contains("<c:calendar-query") == true)
        #expect(reportsInOrder.last?.contains("<c:calendar-multiget") == true)
        #expect(try reports(requests, containing: "calendar-multiget").flatMap(requestedHrefs) == [href])

        let fresh = ModelContext(container)
        let saved = try fresh.fetch(FetchDescriptor<TaskItem>())
        let stored = saved.first { $0.id == task.id }
        #expect(stored?.remoteHref == href && stored?.etag == "same" && stored?.uid == "series")
        #expect(stored?.title == "Saved title" && stored?.isDirty == false && stored?.pendingMoveFromHref == nil)
        let proof = try SyncResourceState.read(scope: shapeScope, href: href, in: fresh)
        #expect(proof?.shape == .singleTask && proof?.etag == "same" && proof?.uid == "series")
        if let stored {
            let writable = try? SyncResourceState.proof(list: stored.taskList, href: href, etag: stored.etag,
                taskID: stored.id, uid: stored.uid, allowRetainedRevision: false, in: fresh)
            #expect(writable == proof && writable != nil)
        }
        #expect(try SyncImportCheckpoint.accountedETags(id: key, container: container) == [href: "same"])
        let next = try checkpoint(accountID: accountID, listID: list.id, host: host, container: container)
        #expect(next?.hasCompletedBaseline == true && next?.ctag == "c1")
        #expect(next?.token == (supportsToken ? "observed" : nil))
        #expect((next?.lastIntegrity ?? .distantPast) > (previous.lastIntegrity ?? .distantFuture))
        #expect(saved.count == 2 && saved.first { $0.id == foreign.id }?.title == "Independent account")
        #expect(try SyncResourceState.read(scope: foreignScope, href: href, in: fresh) == foreignProof)
        #expect(try SyncImportCheckpoint.accountedETags(id: foreignKey, container: container) == [href: "same"])
        #expect(try checkpoint(accountID: otherID, listID: otherList.id, host: host, container: container) == foreignCheckpoint)
        withExtendedLifetime(container) {}
    }

    @Test("Complete manifest keeps present legacy hrefs without refetching their known bodies",
          arguments: [false, true])
    func completeManifestPreservesKnownLegacyHref(absolute: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let host = fixtureHost()
        let baseURL = "https://" + host
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let context = container.mainContext
        let accounts = try context.fetch(FetchDescriptor<ServerAccount>())
        let account = try #require(accounts.first { $0.id == accountID })
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        context.insert(list)
        list.account = account
        SyncEngine.markCategoriesCaughtUp(listID: list.id)
        let shapeScope = try #require(TaskPhotoOwnership.Scope(list: list))
        let alias = absolute ? baseURL + "/one/series.ics" : "series.ics"
        let members = [
            (uid: "series", raw: alias, href: "/one/series.ics"),
            (uid: "peer", raw: "/one/peer.ics", href: "/one/peer.ics"),
            (uid: "missing", raw: "/one/missing.ics", href: "/one/missing.ics"),
        ]
        var ids: [String: String] = [:]
        var resources: [CalDAVClient.RemoteTask] = []
        var shapes: [SyncResourceState] = []
        for member in members {
            let task = TaskItem(uid: member.uid, title: "Saved " + member.uid)
            context.insert(task)
            task.taskList = list
            task.remoteHref = member.raw
            task.etag = "same"
            task.isLocalOnly = false
            ids[member.uid] = task.id
            let body = "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VTODO\nUID:\(member.uid)\n"
                + "SUMMARY:Saved \(member.uid)\nEND:VTODO\nEND:VCALENDAR"
            let shape = SyncResourceState(scope: shapeScope, href: member.href, etag: "same",
                shape: .singleTask, originalBody: nil, uid: member.uid)
            try shape.store(in: context)
            shapes.append(shape)
            resources.append(.init(href: member.href, etag: "same", icsData: body))
        }
        try context.save()
        let classification = try SyncResourceState.needsClassification(list: list, in: context)
        try #require(classification.isEmpty)
        let key = checkpointID(accountID: accountID, listID: list.id, host: host)
        try DAVSyncScenario.seedRecentCheckpoint(for: list, in: container, at: Date().addingTimeInterval(-30))
        try SyncImportCheckpoint.markAccounted(resources, id: key, container: container)
        let previous = try #require(try checkpoint(accountID: accountID, listID: list.id,
            host: host, container: container))
        #expect(previous.hasCompletedBaseline && previous.ctag == "c1")

        let knownMembers = members.prefix(2)
        let manifest = DAVSyncScenario.multistatus(knownMembers.map {
            DAVSyncScenario.prop($0.href, "<d:getetag>same</d:getetag>")
        }.joined())
        let engine = makeEngine(host: host, responses: discovery(ctag: "c2") + [.init(body: manifest)])
        let outcome = await run(engine, background: false, accountID: accountID, host: host, container: container)
        #expect(outcome.status == .completed && outcome.failures.isEmpty)
        #expect(outcome.importedCount == 0 && outcome.updatedCount == 0)
        #expect(outcome.deletedCount == 1 && outcome.changedListIDs == [list.id])
        #expect(outcome.pendingOutboundCount == 0)
        let requests = ScriptedDAVProtocol.requests(host: host)
        try expectDiscovery(requests)
        #expect(requests.map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND", "REPORT"])
        #expect(reports(requests, containing: "calendar-query").count == 1)
        #expect(reports(requests, containing: "calendar-multiget").isEmpty)

        let read = ModelContext(container)
        let saved = try read.fetch(FetchDescriptor<TaskItem>())
        #expect(Set(saved.map(\.uid)) == ["series", "peer"])
        for member in knownMembers {
            let task = saved.first { $0.uid == member.uid }
            #expect(task?.id == ids[member.uid] && task?.taskList?.id == list.id)
            #expect(task?.remoteHref == member.raw && task?.etag == "same")
            #expect(task?.title == "Saved " + member.uid && task?.isDirty == false)
        }
        for shape in shapes.prefix(2) {
            #expect(try SyncResourceState.read(scope: shapeScope, href: shape.href, in: read) == shape)
        }
        #expect(try SyncImportCheckpoint.accountedETags(id: key, container: container) ==
            ["/one/series.ics": "same", "/one/peer.ics": "same"])
        let next = try checkpoint(accountID: accountID, listID: list.id, host: host, container: container)
        #expect(next?.hasCompletedBaseline == true && next?.ctag == "c2")
        #expect((next?.lastIntegrity ?? .distantPast) > (previous.lastIntegrity ?? .distantFuture))
    }


    @Test("Delta matching reads a nil ETag saved while its REPORT is suspended", arguments: [false, true])
    func deltaReadsFreshETagInvalidation(invalidated: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let host = fixtureHost()
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let href = "/one/0.ics"
        let engine = makeEngine(host: host, responses: discovery(ctag: "c1", token: "start") + [
            .init(body: DAVSyncScenario.manifest(count: 1)), .init(body: DAVSyncScenario.tasks(count: 1))
        ])
        let initial = await run(engine, background: false, accountID: accountID, host: host, container: container)
        try #require(initial.status == .completed && initial.importedCount == 1)
        let initialReader = ModelContext(container)
        let task = try #require(try initialReader.fetch(FetchDescriptor<TaskItem>()).first)
        let taskID = task.id
        let listID = try #require(task.taskList?.id)
        let key = checkpointID(accountID: accountID, listID: listID, host: host)
        let gate = ScriptedDAVProtocol.Gate()
        defer { gate.release() }
        _ = ScriptedDAVProtocol.install(host: host, responses: discovery(ctag: "c1", token: "seen") + [
            .init(body: delta(DAVSyncScenario.prop(href, "<d:getetag>e0</d:getetag>"), token: "next"), gate: gate),
            .init(body: DAVSyncScenario.tasks(count: 1))
        ])
        let operations = PerformanceTrace.OperationRecorder()
        let operation = Task {
            await PerformanceTrace.$operationRecorder.withValue(operations) {
                await run(engine, background: false, accountID: accountID, host: host, container: container)
            }
        }
        try await waitForRequests(4, host: host)
        if invalidated {
            let concurrent = ModelContext(container)
            let saved = try #require(try concurrent.fetch(FetchDescriptor<TaskItem>()).first)
            saved.etag = nil
            try concurrent.save()
        }
        #expect(try SyncImportCheckpoint.accountedETags(id: key, container: container)[href] == "e0")
        gate.release()
        let outcome = await operation.value
        #expect(outcome.status == .completed && outcome.importedCount == 0 && outcome.deletedCount == 0)
        let requests = ScriptedDAVProtocol.requests(host: host)
        try expectInventoryKind(requests, delta: true, token: "start")
        #expect(try reports(requests, containing: "calendar-multiget").flatMap(requestedHrefs) == (invalidated ? [href] : []))
        #expect(operations.count(.matchingTaskLookup).rows == 1)
        #expect(operations.count(.matchingReceiptLookup).rows == 1)
        let finalReader = ModelContext(container)
        let finalTask = try #require(try finalReader.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(finalTask.id == taskID && finalTask.etag == "e0" && !finalTask.isDirty)
        #expect(try checkpoint(accountID: accountID, listID: listID, host: host, container: container)?.token == "next")
    }

    @Test("A 101-member delta bounds the actual task and receipt queries")
    func productionDeltaBatchesExactInventory() async throws {
        let container = try DAVSyncScenario.container()
        let host = fixtureHost()
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let manifest = DAVSyncScenario.manifest(count: 101)
        let engine = makeEngine(host: host, responses: discovery(ctag: "c1", token: "start") + [
            .init(body: manifest), .init(body: DAVSyncScenario.tasks(count: 100)),
            .init(body: DAVSyncScenario.tasks(count: 1, startIndex: 100))
        ])
        let initial = await run(engine, background: false, accountID: accountID, host: host, container: container)
        try #require(initial.status == .completed && initial.importedCount == 101)
        let members = (0..<101).map { DAVSyncScenario.prop("/one/\($0).ics", "<d:getetag>e\($0)</d:getetag>") }.joined()
        _ = ScriptedDAVProtocol.install(host: host, responses: discovery(ctag: "c1", token: "seen") + [
            .init(body: delta(members, token: "next"))
        ])
        let operations = PerformanceTrace.OperationRecorder()
        let outcome = await PerformanceTrace.$operationRecorder.withValue(operations) {
            await run(engine, background: false, accountID: accountID, host: host, container: container)
        }
        #expect(outcome.status == .completed && outcome.changedListIDs.isEmpty)
        let requests = ScriptedDAVProtocol.requests(host: host)
        try expectInventoryKind(requests, delta: true, token: "start")
        #expect(requests.count == 4)
        for operation in [PerformanceTrace.Operation.matchingTaskLookup, .matchingReceiptLookup] {
            let count = operations.count(operation)
            #expect(count.calls == 2 && count.rows == 101 && count.maxKeys == 100)
        }
        #expect(operations.count(.matchingTaskInventory).calls == 0)
        #expect(operations.count(.receiptInventory).calls == 0)
    }

    @Test("A reopened store skips 100 durable receipts, including excluded completed history",
          arguments: [false, true])
    func interruptedImportResumesAfterReopeningStore(background: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-large-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("tasks.store")
        let host = fixtureHost()
        // The helper's container, contexts, models and engine all leave scope before reopening.
        let saved = try await interruptFirstBatch(storeURL: storeURL, host: host, background: background)
        try #require(saved.closedContainer == nil, "The interrupted store must be closed before reopening its file")
        let reopened = try persistentContainer(at: storeURL)
        #expect(try ModelContext(reopened).fetchCount(FetchDescriptor<TaskItem>()) == 99)
        let receipts = try SyncImportCheckpoint.accountedETags(id: saved.checkpointID, container: reopened)
        #expect(receipts.count == 100)
        #expect(receipts["/one/0.ics"] == "e0", "Excluded history must be receipted even without a visible TaskItem")
        #expect(try checkpoint(accountID: saved.accountID, listID: saved.listID,
            host: host, container: reopened, months: 3) == nil)

        let engine = makeEngine(host: host, responses: discovery(ctag: "c1", token: "baseline-token")
            + [.init(body: DAVSyncScenario.manifest(count: 100))])
        let progress = await recordProgress(engine)
        defer { progress.cancel() }
        let result = await run(engine, background: background, accountID: saved.accountID,
            host: host, container: reopened, months: 3)
        #expect(result.status == .completed)
        #expect(result.importedCount == 0)
        #expect(result.updatedCount == 2 && result.deletedCount == 0) // Child edge and inverse parent's children.
        #expect(result.changedListIDs == [saved.listID])
        let requests = ScriptedDAVProtocol.requests(host: host)
        try expectDiscovery(requests)
        #expect(requests.count == 4)
        #expect(reports(requests, containing: "calendar-query").count == 1)
        let batches = reports(requests, containing: "calendar-multiget")
        #expect(batches.isEmpty, "All remaining resources already have durable receipts")
        #expect(reports(requests, containing: "sync-collection").isEmpty,
            "An interrupted baseline must retry the inventory before adopting the discovery token")
        let read = ModelContext(reopened)
        let tasks = try read.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == 99)
        #expect(tasks.first { $0.uid == "fixture-1" }?.parentTask?.uid == "fixture-2")
        #expect(Set(tasks.map(\.uid)) == Set((1..<100).map { "fixture-\($0)" }))
        #expect(Set(tasks.map(\.id)).count == 99)
        #expect(saved.taskIDs.isSubset(of: Set(tasks.map(\.id))))
        #expect(tasks.allSatisfy { !$0.isDirty && !$0.isLocalOnly })
        #expect(try SyncImportCheckpoint.accountedETags(id: saved.checkpointID, container: reopened).count == 100)
        let committed = try #require(try checkpoint(accountID: saved.accountID, listID: saved.listID,
            host: host, container: reopened, months: 3))
        #expect(committed.hasCompletedBaseline)
        #expect(committed.token == "baseline-token")
        #expect(committed.ctag == "c1")
        #expect(try read.fetch(FetchDescriptor<ServerAccount>()).first?.lastSyncDate != nil)
        try expectProgress(await progress.value, accountID: saved.accountID, listID: saved.listID,
            completed: 0, total: 0, finished: true)
        #expect(await engine.consumePendingInboundRefresh())
        withExtendedLifetime(reopened) {}
    }

    @Test("Missing UID cannot complete a baseline or advance a previously committed delta token",
          arguments: [false, true], [false, true])
    func missingUIDDoesNotAdvanceCheckpoint(background: Bool, completedBaseline: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let host = fixtureHost()
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let initial = completedBaseline
            ? discovery(ctag: "c1", token: "token-1")
                + [.init(body: DAVSyncScenario.manifest(count: 1)), .init(body: DAVSyncScenario.tasks(count: 1))]
            : []
        let engine = makeEngine(host: host, responses: initial)
        if completedBaseline {
            let baseline = await run(engine, background: background, accountID: accountID, host: host, container: container)
            #expect(baseline.status == .completed)
            #expect(baseline.importedCount == 1)
            #expect(await engine.consumePendingInboundRefresh())
        }
        let originalSyncDate = try ModelContext(container).fetch(FetchDescriptor<ServerAccount>()).first?.lastSyncDate
        let originalList = try ModelContext(container).fetch(FetchDescriptor<TaskList>()).first
        let originalCheckpoint = try originalList.flatMap {
            try checkpoint(accountID: accountID, listID: $0.id, host: host, container: container)
        }
        let etag = completedBaseline ? "changed-etag" : "e0"
        let resource = DAVSyncScenario.prop("/one/0.ics", "<d:getetag>\(etag)</d:getetag>")
        let inventory = completedBaseline ? delta(resource, token: "token-2") : DAVSyncScenario.multistatus(resource)
        let malformed = DAVSyncScenario.multistatus(DAVSyncScenario.prop("/one/0.ics", """
            <d:getetag>\(etag)</d:getetag><c:calendar-data>BEGIN:VCALENDAR
            BEGIN:VTODO
            SUMMARY:Missing UID must not be acknowledged
            END:VTODO
            END:VCALENDAR</c:calendar-data>
            """))
        _ = ScriptedDAVProtocol.install(host: host, responses: discovery(ctag: "c2", token: "token-2")
            + [.init(body: inventory), .init(body: malformed)])
        let progress = await recordProgress(engine)
        defer { progress.cancel() }
        let failed = await run(engine, background: background, accountID: accountID, host: host, container: container)
        #expect(failed.status == .partial)
        #expect(!failed.failures.isEmpty)
        #expect(failed.importedCount == 0 && failed.updatedCount == 0 && failed.deletedCount == 0)
        let read = ModelContext(container)
        let list = try #require(try read.fetch(FetchDescriptor<TaskList>()).first)
        #expect(try checkpoint(accountID: accountID, listID: list.id, host: host, container: container) == originalCheckpoint)
        let key = checkpointID(accountID: accountID, listID: list.id, host: host)
        #expect(try SyncImportCheckpoint.accountedETags(id: key, container: container)
            == (completedBaseline ? ["/one/0.ics": "e0"] : [:]))
        #expect(try read.fetch(FetchDescriptor<ServerAccount>()).first?.lastSyncDate == originalSyncDate)
        let retained = try read.fetch(FetchDescriptor<TaskItem>())
        #expect(retained.count == (completedBaseline ? 1 : 0))
        if completedBaseline {
            #expect(retained.first?.title == "Moon bakery delivery 0")
            #expect(retained.first?.etag == "e0")
            #expect(!(await engine.pendingInboundRefresh))
        } else {
            #expect(list.lastFullPullDate == nil && list.syncCTag == nil)
        }
        let failedRequests = ScriptedDAVProtocol.requests(host: host)
        try expectDiscovery(failedRequests)
        #expect(failedRequests.count == 5)
        #expect(try reports(failedRequests, containing: "calendar-multiget").flatMap(requestedHrefs) == ["/one/0.ics"])
        try expectInventoryKind(failedRequests, delta: completedBaseline, token: "token-1")
        #expect((await progress.value).contains { $0 == nil })

        // The corrected body must be fetched again: neither a receipt nor the new token was accepted.
        let corrected = DAVSyncScenario.tasks(count: 1)
            .replacingOccurrences(of: "<d:getetag>e0</d:getetag>", with: "<d:getetag>\(etag)</d:getetag>")
            .replacingOccurrences(of: "Moon bakery delivery 0", with: "Corrected task")
        _ = ScriptedDAVProtocol.install(host: host, responses: discovery(ctag: "c2", token: "token-2")
            + [.init(body: inventory), .init(body: corrected)])
        let recovered = await run(engine, background: background, accountID: accountID, host: host, container: container)
        #expect(recovered.status == .completed)
        #expect(recovered.importedCount == (completedBaseline ? 0 : 1))
        #expect(recovered.updatedCount == (completedBaseline ? 1 : 0))
        #expect(recovered.deletedCount == 0)
        let retryRequests = ScriptedDAVProtocol.requests(host: host)
        #expect(retryRequests.count == 5)
        try expectInventoryKind(retryRequests, delta: completedBaseline, token: "token-1")
        #expect(try reports(retryRequests, containing: "calendar-multiget").flatMap(requestedHrefs) == ["/one/0.ics"])
        let committed = try #require(try checkpoint(accountID: accountID, listID: list.id, host: host, container: container))
        #expect(committed.hasCompletedBaseline && committed.token == "token-2" && committed.ctag == "c2")
        let finalTasks = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(finalTasks.count == 1)
        #expect(finalTasks.first?.title == "Corrected task")
        #expect(finalTasks.first?.etag == etag)
        withExtendedLifetime(container) {}
    }

    @Test("An engine body await preserves a pending UI edit and insert without saving or duplicating them",
          arguments: [false, true])
    func pendingUIChangesSurviveBodyAwait(background: Bool) async throws {
        let container = try DAVSyncScenario.container()
        container.mainContext.autosaveEnabled = false
        let host = fixtureHost()
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let engine = makeEngine(host: host, responses: discovery(ctag: "c1")
            + [.init(body: DAVSyncScenario.manifest(count: 1)), .init(body: DAVSyncScenario.tasks(count: 1))])
        let initial = await run(engine, background: background, accountID: accountID, host: host, container: container)
        #expect(initial.status == .completed)
        _ = await engine.consumePendingInboundRefresh()
        let main = container.mainContext
        let task = try #require(try main.fetch(FetchDescriptor<TaskItem>()).first)
        let list = try #require(task.taskList)
        let gate = ScriptedDAVProtocol.Gate()
        defer { gate.release() }
        let manifest = DAVSyncScenario.manifest(count: 2)
            .replacingOccurrences(of: "<d:getetag>e0</d:getetag>", with: "<d:getetag>new-e0</d:getetag>")
        let bodies = DAVSyncScenario.tasks(count: 2)
            .replacingOccurrences(of: "<d:getetag>e0</d:getetag>", with: "<d:getetag>new-e0</d:getetag>")
        _ = ScriptedDAVProtocol.install(host: host, responses: discovery(ctag: "c2")
            + [.init(body: manifest), .init(body: bodies, gate: gate)])
        let active = Task { await run(engine, background: background, accountID: accountID, host: host, container: container) }
        defer { active.cancel() }
        try await waitForRequests(5, host: host)
        task.title = "My unsaved edit"
        task.isDirty = true
        let pending = TaskItem(uid: "fixture-1", title: "My unsaved insert")
        pending.taskList = list
        pending.isDirty = true
        main.insert(pending)
        gate.release()
        let result = await active.value
        #expect(result.status == .completed)
        #expect(result.importedCount == 0 && result.updatedCount == 0 && result.deletedCount == 0)
        #expect(task.title == "My unsaved edit" && task.isDirty)
        #expect(pending.title == "My unsaved insert" && pending.isLocalOnly)
        #expect(main.hasChanges, "Engine bookkeeping must not save an editor's pending changes")
        #expect(try main.fetch(FetchDescriptor<TaskItem>()).count == 2)
        let persisted = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(persisted.count == 1)
        #expect(persisted.first?.title == "Moon bakery delivery 0")
        #expect(persisted.first?.etag == "e0")
        #expect(persisted.first?.isDirty == false)
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.count == 5)
        #expect(!requests.contains { $0.method == "PUT" || $0.method == "DELETE" })
        #expect(try reports(requests, containing: "calendar-multiget").flatMap(requestedHrefs)
            == ["/one/0.ics", "/one/1.ics"])
        #expect(!(await engine.pendingInboundRefresh))
        withExtendedLifetime(container) {}
    }

    private struct InterruptedStore {
        let accountID: String
        let listID: String
        let checkpointID: String
        let taskIDs: Set<String>
        weak var closedContainer: ModelContainer?
    }

    private func interruptFirstBatch(storeURL: URL, host: String, background: Bool) async throws -> InterruptedStore {
        let container = try persistentContainer(at: storeURL)
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let gate = ScriptedDAVProtocol.Gate()
        defer { gate.release() }
        let firstBatch = DAVSyncScenario.tasks(count: 100)
            .replacingOccurrences(of: "UID:fixture-1\n", with: "UID:fixture-1\nRELATED-TO:fixture-2\n")
            .replacingOccurrences(
            of: "SUMMARY:Moon bakery delivery 0\n", with: "SUMMARY:Moon bakery delivery 0\nSTATUS:COMPLETED\nCOMPLETED:20000101T120000Z\n")
        let engine = makeEngine(host: host, responses: discovery(ctag: "c1", token: "baseline-token")
            + [.init(body: DAVSyncScenario.manifest(count: 101)), .init(body: firstBatch),
               .init(status: 503, body: "Interrupted after the first committed batch", gate: gate)])
        let progress = await recordProgress(engine)
        defer { progress.cancel() }
        let active = Task { await run(engine, background: background, accountID: accountID,
            host: host, container: container, months: 3) }
        defer { active.cancel() }
        try await waitForRequests(6, host: host)
        #expect(await engine.isSyncInProgress)
        #expect(await engine.pendingInboundRefresh, "A committed batch must be visible before the later request completes")
        let read = ModelContext(container)
        let list = try #require(try read.fetch(FetchDescriptor<TaskList>()).first)
        let key = checkpointID(accountID: accountID, listID: list.id, host: host, months: 3)
        let tasks = try read.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == 99)
        #expect(Set(tasks.map(\.uid)) == Set((1..<100).map { "fixture-\($0)" }))
        #expect(try SyncImportCheckpoint.accountedETags(id: key, container: container).count == 100)
        #expect(try checkpoint(accountID: accountID, listID: list.id, host: host, container: container, months: 3) == nil)
        let batches = reports(ScriptedDAVProtocol.requests(host: host), containing: "calendar-multiget")
        #expect(batches.count == 2)
        #expect(try requestedHrefs(try #require(batches.first)) == (0..<100).map { "/one/\($0).ics" })
        #expect(try requestedHrefs(try #require(batches.last)) == ["/one/100.ics"])
        gate.release()
        let failed = await active.value
        #expect(failed.status == .partial)
        #expect(failed.importedCount == 99)
        #expect(failed.updatedCount == 0 && failed.deletedCount == 0)
        #expect(failed.changedListIDs == [list.id])
        #expect(try ModelContext(container).fetch(FetchDescriptor<ServerAccount>()).first?.lastSyncDate == nil)
        #expect(await engine.consumePendingInboundRefresh())
        #expect(!(await engine.consumePendingInboundRefresh()))
        try expectProgress(await progress.value, accountID: accountID, listID: list.id,
            completed: 100, total: 101, finished: false)
        return InterruptedStore(accountID: accountID, listID: list.id, checkpointID: key,
            taskIDs: Set(tasks.map(\.id)), closedContainer: container)
    }

    private func persistentContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema(SchemaV2.models)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func fixtureHost() -> String { "engine-import-" + UUID().uuidString.lowercased() + ".invalid" }

    private func makeEngine(host: String, responses: [ScriptedDAVProtocol.Response]) -> SyncEngine {
        SyncEngine(calDAVClient: CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
    }

    private func run(_ engine: SyncEngine, background: Bool, accountID: String, host: String,
                     container: ModelContainer, months: Int = 0) async -> SyncOutcome {
        if background {
            return await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
                credentials: credentials, modelContainer: container, syncWindowMonths: months, reconcileNotifications: false)
        }
        return await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: credentials, modelContainer: container, syncWindowMonths: months, reconcileNotifications: false)
    }

    private func discovery(ctag: String, token: String? = nil) -> [ScriptedDAVProtocol.Response] {
        var responses = DAVSyncScenario.discovery(paths: ["/one/"])
        responses[2].body = responses[2].body.replacingOccurrences(of: "<cs:getctag>c1</cs:getctag>",
            with: "<cs:getctag>\(ctag)</cs:getctag>")
        if let token {
            let capability = "<d:sync-token>\(token)</d:sync-token><d:supported-report-set>"
                + "<d:supported-report><d:report><d:sync-collection/></d:report></d:supported-report></d:supported-report-set>"
            responses[2].body = responses[2].body.replacingOccurrences(of: "</d:prop>", with: capability + "</d:prop>")
        }
        return responses
    }

    private func delta(_ resources: String, token: String) -> String {
        DAVSyncScenario.multistatus(resources + "<d:sync-token>\(token)</d:sync-token>")
    }

    private func checkpointID(accountID: String, listID: String, host: String, months: Int = 0) -> String {
        SyncImportCheckpoint.identity(accountID: accountID, listID: listID,
            baseURL: "https://" + host, username: credentials.username, months: months)
    }

    private func checkpoint(accountID: String, listID: String, host: String, container: ModelContainer,
                            months: Int = 0) throws -> SyncCollectionPuller.Checkpoint? {
        try SyncImportCheckpoint.read(id: checkpointID(accountID: accountID, listID: listID, host: host, months: months),
            scope: .init(accountID: accountID, listID: listID, historyScope: String(months)), in: ModelContext(container))
    }

    private func reports(_ requests: [ScriptedDAVProtocol.RecordedRequest], containing name: String)
        -> [ScriptedDAVProtocol.RecordedRequest] {
        requests.filter { $0.method == "REPORT" && String(decoding: $0.body, as: UTF8.self).contains(name) }
    }

    private func requestedHrefs(_ request: ScriptedDAVProtocol.RecordedRequest) throws -> [String] {
        let body = String(decoding: request.body, as: UTF8.self)
        let pattern = try NSRegularExpression(pattern: "<d:href>([^<]+)</d:href>")
        return pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap {
            Range($0.range(at: 1), in: body).map { String(body[$0]) }
        }
    }

    private func expectDiscovery(_ requests: [ScriptedDAVProtocol.RecordedRequest]) throws {
        let first = Array(requests.prefix(3))
        #expect(first.map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND"])
        #expect(first.map(\.path) == ["/remote.php/dav", "/principal", "/"])
        #expect(first.allSatisfy { $0.bodyBytes > 0 })
        #expect(!requests.contains { $0.method == "PUT" || $0.method == "DELETE" })
    }

    private func expectInventoryKind(_ requests: [ScriptedDAVProtocol.RecordedRequest], delta: Bool, token: String) throws {
        let deltas = reports(requests, containing: "sync-collection")
        #expect(deltas.count == (delta ? 1 : 0))
        #expect(reports(requests, containing: "calendar-query").count == (delta ? 0 : 1))
        if delta {
            let report = try #require(deltas.first)
            #expect(report.path == "/one")
            #expect(String(decoding: report.body, as: UTF8.self).contains("<d:sync-token>\(token)</d:sync-token>"))
            #expect(!String(decoding: report.body, as: UTF8.self).contains("calendar-data"))
        }
    }

    private func waitForRequests(_ count: Int, host: String) async throws {
        for _ in 0..<500 {
            if ScriptedDAVProtocol.requests(host: host).count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ScriptedDAVProtocol.requests(host: host).count >= count, "Engine never reached the gated DAV request")
    }

    private func recordProgress(_ engine: SyncEngine) async -> Task<[SyncProgress?], Never> {
        let stream = await engine.progressUpdates()
        return Task {
            var values: [SyncProgress?] = []
            for await value in stream {
                values.append(value)
                if value == nil { break }
            }
            return values
        }
    }

    private func expectProgress(_ values: [SyncProgress?], accountID: String, listID: String,
                                completed: Int, total: Int, finished: Bool) throws {
        #expect(values.contains { $0 == nil }, "Both success and failure must clear the visible progress")
        let updates = values.compactMap { $0 }
        #expect(updates.first?.stage == .discovering)
        #expect(updates.allSatisfy { $0.accountID == accountID && $0.completed >= 0 })
        #expect(updates.contains { $0.listID == listID && $0.stage == .inventory })
        #expect(updates.contains {
            $0.listID == listID && $0.stage == .downloading && $0.completed == completed && $0.total == total
        })
        #expect(updates.contains { $0.stage == .finishing } == finished)
        for update in updates {
            if let bound = update.total { #expect(update.completed <= bound) }
        }
    }
}
