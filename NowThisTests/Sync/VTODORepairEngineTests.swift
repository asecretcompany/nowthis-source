import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Legacy opaque destination repair", .serialized)
@MainActor
struct VTODORepairEngineTests {
    private let raw = "BEGIN:VTODO\nUID:repair\nSUMMARY:Original\nCLASS:PRIVATE\nRELATED-TO;RELTYPE=SIBLING:source-related\nATTACH:https://example.invalid/source.pdf\nBEGIN:VALARM\nTRIGGER:-PT15M\nACTION:EMAIL\nDESCRIPTION:Keep me\nEND:VALARM\nEND:VTODO"

    private func fixture(_ configuration: ModelConfiguration) throws -> ModelContainer {
        let c = try ModelContainer(for: Schema(SchemaV2.models), configurations: configuration)
        let context = c.mainContext
        let account = ServerAccount(displayName: "Repair", serverBaseURL: "https://unused.invalid", username: "fixture")
        context.insert(account)
        for path in ["/source/", "/destination/"] {
            let list = TaskList(serverURL: path, name: path, colorHex: "#007AFF")
            context.insert(list); list.account = account
            list.syncCTag = "c1"; list.lastFullPullDate = Date()
            SyncEngine.markCategoriesCaughtUp(listID: list.id)
        }
        let task = TaskItem(uid: "repair", title: "Local title")
        context.insert(task)
        task.taskList = account.taskLists.first { $0.serverURL == "/destination/" }
        task.pendingMoveFromListID = account.taskLists.first { $0.serverURL == "/source/" }?.id
        task.pendingMoveFromHref = "/source/repair.ics"
        task.remoteHref = "/destination/repair.ics"; task.etag = "stripped"
        task.isLocalOnly = false; task.isDirty = false; task.attachmentStateKnown = true
        task.reminderOffset = 900
        try context.save()
        return c
    }

    private func run(_ c: ModelContainer, responses: [ScriptedDAVProtocol.Response], duringPut: (() throws -> Void)? = nil) async throws -> [ScriptedDAVProtocol.RecordedRequest] {
        let account = try #require(try c.mainContext.fetch(FetchDescriptor<ServerAccount>()).first)
        let host = "repair-" + UUID().uuidString.lowercased() + ".invalid"
        account.serverBaseURL = "https://" + host
        for task in try c.mainContext.fetch(FetchDescriptor<TaskItem>()) {
            try SyncResourceFixture.prove(task, in: c.mainContext)
            try SyncResourceFixture.proveSource(task, etag: "source-baseline", in: c.mainContext)
        }
        try c.mainContext.save()
        for list in account.taskLists where list.syncCTag == "c1" {
            try DAVSyncScenario.seedRecentCheckpoint(for: list, in: c)
        }
        var responses = responses.map { response in
            var response = response
            if response.body == raw { response.headers["ETag"] = "source-baseline" }
            return response
        }
        let gate = ScriptedDAVProtocol.Gate()
        if duringPut != nil { responses[0].gate = gate }
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host,
            responses: DAVSyncScenario.discovery(paths: ["/source/", "/destination/"]) + responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let operation = Task {
            await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: "https://" + host,
                credentials: .init(username: "fixture", password: "fixture"), modelContainer: c, reconcileNotifications: false)
        }
        if let duringPut {
            let deadline = Date().addingTimeInterval(5)
            while !ScriptedDAVProtocol.requests(host: host).contains(where: { $0.method == "PUT" }), Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(ScriptedDAVProtocol.requests(host: host).contains { $0.method == "PUT" })
            do { try duringPut() } catch { gate.release(); _ = await operation.value; throw error }
            gate.release()
        }
        _ = await operation.value
        return ScriptedDAVProtocol.requests(host: host).filter { ["GET", "PUT", "DELETE"].contains($0.method) }
    }

    @Test("Landed legacy destination accepts recovered CLASS and EMAIL before source DELETE")
    func landedDestinationRepairBeforeDelete() async throws {
        let c = try fixture(ModelConfiguration(isStoredInMemoryOnly: true))
        let captured = try await run(c, responses: [.init(status: 200, body: raw)])
        #expect(captured.map(\.method) == ["GET"])
        let task = try #require(try ModelContext(c).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(task.isDirty)
        #expect(task.pendingMoveFromHref == "/source/repair.ics")
        let repaired = try await run(c, responses: [.init(status: 204, body: "", headers: ["ETag": "repaired"]), .init(status: 204, body: "")])
        #expect(repaired.map(\.method) == ["PUT", "DELETE"])
        let put = try #require(repaired.first { $0.method == "PUT" })
        #expect(put.path == "/destination/repair.ics")
        let body = String(decoding: put.body, as: UTF8.self)
        #expect(body.contains("CLASS:PRIVATE")); #expect(body.contains("ACTION:EMAIL"))
        let final = try #require(try ModelContext(c).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(final.pendingMoveFromHref == nil)
    }
    @Test("Changed stripped destination cannot consume recovery before or after capture", arguments: [false, true])
    func destinationImportBeforeCapturePreservesOriginalEvidence(alreadyCaptured: Bool) async throws {
        let c = try fixture(ModelConfiguration(isStoredInMemoryOnly: true))
        if alreadyCaptured { _ = try await run(c, responses: [.init(status: 200, body: raw)]) }
        let edit = ModelContext(c)
        let task = try #require(try edit.fetch(FetchDescriptor<TaskItem>()).first)
        task.taskList?.syncCTag = nil; try edit.save()
        let href = "/destination/repair.ics"
        let stripped = "BEGIN:VTODO\nUID:repair\nSUMMARY:Changed stripped destination\nEND:VTODO"
        let requests = try await run(c, responses: [
            .init(body: DAVSyncScenario.multistatus(DAVSyncScenario.prop(href, "<d:getetag>changed</d:getetag>"))),
            .init(body: DAVSyncScenario.multistatus(DAVSyncScenario.prop(href, "<d:getetag>changed</d:getetag><c:calendar-data>" + stripped + "</c:calendar-data>"))),
            .init(status: alreadyCaptured ? 500 : 200, body: alreadyCaptured ? "failed" : raw)])
        #expect(requests.map(\.method) == (alreadyCaptured ? ["PUT"] : ["GET"]))
        let context = ModelContext(c)
        let stored = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "Local title"); #expect(stored.etag == "stripped")
        #expect(stored.isDirty); #expect(stored.pendingMoveFromHref != nil)
        let state = try #require(try VTODOOpaqueState.load(taskID: stored.id, in: context))
        #expect(state.opaqueProperties.contains("CLASS:PRIVATE"))
        #expect(state.destinationRepairPending == true)
    }

    @Test("Failed repair survives a store reopen and keeps source until a later acceptance", arguments: [500, 403])
    func failedRepairSurvivesRelaunch(status: Int) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let configuration = ModelConfiguration(url: url)
        do {
            let c = try fixture(configuration)
            _ = try await run(c, responses: [.init(status: 200, body: raw)])
            let failed = try await run(c, responses: [.init(status: status, body: "failed")])
            #expect(failed.map(\.method) == ["PUT"])
        }
        let reopened = try ModelContainer(for: Schema(SchemaV2.models), configurations: configuration)
        let context = ModelContext(reopened)
        let stored = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.isDirty); #expect(stored.pendingMoveFromHref == "/source/repair.ics")
        #expect(stored.taskList?.serverURL == "/destination/")
        #expect(stored.remoteHref == "/destination/repair.ics")
        #expect(stored.pendingMoveFromListID != nil)
        let state = try #require(try VTODOOpaqueState.load(taskID: stored.id, in: context))
        #expect(state.destinationRepairPending == true)
        #expect(state.opaqueProperties.contains("CLASS:PRIVATE"))
        #expect(state.alarmBlocks.joined().contains("ACTION:EMAIL"))
        let retried = try await run(reopened, responses: [.init(status: 204, body: "", headers: ["ETag": "accepted"]), .init(status: 204, body: "")])
        #expect(retried.map(\.method) == ["PUT", "DELETE"])
        let body = String(decoding: try #require(retried.first).body, as: UTF8.self)
        #expect(body.contains("CLASS:PRIVATE")); #expect(body.contains("ACTION:EMAIL"))
    }

    @Test("Repair conflict rebases remote fields and retries recovered data before cleanup", arguments: [false, true])
    func repairConflictRebasesAndRetries(remoteAlarm: Bool) async throws {
        let c = try fixture(ModelConfiguration(isStoredInMemoryOnly: true))
        _ = try await run(c, responses: [.init(status: 200, body: raw)])
        let edit = ModelContext(c)
        let existing = try #require(try edit.fetch(FetchDescriptor<TaskItem>()).first)
        existing.opaqueAttachments = ["ATTACH:https://example.invalid/source.pdf"]
        try edit.save()
        let alarm = remoteAlarm ? "BEGIN:VALARM\nTRIGGER:-PT15M\nACTION:DISPLAY\nDESCRIPTION:Remote alarm\nEND:VALARM\n" : ""
        let requests = try await run(c, responses: [.init(status: 412, body: ""),
            .init(status: 200, body: "BEGIN:VTODO\nUID:repair\nSUMMARY:Remote change\nCLASS:PUBLIC\nX-REMOTE:preserve\nRELATED-TO;RELTYPE=SIBLING:remote-related\nATTACH:https://example.invalid/remote.pdf\n" + alarm + "END:VTODO", headers: ["ETag": "changed"]),
            .init(status: 500, body: "failed")])
        #expect(requests.map(\.method) == ["PUT", "GET", "PUT"])
        let initialBody = String(decoding: try #require(requests.first).body, as: UTF8.self)
        #expect(initialBody.contains("ATTACH:https://example.invalid/source.pdf"))
        let retry = try #require(requests.last)
        #expect(retry.ifMatch == "\"changed\"")
        let retryBody = String(decoding: retry.body, as: UTF8.self)
        #expect(retryBody.contains("SUMMARY:Remote change"))
        #expect(retryBody.contains("CLASS:PUBLIC")); #expect(!retryBody.contains("CLASS:PRIVATE")); #expect(retryBody.contains("ACTION:EMAIL"))
        #expect(retryBody.contains("RELATED-TO;RELTYPE=SIBLING:source-related")); #expect(retryBody.contains("RELATED-TO;RELTYPE=SIBLING:remote-related"))
        #expect(retryBody.contains("ATTACH:https://example.invalid/source.pdf")); #expect(retryBody.contains("ATTACH:https://example.invalid/remote.pdf"))
        #expect(retryBody.contains("X-REMOTE:preserve")); #expect(retryBody.contains("DESCRIPTION:Remote alarm") == remoteAlarm)
        let context = ModelContext(c)
        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(task.title == "Remote change"); #expect(task.reminderOffset == 900)
        #expect(task.etag == "changed"); #expect(task.isDirty); #expect(task.pendingMoveFromHref != nil)
        let state = try #require(try VTODOOpaqueState.load(taskID: task.id, in: context))
        #expect(state.destinationRepairPending == true); #expect(state.alarmBlocks.joined().contains("ACTION:EMAIL"))
        let accepted = try await run(c, responses: [.init(status: 204, body: "", headers: ["ETag": "accepted"]),
            .init(status: 204, body: "")])
        #expect(accepted.map(\.method) == ["PUT", "DELETE"])
        #expect(accepted.first?.ifMatch == "\"changed\"")
        let acceptedBody = String(decoding: try #require(accepted.first).body, as: UTF8.self)
        #expect(acceptedBody.contains("SUMMARY:Remote change"))
        #expect(acceptedBody.contains("CLASS:PUBLIC")); #expect(!acceptedBody.contains("CLASS:PRIVATE")); #expect(acceptedBody.contains("ACTION:EMAIL"))
        #expect(acceptedBody.contains("RELATED-TO;RELTYPE=SIBLING:source-related")); #expect(acceptedBody.contains("RELATED-TO;RELTYPE=SIBLING:remote-related"))
        #expect(acceptedBody.contains("ATTACH:https://example.invalid/source.pdf")); #expect(acceptedBody.contains("ATTACH:https://example.invalid/remote.pdf"))
        #expect(acceptedBody.contains("X-REMOTE:preserve")); #expect(acceptedBody.contains("DESCRIPTION:Remote alarm") == remoteAlarm)
        let final = try #require(try ModelContext(c).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(final.pendingMoveFromHref == nil)
    }

    @Test("Repair conflict without a current ETag keeps recovered state and source")
    func repairConflictWithoutETagFailsClosed() async throws {
        let c = try fixture(ModelConfiguration(isStoredInMemoryOnly: true))
        _ = try await run(c, responses: [.init(status: 200, body: raw)])
        let requests = try await run(c, responses: [.init(status: 412, body: ""),
            .init(status: 200, body: "BEGIN:VTODO\nUID:repair\nSUMMARY:Remote change\nEND:VTODO")])
        #expect(requests.map(\.method) == ["PUT", "GET"])
        let context = ModelContext(c)
        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(task.title == "Local title"); #expect(task.etag == "stripped")
        #expect(task.isDirty); #expect(task.pendingMoveFromHref != nil)
        let state = try #require(try VTODOOpaqueState.load(taskID: task.id, in: context))
        #expect(state.destinationRepairPending == true)
        #expect(state.opaqueProperties.contains("CLASS:PRIVATE"))
        #expect(state.alarmBlocks.joined().contains("ACTION:EMAIL"))
    }

    @Test("Newer fields allow accepted repair cleanup; newer opaque state keeps the gate", arguments: [false, true])
    func editsDuringRepairPut(metadataEdit: Bool) async throws {
        let c = try fixture(ModelConfiguration(isStoredInMemoryOnly: true))
        _ = try await run(c, responses: [.init(status: 200, body: raw)])
        let requests = try await run(c, responses: [.init(status: 204, body: "", headers: ["ETag": "accepted"]), .init(status: 204, body: "")]) {
            let context = ModelContext(c)
            let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
            task.title = "Newer local edit"; task.isDirty = true
            if metadataEdit {
                var state = try #require(try VTODOOpaqueState.load(taskID: task.id, in: context))
                state.opaqueProperties.append("COMMENT:newer")
                try state.store(taskID: task.id, in: context)
            }
            try context.save()
        }
        #expect(requests.map(\.method) == (metadataEdit ? ["PUT"] : ["PUT", "DELETE"]))
        let context = ModelContext(c)
        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(task.title == "Newer local edit"); #expect(task.isDirty)
        #expect((task.pendingMoveFromHref != nil) == metadataEdit)
        let state = try #require(try VTODOOpaqueState.load(taskID: task.id, in: context))
        #expect((state.destinationRepairPending == true) == metadataEdit)
        #expect(state.opaqueProperties.contains("COMMENT:newer") == metadataEdit)
        #expect(state.alarmBlocks.joined().contains("ACTION:EMAIL"))
    }

}
