import Foundation
import SwiftData
import Testing
@testable import NowThis

@MainActor
struct NextcloudCalendarTransportTests {
    private let login = "person@example.com"
    private let root = "/nextcloud/remote.php/dav/"
    private let principal = "/nextcloud/remote.php/dav/principals/users/backend%40id/"
    private let home = "/nextcloud/remote.php/dav/calendars/backend%40id/"
    private let marker = "calendar-mirror-v1:fixture"

    @Test func discoveredHomePreservesInstallationAndPrincipal() async throws {
        let host = "calendar-path.invalid"
        let targetPath = home + "calendar%20%26%20events/"
        let transport = transport(host, responses: [
            .init(body: xml(root, "<d:current-user-principal><d:href>\(principal)</d:href></d:current-user-principal>")),
            .init(body: xml(principal, "<c:calendar-home-set><d:href>\(home)</d:href></c:calendar-home-set>")),
            .init(body: xml(home, "<d:resourcetype><d:collection/></d:resourcetype>")),
            .init(status: 201, body: ""), .init(body: proof(targetPath))
        ])
        let account = credentials(host)
        let discovery = try await transport.discover(address: NextcloudServerAddress.parse(account.scope.serverBaseURL),
            admitted: account, validate: {})
        #expect(discovery.principalURL?.absoluteString == "https://\(host)\(principal)")
        let target = try NextcloudCalendarAddress.child("calendar & events", of: discovery.calendarHomeURL, collection: true)
        let href = try await transport.ensureCollection(target: target, marker: marker, create: true,
            admitted: account, validate: {}).absoluteString
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND", "MKCALENDAR", "PROPFIND"])
        #expect(requests.map { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.percentEncodedPath }
            == [root, principal, home, targetPath, targetPath])
        #expect(requests.map(\.depth) == ["0", "0", "1", nil, "0"])
        #expect(requests.allSatisfy { $0.basicAuthUsername == login })
        #expect(href == "https://\(host)\(targetPath)")
        #expect(requests.first { $0.method == "MKCALENDAR" }?.url.absoluteString == href)
        #expect(requests.first { $0.method == "MKCALENDAR" }?.ifNoneMatch == "*")
    }

    @Test(arguments: [201, 405, 409, 412, 0])
    func collectionReplyRequiresIndependentProof(status: Int) async throws {
        let host = "calendar-proven-\(status).invalid"
        let path = home + "calendar/"
        let target = try #require(URL(string: "https://\(host)\(path)"))
        let transport = transport(host, responses: [
            status == 0 ? .init(body: "", errorCode: .networkConnectionLost) : .init(status: status, body: ""),
            .init(body: proof(path))
        ])
        #expect(try await transport.ensureCollection(target: target, marker: marker, create: true,
            admitted: credentials(host), validate: {}) == target)
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.method) == ["MKCALENDAR", "PROPFIND"])
    }

    @Test(arguments: ["marker", "duplicate", "duplicateComponent", "nested", "privilege", "redirect", "trash"])
    func uncertainCollectionIsNeverAccepted(reason: String) async throws {
        let host = "calendar-rejected-\(reason).invalid"
        let path = home + "calendar/"
        let target = try #require(URL(string: "https://\(host)\(path)"))
        let validComponents = "<c:supported-calendar-component-set><c:comp name=\"VEVENT\"/></c:supported-calendar-component-set>"
        var evidence = proof(path)
        switch reason {
        case "marker": evidence = evidence.replacingOccurrences(of: marker, with: "foreign")
        case "duplicate": evidence = evidence.replacingOccurrences(of: validComponents, with: validComponents + validComponents)
        case "duplicateComponent": evidence = evidence.replacingOccurrences(of: "<c:comp name=\"VEVENT\"/>",
            with: "<c:comp name=\"VEVENT\"/><c:comp name=\"VEVENT\"/>")
        case "nested": evidence = evidence.replacingOccurrences(of: "<c:comp name=\"VEVENT\"/>", with: "<n:wrapper><c:comp name=\"VEVENT\"/></n:wrapper>")
        case "privilege": evidence = evidence.replacingOccurrences(of: "</d:prop>", with: "<d:current-user-privilege-set><d:privilege><d:read/></d:privilege></d:current-user-privilege-set></d:prop>")
        case "trash": evidence = evidence.replacingOccurrences(of: "</d:prop>", with: "<nc:deleted-at xmlns:nc=\"http://nextcloud.com/ns\">unknown-date</nc:deleted-at></d:prop>")
        default: break
        }
        let finalURL = reason == "redirect" ? URL(string: target.absoluteString + "?different") : nil
        let transport = transport(host, responses: [.init(status: 201, body: ""), .init(body: evidence, responseURL: finalURL)])
        await #expect(throws: (any Error).self) {
            try await transport.ensureCollection(target: target, marker: marker, create: true,
                admitted: credentials(host), validate: {})
        }
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.method) == ["MKCALENDAR", "PROPFIND"])
    }

    @Test func secondWriteUsesAcknowledgedVersion() async throws {
        let host = "calendar-update.invalid"
        let fixture = try fixture(host)
        let transport = transport(host, responses: firstWrite(host, reply: success("first"))
            + existingCollection(host) + [success("second", status: 204)]
            + existingCollection(host) + [success("third", status: 204)])
        var publications = 0
        #expect(try await fixture.sync(transport) { publications += 1 })
        try fixture.edit("After")
        #expect(try await fixture.sync(transport) { publications += 1 })
        try fixture.edit("After again")
        #expect(try await fixture.sync(transport) { publications += 1 })
        let requests = ScriptedDAVProtocol.requests(host: host)
        let writes = requests.filter { $0.method == "PUT" }
        #expect(writes.map(\.ifNoneMatch) == ["*", nil, nil])
        #expect(writes.map(\.ifMatch) == [nil, "\"first\"", "\"second\""])
        #expect(Set(writes.map(\.url)).count == 1)
        let collection = try #require(requests.first { $0.method == "MKCALENDAR" }?.url.absoluteString)
        #expect(collection.hasPrefix("https://\(host)\(home)"))
        #expect(writes.allSatisfy { $0.url.absoluteString.hasPrefix(collection) && $0.basicAuthUsername == login })
        #expect(Set(writes.compactMap { Self.value("UID", in: $0.body) }).count == 1)
        #expect(Set(writes.compactMap { Self.value("X-NOWTHIS-MIRROR-OPERATION", in: $0.body) }).count == 3)
        #expect(writes.compactMap { Self.value("SUMMARY", in: $0.body) } == ["Before", "After", "After again"])
        let receipt = try #require(try persistedNextcloudReceipts(fixture.container).first)
        #expect(receipt.acknowledged?.version.etag.header == "\"third\"")
        #expect(receipt.acknowledged?.version.href == writes.last?.url.absoluteString)
        #expect(receipt.pending == nil)
        #expect(publications == 3)
    }

    @Test(arguments: [false, true])
    func conflictPreservesRemoteEvent(otherUID: Bool) async throws {
        let host = "calendar-conflict-\(otherUID).invalid"
        let fixture = try fixture(host)
        let conflict = ScriptedDAVProtocol.Response(status: 412, body: "", headers: ["ETag": "\"remote\""])
        let recovery = [collectionProof(host), readback(host, tag: "\"remote\"") { body in
            if otherUID, let uid = Self.value("UID", in: Data(body.utf8)) {
                return body.replacingOccurrences(of: "UID:\(uid)", with: "UID:unrelated-event")
            }
            return body.replacingOccurrences(of: "SUMMARY:After", with: "SUMMARY:Remote edit")
        }]
        let responses = otherUID ? firstWrite(host, reply: conflict) + recovery
            : firstWrite(host, reply: success("first")) + existingCollection(host) + [conflict] + recovery
        let transport = transport(host, responses: responses)
        let baseline: CalendarEventAcknowledgement?
        if otherUID {
            baseline = nil
        } else {
            #expect(try await fixture.sync(transport))
            baseline = try persistedNextcloudReceipts(fixture.container).first?.acknowledged
            try fixture.edit("After")
        }
        do {
            _ = try await fixture.sync(transport) { Issue.record("A conflict cannot publish success") }
            Issue.record("The externally edited event must remain in conflict")
        } catch CalDAVError.conflict {}
        let events = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "PUT" || $0.method == "GET" }
        #expect(events.map(\.method) == (otherUID ? ["PUT", "GET"] : ["PUT", "PUT", "GET"]))
        #expect(Set(events.map(\.url)).count == 1)
        #expect(events.dropLast().last?.ifMatch == (otherUID ? nil : "\"first\""))
        let receipt = try #require(try persistedNextcloudReceipts(fixture.container).first)
        #expect(receipt.acknowledged == baseline)
        #expect(receipt.pending?.kind == (otherUID ? .create : .update))
    }

    @Test(arguments: ["complete", "folded", "stripped", "property", "alarm", "weak", "combined", "redirect"])
    func recoveryRequiresExactOperationAndStrongVersion(change: String) async throws {
        let host = "calendar-recovery-\(change).invalid"
        let fixture = try fixture(host)
        let tag = change == "weak" ? "W/\"remote\"" : change == "combined" ? "\"one\", \"two\"" : "\"remote\""
        let responseURL = change == "redirect" ? URL(string: "https://\(host)\(home)other.ics") : nil
        let transport = transport(host, responses: firstWrite(host, reply: .init(status: 201, body: ""))
            + [collectionProof(host), readback(host, tag: tag, responseURL: responseURL) { body in
                switch change {
                case "folded": body.replacingOccurrences(of: "SUMMARY:Before", with: "SUMMARY:Befo\r\n re")
                    .replacingOccurrences(of: "\r\n", with: "\n")
                case "stripped": body.components(separatedBy: "\r\n").filter { !$0.hasPrefix("X-NOWTHIS-MIRROR-OPERATION:") }
                    .joined(separator: "\r\n")
                case "property": body.replacingOccurrences(of: "STATUS:CONFIRMED", with: "STATUS:TENTATIVE")
                case "alarm": body.replacingOccurrences(of: "END:VEVENT", with: "BEGIN:VALARM\r\nEND:VALARM\r\nEND:VEVENT")
                default: body
                }
            }])
        let recoverable = change == "complete" || change == "folded"
        var publications = 0
        do {
            #expect(try await fixture.sync(transport) { publications += 1 })
            #expect(recoverable)
        } catch {
            #expect(!recoverable, "\(error)")
        }
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.filter { $0.method == "PUT" || $0.method == "GET" }.map(\.method) == ["PUT", "GET"])
        let receipt = try #require(try persistedNextcloudReceipts(fixture.container).first)
        #expect(receipt.acknowledged?.version.etag.header == (recoverable ? "\"remote\"" : nil))
        #expect((receipt.pending == nil) == recoverable)
        #expect(publications == (recoverable ? 1 : 0))
    }

    @Test(arguments: [204, 412])
    func managedRemovalNeverTouchesManualExport(status: Int) async throws {
        let host = "calendar-roles-\(status).invalid"
        let fixture = try fixture(host)
        let transport = transport(host, responses: firstWrite(host, reply: success("manual"))
            + existingCollection(host) + [success("managed")]
            + existingCollection(host) + [.init(status: status, body: "")])
        #expect(try await fixture.sync(transport, role: .manualExport))
        #expect(try await fixture.manager(transport).syncAll(accountID: fixture.accountID, container: fixture.container))
        let before = try persistedNextcloudReceipts(fixture.container)
        let manual = try #require(before.first { $0.role == .manualExport })
        let managed = try #require(before.first { $0.role == .managedMirror })
        #expect(manual.target != managed.target)
        #expect(manual.target.uid != managed.target.uid)
        fixture.task.dueDate = nil
        try fixture.container.mainContext.save()
        #expect(try await fixture.sync(transport, role: .manualExport) == false)
        do {
            #expect(try await fixture.manager(transport).syncAll(accountID: fixture.accountID, container: fixture.container))
            #expect(status == 204)
        } catch CalDAVError.conflict { #expect(status == 412) }
        let requests = ScriptedDAVProtocol.requests(host: host)
        let writes = requests.filter { $0.method == "PUT" || $0.method == "DELETE" }
        #expect(writes.map(\.method) == ["PUT", "PUT", "DELETE"])
        #expect(requests.filter { $0.method == "MKCALENDAR" }.count == 1)
        #expect(writes.last?.url.absoluteString == managed.target.href)
        #expect(writes.last?.ifMatch == "\"managed\"")
        let after = try persistedNextcloudReceipts(fixture.container)
        #expect(after.first { $0.role == .manualExport } == manual)
        #expect(after.first { $0.role == .managedMirror }?.wasRemoved == (status == 204))
        #expect(after.first { $0.role == .managedMirror }?.pending?.kind == (status == 412 ? .remove : nil))
    }

    @Test func onlyExplicitExportRetriesAnAbsentManualCreate() async throws {
        let host = "calendar-retry-manual.invalid"
        let fixture = try fixture(host)
        let absent = ScriptedDAVProtocol.Response(status: 404, body: "")
        let transport = transport(host, responses: firstWrite(host, reply: .init(status: 412, body: ""))
            + [collectionProof(host), absent] + existingCollection(host) + [success("managed")]
            + existingCollection(host) + [absent, success("manual")])
        await #expect(throws: CalDAVError.self) { try await fixture.sync(transport, role: .manualExport) }
        let pending = try #require(try persistedNextcloudReceipts(fixture.container).first?.pending)
        #expect(try await fixture.manager(transport).syncAll(accountID: fixture.accountID, container: fixture.container))
        #expect(try persistedNextcloudReceipts(fixture.container).first { $0.role == .manualExport }?.pending == pending)
        #expect(try await fixture.sync(transport, role: .manualExport))
        let writes = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "PUT" }
        #expect(writes.count == 3)
        #expect(writes.first?.url == writes.last?.url)
        #expect(writes.first?.body == writes.last?.body)
        #expect(writes.last?.ifNoneMatch == "*")
        #expect(writes.first?.url != writes.dropFirst().first?.url)
    }

    @Test func explicitManualExportAcceptsSupportedLongSourceUID() async throws {
        let host = "calendar-manual-long-uid.invalid"
        let fixture = try fixture(host)
        fixture.task.uid = String(repeating: "u", count: 3_000)
        try fixture.container.mainContext.save()
        let transport = transport(host, responses: firstWrite(host, reply: success("manual-long-uid")))

        #expect(try await fixture.sync(transport, role: .manualExport))
        let manual = try #require(try persistedNextcloudReceipts(fixture.container).first { $0.role == .manualExport })
        #expect(manual.sourceUID == fixture.task.uid)
        #expect(manual.acknowledged != nil)
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "PUT" }.count == 1)
    }

    @Test func oldAcknowledgedManualReceiptDoesNotHoldManagedWorkerWake() async throws {
        let host = "calendar-old-manual-origin.invalid"
        let fixture = try fixture(host)
        let transport = transport(host, responses: firstWrite(host, reply: success("manual"))
            + existingCollection(host) + [success("managed")]
            + existingCollection(host) + [success("managed-update", status: 204)])
        #expect(try await fixture.sync(transport, role: .manualExport))
        #expect(try await fixture.sync(transport, role: .managedMirror))
        let context = ModelContext(fixture.container)
        let receipts = try persistedNextcloudReceipts(fixture.container)
        let manual = try #require(receipts.first { $0.role == .manualExport })
        let manualKey = try CalendarReceiptKey.event(
            task: CalendarTaskSnapshot(fixture.task, account: AccountCredentialScope(fixture.account), role: .manualExport),
            binding: manual.bindingID)
        let row = try #require(try context.fetch(FetchDescriptor<SyncMetadata>()).first { $0.id == manualKey })
        let rowJSON = try #require(row.syncToken)
        var encoded = try #require(JSONSerialization.jsonObject(with: Data(rowJSON.utf8)) as? [String: Any])
        encoded.removeValue(forKey: "lifecycleOrigin")
        row.syncToken = String(decoding: try JSONSerialization.data(withJSONObject: encoded), as: UTF8.self)
        try context.save()
        try fixture.edit("Managed task updated")

        let destination = try #require(try CalendarReceiptStore.destination(for: AccountCredentialScope(fixture.account),
            in: ModelContext(fixture.container)))
        let receiptInventory = try CalendarReceiptStore.managedTaskInventory(for: destination.scope,
            in: ModelContext(fixture.container))
        #expect(!receiptInventory.held)
        let destinationInventory = try CalendarReceiptStore.destinationInventory(in: ModelContext(fixture.container))
        #expect(!destinationInventory.held)

        var failures: [String] = []
        let coordinator = CalendarMirrorCoordinator(container: fixture.container,
            nextcloud: fixture.manager(transport), apple: AppleCalendarSyncManager(store: FakeAppleCalendarStore(),
                makeJournal: { AppleCalendarOwnershipJournal(container: $0,
                    anchor: AppleCalendarAnchor { _, _ in Data(repeating: 41, count: 32) }, selector: "legacy-manual-test") }),
            appleEnabled: { false }, nextcloudEnabled: { true },
            debounce: .milliseconds(1), onFailure: { failures.append($0) })
        await coordinator.reconcileNow()

        #expect(failures.isEmpty)
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "PUT" }.count == 3)
        #expect(try persistedNextcloudReceipts(fixture.container).first { $0.role == .manualExport }?.lifecycleOrigin == nil)
        #expect(try persistedNextcloudReceipts(fixture.container).first { $0.role == .managedMirror }?.acknowledged != nil)
    }

    @Test func legacyT7AcknowledgedManagedReceiptUpdatesExplicitlyButGenericWakeHolds() async throws {
        let host = "calendar-t7-managed-ack.invalid"
        let fixture = try fixture(host)
        let transport = transport(host, responses: firstWrite(host, reply: success("first"))
            + existingCollection(host) + [success("second", status: 204)])
        #expect(try await fixture.sync(transport))
        let context = ModelContext(fixture.container)
        let eventRow = try #require(try context.fetch(FetchDescriptor<SyncMetadata>())
            .first { $0.id.contains(":event:") })
        let originalTarget = try #require(try persistedNextcloudReceipts(fixture.container).first?.target)
        let eventJSON = try #require(eventRow.syncToken)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(eventJSON.utf8)) as? [String: Any])
        envelope.removeValue(forKey: "lifecycleOrigin")
        eventRow.syncToken = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        try context.save()

        try fixture.edit("Explicit T7 managed update")
        #expect(try await fixture.sync(transport))
        let afterExplicit = try #require(try persistedNextcloudReceipts(fixture.container).first)
        #expect(afterExplicit.target == originalTarget)
        #expect(afterExplicit.acknowledged?.version.etag.header == "\"second\"")
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "PUT" }.count == 2)

        fixture.task.title = "Generic lifecycle must hold legacy source"
        try ReminderSchedulingJournal.saveTaskChanges(in: fixture.container.mainContext)
        let beforeGeneric = ScriptedDAVProtocol.requests(host: host).count
        await #expect(throws: CalendarReceiptStore.Held.self) {
            try await fixture.manager(transport).reconcileManaged(accountID: fixture.accountID,
                container: fixture.container, isEnabled: { true })
        }
        #expect(ScriptedDAVProtocol.requests(host: host).count == beforeGeneric)
        #expect(try !CalendarMirrorState.pending(in: ModelContext(fixture.container), taskID: fixture.task.id).isEmpty)
    }

    @Test func interruptedLegacyExplicitUpdateCannotAuthorizeGenericPurge() async throws {
        let host = "calendar-t7-generic-purge-after-interrupted-update.invalid"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("calendar.store")
        let fixture = try fixture(host, store: store)
        let schema = Schema(SchemaV2.models)
        let readOnly = try ModelContainer(for: schema, configurations:
            ModelConfiguration(schema: schema, url: store, allowsSave: false, cloudKitDatabase: .none))
        let transport = transport(host, responses: firstWrite(host, reply: success("first"))
            + existingCollection(host) + [success("second", status: 204)]
            + existingCollection(host) + [readback(host, tag: "\"second\"") { $0 }, .init(status: 204, body: "")])
        #expect(try await fixture.sync(transport))
        let context = ModelContext(fixture.container)
        let eventRow = try #require(try context.fetch(FetchDescriptor<SyncMetadata>())
            .first { $0.id.contains(":event:") })
        let eventRaw = try #require(eventRow.syncToken)
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(eventRaw.utf8)) as? [String: Any])
        legacy.removeValue(forKey: "lifecycleOrigin")
        eventRow.syncToken = String(decoding: try JSONSerialization.data(withJSONObject: legacy), as: UTF8.self)
        try context.save()

        fixture.task.createdDate = Date(timeIntervalSince1970: 1_600_000_000)
        try fixture.edit("Replacement row update")
        let interrupted = NextcloudCalendarSyncManager(transport: transport, keychainManager: fixture.keychain,
            makeCommitContext: { container, phase in
                if case .acknowledgeEvent = phase { return ModelContext(readOnly) }
                return ModelContext(container)
            })
        await #expect(throws: (any Error).self) {
            try await interrupted.syncSingleTask(taskID: fixture.task.id, accountID: fixture.accountID,
                role: .managedMirror, container: fixture.container)
        }
        let pending = try #require(try persistedNextcloudReceipts(fixture.container).first)
        #expect(pending.lifecycleOrigin == nil)
        #expect(pending.pending?.kind == .update)
        #expect(pending.pending?.snapshot.mirrorIdentity?.created == fixture.task.createdDate)

        try SyncPushAcknowledgement.finalizeDeletion(fixture.task, in: fixture.container.mainContext)
        try ReminderSchedulingJournal.saveTaskChanges(in: fixture.container.mainContext)
        await #expect(throws: CalendarReceiptStore.Held.self) {
            try await fixture.manager(transport).reconcileManaged(accountID: fixture.accountID,
                container: fixture.container, isEnabled: { true })
        }
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "DELETE" }.isEmpty)
        #expect(try persistedNextcloudReceipts(fixture.container).first == pending)
    }

    @Test func legacyT7PendingManagedReceiptRecoversExplicitlyButGenericWakeHolds() async throws {
        let host = "calendar-t7-managed-pending.invalid"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("calendar.store")
        let fixture = try fixture(host, store: store)
        let schema = Schema(SchemaV2.models)
        let readOnly = try ModelContainer(for: schema, configurations:
            ModelConfiguration(schema: schema, url: store, allowsSave: false, cloudKitDatabase: .none))
        let transport = transport(host, responses: firstWrite(host, reply: success("first"))
            + existingCollection(host) + [success("second", status: 204)]
            + existingCollection(host) + [readback(host, tag: "\"second\"") { $0 }])
        #expect(try await fixture.sync(transport))
        try fixture.edit("Durable pending T7 update")
        let interrupted = NextcloudCalendarSyncManager(transport: transport, keychainManager: fixture.keychain,
            makeCommitContext: { container, phase in
                if case .acknowledgeEvent = phase { return ModelContext(readOnly) }
                return ModelContext(container)
            })
        await #expect(throws: (any Error).self) {
            try await interrupted.syncSingleTask(taskID: fixture.task.id, accountID: fixture.accountID,
                role: .managedMirror, container: fixture.container)
        }
        let pendingBefore = try #require(try persistedNextcloudReceipts(fixture.container).first)
        #expect(pendingBefore.pending?.kind == .update)
        let context = ModelContext(fixture.container)
        let eventRow = try #require(try context.fetch(FetchDescriptor<SyncMetadata>())
            .first { $0.id.contains(":event:") })
        let eventJSON = try #require(eventRow.syncToken)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(eventJSON.utf8)) as? [String: Any])
        envelope.removeValue(forKey: "lifecycleOrigin")
        var oldPending = try #require(envelope["pending"] as? [String: Any])
        var oldSnapshot = try #require(oldPending["snapshot"] as? [String: Any])
        oldSnapshot.removeValue(forKey: "mirrorIdentity")
        oldPending["snapshot"] = oldSnapshot
        envelope["pending"] = oldPending
        eventRow.syncToken = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        try context.save()

        await #expect(throws: CalendarReceiptStore.Held.self) {
            try await fixture.manager(transport).reconcileManaged(accountID: fixture.accountID,
                container: fixture.container, isEnabled: { true })
        }
        let beforeRetry = ScriptedDAVProtocol.requests(host: host)
        #expect(beforeRetry.filter { $0.method == "PUT" }.count == 2)
        #expect(!beforeRetry.contains { $0.method == "GET" })

        #expect(try await fixture.sync(transport))
        let afterRetry = ScriptedDAVProtocol.requests(host: host)
        #expect(afterRetry.filter { $0.method == "PUT" }.count == 2)
        #expect(afterRetry.filter { $0.method == "GET" }.count == 1)
        let recovered = try #require(try persistedNextcloudReceipts(fixture.container).first)
        #expect(recovered.target == pendingBefore.target)
        #expect(recovered.acknowledged?.version.etag.header == "\"second\"")
        #expect(recovered.pending == nil)
    }

    @Test func legacyT7AcknowledgedDueClearRemovesOnExplicitSettingsSync() async throws {
        let host = "calendar-t7-managed-due-clear.invalid"
        let fixture = try fixture(host)
        let transport = transport(host, responses: firstWrite(host, reply: success("first"))
            + existingCollection(host) + [.init(status: 204, body: "")])
        #expect(try await fixture.sync(transport))
        let context = ModelContext(fixture.container)
        let row = try #require(try context.fetch(FetchDescriptor<SyncMetadata>()).first { $0.id.contains(":event:") })
        let raw = try #require(row.syncToken)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        envelope.removeValue(forKey: "lifecycleOrigin")
        row.syncToken = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        try context.save()
        fixture.task.dueDate = nil
        try fixture.container.mainContext.save()

        #expect(try await fixture.manager(transport).syncAll(accountID: fixture.accountID, container: fixture.container))
        let writes = ScriptedDAVProtocol.requests(host: host).filter { ["PUT", "DELETE"].contains($0.method) }
        #expect(writes.map(\.method) == ["PUT", "DELETE"])
        let target = try #require(try persistedNextcloudReceipts(fixture.container).first?.target.href)
        #expect(writes.last?.url.absoluteString == target)
        #expect(try persistedNextcloudReceipts(fixture.container).first?.wasRemoved == true)
    }

    @Test func legacyT7PendingDeleteRecoversExplicitlyWithFieldsAbsent() async throws {
        let host = "calendar-t7-managed-pending-delete.invalid"
        let fixture = try fixture(host)
        let transport = transport(host, responses: firstWrite(host, reply: success("first"))
            + existingCollection(host) + existingCollection(host)
            + [readback(host, tag: "\"first\"") { $0 }, .init(status: 204, body: "")])
        #expect(try await fixture.sync(transport))
        let context = ModelContext(fixture.container)
        let row = try #require(try context.fetch(FetchDescriptor<SyncMetadata>()).first { $0.id.contains(":event:") })
        let raw = try #require(row.syncToken)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        envelope.removeValue(forKey: "lifecycleOrigin")
        row.syncToken = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        try context.save()
        fixture.task.dueDate = nil
        try fixture.container.mainContext.save()

        await #expect(throws: CancellationError.self) {
            try await fixture.sync(InterruptCalendarRequest(transport, stage: .removal))
        }
        let pendingContext = ModelContext(fixture.container)
        let pendingRow = try #require(try pendingContext.fetch(FetchDescriptor<SyncMetadata>())
            .first { $0.id.contains(":event:") })
        let pendingRaw = try #require(pendingRow.syncToken)
        var pendingEnvelope = try #require(JSONSerialization.jsonObject(with: Data(pendingRaw.utf8)) as? [String: Any])
        pendingEnvelope.removeValue(forKey: "lifecycleOrigin")
        var pending = try #require(pendingEnvelope["pending"] as? [String: Any])
        #expect(pending["kind"] as? String == "remove")
        var snapshot = try #require(pending["snapshot"] as? [String: Any])
        snapshot.removeValue(forKey: "mirrorIdentity")
        pending["snapshot"] = snapshot
        pendingEnvelope["pending"] = pending
        pendingRow.syncToken = String(decoding: try JSONSerialization.data(withJSONObject: pendingEnvelope), as: UTF8.self)
        try pendingContext.save()

        #expect(try await fixture.sync(transport))
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "DELETE" }.count == 1)
        #expect(try persistedNextcloudReceipts(fixture.container).first?.wasRemoved == true)
    }

    @Test(arguments: ["manualRemoved", "acknowledgedOddRevision", "unacknowledgedCreateAtUpdateRevision"])
    func impossibleEventStateCannotAuthorizeMutation(state: String) async throws {
        let host = "calendar-impossible-\(state.lowercased()).invalid"
        let fixture = try fixture(host)
        let transport = transport(host, responses: firstWrite(host, reply: success("first"))
            + existingCollection(host) + [success("replacement")])
        #expect(try await fixture.sync(transport, role: .manualExport))
        let context = fixture.container.mainContext
        let row = try #require(try context.fetch(FetchDescriptor<SyncMetadata>()).first { $0.id.contains(":event:") })
        var receipt = try #require(try persistedNextcloudReceipts(fixture.container).first)
        switch state {
        case "manualRemoved":
            receipt.wasRemoved = true
            receipt.acknowledged = nil
            receipt.revision = 4
        case "acknowledgedOddRevision":
            receipt.revision = 3
            try fixture.edit("After")
        default:
            let write = try #require(ScriptedDAVProtocol.requests(host: host).last { $0.method == "PUT" })
            let acknowledged = try #require(receipt.acknowledged)
            let body = String(decoding: write.body, as: UTF8.self)
            receipt.pending = CalendarEventIntent(kind: .create, target: receipt.target, bindingID: receipt.bindingID,
                bindingRevision: 2, receiptRevision: 2, operation: acknowledged.operation,
                snapshot: try CalendarTaskSnapshot(fixture.task, account: receipt.scope, role: .manualExport),
                priorVersion: nil, stamp: Date(), body: body, bodyProof: acknowledged.bodyProof)
            receipt.acknowledged = nil
            receipt.revision = 3
        }
        row.syncToken = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        let raw = row.syncToken
        try context.save()
        await #expect(throws: CalendarReceiptStore.Held.self) { try await fixture.sync(transport, role: .manualExport) }
        let writes = ScriptedDAVProtocol.requests(host: host).filter { ["PUT", "DELETE", "GET"].contains($0.method) }
        #expect(writes.map(\.method) == ["PUT"])
        let saved = try #require(try ModelContext(fixture.container).fetch(FetchDescriptor<SyncMetadata>())
            .first { $0.id.contains(":event:") })
        #expect(saved.syncToken == raw)
    }

    @Test(arguments: [CalendarEventIntent.Kind.update, .remove])
    func revisionOneCannotCarryAnAcknowledgedBaseline(kind: CalendarEventIntent.Kind) async throws {
        let host = "calendar-impossible-first-\(kind.rawValue).invalid"
        let fixture = try fixture(host)
        let removing = kind == .remove
        let first = firstWrite(host, reply: success("owned")) + existingCollection(host)
        let interruptedUpdate: [ScriptedDAVProtocol.Response] = [
            .init(status: 412, body: ""), collectionProof(host), .init(status: 404, body: "")
        ]
        let readback = readback(host, tag: removing ? "\"owned\"" : "\"observed\"") { $0 }
        let retry = existingCollection(host) + [readback] + (removing ? [.init(status: 204, body: "")] : [])
        let transport = transport(host, responses: first + (removing ? [] : interruptedUpdate) + retry)
        #expect(try await fixture.sync(transport))
        if removing {
            await #expect(throws: CancellationError.self) {
                try await fixture.remove(InterruptCalendarRequest(transport, stage: .removal), explicit: true)
            }
        } else {
            try fixture.edit("After")
            await #expect(throws: CalDAVError.self) { try await fixture.sync(transport) }
        }

        let valid = try #require(try persistedNextcloudReceipts(fixture.container).first)
        #expect(valid.revision == 3)
        #expect(valid.acknowledged != nil)
        #expect(valid.pending?.kind == kind)
        let context = fixture.container.mainContext
        let row = try #require(try context.fetch(FetchDescriptor<SyncMetadata>()).first { $0.id.contains(":event:") })
        let original = try #require(row.syncToken)
        let json = try JSONSerialization.jsonObject(with: Data(original.utf8))
        var record = try #require(json as? [String: Any])
        var pending = try #require(record["pending"] as? [String: Any])
        pending["receiptRevision"] = 0
        record["pending"] = pending
        record["revision"] = 1
        let corrupt = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        row.syncToken = corrupt
        try context.save()

        let before = ScriptedDAVProtocol.requests(host: host).filter { ["PUT", "GET", "DELETE"].contains($0.method) }.map(\.method)
        var publications = 0
        await #expect(throws: CalendarReceiptStore.Held.self) {
            if removing { try await fixture.remove(transport, explicit: true) { publications += 1 } }
            else { try await fixture.sync(transport) { publications += 1 } }
        }
        let after = ScriptedDAVProtocol.requests(host: host).filter { ["PUT", "GET", "DELETE"].contains($0.method) }.map(\.method)
        #expect(after == before)
        #expect(publications == 0)
        let saved = try #require(try ModelContext(fixture.container).fetch(FetchDescriptor<SyncMetadata>())
            .first { $0.id.contains(":event:") })
        #expect(saved.syncToken == corrupt)
    }

    @Test(arguments: [false, true], ["exact", "changedTag", "changedBody", "absent"])
    func interruptedManagedRemovalOnlyRetriesTheRetainedVersion(explicit: Bool, reply: String) async throws {
        let host = "calendar-interrupted-delete-\(explicit)-\(reply.lowercased()).invalid"
        let fixture = try fixture(host)
        let read = reply == "absent" ? ScriptedDAVProtocol.Response(status: 404, body: "")
            : readback(host, tag: reply == "changedTag" ? "\"changed\"" : "\"owned\"") { body in
                reply == "changedBody" ? body.replacingOccurrences(of: "SUMMARY:Before", with: "SUMMARY:Remote edit") : body
            }
        let transport = transport(host, responses: firstWrite(host, reply: success("owned"))
            + existingCollection(host) + existingCollection(host) + [read, .init(status: 204, body: "")])
        #expect(try await fixture.sync(transport))
        if !explicit {
            fixture.task.dueDate = nil
            try fixture.container.mainContext.save()
        }
        let interrupted = InterruptCalendarRequest(transport, stage: .removal)
        await #expect(throws: CancellationError.self) { try await fixture.remove(interrupted, explicit: explicit) }
        let saved = try #require(try persistedNextcloudReceipts(fixture.container).first)
        #expect(saved.pending?.kind == .remove)
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "DELETE" })

        let shouldResolve = reply == "exact" || reply == "absent"
        var publications = 0
        do {
            #expect(try await fixture.remove(transport, explicit: explicit) { publications += 1 })
            #expect(shouldResolve)
        } catch CalDAVError.conflict { #expect(!shouldResolve) }
        let events = ScriptedDAVProtocol.requests(host: host).filter { ["PUT", "GET", "DELETE"].contains($0.method) }
        #expect(events.map(\.method) == (reply == "exact" ? ["PUT", "GET", "DELETE"] : ["PUT", "GET"]))
        #expect(events.filter { $0.method == "DELETE" }.map(\.ifMatch) == (reply == "exact" ? ["\"owned\""] : []))
        #expect(Set(events.map(\.url)).count == 1)
        let after = try #require(try persistedNextcloudReceipts(fixture.container).first)
        #expect(after.wasRemoved == shouldResolve)
        #expect(after.pending == (shouldResolve ? nil : saved.pending))
        #expect(publications == (shouldResolve ? 1 : 0))
    }

    @Test func activeManagedUpsertCannotRetryExplicitRemoval() async throws {
        let host = "calendar-active-no-delete-retry.invalid"
        let fixture = try fixture(host)
        let sameEvent = readback(host, tag: "\"owned\"") { $0 }
        let transport = transport(host, responses: firstWrite(host, reply: success("owned")) + existingCollection(host)
            + existingCollection(host) + [sameEvent] + existingCollection(host) + [sameEvent, .init(status: 204, body: "")])
        #expect(try await fixture.sync(transport))
        await #expect(throws: CancellationError.self) {
            try await fixture.remove(InterruptCalendarRequest(transport, stage: .removal), explicit: true)
        }
        let pending = try #require(try persistedNextcloudReceipts(fixture.container).first?.pending)
        await #expect(throws: CalDAVError.self) { try await fixture.sync(transport) }
        #expect(try persistedNextcloudReceipts(fixture.container).first?.pending == pending)
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "DELETE" })
        #expect(try await fixture.remove(transport, explicit: true))
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "DELETE" }.map(\.ifMatch) == ["\"owned\""])
    }

    @Test(arguments: ["proof", "put", "readback", "delete", "createAbsence"])
    func incompleteDeclaredResponsesNeverAuthorizeWritesOrAcknowledgements(stage: String) async throws {
        let host = "calendar-incomplete-\(stage.lowercased()).invalid"
        let fixture = try fixture(host)
        var shortProof = collectionProof(host)
        shortProof.headers = ["Content-Length": "8192"]
        var shortRead = readback(host, tag: "\"recovered\"") { $0 }
        shortRead.headers["Content-Length"] = "8192"
        let shortAbsence = ScriptedDAVProtocol.Response(status: 404, body: "short", headers: ["Content-Length": "8192"])
        let shortPut = ScriptedDAVProtocol.Response(status: 201, body: "short",
            headers: ["ETag": "\"invalid\"", "Content-Length": "8192"])
        let responses: [ScriptedDAVProtocol.Response]
        switch stage {
        case "proof": responses = discovery() + [.init(status: 201, body: ""), shortProof, success("unwanted")]
        case "put": responses = firstWrite(host, reply: shortPut)
        case "readback": responses = firstWrite(host, reply: .init(status: 201, body: "")) + [collectionProof(host), shortRead]
        case "delete": responses = firstWrite(host, reply: success("first")) + existingCollection(host) + [shortAbsence]
        default:
            responses = firstWrite(host, reply: .init(status: 412, body: "")) + [collectionProof(host), .init(status: 404, body: "")]
                + existingCollection(host) + [shortAbsence, success("unwanted")]
        }
        let transport = transport(host, responses: responses)
        var prior: CalendarEventReceipt?
        if stage == "delete" {
            #expect(try await fixture.sync(transport))
            prior = try persistedNextcloudReceipts(fixture.container).first
            fixture.task.dueDate = nil
            try fixture.container.mainContext.save()
        } else if stage == "createAbsence" {
            await #expect(throws: CalDAVError.self) { try await fixture.sync(transport) }
            prior = try persistedNextcloudReceipts(fixture.container).first
        }
        var publications = 0
        await #expect(throws: (any Error).self) { try await fixture.sync(transport) { publications += 1 } }
        #expect(publications == 0)
        let receipt = try persistedNextcloudReceipts(fixture.container).first
        #expect(receipt?.acknowledged == prior?.acknowledged)
        #expect(receipt?.pending?.kind == (stage == "proof" ? nil : stage == "delete" ? .remove : .create))
        if stage == "createAbsence" { #expect(receipt == prior) }
        let puts = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "PUT" }
        #expect(puts.count == (stage == "proof" ? 0 : 1))
    }

    @Test func contentEncodedProofAndBodylessPutCanAcknowledge() async throws {
        let host = "calendar-decoded-proof.invalid"
        let fixture = try fixture(host)
        var proof = collectionProof(host)
        // The URLProtocol delivers the decoded XML bytes while the header describes the encoded representation.
        proof.headers = ["Content-Encoding": "gzip", "Content-Length": "128"]
        let transport = transport(host, responses: discovery() + [.init(status: 201, body: ""), proof, success("first")]
            + existingCollection(host) + [success("second", status: 204)])
        #expect(try await fixture.sync(transport))
        try fixture.edit("After")
        #expect(try await fixture.sync(transport))
        #expect(try persistedNextcloudReceipts(fixture.container).first?.acknowledged?.version.etag.header == "\"second\"")
    }

    @Test(arguments: ["legacyHref", "legacyCollection", "receipt", "claimAndReceipt", "destination", "unknownRole", "rebound"])
    func uncertaintyHoldsInsteadOfAllocatingReplacement(reason: String) async throws {
        let host = "calendar-hold-\(reason.lowercased()).invalid"
        let fixture = try fixture(host)
        let legacy = reason == "legacyHref" || reason == "legacyCollection"
        let responses = legacy ? discovery(legacy: reason == "legacyCollection")
            : firstWrite(host, reply: success("initial")) + existingCollection(host)
        let transport = transport(host, responses: responses)
        if !legacy { #expect(try await fixture.sync(transport)) }
        let context = fixture.container.mainContext
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>())
        switch reason {
        case "legacyHref": fixture.task.calendarEventHref = "/legacy.ics"
        case "receipt", "claimAndReceipt":
            for row in rows where row.id.contains(":event:") || (reason == "claimAndReceipt" && row.id.contains(":claim:")) {
                context.delete(row)
            }
        case "destination":
            for row in rows where row.id.contains(":destination:") { context.delete(row) }
        case "unknownRole":
            let event = try #require(rows.first { $0.id.contains(":event:") })
            event.syncToken = event.syncToken?.replacingOccurrences(of: "managedMirror", with: "futureRole")
        case "rebound": fixture.account.serverBaseURL += "/"
        default: break
        }
        try fixture.edit("After")
        let originalCount = ScriptedDAVProtocol.requests(host: host).filter { ["PUT", "MKCALENDAR", "DELETE"].contains($0.method) }.count
        await #expect(throws: CalendarReceiptStore.Held.self) { try await fixture.sync(transport) }
        let finalCount = ScriptedDAVProtocol.requests(host: host).filter { ["PUT", "MKCALENDAR", "DELETE"].contains($0.method) }.count
        #expect(finalCount == originalCount)
        if reason == "legacyHref" { #expect(fixture.task.calendarEventHref == "/legacy.ics") }
    }

    @Test(arguments: [false, true])
    func committedEditsDuringRealPutNeverAcknowledge(rebindAccount: Bool) async throws {
        let host = "calendar-stale-\(rebindAccount).invalid"
        let fixture = try fixture(host)
        let gate = ScriptedDAVProtocol.Gate()
        let transport = transport(host, responses: firstWrite(host,
            reply: .init(status: 201, body: "", headers: ["ETag": "\"first\""], gate: gate)))
        let sync = Task { try await fixture.sync(transport) { Issue.record("A stale write cannot publish") } }
        defer { gate.release(); sync.cancel() }
        try await waitForPut(host)
        if rebindAccount {
            fixture.account.serverBaseURL += "/"
            try fixture.container.mainContext.save()
        } else {
            try fixture.edit("After")
        }
        gate.release()
        #expect(try await sync.value == false)
        let receipt = try #require(try persistedNextcloudReceipts(fixture.container).first)
        #expect(receipt.acknowledged == nil)
        #expect(receipt.pending?.kind == .create)
    }

    @Test(arguments: [false, true])
    func discoverySeedEditStopsDiscoveryAndRetries(retry: Bool) async throws {
        let host = "calendar-seed-discovery-\(retry).invalid"
        let fixture = try fixture(host)
        let gate = ScriptedDAVProtocol.Gate()
        var responses = firstWrite(host, reply: success("first"))
        if retry { responses.insert(.init(status: 500, body: "", gate: gate), at: 0) }
        else { responses[0].gate = gate }
        let transport = transport(host, responses: responses, maxAttempts: retry ? 2 : 1)
        let sync = Task { try await fixture.sync(transport) { Issue.record("A stale discovery cannot publish") } }
        defer { gate.release(); sync.cancel() }
        try await waitForRequest(host) { $0.method == "PROPFIND" }
        try await fixture.changeDiscoverySeed(to: String(root.dropLast()))
        gate.release()
        #expect(try await sync.value == false)
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.method) == ["PROPFIND"])
        let context = ModelContext(fixture.container)
        #expect(try CalendarReceiptStore.destination(for: AccountCredentialScope(fixture.account), in: context) == nil)
    }

    @Test func discoverySeedEditAfterPutRetainsIntentAndLaterProvesSameBinding() async throws {
        let host = "calendar-seed-put.invalid"
        let fixture = try fixture(host)
        let gate = ScriptedDAVProtocol.Gate()
        let newSeed = String(root.dropLast())
        let transport = transport(host, responses: firstWrite(host,
            reply: .init(status: 201, body: "", headers: ["ETag": "\"stale\""], gate: gate))
            + discovery(start: newSeed) + [collectionProof(host), readback(host, tag: "\"recovered\"") { $0 }])
        var publications = 0
        let sync = Task { try await fixture.sync(transport) { publications += 1 } }
        defer { gate.release(); sync.cancel() }
        try await waitForPut(host)
        let before = try #require(try persistedNextcloudReceipts(fixture.container).first)
        try await fixture.changeDiscoverySeed(to: newSeed)
        gate.release()
        #expect(try await sync.value == false)
        #expect(try persistedNextcloudReceipts(fixture.container).first == before)
        #expect(before.pending != nil)
        #expect(before.acknowledged == nil)
        #expect(publications == 0)

        #expect(try await fixture.sync(transport) { publications += 1 })
        let requests = ScriptedDAVProtocol.requests(host: host)
        let events = requests.filter { ["PUT", "GET"].contains($0.method) }
        #expect(events.map(\.method) == ["PUT", "GET"])
        #expect(events.first?.url == events.last?.url)
        #expect(requests.contains { $0.url.absoluteString == "https://\(host)\(newSeed)" && $0.method == "PROPFIND" })
        #expect(requests.filter { $0.method == "MKCALENDAR" }.count == 1)
        let after = try #require(try persistedNextcloudReceipts(fixture.container).first)
        #expect(after.target == before.target)
        #expect(after.acknowledged?.version.etag.header == "\"recovered\"")
        #expect(after.pending == nil)
        #expect(publications == 1)
    }

    @Test func inFlightResponseNeverReplacesNewerReceipt() async throws {
        let host = "calendar-newer-receipt.invalid"
        let fixture = try fixture(host)
        let gate = ScriptedDAVProtocol.Gate()
        let transport = transport(host, responses: firstWrite(host,
            reply: .init(status: 201, body: "", headers: ["ETag": "\"old-response\""], gate: gate)))
        let sync = Task { try await fixture.sync(transport) { Issue.record("A stale response cannot publish") } }
        defer { gate.release(); sync.cancel() }
        try await waitForPut(host)
        var receipt = try #require(try persistedNextcloudReceipts(fixture.container).first)
        let intent = try #require(receipt.pending)
        let tag = try #require(CalendarStrongETag("\"newer-local-receipt\""))
        receipt.acknowledged = .init(version: intent.target.version(tag), operation: intent.operation,
            bodyProof: try #require(intent.bodyProof), contentProof: intent.snapshot.contentProof)
        receipt.pending = nil
        receipt.revision += 1
        let context = fixture.container.mainContext
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>())
        let event = try #require(rows.first { $0.id.contains(":event:") })
        event.syncToken = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        try context.save()
        gate.release()
        #expect(try await sync.value == false)
        #expect(try persistedNextcloudReceipts(fixture.container).first == receipt)
    }

    @Test func twoManagersSerializeTheSameDestination() async throws {
        let host = "calendar-serialized.invalid"
        let fixture = try fixture(host)
        let gate = ScriptedDAVProtocol.Gate()
        let transport = transport(host, responses: firstWrite(host,
            reply: .init(status: 201, body: "", headers: ["ETag": "\"first\""], gate: gate)) + existingCollection(host))
        let first = Task { try await fixture.sync(transport) }
        defer { gate.release(); first.cancel() }
        try await waitForPut(host)
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return try await fixture.sync(transport)
        }
        defer { second.cancel() }
        while !secondStarted { await Task.yield() }
        gate.release()
        #expect(try await first.value)
        #expect(try await second.value == false)
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.filter { ["MKCALENDAR", "PUT", "GET"].contains($0.method) }.map(\.method) == ["MKCALENDAR", "PUT"])
        #expect(try persistedNextcloudReceipts(fixture.container).count == 1)
    }

    @Test func preparedCollectionRecoversWhenFirstCreateNeverDispatched() async throws {
        let host = "calendar-prepared-absent.invalid"
        let fixture = try fixture(host)
        let transport = transport(host, responses: discovery() + discovery() + [
            .init(status: 404, body: ""), .init(status: 201, body: ""), collectionProof(host), success("first")
        ])
        let interrupted = InterruptCalendarRequest(transport, stage: .collection)
        await #expect(throws: CancellationError.self) { try await fixture.sync(interrupted) }
        let prepared = try fixture.destination()
        #expect(!prepared.owned)
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND"])
        do {
            #expect(try await fixture.sync(transport))
        } catch {
            Issue.record("A prepared collection should recover after an exact top-level 404: \(error)")
        }
        let requests = ScriptedDAVProtocol.requests(host: host)
        let mutations = requests.filter { $0.method == "MKCALENDAR" || $0.method == "PUT" }
        #expect(mutations.map(\.method) == ["MKCALENDAR", "PUT"])
        #expect(mutations.first?.url == prepared.collection)
        #expect(mutations.first?.ifNoneMatch == "*")
        #expect(mutations.first.map { String(decoding: $0.body, as: UTF8.self).contains(prepared.marker) } == true)
        #expect(try fixture.destination().owned)
    }

    @Test(arguments: ["proof", "save"])
    func unacknowledgedCreationCanResumeWithTheSameWireIntent(failure: String) async throws {
        let host = "calendar-prepared-after-\(failure).invalid"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("calendar.store")
        let fixture = try fixture(host, store: store)
        let readOnly = try ModelContainer(for: Schema(SchemaV2.models), configurations:
            ModelConfiguration(schema: Schema(SchemaV2.models), url: store, allowsSave: false, cloudKitDatabase: .none))
        let absent = ScriptedDAVProtocol.Response(status: 404, body: "")
        let transport = transport(host, responses: discovery() + [.init(status: 201, body: ""),
            failure == "proof" ? absent : collectionProof(host)] + discovery() + [absent,
            .init(status: 201, body: ""), collectionProof(host), success("event")])
        let interrupted = NextcloudCalendarSyncManager(transport: transport, keychainManager: fixture.keychain,
            makeCommitContext: { container, phase in
                ModelContext(failure == "save" && phase == .proveDestination ? readOnly : container)
            })
        var publications = 0
        await #expect(throws: (any Error).self) {
            try await interrupted.syncSingleTask(taskID: fixture.task.id, accountID: fixture.accountID, role: .managedMirror,
                container: fixture.container) { publications += 1 }
        }
        #expect(publications == 0)
        #expect(try fixture.destination().state == .prepared)
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "PUT" })
        #expect(try await fixture.sync(transport) { publications += 1 })
        let creations = ScriptedDAVProtocol.requests(host: host).filter { $0.method == "MKCALENDAR" }
        #expect(creations.count == 2)
        #expect(creations.first?.url == creations.last?.url)
        #expect(creations.first?.body == creations.last?.body)
        #expect(creations.map(\.ifNoneMatch) == ["*", "*"])
        #expect(try fixture.destination().owned)
        #expect(publications == 1)
    }

    @Test func recoveredCollectionProofAvoidsAnotherCreate() async throws {
        let host = "calendar-prepared-proof.invalid"
        let fixture = try fixture(host)
        let transport = transport(host, responses: discovery() + [.init(body: "", errorCode: .networkConnectionLost),
            .init(body: "", errorCode: .timedOut)] + existingCollection(host) + [success("event")])
        await #expect(throws: (any Error).self) { try await fixture.sync(transport) }
        #expect(try fixture.destination().state == .prepared)
        #expect(try await fixture.sync(transport))
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.filter { $0.method == "MKCALENDAR" }.count == 1)
        #expect(requests.filter { $0.method == "PUT" }.count == 1)
    }

    @Test(arguments: [false, true])
    func previouslyOwnedMissingCollectionNeverRecreates(withEvent: Bool) async throws {
        let host = "calendar-owned-absent-\(withEvent).invalid"
        let fixture = try fixture(host)
        let setup = discovery() + [.init(status: 201, body: ""), collectionProof(host)] + (withEvent ? [success("event")] : [])
        let transport = transport(host, responses: setup + discovery() + [.init(status: 404, body: "")])
        let empty = try DAVSyncScenario.container()
        let manager = NextcloudCalendarSyncManager(transport: transport, keychainManager: fixture.keychain,
            makeCommitContext: { container, phase in
                ModelContext(!withEvent && phase == .prepareEvent ? empty : container)
            })
        #expect(try await manager.syncSingleTask(taskID: fixture.task.id, accountID: fixture.accountID,
            role: .managedMirror, container: fixture.container) == withEvent)
        #expect(try fixture.destination().owned)
        #expect(try fixture.destination().eventCount == (withEvent ? 1 : 0))
        await #expect(throws: CalendarReceiptStore.Held.self) { try await fixture.sync(transport) }
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "MKCALENDAR" }.count == 1)
        #expect(try fixture.destination().owned)
    }

    @Test(arguments: [false, true])
    func collisionAfterPinnedAbsenceDurablyHoldsThePreparedDestination(typeAvailable: Bool) async throws {
        let host = "calendar-prepared-collision-\(typeAvailable).invalid"
        let fixture = try await interruptedCollection(host)
        let destination = try fixture.destination()
        let path = try #require(URLComponents(url: destination.collection, resolvingAgainstBaseURL: false)?.percentEncodedPath)
        var evidence = Self.proof(path, marker: "foreign")
        if !typeAvailable {
            evidence = evidence.replacingOccurrences(of: "<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>", with: "")
                .replacingOccurrences(of: "</d:response>", with: """
                <d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
                """)
        }
        let transport = transport(host, responses: discovery() + [.init(status: 404, body: ""),
            .init(status: 412, body: ""), .init(body: evidence)])
        await #expect(throws: (any Error).self) { try await fixture.sync(transport) }
        let held = try fixture.destination()
        #expect(held.state == .held)
        #expect(held.id == destination.id)
        #expect(held.marker == destination.marker)
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.filter { $0.method != "PROPFIND" }.map(\.method) == ["MKCALENDAR"])
        // The foreign claimant has since disappeared. A recorded contradiction still forbids the retry.
        let later = self.transport(host, responses: discovery() + [.init(status: 404, body: "")])
        await #expect(throws: (any Error).self) { try await fixture.sync(later) }
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "MKCALENDAR" })
        #expect(try fixture.destination() == held)
    }

    @Test(arguments: ["task", "draft", "seed", "binding"])
    func negativeCollectionProofPersistsOnlyForTheExactPreparedBinding(change: String) async throws {
        let host = "calendar-stale-negative-\(change).invalid"
        let fixture = try await interruptedCollection(host)
        let prepared = try fixture.destination()
        let path = try #require(URLComponents(url: prepared.collection, resolvingAgainstBaseURL: false)?.percentEncodedPath)
        let gate = ScriptedDAVProtocol.Gate()
        let transport = transport(host, responses: discovery() + [.init(body: Self.proof(path, marker: "foreign"), gate: gate)])
        var publications = 0
        let sync = Task { try await fixture.sync(transport) { publications += 1 } }
        defer { gate.release(); sync.cancel() }
        try await waitForRequest(host) { $0.method == "PROPFIND" && $0.url == prepared.collection }
        let context = fixture.container.mainContext
        var replacement: CalendarDestinationReceipt?
        switch change {
        case "task": try fixture.edit("After")
        case "draft": fixture.task.title = "Unsaved"
        case "seed": try await fixture.changeDiscoverySeed(to: String(root.dropLast()))
        default:
            let row = try #require(try context.fetch(FetchDescriptor<SyncMetadata>()).first { $0.id.contains(":destination:") })
            context.delete(row)
            let discovery = CalDAVDiscoveryResult(principalURL: prepared.principal, calendarHomeURL: prepared.home,
                calendars: .init(live: [], trashed: []), collectionAddresses: [])
            let next = try CalendarDestinationReceipt(scope: prepared.scope, discovery: discovery)
            try CalendarReceiptStore.store(next, in: context)
            try context.save()
            replacement = next
        }
        gate.release()
        if case .success(let changed) = await sync.result { #expect(!changed) }
        let saved = try fixture.destination()
        if let replacement { #expect(saved == replacement) }
        else {
            #expect(saved.state == .held)
            #expect(saved.id == prepared.id)
            #expect(saved.collection == prepared.collection)
        }
        #expect(publications == 0)
        #expect(try persistedNextcloudReceipts(fixture.container).isEmpty)
        #expect(ScriptedDAVProtocol.requests(host: host).allSatisfy { $0.method == "PROPFIND" })
        if change == "draft" {
            #expect(context.hasChanges)
            #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<TaskItem>()).first?.title == "Before")
        }
    }

    @Test(arguments: ["query", "path", "origin", "redirect", "propstat", "malformed", "partial", "denied", "timeout", "retryAfter"])
    func onlyFullyReceivedPinnedTopLevel404AuthorizesCreate(reason: String) async throws {
        let host = "calendar-invalid-absence-\(reason.lowercased()).invalid"
        let fixture = try await interruptedCollection(host)
        let destination = try fixture.destination()
        let path = try #require(URLComponents(url: destination.collection, resolvingAgainstBaseURL: false)?.percentEncodedPath)
        let reply: ScriptedDAVProtocol.Response
        switch reason {
        case "query": reply = .init(status: 404, body: "", responseURL: URL(string: destination.collection.absoluteString + "?wrong"))
        case "path": reply = .init(status: 404, body: "", responseURL: URL(string: "https://\(host)\(home)different/"))
        case "origin": reply = .init(status: 404, body: "", responseURL: URL(string: "https://foreign-calendar.invalid\(path)"))
        case "redirect": reply = .init(status: 302, body: "", redirectURL: destination.collection)
        case "propstat": reply = .init(body: xml(path, "<d:resourcetype/>").replacingOccurrences(of: "200 OK", with: "404 Not Found"))
        case "malformed": reply = .init(body: "<d:multistatus")
        case "partial": reply = .init(status: 404, body: "short", headers: ["Content-Length": "64"])
        case "denied": reply = .init(status: 403, body: "")
        case "timeout": reply = .init(body: "", errorCode: .timedOut)
        default: reply = .init(status: 429, body: "", headers: ["Retry-After": "60"])
        }
        let transport = transport(host, responses: discovery() + [reply])
        await #expect(throws: (any Error).self) { try await fixture.sync(transport) }
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND", "PROPFIND"])
        #expect(try fixture.destination().state == .prepared)
    }

    @Test(arguments: ["event", "claim", "duplicate", "corrupt", "rebound", "legacy", "home"])
    func preparedCollectionWithContradictingLocalOrDiscoveryEvidenceCannotResume(reason: String) async throws {
        let host = "calendar-prepared-hold-\(reason).invalid"
        let fixture = try await interruptedCollection(host)
        let prepared = try fixture.destination()
        let context = fixture.container.mainContext
        switch reason {
        case "event", "claim":
            let prefix = reason == "event" ? CalendarReceiptKey.events(fixture.accountID) : CalendarReceiptKey.claims(fixture.accountID)
            context.insert(SyncMetadata(id: prefix + "residual", collectionPath: ""))
        case "duplicate":
            let discovery = CalDAVDiscoveryResult(principalURL: prepared.principal, calendarHomeURL: prepared.home,
                calendars: .init(live: [], trashed: []), collectionAddresses: [])
            try CalendarReceiptStore.store(CalendarDestinationReceipt(scope: prepared.scope, discovery: discovery), in: context)
        case "corrupt":
            let row = try #require(try context.fetch(FetchDescriptor<SyncMetadata>()).first { $0.id.contains(":destination:") })
            row.syncToken = row.syncToken?.replacingOccurrences(of: "\"version\":1", with: "\"version\":100")
        case "rebound": fixture.account.serverBaseURL += "/"
        default: break
        }
        try context.save()
        let discovery = discovery(legacy: reason == "legacy").map { response in
            guard reason == "home" else { return response }
            var changed = response
            changed.body = response.body.replacingOccurrences(of: home, with: "/nextcloud/remote.php/dav/calendars/moved/")
            return changed
        }
        let transport = transport(host, responses: discovery + [.init(status: 404, body: "")])
        await #expect(throws: CalendarReceiptStore.Held.self) { try await fixture.sync(transport) }
        #expect(ScriptedDAVProtocol.requests(host: host).allSatisfy { $0.method == "PROPFIND" })
    }

    @Test(arguments: ["task", "account", "draft", "binding", "cancel", "budget"])
    func stalePreparedCollectionCannotCreateAfterAbsence(change: String) async throws {
        let host = "calendar-prepared-stale-\(change).invalid"
        let fixture = try await interruptedCollection(host)
        let target = try fixture.destination().collection
        let gate = ScriptedDAVProtocol.Gate()
        let transport = transport(host, responses: discovery() + [.init(status: 404, body: "", gate: gate)])
        let budget = BackgroundRunBudget()
        let sync = Task {
            try await BackgroundRunBudget.$current.withValue(change == "budget" ? budget : nil) {
                try await fixture.sync(transport) { Issue.record("A stale collection retry cannot publish") }
            }
        }
        defer { gate.release(); sync.cancel() }
        try await waitForRequest(host) { $0.method == "PROPFIND" && $0.url == target }
        let context = fixture.container.mainContext
        switch change {
        case "task": try fixture.edit("Newer title")
        case "account":
            fixture.account.serverBaseURL += "/"
            try context.save()
        case "draft": context.insert(TaskItem(title: "Unsaved"))
        case "binding":
            var receipt = try fixture.destination()
            receipt.state = .held
            receipt.revision += 1
            try CalendarReceiptStore.store(receipt, in: context)
            try context.save()
        case "cancel": sync.cancel()
        default: budget.stopRemote()
        }
        gate.release()
        let result = await sync.result
        if case .success(let changed) = result { #expect(!changed) }
        #expect(!ScriptedDAVProtocol.requests(host: host).contains { $0.method == "MKCALENDAR" || $0.method == "PUT" })
        if change == "draft" { #expect(context.hasChanges) }
    }

    @Test func preparedCollectionRetriesOnceForTheWholeBulkInvocation() async throws {
        let host = "calendar-prepared-bulk.invalid"
        let fixture = try await interruptedCollection(host)
        let second = TaskItem(title: "Another dated task")
        second.dueDate = fixture.task.dueDate
        fixture.container.mainContext.insert(second)
        try fixture.container.mainContext.save()
        let target = try fixture.destination().collection
        let transport = transport(host, responses: discovery() + [.init(status: 404, body: ""),
            .init(status: 201, body: ""), .init(status: 404, body: "")])
        await #expect(throws: CalendarReceiptStore.Held.self) {
            try await fixture.manager(transport).syncAll(accountID: fixture.accountID, container: fixture.container)
        }
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.filter { $0.url == target }.map(\.method) == ["PROPFIND", "MKCALENDAR", "PROPFIND"])
        #expect(!requests.contains { $0.method == "PUT" })
        #expect(try fixture.destination().state == .prepared)
    }

    @Test func inconsistentInventoryDoesNotStrandProvedManagedRemoval() async throws {
        let host = "calendar-independent-removal.invalid"
        let fixture = try fixture(host)
        let context = fixture.container.mainContext
        let second = TaskItem(title: "Keep this receipt")
        second.dueDate = fixture.task.dueDate
        context.insert(second)
        try context.save()
        let transport = transport(host, responses: firstWrite(host, reply: success("one"))
            + [success("two")] + existingCollection(host) + [.init(status: 204, body: "")])
        let manager = fixture.manager(transport)
        #expect(try await manager.syncAll(accountID: fixture.accountID, container: fixture.container))
        let before = try persistedNextcloudReceipts(fixture.container)
        let missing = try #require(before.first { $0.taskID == fixture.task.id })
        let remaining = try #require(before.first { $0.taskID == second.id })
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>())
        for row in rows {
            if row.id.contains(":claim:") && row.syncToken == missing.target.href {
                context.delete(row)
            } else if row.id.contains(":event:"), let raw = row.syncToken,
                      try JSONDecoder().decode(CalendarEventReceipt.self, from: Data(raw.utf8)).taskID == fixture.task.id {
                context.delete(row)
            }
        }
        second.dueDate = nil
        try context.save()
        var publications = 0
        await #expect(throws: CalendarReceiptStore.Held.self) {
            try await manager.syncAll(accountID: fixture.accountID, container: fixture.container) { publications += 1 }
        }
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.filter { $0.method == "PUT" }.count == 2)
        #expect(requests.filter { $0.method == "DELETE" }.map { $0.url.absoluteString } == [remaining.target.href])
        #expect(try persistedNextcloudReceipts(fixture.container).first?.wasRemoved == true)
        #expect(publications == 1)
    }

    private func waitForPut(_ host: String) async throws {
        try await waitForRequest(host) { $0.method == "PUT" }
    }

    private func waitForRequest(_ host: String, matches: (ScriptedDAVProtocol.RecordedRequest) -> Bool) async throws {
        let cutoff = ContinuousClock.now + .seconds(10)
        while !ScriptedDAVProtocol.requests(host: host).contains(where: matches), ContinuousClock.now < cutoff {
            try await Task.sleep(for: .milliseconds(5))
        }
        let captured = ScriptedDAVProtocol.requests(host: host).contains(where: matches)
        try #require(captured)
    }

    private struct Fixture {
        let container: ModelContainer
        let account: ServerAccount
        let task: TaskItem
        let keychain: KeychainManager

        var accountID: String { account.id }

        @MainActor func manager(_ transport: any NextcloudCalendarTransport) -> NextcloudCalendarSyncManager {
            NextcloudCalendarSyncManager(transport: transport, keychainManager: keychain)
        }

        @MainActor func sync(_ transport: any NextcloudCalendarTransport, role: CalendarEventRole = .managedMirror,
                             onCommit: @MainActor () -> Void = {}) async throws -> Bool {
            try await manager(transport).syncSingleTask(taskID: task.id, accountID: accountID, role: role,
                container: container, onCommit: onCommit)
        }

        @MainActor func remove(_ transport: any NextcloudCalendarTransport, explicit: Bool,
                               onCommit: @MainActor () -> Void = {}) async throws -> Bool {
            if explicit {
                return try await manager(transport).deleteManagedEvent(taskID: task.id, accountID: accountID,
                    container: container, onCommit: onCommit)
            }
            return try await sync(transport, onCommit: onCommit)
        }

        @MainActor func edit(_ title: String) throws {
            task.title = title
            try container.mainContext.save()
        }

        @MainActor func destination() throws -> CalendarDestinationReceipt {
            try #require(try CalendarReceiptStore.destination(for: AccountCredentialScope(account), in: ModelContext(container)))
        }

        @MainActor func changeDiscoverySeed(to path: String) async throws {
            let scope = AccountCredentialScope(account)
            let origin = try NextcloudServerAddress.parse(scope.serverBaseURL).baseURL
            var target = try #require(URLComponents(url: origin, resolvingAgainstBaseURL: false))
            target.percentEncodedPath = path
            let seed = try #require(target.url)
            try await AccountManager(modelContext: container.mainContext, keychainManager: keychain)
                .updateNextcloudAccount(accountID: scope.id, serverURL: seed.absoluteString)
            let context = ModelContext(container)
            let account = try #require(try context.fetch(FetchDescriptor<ServerAccount>()).first)
            #expect(AccountCredentialScope(account) == scope)
            #expect(try NextcloudDiscoverySeed.address(accountID: scope.id, serverURL: scope.serverBaseURL,
                in: context).discoverySeed == seed)
        }
    }

    private func fixture(_ host: String, store: URL? = nil) throws -> Fixture {
        let container: ModelContainer
        if let store {
            let schema = Schema(SchemaV2.models)
            container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: store, cloudKitDatabase: .none))
        } else {
            container = try DAVSyncScenario.container()
        }
        container.mainContext.autosaveEnabled = false
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: "https://\(host)/nextcloud", username: login)
        let task = TaskItem(title: "Before")
        task.dueDate = Date(timeIntervalSince1970: 1_700_000_000)
        container.mainContext.insert(account)
        container.mainContext.insert(task)
        try container.mainContext.save()
        return Fixture(container: container, account: account, task: task,
            keychain: DAVSyncScenario.keychain(accountID: account.id, password: "fixture"))
    }

    private func interruptedCollection(_ host: String) async throws -> Fixture {
        let fixture = try fixture(host)
        let interrupted = InterruptCalendarRequest(transport(host, responses: discovery()), stage: .collection)
        await #expect(throws: CancellationError.self) { try await fixture.sync(interrupted) }
        #expect(try fixture.destination().state == .prepared)
        return fixture
    }

    private func discovery(legacy: Bool = false, start: String? = nil) -> [ScriptedDAVProtocol.Response] {
        let homeProperty = DAVSyncScenario.prop(home, "<d:resourcetype><d:collection/></d:resourcetype>")
        let legacyProperty = legacy ? DAVSyncScenario.prop(home + "nowthis-calendar/", """
            <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
            <c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set>
            """) : ""
        return [
            .init(body: xml(start ?? root, "<d:current-user-principal><d:href>\(principal)</d:href></d:current-user-principal>")),
            .init(body: xml(principal, "<c:calendar-home-set><d:href>\(home)</d:href></c:calendar-home-set>")),
            .init(body: DAVSyncScenario.multistatus(homeProperty + legacyProperty))
        ]
    }

    private func firstWrite(_ host: String, reply: ScriptedDAVProtocol.Response) -> [ScriptedDAVProtocol.Response] {
        discovery() + [.init(status: 201, body: ""), collectionProof(host), reply]
    }

    private func existingCollection(_ host: String) -> [ScriptedDAVProtocol.Response] { discovery() + [collectionProof(host)] }

    private func collectionProof(_ host: String) -> ScriptedDAVProtocol.Response {
        .init(body: "", bodyForRequest: { request in
            guard let mk = ScriptedDAVProtocol.requests(host: host).first(where: { $0.method == "MKCALENDAR" }),
                  let path = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return "" }
            let mkBody = String(decoding: mk.body, as: UTF8.self)
            guard let start = mkBody.range(of: "<n:creation-id>"), let end = mkBody.range(of: "</n:creation-id>") else { return "" }
            return Self.proof(path, marker: String(mkBody[start.upperBound..<end.lowerBound]))
        })
    }

    private func success(_ etag: String, status: Int = 201) -> ScriptedDAVProtocol.Response {
        .init(status: status, body: "", headers: ["ETag": "\"\(etag)\""])
    }

    private func readback(_ host: String, tag: String, responseURL: URL? = nil,
                          mutate: @escaping @Sendable (String) -> String) -> ScriptedDAVProtocol.Response {
        .init(status: 200, body: "", headers: ["ETag": tag], responseURL: responseURL, bodyForRequest: { _ in
            let body = ScriptedDAVProtocol.requests(host: host).last { $0.method == "PUT" }?.body ?? Data()
            return mutate(String(decoding: body, as: UTF8.self))
        })
    }

    nonisolated private static func value(_ property: String, in data: Data) -> String? {
        let prefix = property + ":"
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
            .first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private func transport(_ host: String, responses: [ScriptedDAVProtocol.Response], maxAttempts: Int = 1) -> NextcloudCalendarHTTPTransport {
        let configuration = ScriptedDAVProtocol.install(host: host, responses: responses)
        return NextcloudCalendarHTTPTransport(client: CalDAVClient(configuration: configuration,
            retryPolicy: .init(maxAttempts: maxAttempts, baseDelay: 0)))
    }

    private func credentials(_ host: String) -> CommittedAccountCredentials {
        .init(scope: .init(id: host, serverBaseURL: "https://\(host)/nextcloud", username: login), password: "fixture")
    }

    private func proof(_ path: String) -> String {
        Self.proof(path, marker: marker)
    }

    nonisolated private static func proof(_ path: String, marker: String) -> String {
        DAVSyncScenario.multistatus(DAVSyncScenario.prop(path, """
            <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
            <c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set>
            <n:creation-id xmlns:n="https://nowthis.app/ns/caldav">\(marker)</n:creation-id>
            """)).replacingOccurrences(of: "<d:multistatus ", with: "<d:multistatus xmlns:n=\"https://nowthis.app/ns/caldav\" ")
    }

    private func xml(_ href: String, _ properties: String) -> String {
        DAVSyncScenario.multistatus(DAVSyncScenario.prop(href, properties))
    }
}

/// Interrupt one persisted mutation before the real HTTP transport dispatches it.
private actor InterruptCalendarRequest: NextcloudCalendarTransport {
    enum Stage: Sendable { case collection, removal }
    private let transport: NextcloudCalendarHTTPTransport
    private let stage: Stage
    private var cancelled = false

    init(_ transport: NextcloudCalendarHTTPTransport, stage: Stage) {
        self.transport = transport
        self.stage = stage
    }

    func discover(address: NextcloudServerAddress, admitted: CommittedAccountCredentials,
                  validate: @escaping CalendarRequestValidation) async throws -> CalDAVDiscoveryResult {
        try await transport.discover(address: address, admitted: admitted, validate: validate)
    }

    func ensureCollection(target: URL, marker: String, create: Bool, admitted: CommittedAccountCredentials,
                          validate: @escaping CalendarRequestValidation) async throws -> URL {
        if stage == .collection && create && !cancelled {
            cancelled = true
            throw CancellationError()
        }
        return try await transport.ensureCollection(target: target, marker: marker, create: create,
            admitted: admitted, validate: validate)
    }

    func read(target: CalendarEventTarget, admitted: CommittedAccountCredentials,
              validate: @escaping CalendarRequestValidation) async throws -> CalendarEventRead {
        try await transport.read(target: target, admitted: admitted, validate: validate)
    }

    func put(_ intent: CalendarEventIntent, admitted: CommittedAccountCredentials,
             validate: @escaping CalendarRequestValidation) async throws -> CalendarEventWrite {
        try await transport.put(intent, admitted: admitted, validate: validate)
    }

    func remove(_ intent: CalendarEventIntent, admitted: CommittedAccountCredentials,
                validate: @escaping CalendarRequestValidation) async throws {
        if stage == .removal && !cancelled {
            cancelled = true
            throw CancellationError()
        }
        try await transport.remove(intent, admitted: admitted, validate: validate)
    }
}
