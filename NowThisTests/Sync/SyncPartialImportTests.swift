import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Committed partial imports", .serialized)
struct SyncPartialImportTests {
    @Test("Saved first-list tasks announce refresh even when the next list fails", arguments: [false, true])
    @MainActor
    func firstListRemainsVisible(background: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container)
        let host = "partial-" + UUID().uuidString.lowercased() + ".invalid"
        let responses = DAVSyncScenario.discovery(paths: ["/one/", "/two/"])
            + [.init(body: DAVSyncScenario.manifest(count: 101)), .init(body: DAVSyncScenario.tasks(count: 100, startIndex: 0)), .init(body: DAVSyncScenario.tasks(count: 1, startIndex: 100)), .init(status: 503, body: "unavailable")]
        let config = ScriptedDAVProtocol.install(host: host, responses: responses)
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config,
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        do {
            if background {
                try await engine.performBackgroundSync(accountID: accountID, serverBaseURL: "https://" + host,
                    credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
            } else {
                try await engine.performFullSync(accountID: accountID, serverBaseURL: "https://" + host,
                    credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
            }
            Issue.record("The second list must fail")
        } catch {}
        let read = ModelContext(container)
        #expect(try read.fetchCount(FetchDescriptor<TaskItem>()) == 101)
        #expect(try read.fetch(FetchDescriptor<ServerAccount>()).first?.lastSyncDate == nil)
        #expect(await engine.consumePendingInboundRefresh(), "Saved content must be announced despite the later failure")
        withExtendedLifetime(container) {}
    }

    @Test("A cancelled background request throws cancellation and preserves saved first-list tasks")
    @MainActor
    func cancelledBackgroundIsNotSuccess() async throws {
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container)
        let host = "cancel-" + UUID().uuidString.lowercased() + ".invalid"
        let gate = ScriptedDAVProtocol.Gate()
        let responses = DAVSyncScenario.discovery(paths: ["/one/", "/two/"])
            + [.init(body: DAVSyncScenario.manifest(count: 101)), .init(body: DAVSyncScenario.tasks(count: 100, startIndex: 0)), .init(body: DAVSyncScenario.tasks(count: 1, startIndex: 100)), .init(body: DAVSyncScenario.manifest(count: 1), gate: gate), .init(body: DAVSyncScenario.tasks(count: 1, startIndex: 0))]
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let run = Task {
            try await engine.performBackgroundSync(accountID: accountID, serverBaseURL: "https://" + host,
                credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        }
        for _ in 0..<500 where ScriptedDAVProtocol.requests(host: host).count < 7 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 7)
        run.cancel(); gate.release()
        do { try await run.value; Issue.record("Cancellation must not return success") }
        catch { #expect(error is CancellationError) }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 101)
        #expect(await engine.consumePendingInboundRefresh())
        withExtendedLifetime(container) {}
    }
    @Test("An unchanged CTag run produces no display change event")
    @MainActor
    func unchangedCTagDoesNotAnnounceChanges() async throws {
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container)
        let host = "noop-" + UUID().uuidString.lowercased() + ".invalid"
        let responses = DAVSyncScenario.discovery(paths: ["/one/"])
            + [.init(body: DAVSyncScenario.manifest(count: 1)), .init(body: DAVSyncScenario.tasks(count: 1, startIndex: 0))]
            + DAVSyncScenario.discovery(paths: ["/one/"])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let first = await engine.performFullSyncOutcome(accountID: accountID,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container)
        #expect(first.status == .completed)
        #expect(first.importedCount == 1)
        _ = await engine.consumePendingInboundRefresh()
        let second = await engine.performFullSyncOutcome(accountID: accountID,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container)
        #expect(second.status == .completed)
        #expect(second.changedListIDs.isEmpty)
        #expect(!(await engine.consumePendingInboundRefresh()))
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "REPORT" }.count == 2)
    }

    @Test("Committed task change values survive a later failure")
    @MainActor
    func changesStreamContainsCommittedBatch() async throws {
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container)
        let host = "stream-" + UUID().uuidString.lowercased() + ".invalid"
        let responses = DAVSyncScenario.discovery(paths: ["/one/", "/two/"])
            + [.init(body: DAVSyncScenario.manifest(count: 101)), .init(body: DAVSyncScenario.tasks(count: 100, startIndex: 0)), .init(body: DAVSyncScenario.tasks(count: 1, startIndex: 100)), .init(status: 503, body: "unavailable")]
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let stream = await engine.changes()
        var iterator = stream.makeAsyncIterator()
        let result = await engine.performFullSyncOutcome(accountID: accountID,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container)
        var first = try #require(await iterator.next())
        while first.kind == .lists { first = try #require(await iterator.next()) }
        #expect(first.changedIDs.count == 100)
        #expect(first.accountIDs == [accountID])
        #expect(first.listIDs.count == 1)
        #expect(first.revision > 0)
        #expect(result.status == .partial)
        #expect(result.importedCount == 101)
    }

    @Test("A committed move announces both source and destination lists")
    @MainActor
    func moveAnnouncesBothScopes() async throws {
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container)
        let account = try #require(try container.mainContext.fetch(FetchDescriptor<ServerAccount>()).first)
        let source = TaskList(id: "source", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        let destination = TaskList(id: "destination", serverURL: "/two/", name: "Fixture", colorHex: "#007AFF")
        source.account = account; destination.account = account
        container.mainContext.insert(source); container.mainContext.insert(destination)
        let task = TaskItem(uid: "moved", title: "Move the moon bakery")
        task.taskList = source; task.remoteHref = "/one/moved.ics"; task.etag = "before"
        task.isDirty = false; task.isLocalOnly = false
        container.mainContext.insert(task); try container.mainContext.save()
        TaskMover.move(task, to: destination, in: container.mainContext)
        try container.mainContext.save()
        let host = "move-" + UUID().uuidString.lowercased() + ".invalid"
        let responses = DAVSyncScenario.discovery(paths: ["/one/", "/two/"])
            + [.init(body: DAVSyncScenario.manifest(count: 0)), .init(body: DAVSyncScenario.manifest(count: 0)),
               .init(status: 201, body: "", headers: ["ETag": "after"]), .init(status: 204, body: "")]
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let result = await engine.performFullSyncOutcome(accountID: accountID,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container)
        #expect(result.status == .completed)
        #expect(result.changedListIDs == [source.id, destination.id])
    }

    @Test("A foreground 401 pauses the same credentials in background and new credentials recover")
    @MainActor
    func rejectedCredentialsAreSharedAcrossRunners() async throws {
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container)
        let host = "auth-" + UUID().uuidString.lowercased() + ".invalid"
        let config = ScriptedDAVProtocol.install(host: host,
            responses: [.init(status: 401, body: "rejected"), .init(status: 401, body: "rejected")])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config,
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let credentials = CalDAVClient.Credentials(username: "fixture", password: "old")
        let first = await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: credentials, modelContainer: container)
        let background = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: credentials, modelContainer: container)
        #expect(first.failures.first?.category == .authentication)
        #expect(background.status == .partial)
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
        _ = ScriptedDAVProtocol.install(host: host, responses:
            DAVSyncScenario.discovery(paths: ["/one/"]) + [.init(body: DAVSyncScenario.manifest(count: 0))])
        let recovered = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: .init(username: "fixture", password: "new"), modelContainer: container)
        #expect(recovered.status == .completed)
    }

    @Test("Rejected outbound writes stay pending and never count as successful sync",
          arguments: [401, 403, 429], ["PUT", "DELETE"])
    @MainActor
    func rejectedWritesRemainPending(status: Int, method: String) async throws {
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container)
        let account = try #require(try container.mainContext.fetch(FetchDescriptor<ServerAccount>()).first)
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        list.account = account; container.mainContext.insert(list)
        for index in 0..<2 {
            let task = TaskItem(uid: "write-\(index)", title: "Pending \(index)")
            task.taskList = list; task.remoteHref = "/one/write-\(index).ics"
            task.etag = "before"; task.isLocalOnly = false; task.isDirty = true
            task.isDeletedLocally = method == "DELETE"
            container.mainContext.insert(task)
        }
        try container.mainContext.save()
        let host = "reject-" + UUID().uuidString.lowercased() + ".invalid"
        let success = ScriptedDAVProtocol.Response(status: method == "PUT" ? 201 : 204,
            body: "", headers: ["ETag": "after"])
        let responses = DAVSyncScenario.discovery(paths: ["/one/"])
            + [.init(body: DAVSyncScenario.manifest(count: 0)), .init(status: status, body: "rejected"), success]
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let result = await engine.performFullSyncOutcome(accountID: accountID,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container)
        #expect(result.status == .partial)
        #expect(result.pendingOutboundCount == (status == 403 ? 1 : 2))
        let category: SyncFailure.Category = status == 401 ? .authentication : status == 403 ? .accessDenied : .busy
        #expect(result.failures.first?.category == category)
        #expect(try ModelContext(container).fetch(FetchDescriptor<ServerAccount>()).first?.lastSyncDate == nil)
        let attempts = ScriptedDAVProtocol.requests(host: host).filter { $0.method == method }
        #expect(attempts.count == (status == 403 ? 2 : 1))
    }

    @Test("Retrying a partial import converges without duplicate tasks", arguments: [false, true])
    @MainActor
    func retryConverges(background: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container)
        let host = "resume-" + UUID().uuidString.lowercased() + ".invalid"
        let initial = DAVSyncScenario.discovery(paths: ["/one/", "/two/"])
            + [.init(body: DAVSyncScenario.manifest(count: 101)), .init(body: DAVSyncScenario.tasks(count: 100, startIndex: 0)), .init(body: DAVSyncScenario.tasks(count: 1, startIndex: 100)), .init(status: 503, body: "unavailable")]
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: initial),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
        if background {
            _ = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
                credentials: credentials, modelContainer: container)
        } else {
            _ = await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
                credentials: credentials, modelContainer: container)
        }
        let retry = DAVSyncScenario.discovery(paths: ["/one/", "/two/"])
            + [.init(body: DAVSyncScenario.manifest(count: 2, path: "/two/")), .init(body: DAVSyncScenario.tasks(count: 2, path: "/two/", startIndex: 0))]
        _ = ScriptedDAVProtocol.install(host: host, responses: retry)
        let result: SyncOutcome
        if background {
            result = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
                credentials: credentials, modelContainer: container)
        } else {
            result = await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
                credentials: credentials, modelContainer: container)
        }
        #expect(result.status == .completed)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 103)
        #expect(result.importedCount == 2)
    }

    @Test("A blocked engine run has an explicit already-running outcome")
    @MainActor
    func sharedGateHasExplicitOutcome() async throws {
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container)
        let host = "gate-" + UUID().uuidString.lowercased() + ".invalid"
        let gate = ScriptedDAVProtocol.Gate()
        var responses = DAVSyncScenario.discovery(paths: ["/one/"])
            + [.init(body: DAVSyncScenario.manifest(count: 0))]
        responses[0].gate = gate
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
        let active = Task { await engine.performFullSyncOutcome(accountID: accountID,
            serverBaseURL: "https://" + host, credentials: credentials, modelContainer: container) }
        for _ in 0..<100 where ScriptedDAVProtocol.requests(host: host).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let blocked = await engine.performBackgroundSyncOutcome(accountID: accountID,
            serverBaseURL: "https://" + host, credentials: credentials, modelContainer: container)
        #expect(blocked.status == .alreadyRunning)
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
        gate.release()
        #expect(await active.value.status == .completed)
    }

}
