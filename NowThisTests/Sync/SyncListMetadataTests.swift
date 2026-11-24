import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - List Metadata Round Trip

/// Covers the rule that keeps a user's list colour: a locally edited name or colour is
/// not replaced by the server's copy until that edit has actually been pushed.
///
/// Calendar discovery adopted the remote name and colour unconditionally, on every sync,
/// before the CTag delta-skip even ran — and nothing ever sent a colour change back, since
/// the client had no PROPPATCH at all. So recolouring a list was a local change that the
/// next sync (about two seconds later) reverted. That is the "colours all return back to
/// blue" report, and the blue itself came from the `?? .blue` fallback at the render sites.
@Suite("Sync — List Metadata")
@MainActor
struct SyncListMetadataTests {

    /// Held by the caller for the test's lifetime — returning `.mainContext` from a factory
    /// deallocates the container out from under the context and SIGTRAPs the test process.
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    @Test("A list with an unpushed colour edit keeps it when the server says otherwise")
    func dirtyListKeepsLocalColor() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "/calendars/x/", name: "Work", colorHex: "#FF3B30")
        list.isMetadataDirty = true
        context.insert(list)

        list.applyRemoteMetadata(name: "Work", colorHex: "#007AFFFF")

        #expect(list.colorHex == "#FF3B30",
                "an unpushed colour edit must survive the discovery pass that follows it")
    }

    @Test("A list with no local edit adopts the server's colour")
    func cleanListAdoptsRemoteColor() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "/calendars/x/", name: "Work", colorHex: "#007AFF")
        context.insert(list)

        list.applyRemoteMetadata(name: "Work Renamed", colorHex: "#34C759FF")

        #expect(list.colorHex == "#34C759FF", "a colour set on another device must still arrive")
        #expect(list.name == "Work Renamed", "so must a rename")
    }

    @Test("An empty remote colour never blanks the local one")
    func emptyRemoteColorIgnored() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "/calendars/x/", name: "Work", colorHex: "#FF3B30")
        context.insert(list)

        list.applyRemoteMetadata(name: "Work", colorHex: "")

        #expect(list.colorHex == "#FF3B30", "a server with no colour set says nothing, not 'none'")
    }

    @Test("The PROPPATCH body carries the display name and an 8-digit colour")
    func propPatchBodyIsWellFormed() {
        let body = CalDAVClient.calendarPropertyPatchBody(name: "Work", colorHex: "#FF3B30")

        #expect(body.contains("<d:displayname>Work</d:displayname>"))
        #expect(body.contains("#FF3B30FF"),
                "calendar-color is Apple's extension and its convention carries the alpha byte")
        #expect(body.contains("propertyupdate"), "a PROPPATCH body is a propertyupdate document")
    }

    @Test("A colour that already carries alpha is not given a second one")
    func propPatchBodyDoesNotDoubleAlpha() {
        let body = CalDAVClient.calendarPropertyPatchBody(name: "Work", colorHex: "#FF3B30FF")

        #expect(body.contains("#FF3B30FF"))
        #expect(!body.contains("#FF3B30FFFF"), "appending alpha blindly is what corrupted it")
    }
}

extension SyncListMetadataTests {
    private var colorProperty: String { "<x:calendar-color xmlns:x=\"http://apple.com/ns/ical/\"/>" }

    @Test("PROPPATCH accepts only explicit per-property evidence on its exact resource", arguments: [
        "split", "mixed", "dependent", "missing", "duplicate", "duplicate-in-group", "foreign",
        "extra-success", "extra-failure", "extra-with-denial",
        "other-href", "other-final-url", "two-responses", "empty-href", "response-error",
        "missing-status", "two-props", "nested-property", "200", "204"
    ])
    func patchResponseEvidence(fixture: String) async throws {
        let host = "metadata-proof-" + UUID().uuidString.lowercased() + ".invalid"
        let target = "/one/"
        let name = "<d:displayname/>"
        let color = colorProperty
        let ok = "HTTP/1.1 200 OK"
        let denied = "HTTP/1.1 403 Forbidden"
        let dependent = "HTTP/1.1 424 Failed Dependency"
        let success = propstat(name, status: ok) + propstat(color, status: "HTTP/1.1 201 Created")
        let code = Int(fixture) ?? 207
        var href = target
        var groups = success
        switch fixture {
        case "mixed": groups = propstat(name, status: ok) + propstat(color, status: denied)
        case "dependent": groups = propstat(name, status: denied) + propstat(color, status: dependent)
        case "missing": groups = propstat(name, status: ok)
        case "duplicate": groups += propstat(name, status: denied)
        case "duplicate-in-group": groups = propstat(name + name + color, status: ok)
        case "foreign": groups = propstat(name + "<d:calendar-color/>", status: ok)
        case "extra-success": groups += propstat("<d:getetag/>", status: ok)
        case "extra-failure": groups += propstat("<f:color xmlns:f=\"urn:foreign\"/>", status: denied)
        case "extra-with-denial": groups = propstat(name, status: denied) + propstat(color + "<d:getetag/>", status: ok)
        case "other-href": href = "/two/"
        case "empty-href": groups += "<d:href/>"
        case "response-error": groups += "<d:status>" + denied + "</d:status>"
        case "missing-status": groups = propstat(name, status: ok) + "<d:propstat><d:prop>" + color + "</d:prop></d:propstat>"
        case "two-props": groups = "<d:propstat><d:prop>" + name + "</d:prop><d:prop>" + color + "</d:prop><d:status>" + ok + "</d:status></d:propstat>"
        case "nested-property": groups = propstat("<d:wrapper>" + name + "</d:wrapper>" + color, status: ok)
        default: break
        }
        let result = response(href, groups)
        let body = code == 207 ? DAVSyncScenario.multistatus(result + (fixture == "two-responses" ? result : "")) : ""
        let base = "https://" + host
        let finalURL = fixture == "other-final-url" ? URL(string: base + "/two/") : nil
        let client = CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host,
            responses: [.init(status: code, body: body, responseURL: finalURL)]), retryPolicy: .init(maxAttempts: 1, baseDelay: 0))
        let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
        do {
            try await client.updateCalendarProperties(baseURL: base, calendarPath: target, name: "New",
                colorHex: "#AABBCC", credentials: credentials)
            #expect(fixture == "split", "An unproven response cannot acknowledge list metadata")
        } catch CalDAVError.forbidden {
            #expect(fixture == "mixed" || fixture == "dependent")
        } catch CalDAVError.invalidResponse {
            #expect(!["split", "mixed", "dependent"].contains(fixture))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A rejected list edit stays dirty while another list syncs")
    func rejectedMetadataSurvivesRediscovery() async throws {
        let host = "metadata-rejection-" + UUID().uuidString.lowercased() + ".invalid"
        let container = try makeContainer()
        let (accountID, list) = try makeMetadataList(host: host, container: container)
        let discovery = DAVSyncScenario.discovery(paths: ["/one/", "/two/"])
        let groups = propstat("<d:displayname/>", status: "HTTP/1.1 424 Failed Dependency")
            + propstat(colorProperty, status: "HTTP/1.1 403 Forbidden")
        let outcome = await runMetadataSync(host: host, accountID: accountID, container: container,
            responses: discovery + [.init(body: DAVSyncScenario.multistatus(response("/one/", groups))),
                try #require(discovery.last), .init(body: DAVSyncScenario.manifest(count: 0, path: "/one/")),
                .init(body: DAVSyncScenario.manifest(count: 0, path: "/two/"))])
        #expect(outcome.status == .partial)
        #expect(outcome.failures.contains { $0.category == .accessDenied })
        let lists = try ModelContext(container).fetch(FetchDescriptor<TaskList>())
        let saved = try #require(lists.first { $0.id == list.id })
        #expect(saved.name == "Edited")
        #expect(saved.colorHex == "#AABBCC")
        #expect(saved.isMetadataDirty)
        #expect(lists.contains { $0.serverURL.hasSuffix("/two/") })
        #expect(ScriptedDAVProtocol.requests(host: host).contains { $0.method == "REPORT" && $0.path == "/two" })
    }

    @Test("A successful suspended patch only acknowledges the snapshot sent", arguments: [true, false])
    func acceptedOlderPatchLeavesRenamePending(saveEdit: Bool) async throws {
        let host = "metadata-race-" + UUID().uuidString.lowercased() + ".invalid"
        let container = try makeContainer()
        let (accountID, list) = try makeMetadataList(host: host, container: container)
        let context = container.mainContext
        context.autosaveEnabled = false
        let discovery = DAVSyncScenario.discovery(paths: ["/one/"])
        let gate = ScriptedDAVProtocol.Gate()
        defer { gate.release() }
        let ack = DAVSyncScenario.multistatus(DAVSyncScenario.prop("/one/", "<d:displayname/>" + colorProperty))
        var refreshed = try #require(discovery.last)
        refreshed.body = refreshed.body.replacingOccurrences(of: ">Fixture<", with: ">Edited<")
        let manifest = ScriptedDAVProtocol.Response(body: DAVSyncScenario.manifest(count: 0))
        let firstResponses = discovery + [.init(body: ack, gate: gate), refreshed, manifest]
        let run = Task { await runMetadataSync(host: host, accountID: accountID, container: container, responses: firstResponses) }
        for _ in 0..<500 where ScriptedDAVProtocol.requests(host: host).last?.method != "PROPPATCH" {
            try await Task.sleep(for: .milliseconds(10))
        }
        let patch = try #require(ScriptedDAVProtocol.requests(host: host).last { $0.method == "PROPPATCH" })
        #expect(String(decoding: patch.body, as: UTF8.self).contains(">Edited<"))
        list.name = "Newer"
        list.isMetadataDirty = true
        if saveEdit { try context.save() }
        gate.release()
        let outcome = await run.value
        #expect(outcome.status == .partial)
        let read = ModelContext(container)
        let persisted = try #require(try read.fetch(FetchDescriptor<TaskList>()).first)
        #expect(persisted.name == (saveEdit ? "Newer" : "Edited"))
        #expect(persisted.isMetadataDirty)
        #expect(list.name == "Newer")
        #expect(list.isMetadataDirty)
        if !saveEdit { try context.save() }

        refreshed.body = refreshed.body.replacingOccurrences(of: ">Edited<", with: ">Newer<")
        let second = await runMetadataSync(host: host, accountID: accountID, container: container,
            responses: discovery + [.init(body: ack), refreshed, manifest])
        #expect(second.status == .completed)
        let retry = try #require(ScriptedDAVProtocol.requests(host: host).first { $0.method == "PROPPATCH" })
        #expect(String(decoding: retry.body, as: UTF8.self).contains(">Newer<"))
        let retried = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskList>()).first)
        #expect(retried.name == "Newer")
        #expect(!retried.isMetadataDirty)
    }

    @Test("A successful suspended patch cannot acknowledge a new target or account", arguments: [true, false])
    func acceptedPatchCannotAcknowledgeChangedScope(changeAccount: Bool) async throws {
        let host = "metadata-scope-" + UUID().uuidString.lowercased() + ".invalid"
        let container = try makeContainer()
        let (accountID, list) = try makeMetadataList(host: host, container: container)
        let context = container.mainContext
        let gate = ScriptedDAVProtocol.Gate()
        defer { gate.release() }
        let discovery = DAVSyncScenario.discovery(paths: ["/one/"])
        let ack = DAVSyncScenario.multistatus(DAVSyncScenario.prop("/one/", "<d:displayname/>" + colorProperty))
        let refresh = try #require(DAVSyncScenario.discovery(paths: ["/two/"]).last)
        let responses = discovery + [.init(body: ack, gate: gate), refresh,
            .init(body: DAVSyncScenario.manifest(count: 0, path: "/two/"))]
        let run = Task { await runMetadataSync(host: host, accountID: accountID, container: container, responses: responses) }
        for _ in 0..<500 where ScriptedDAVProtocol.requests(host: host).last?.method != "PROPPATCH" {
            try await Task.sleep(for: .milliseconds(10))
        }
        let patch = try #require(ScriptedDAVProtocol.requests(host: host).last { $0.method == "PROPPATCH" })
        #expect(patch.url.absoluteString == "https://" + host + "/one/")
        if changeAccount {
            list.account?.username = "another-user"
        } else {
            list.serverURL = "/two/"
        }
        try context.save()
        gate.release()

        #expect(await run.value.status == (changeAccount ? .cancelled : .partial))
        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskList>())
        #expect(saved.map(\.id) == [list.id])
        #expect(saved.first?.serverURL == (changeAccount ? "/one/" : "/two/"))
        #expect(saved.first?.name == "Edited")
        #expect(saved.first?.isMetadataDirty == true)
        if changeAccount { #expect(ScriptedDAVProtocol.requests(host: host).last?.method == "PROPPATCH") }
    }

    @Test("Read-only discovery persists privilege independently of a pending rename", arguments: [false, true])
    func readOnlyDiscoveryPreservesPendingRename(background: Bool) async throws {
        let host = "metadata-privilege-" + UUID().uuidString.lowercased() + ".invalid"
        let container = try makeContainer()
        let (accountID, list) = try makeMetadataList(host: host, container: container)
        let main = container.mainContext
        main.autosaveEnabled = false
        list.isMetadataDirty = false
        try main.save()
        list.name = "Pending rename"
        list.colorHex = "#AABB00"
        list.isMetadataDirty = true

        let outcome = await runMetadataSync(host: host, accountID: accountID, container: container,
            responses: readOnlyListResponses(), background: background)
        #expect(outcome.status == .completed)
        #expect(outcome.changedListIDs.contains(list.id))
        let read = ModelContext(container)
        let persisted = try #require(try read.fetch(FetchDescriptor<TaskList>()).first)
        #expect(persisted.isReadOnly)
        #expect(persisted.name == "Edited")
        #expect(persisted.colorHex == "#AABBCC")
        #expect(!persisted.isMetadataDirty)
        #expect(list.name == "Pending rename")
        #expect(list.colorHex == "#AABB00")
        #expect(list.isMetadataDirty)
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "PROPPATCH" })
        try main.save()
        let afterSave = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskList>()).first)
        #expect(afterSave.name == "Pending rename")
        #expect(afterSave.isReadOnly)
    }

    @Test("Read-only discovery skips lists with pending binding changes or deletion",
          arguments: ["href", "calendar path", "account", "delete"])
    func readOnlyDiscoveryRespectsPendingBinding(change: String) async throws {
        let host = "metadata-privilege-binding-" + UUID().uuidString.lowercased() + ".invalid"
        let container = try makeContainer()
        let (accountID, list) = try makeMetadataList(host: host, container: container)
        let main = container.mainContext
        main.autosaveEnabled = false
        let id = list.id
        switch change {
        case "href": list.serverURL = "/two/"
        case "calendar path": list.calendarPath = "/two/"
        case "account": list.account = nil
        case "delete": main.delete(list)
        default: Issue.record("Unexpected fixture \(change)")
        }
        let outcome = await runMetadataSync(host: host, accountID: accountID, container: container,
            responses: readOnlyListResponses(), background: true)
        let read = ModelContext(container)
        let persisted = try #require(try read.fetch(FetchDescriptor<TaskList>()).first)
        #expect(persisted.id == id)
        #expect(!persisted.isReadOnly)
        #expect(!outcome.changedListIDs.contains(id))
    }

    private func readOnlyListResponses() -> [ScriptedDAVProtocol.Response] {
        var discovery = DAVSyncScenario.discovery(paths: ["/one/"])
        discovery[2].body = discovery[2].body.replacingOccurrences(of: "</d:displayname>", with:
            "</d:displayname><d:current-user-privilege-set><d:privilege><d:read/></d:privilege></d:current-user-privilege-set>")
        return discovery + [.init(body: DAVSyncScenario.manifest(count: 0))]
    }

    @Test("Final 503 on collection metadata stops later requests and survives a background delivery",
          arguments: ["MKCALENDAR", "PROPPATCH"])
    func collectionMetadataWaitStopsAccount(method: String) async throws {
        let container = try makeContainer()
        let host = "metadata-wait-" + UUID().uuidString.lowercased() + ".invalid"
        let baseURL = "https://" + host
        let (accountID, list) = try makeMetadataList(host: host, container: container)
        if method == "MKCALENDAR" {
            list.serverURL = ""
            try container.mainContext.save()
        }
        let discovery = DAVSyncScenario.discovery(paths: method == "MKCALENDAR" ? [] : ["/one/"])
        let responses = discovery + [.init(status: 503, body: "", headers: ["Retry-After": "1800"])] + discovery
        let wall = Date()
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0), now: { wall }))
        let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
        let first = await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
        let methods = ["PROPFIND", "PROPFIND", "PROPFIND", method]
        #expect(first.status == .partial)
        #expect(first.failures.first?.httpStatusCode == 503)
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.method) == methods)
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskList>()).first)
        #expect(saved.isMetadataDirty)
        #expect(saved.serverURL == (method == "MKCALENDAR" ? "" : "/one/"))

        do {
            try await engine.performBackgroundSync(accountID: accountID, serverBaseURL: baseURL,
                credentials: credentials, modelContainer: container, reconcileNotifications: false)
            Issue.record("Expected the retained server deadline on the next delivery")
        } catch let error as RetryDeferredError {
            #expect(error.deadline == wall.addingTimeInterval(1800))
        } catch {
            Issue.record("Expected the retained server deadline, received \(type(of: error))")
        }
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.method) == methods)
    }

    private func propstat(_ properties: String, status: String) -> String {
        "<d:propstat><d:prop>" + properties + "</d:prop><d:status>" + status + "</d:status></d:propstat>"
    }

    private func response(_ href: String, _ propstats: String) -> String {
        "<d:response><d:href>" + href + "</d:href>" + propstats + "</d:response>"
    }

    private func makeMetadataList(host: String, container: ModelContainer) throws -> (String, TaskList) {
        let context = container.mainContext
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: "https://" + host, username: "fixture")
        context.insert(account)
        let list = TaskList(serverURL: "/one/", name: "Edited", colorHex: "#AABBCC")
        list.account = account
        list.isMetadataDirty = true
        context.insert(list)
        try context.save()
        return (account.id, list)
    }

    private func runMetadataSync(host: String, accountID: String, container: ModelContainer,
                                 responses: [ScriptedDAVProtocol.Response], background: Bool = false) async -> SyncOutcome {
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
        if background {
            return await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
                credentials: credentials, modelContainer: container, reconcileNotifications: false)
        }
        return await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
    }
}
