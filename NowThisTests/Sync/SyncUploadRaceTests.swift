import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Upload acknowledgement races", .serialized)
@MainActor
struct SyncUploadRaceTests {
    @Test("A successful old upload keeps a newer saved or unsaved edit pending", arguments: [true, false])
    func newerEditSurvives(saveEdit: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let accountID = try DAVSyncScenario.account(in: container)
        let account = try #require(try context.fetch(FetchDescriptor<ServerAccount>()).first)
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        list.account = account; context.insert(list)
        let local = TaskItem(uid: "local", title: "Before")
        local.taskList = list; local.isDirty = true
        context.insert(local); try context.save()
        let host = "ack-" + UUID().uuidString.lowercased() + ".invalid"
        let gate = ScriptedDAVProtocol.Gate()
        defer { gate.release() }
        let responses = DAVSyncScenario.discovery(paths: ["/one/"]) + [
            .init(body: DAVSyncScenario.manifest(count: 0)),
            .init(status: 201, body: "", headers: ["ETag": "accepted-before"], gate: gate)]
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let run = Task { await engine.performFullSyncOutcome(accountID: accountID,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"), modelContainer: container) }
        for _ in 0..<500 where ScriptedDAVProtocol.requests(host: host).last?.method != "PUT" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ScriptedDAVProtocol.requests(host: host).last?.method == "PUT")
        #expect(String(decoding: ScriptedDAVProtocol.requests(host: host).last!.body, as: UTF8.self).contains("SUMMARY:Before"))
        local.title = "After"; local.isDirty = true; local.lastModifiedDate = Date()
        if saveEdit { try context.save() }
        gate.release(); _ = await run.value
        let refreshed = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(refreshed.title == "After")
        #expect(refreshed.isDirty, "An acknowledgement may only clear the exact bytes sent")
        if saveEdit {
            let persisted = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
            #expect(persisted.title == "After")
            #expect(persisted.isDirty)
        }
        withExtendedLifetime(container) {}
    }
    @Test("Moving or deleting during an accepted PUT never acknowledges the new destination", arguments: [true, false])
    func moveOrDeleteDuringUpload(move: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let accountID = try DAVSyncScenario.account(in: container)
        let account = try #require(try context.fetch(FetchDescriptor<ServerAccount>()).first)
        let source = TaskList(serverURL: "/one/", name: "Source", colorHex: "#007AFF")
        let destination = TaskList(serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        source.account = account; destination.account = account
        context.insert(source); context.insert(destination)
        let local = TaskItem(uid: "moving", title: "Rocket inspection")
        local.taskList = source; local.isDirty = true
        context.insert(local)
        let host = "move-ack-" + UUID().uuidString.lowercased() + ".invalid"
        account.serverBaseURL = "https://" + host; try context.save()
        let gate = ScriptedDAVProtocol.Gate(); defer { gate.release() }
        let responses = DAVSyncScenario.discovery(paths: ["/one/"]) + [
            .init(body: DAVSyncScenario.manifest(count: 0)),
            .init(status: 201, body: "", headers: ["ETag": "accepted"], gate: gate),
            .init(status: 204, body: "")]
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let run = Task { await engine.performFullSyncOutcome(accountID: accountID,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"), modelContainer: container) }
        for _ in 0..<500 where ScriptedDAVProtocol.requests(host: host).last?.method != "PUT" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ScriptedDAVProtocol.requests(host: host).last?.method == "PUT")
        if move { local.taskList = destination; local.remoteHref = nil; local.etag = nil }
        else { local.isDeletedLocally = true }
        local.lastModifiedDate = Date(); local.isDirty = true; try context.save()
        gate.release(); _ = await run.value
        let live = try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).filter { !$0.isDeletedLocally }
        if move {
            #expect(live.count == 1)
            #expect(live.first?.taskList?.id == destination.id)
            #expect(live.first?.isDirty == true)
            #expect(live.first?.remoteHref == nil)
        } else { #expect(live.isEmpty) }
        #expect(ScriptedDAVProtocol.requests(host: host).contains { $0.method == "DELETE" }, "The accepted old copy must be queued for cleanup")
        withExtendedLifetime(container) {}
    }

    @Test("Cancelling a server-accepted PUT leaves the edit pending and a retry converges")
    func acceptedThenCancelledRetries() async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let accountID = try DAVSyncScenario.account(in: container)
        let account = try #require(try context.fetch(FetchDescriptor<ServerAccount>()).first)
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        list.account = account; context.insert(list)
        let local = TaskItem(uid: "retry", title: "Train moon pigeons")
        local.taskList = list; local.isDirty = true; context.insert(local); try context.save()
        let host = "cancel-ack-" + UUID().uuidString.lowercased() + ".invalid"
        let gate = ScriptedDAVProtocol.Gate(); defer { gate.release() }
        let config = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
            .init(body: DAVSyncScenario.manifest(count: 0)), .init(status: 201, body: "", gate: gate)])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let run = Task { await engine.performFullSyncOutcome(accountID: accountID,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"), modelContainer: container) }
        for _ in 0..<500 where ScriptedDAVProtocol.requests(host: host).last?.method != "PUT" { try await Task.sleep(for: .milliseconds(10)) }
        run.cancel(); let cancelled = await run.value
        #expect(cancelled.status == .cancelled)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.isDirty == true)
        gate.release()
        _ = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
            .init(body: DAVSyncScenario.manifest(count: 0)), .init(status: 201, body: "", headers: ["ETag": "retry-accepted"])])
        let retried = await engine.performFullSyncOutcome(accountID: accountID,
            serverBaseURL: "https://" + host, credentials: .init(username: "fixture", password: "fixture"), modelContainer: container)
        #expect(retried.status == .completed)
        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(saved.count == 1)
        #expect(saved.first?.isDirty == false)
        withExtendedLifetime(container) {}
    }

    @Test("Restoring a task while DELETE is suspended preserves the newer task")
    func undoDeleteDuringRequest() async throws {
        let container = try DAVSyncScenario.container(); let context = container.mainContext
        let accountID = try DAVSyncScenario.account(in: container)
        let account = try #require(try context.fetch(FetchDescriptor<ServerAccount>()).first)
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        list.account = account; context.insert(list)
        let local = TaskItem(uid: "undo", title: "Before")
        local.taskList = list; local.remoteHref = "/one/undo.ics"; local.etag = "before"
        local.isLocalOnly = false; local.isDeletedLocally = true
        context.insert(local); try context.save()
        let host = "undo-delete-" + UUID().uuidString.lowercased() + ".invalid"
        let gate = ScriptedDAVProtocol.Gate(); defer { gate.release() }
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host,
            responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
                .init(body: DAVSyncScenario.manifest(count: 0)), .init(status: 204, body: "", gate: gate)]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let run = Task { await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: .init(username: "fixture", password: "fixture"), modelContainer: container) }
        for _ in 0..<500 where ScriptedDAVProtocol.requests(host: host).last?.method != "DELETE" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ScriptedDAVProtocol.requests(host: host).last?.method == "DELETE")
        local.isDeletedLocally = false; local.title = "Restored newer edit"; local.isDirty = true
        try context.save(); gate.release(); _ = await run.value
        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(saved.count == 1)
        #expect(saved.first?.title == "Restored newer edit")
        #expect(saved.first?.isDirty == true)
        withExtendedLifetime(container) {}
    }

}
