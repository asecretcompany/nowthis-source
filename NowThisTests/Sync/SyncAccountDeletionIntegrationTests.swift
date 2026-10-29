import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Account deletion during discovery", .serialized)
@MainActor
struct SyncAccountDeletionIntegrationTests {
    @Test("Deleting an account during discovery cancels without further requests or persisted data",
          arguments: [false, true], [0, 1, 2])
    func deletionDuringDiscovery(background: Bool, discoveryResponse: Int) async throws {
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        let accountID = try DAVSyncScenario.account(in: container)
        let account = try #require(try main.fetch(FetchDescriptor<ServerAccount>()).first)
        let list = TaskList(id: "existing-list", serverURL: "/existing/",
                            name: "Existing synced list", colorHex: "#007AFF")
        list.account = account
        main.insert(list)
        let task = TaskItem(uid: "existing-task", title: "Existing synced task")
        task.taskList = list
        task.remoteHref = "/existing/existing-task.ics"
        task.etag = "existing-etag"
        task.isLocalOnly = false
        task.isDirty = false
        main.insert(task)
        if discoveryResponse == 1 {
            // A home-discovery cancellation must stop before MKCALENDAR.
            let localList = TaskList(serverURL: "", name: "Unpublished list", colorHex: "#007AFF")
            localList.account = account
            main.insert(localList)
        }
        try main.save()

        let host = "account-deletion-" + UUID().uuidString.lowercased() + ".invalid"
        let baseURL = "https://" + host
        let scope = SyncCollectionPuller.Scope(accountID: accountID, listID: list.id, historyScope: "0")
        let checkpointID = SyncImportCheckpoint.identity(accountID: accountID, listID: list.id,
            baseURL: baseURL, username: "fixture", months: 0)
        try SyncImportCheckpoint.commit(.init(scope: scope, token: "existing-token", ctag: "existing-ctag",
            lastIntegrity: Date(), hasCompletedBaseline: true), id: checkpointID,
            collectionPath: "/existing/", container: container)
        let seeded = ModelContext(container)
        #expect(try seeded.fetchCount(FetchDescriptor<TaskList>()) == (discoveryResponse == 1 ? 2 : 1))
        #expect(try seeded.fetchCount(FetchDescriptor<TaskItem>()) == 1)
        #expect(try seeded.fetchCount(FetchDescriptor<SyncMetadata>()) == 1)

        let gate = ScriptedDAVProtocol.Gate()
        // The engine has retained the account before either discovery response.
        // A new remote path exercises list creation if calendar discovery resumes.
        var responses = DAVSyncScenario.discovery(paths: ["/one/"])
        responses[discoveryResponse].gate = gate
        responses += [.init(body: DAVSyncScenario.manifest(count: 1)),
                      .init(body: DAVSyncScenario.tasks(count: 1))]
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let run = Task {
            if background {
                return await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
                    credentials: .init(username: "fixture", password: "fixture"),
                    modelContainer: container, reconcileNotifications: false)
            }
            return await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
                credentials: .init(username: "fixture", password: "fixture"),
                modelContainer: container, reconcileNotifications: false)
        }
        defer { run.cancel(); gate.release() }
        let expectedRequests = discoveryResponse + 1
        for _ in 0..<500 {
            if ScriptedDAVProtocol.requests(host: host).count == expectedRequests { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let paused = ScriptedDAVProtocol.requests(host: host)
        try #require(paused.count == expectedRequests, "The sync must reach the gated discovery before deletion")
        #expect(paused.last?.method == "PROPFIND")
        let expectedPath = ["/remote.php/dav/principals/users/fixture", "/principal", "/calendars"][discoveryResponse]
        #expect(paused.last?.path == expectedPath || paused.last?.path == expectedPath + "/")

        // Keep this fixture's credential deletion in its own empty Keychain service.
        let manager = AccountManager(modelContext: main,
            keychainManager: KeychainManager(service: "nowthis.account-deletion-tests." + UUID().uuidString))
        try await manager.removeAccount(accountID: accountID)
        try expectEmptyStore(container, phase: "after deletion, before discovery resumes")

        gate.release()
        let outcome = await run.value
        #expect(outcome.status == .cancelled)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.importedCount == 0 && outcome.updatedCount == 0 && outcome.deletedCount == 0)
        let completedRequests = ScriptedDAVProtocol.requests(host: host)
        #expect(completedRequests.count == expectedRequests, "Deletion must stop before staged REPORT bodies or server writes")
        #expect(completedRequests.allSatisfy { $0.method == "PROPFIND" })
        try expectEmptyStore(container, phase: "after \(background ? "background" : "foreground") sync resumed: \(outcome.status)")
        withExtendedLifetime(container) {}
    }

    private func expectEmptyStore(_ container: ModelContainer, phase: String) throws {
        let read = ModelContext(container)
        #expect(try read.fetchCount(FetchDescriptor<ServerAccount>()) == 0, "\(phase): deleted account must stay absent")
        #expect(try read.fetchCount(FetchDescriptor<TaskList>()) == 0, "\(phase): sync must not leave a list")
        #expect(try read.fetchCount(FetchDescriptor<TaskItem>()) == 0, "\(phase): synchronized tasks must stay absent")
        let importPrefix = "collection-v1:"
        #expect(try read.fetchCount(FetchDescriptor<SyncMetadata>(predicate: #Predicate {
            $0.id.starts(with: importPrefix)
        })) == 0, "\(phase): authoritative import checkpoints must stay absent")
        // Local reminder recovery tickets survive account removal until its saved state
        // has been reflected in the OS request set; advisory work is not an import token.
    }
}
