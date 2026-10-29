import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Sync request ownership", .serialized)
struct SyncAccountIsolationTests {
    @Test("Simultaneous manual starts share one run")
    @MainActor
    func simultaneousStarts() async throws {
        let container = try DAVSyncScenario.container()
        var reloads = 0
        let scheduler = SyncScheduler(onWidgetReload: { reloads += 1 })
        let first = Task { @MainActor in await scheduler.syncNow(modelContext: container.mainContext) }
        let second = Task { @MainActor in await scheduler.syncNow(modelContext: container.mainContext) }
        await first.value; await second.value
        #expect(reloads == 1)
        #expect(!scheduler.isSyncing)
    }

    @Test("A failed account does not prevent the next account from importing")
    @MainActor
    func failedAccountDoesNotBlockNext() async throws {
        let container = try DAVSyncScenario.container()
        let host1 = "failure-" + UUID().uuidString.lowercased() + ".invalid"
        let host2 = "success-" + UUID().uuidString.lowercased() + ".invalid"
        let first = ServerAccount(id: "a", displayName: "First", serverBaseURL: "https://" + host1, username: "fixture")
        let second = ServerAccount(id: "b", displayName: "Second", serverBaseURL: "https://" + host2, username: "fixture")
        container.mainContext.insert(first); container.mainContext.insert(second); try container.mainContext.save()
        let ordered = try container.mainContext.fetch(FetchDescriptor<ServerAccount>())
        ordered[0].serverBaseURL = "https://" + host1
        ordered[1].serverBaseURL = "https://" + host2
        try container.mainContext.save()
        let keychain = KeychainManager(service: "nowthis.performance-tests." + UUID().uuidString)
        try await keychain.save(password: "fixture", for: first.id)
        try await keychain.save(password: "fixture", for: second.id)
        let config = ScriptedDAVProtocol.install(host: host1, responses: [.init(status: 503, body: "unavailable")])
        _ = ScriptedDAVProtocol.install(host: host2, responses:
            DAVSyncScenario.discovery(paths: ["/one/"]) + [.init(body: DAVSyncScenario.manifest(count: 3)), .init(body: DAVSyncScenario.tasks(count: 3, startIndex: 0))])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config,
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let scheduler = SyncScheduler(syncEngine: engine, keychainManager: keychain, onWidgetReload: {})
        await scheduler.syncNow(modelContext: container.mainContext)
        try await keychain.delete(for: first.id); try await keychain.delete(for: second.id)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 3)
        #expect(scheduler.lastSyncDate == nil, "A partial run must not advance overall success")
        #expect(scheduler.lastSyncFailure?.category == .server)
    }
    @Test("Edits during a paused upload queue one follow-up run")
    @MainActor
    func editedDuringSyncQueuesDrain() async throws {
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container)
        let list = TaskList(serverURL: "/one/", name: "Tasks", colorHex: "#007AFF")
        list.account = try container.mainContext.fetch(FetchDescriptor<ServerAccount>()).first
        container.mainContext.insert(list)
        let local = TaskItem(uid: "local", title: "Before")
        local.taskList = list; local.isDirty = true
        container.mainContext.insert(local); try container.mainContext.save()
        let host = "queue-" + UUID().uuidString.lowercased() + ".invalid"
        let gate = ScriptedDAVProtocol.Gate()
        let responses = DAVSyncScenario.discovery(paths: ["/one/"])
            + [.init(body: DAVSyncScenario.manifest(count: 0)),
               .init(status: 201, body: "", headers: ["ETag": "pushed"], gate: gate)]
            + DAVSyncScenario.discovery(paths: ["/one/"])
            + [.init(body: DAVSyncScenario.manifest(count: 0)),
               .init(status: 204, body: "", headers: ["ETag": "newer-pushed"])]
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let keychain = KeychainManager(service: "nowthis.performance-tests." + UUID().uuidString)
        try await keychain.save(password: "fixture", for: accountID)
        let account = try #require(try container.mainContext.fetch(FetchDescriptor<ServerAccount>()).first)
        account.serverBaseURL = "https://" + host; try container.mainContext.save()
        let scheduler = SyncScheduler(syncEngine: engine, keychainManager: keychain, onWidgetReload: {})
        let run = Task { @MainActor in await scheduler.syncNow(modelContext: container.mainContext) }
        for _ in 0..<500 where ScriptedDAVProtocol.requests(host: host).count < 5 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ScriptedDAVProtocol.requests(host: host).last?.method == "PUT")
        local.title = "After"; local.isDirty = true; try container.mainContext.save()
        scheduler.syncAfterChange(modelContext: container.mainContext)
        scheduler.syncAfterChange(modelContext: container.mainContext)
        gate.release(); await run.value
        try await keychain.delete(for: accountID)
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.filter { $0.method == "PROPFIND" }.count == 6)
        let uploads = requests.filter { $0.method == "PUT" }
        #expect(uploads.count == 2)
        #expect(uploads.last?.ifMatch == "\"pushed\"")
        #expect(String(decoding: uploads.last!.body, as: UTF8.self).contains("SUMMARY:After"))
        #expect(!scheduler.isSyncing)
    }

}
