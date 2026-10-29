import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Pending parent work on an unchanged collection", .serialized)
@MainActor
struct SyncPendingHierarchyTests {
    @Test("An established unchanged baseline completes parent work without downloading bodies",
          arguments: [false, true])
    func unchangedCollectionCompletesPendingWork(background: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container)
        let host = "pending-hierarchy-" + UUID().uuidString.lowercased() + ".invalid"
        let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
        let initial = DAVSyncScenario.discovery(paths: ["/one/"])
            + [.init(body: DAVSyncScenario.manifest(count: 2)), .init(body: DAVSyncScenario.tasks(count: 2))]
        let first = engine(host: host, responses: initial)
        let imported = await run(first, background: background, accountID: accountID,
            host: host, credentials: credentials, container: container)
        #expect(imported.status == .completed && imported.importedCount == 2)
        let saved = ModelContext(container)
        let tasks = try saved.fetch(FetchDescriptor<TaskItem>())
        let child = try #require(tasks.first { $0.uid == "fixture-0" })
        let listID = try #require(child.taskList?.id)
        let key = SyncImportCheckpoint.identity(accountID: accountID, listID: listID,
            baseURL: "https://" + host, username: credentials.username, months: 0)
        let scope = SyncCollectionPuller.Scope(accountID: accountID, listID: listID, historyScope: "0")
        let checkpoint = try #require(try SyncImportCheckpoint.read(id: key, scope: scope, in: saved))
        // Simulate a crash after saving raw parent data, before wiring relationships.
        child.parentUID = "fixture-1"
        try SyncImportCheckpoint.markHierarchyPending(id: key, in: saved)
        try saved.save()
        let resumed = engine(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]))
        let result = await run(resumed, background: background, accountID: accountID,
            host: host, credentials: credentials, container: container)
        #expect(result.status == .completed)
        #expect(result.updatedCount == 2 && result.importedCount == 0 && result.deletedCount == 0)
        let read = ModelContext(container)
        let current = try read.fetch(FetchDescriptor<TaskItem>())
        #expect(current.first { $0.uid == "fixture-0" }?.parentTask?.uid == "fixture-1")
        #expect(try !SyncImportCheckpoint.hierarchyPending(id: key, in: read))
        #expect(try SyncImportCheckpoint.read(id: key, scope: scope, in: read) == checkpoint)
        #expect(await resumed.consumePendingInboundRefresh())
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.count == 3 && requests.allSatisfy { $0.method == "PROPFIND" })
        withExtendedLifetime(container) {}
    }

    private func engine(host: String, responses: [ScriptedDAVProtocol.Response]) -> SyncEngine {
        SyncEngine(calDAVClient: CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
    }

    private func run(_ engine: SyncEngine, background: Bool, accountID: String, host: String,
                     credentials: CalDAVClient.Credentials, container: ModelContainer) async -> SyncOutcome {
        if background {
            return await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
                credentials: credentials, modelContainer: container, reconcileNotifications: false)
        }
        return await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
    }
}
