import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Scoped CTag pull decisions", .serialized)
@MainActor
struct SyncPullSkipTests {
    @Test("Only an exact recent scoped baseline permits an equal CTag shortcut",
          arguments: ["changed", "missing", "future", "empty", "fresh"])
    func scopedCTagDecision(scenario: String) async throws {
        let host = "scoped-ctag-" + UUID().uuidString.lowercased() + ".invalid"
        let baseURL = "https://" + host
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let context = container.mainContext
        let account = try #require(try context.fetch(FetchDescriptor<ServerAccount>()).first)
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        context.insert(list); list.account = account
        let now = Date()
        list.syncCTag = "c1"; list.lastFullPullDate = now
        try context.save()
        SyncEngine.markCategoriesCaughtUp(listID: list.id)
        let scope = SyncCollectionPuller.Scope(accountID: accountID, listID: list.id, historyScope: "0")
        let key = SyncImportCheckpoint.identity(accountID: accountID, listID: list.id,
            baseURL: baseURL, username: "fixture", months: 0)
        let previous = SyncCollectionPuller.Checkpoint(scope: scope,
            ctag: scenario == "empty" ? "" : "c1",
            lastIntegrity: now.addingTimeInterval(scenario == "future" ? 1 : -30),
            hasCompletedBaseline: true)
        if scenario != "missing" {
            try SyncImportCheckpoint.commit(previous, id: key, collectionPath: list.serverURL, container: container)
        }
        let remoteCTag = scenario == "changed" ? "c2" : scenario == "empty" ? "" : "c1"
        var responses = DAVSyncScenario.discovery(paths: ["/one/"])
        responses[2].body = responses[2].body.replacingOccurrences(
            of: "<cs:getctag>c1</cs:getctag>", with: "<cs:getctag>\(remoteCTag)</cs:getctag>")
        if scenario != "fresh" { responses.append(.init(body: DAVSyncScenario.manifest(count: 0))) }
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses), retryPolicy: .init(maxAttempts: 1, baseDelay: 0)),
            now: { now })
        let outcome = await engine.performFullSyncOutcome(accountID: accountID,
            serverBaseURL: baseURL, credentials: .init(username: "fixture", password: "fixture"),
            modelContainer: container, reconcileNotifications: false)
        #expect(outcome.status == .completed)
        let reports = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "REPORT" }
        #expect(reports.count == (scenario == "fresh" ? 0 : 1))
        #expect(reports.allSatisfy { String(decoding: $0.body, as: UTF8.self).contains("calendar-query") })
        let checkpoint = try SyncImportCheckpoint.read(id: key, scope: scope, in: ModelContext(container))
        #expect(checkpoint?.lastIntegrity == (scenario == "fresh" ? previous.lastIntegrity : now))
    }
}
