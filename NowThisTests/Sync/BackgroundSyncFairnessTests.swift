import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Background account and collection fairness", .serialized)
@MainActor
struct BackgroundSyncFairnessTests {
    private enum Failure: Error { case unavailable }

    // Removing the pre-attempt save would restart every failed delivery at account a.
    @Test(arguments: [false, true])
    func slowFirstAccountDoesNotStarveLaterAccounts(cutoff: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let attempts = FairnessAttempts()
        for _ in 0..<3 {
            let budget = BackgroundRunBudget()
            do {
                _ = try await BackgroundSyncManager.performAccounts(accountIDs: ["a", "b", "c"],
                    modelContainer: container, budget: budget) { id in
                    await attempts.record(id)
                    if cutoff { budget.stopRemote(); try budget.checkRemoteAdmission() }
                    throw Failure.unavailable
                }
            } catch {}
        }
        #expect(await attempts.values == ["a", "b", "c"])
        #expect(try BackgroundSyncCursor.load(scope: "accounts", in: ModelContext(container)) == "c")
    }

    // The actual engine must rotate before its first network pull, even if no body commits.
    @Test(arguments: [false, true])
    func largeFirstListDoesNotStarveLaterLists(cutoff: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container)
        let host = "list-fairness-" + UUID().uuidString.lowercased() + ".invalid"
        var attemptedPaths: [String] = []
        for _ in 0..<3 {
            let gate = ScriptedDAVProtocol.Gate()
            let config = ScriptedDAVProtocol.install(host: host,
                responses: DAVSyncScenario.discovery(paths: ["/a/", "/b/", "/c/"]) + [
                    .init(status: cutoff ? 207 : 503,
                        body: DAVSyncScenario.manifest(count: 0, path: "/a/"), gate: cutoff ? gate : nil)])
            let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config,
                retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
            let budget = BackgroundRunBudget()
            let run = Task {
                await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
                    credentials: .init(username: "fixture", password: "fixture"), modelContainer: container,
                    reconcileNotifications: false, runBudget: budget)
            }
            if cutoff {
                for _ in 0..<500 where !ScriptedDAVProtocol.requests(host: host).contains(where: { $0.method == "REPORT" }) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                budget.stopRemote(); run.cancel(); gate.release()
            }
            let outcome = await run.value
            #expect(outcome.status != .completed)
            let pull = try #require(ScriptedDAVProtocol.requests(host: host).first { $0.method == "REPORT" })
            attemptedPaths.append(pull.path)
        }
        #expect(attemptedPaths == ["/a", "/b", "/c"])
    }

    @Test func deletedCursorFallsBackDeterministically() throws {
        #expect(BackgroundSyncCursor.rotated(["c", "a", "b"], after: "deleted") == ["a", "b", "c"])
        #expect(BackgroundSyncCursor.rotated(["c", "a", "b"], after: "a") == ["b", "c", "a"])
        #expect(BackgroundSyncCursor.rotated([], after: "a").isEmpty)
        let container = try DAVSyncScenario.container()
        try BackgroundSyncCursor.recordAttempt(id: "deleted", scope: "accounts", in: container.mainContext)
        #expect(try BackgroundSyncCursor.load(scope: "accounts", in: ModelContext(container)) == "deleted")
        #expect(try BackgroundSyncCursor.load(scope: "lists:other", in: ModelContext(container)) == nil)
    }

    @Test func expiredCursorCannotWrite() throws {
        let container = try DAVSyncScenario.container()
        let budget = BackgroundRunBudget(); budget.expire()
        BackgroundRunBudget.$current.withValue(budget) {
            #expect(throws: CancellationError.self) {
                try BackgroundSyncCursor.recordAttempt(id: "a", scope: "accounts", in: container.mainContext)
            }
        }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<SyncMetadata>()) == 0)
    }

    // An advisory attempt must never replace the token used by the next real delta REPORT.
    @Test func partialDeltaResumesFromCommittedPage() async throws {
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container)
        let account = try #require(try container.mainContext.fetch(FetchDescriptor<ServerAccount>()).first)
        let list = TaskList(id: "list", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        container.mainContext.insert(list); list.account = account
        let task = TaskItem(uid: "keep", title: "Keep on partial inventory")
        container.mainContext.insert(task); task.taskList = list
        task.remoteHref = "/one/keep.ics"; task.etag = "e1"; task.isLocalOnly = false; task.isDirty = false
        try container.mainContext.save()
        SyncEngine.markCategoriesCaughtUp(listID: list.id)
        let host = "page-resume-" + UUID().uuidString.lowercased() + ".invalid"
        let scope = SyncCollectionPuller.Scope(accountID: accountID, listID: list.id, historyScope: "0")
        let key = SyncImportCheckpoint.identity(accountID: accountID, listID: list.id,
            baseURL: "https://" + host, username: "fixture", months: 0)
        try SyncImportCheckpoint.commit(.init(scope: scope, token: "old", ctag: "c1",
            lastIntegrity: Date(), hasCompletedBaseline: true), id: key, collectionPath: "/one/", container: container)
        var discovery = DAVSyncScenario.discovery(paths: ["/one/"])
        discovery[2].body = discovery[2].body.replacingOccurrences(of: "<cs:getctag>",
            with: "<d:supported-report-set><d:supported-report><d:report><d:sync-collection/></d:report></d:supported-report></d:supported-report-set><d:sync-token>discovery</d:sync-token><cs:getctag>")
        let continuation = DAVSyncScenario.multistatus("<d:response><d:href>/one/</d:href><d:status>HTTP/1.1 507 Insufficient Storage</d:status></d:response><d:sync-token>page1</d:sync-token>")
        let config = ScriptedDAVProtocol.install(host: host, responses: discovery + [
            .init(body: continuation), .init(status: 503, body: "unavailable")])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config,
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let first = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container, reconcileNotifications: false)
        #expect(first.status == .partial)
        #expect(try SyncImportCheckpoint.read(id: key, scope: scope, in: ModelContext(container))?.token == "page1")
        try BackgroundSyncCursor.recordAttempt(id: "/other/", scope: "lists:" + accountID, in: ModelContext(container))
        _ = ScriptedDAVProtocol.install(host: host, responses: discovery + [
            .init(body: DAVSyncScenario.multistatus("<d:sync-token>final</d:sync-token>"))])
        let resumed = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container, reconcileNotifications: false)
        #expect(resumed.status == .completed)
        let report = try #require(ScriptedDAVProtocol.requests(host: host).first { $0.method == "REPORT" })
        #expect(String(decoding: report.body, as: UTF8.self).contains("<d:sync-token>page1</d:sync-token>"))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 1)
        #expect(try SyncImportCheckpoint.read(id: key, scope: scope, in: ModelContext(container))?.token == "final")
        #expect(try BackgroundSyncCursor.load(scope: "lists:" + accountID, in: ModelContext(container)) == "/one/")
    }
}

private actor FairnessAttempts {
    private(set) var values: [String] = []
    func record(_ id: String) { values.append(id) }
}
