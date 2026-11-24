import Foundation
import SwiftData
import Testing
@testable import NowThis

@MainActor
@Suite("Watch edit delivery")
struct PhoneBridgeSendFailureTests {
    @Test func inactiveTransportNeverAddsOptimismOrSends() throws {
        let session = DeliverySpy()
        session.isActivated = false
        let engine = WatchDeliveryEngine(session: session, store: WatchSnapshotStore(containerURL: nil))
        engine.apply(WatchSnapshot(schemaVersion: 1, isProUnlocked: true, generatedAt: Date(),
            lists: [], tasks: [], truncated: false, defaultListID: nil))
        engine.add(rawText: "Buy milk", listID: nil)
        #expect(engine.overlay.pendingAdds.isEmpty)
        #expect(engine.lastSendFailure == .inactive)
        #expect(session.messages.isEmpty)
        #expect(session.transfers.isEmpty)
    }

    @Test func ambiguousDirectFailureRollsBackWithoutReplay() async throws {
        let session = DeliverySpy()
        let engine = WatchDeliveryEngine(session: session, store: WatchSnapshotStore(containerURL: nil))
        engine.apply(WatchSnapshot(schemaVersion: 1, isProUnlocked: true, generatedAt: Date(),
            lists: [], tasks: [], truncated: false, defaultListID: nil))
        engine.add(rawText: "Buy milk", listID: nil)
        session.fail?()
        for _ in 0..<10 { await Task.yield() }
        #expect(engine.overlay.pendingAdds.isEmpty)
        #expect(engine.lastSendFailure == .unconfirmed)
        #expect(session.transfers.isEmpty)
    }
    private func unlocked(_ engine: WatchDeliveryEngine, receipts: [WatchOperationReceipt]? = []) {
        engine.apply(WatchSnapshot(schemaVersion: 1, isProUnlocked: true, generatedAt: Date(),
            lists: [], tasks: [], truncated: false, defaultListID: nil, receipts: receipts))
    }

    @Test func queuedTransferFailureRollsBackButSuccessIsNotApplicationSuccess() throws {
        let session = DeliverySpy()
        session.isReachable = false
        let engine = WatchDeliveryEngine(session: session, store: WatchSnapshotStore(containerURL: nil))
        unlocked(engine)
        engine.add(rawText: "Buy milk tomorrow", listID: nil)
        let id = try #require(engine.overlay.pendingAdds.first?.id)
        #expect(session.messages.isEmpty)
        #expect(session.transfers.count == 1)
        engine.transferFinished(operationID: id, failed: false)
        #expect(engine.overlay.pendingAdds.count == 1)
        engine.transferFinished(operationID: id, failed: true)
        #expect(engine.overlay.pendingAdds.isEmpty)
        #expect(engine.lastSendFailure == .unconfirmed)
    }

    @Test func receiptClearsParsedTitleAfterPersistentRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WatchSnapshotStore(containerURL: directory)
        let session = DeliverySpy()
        session.isReachable = false
        let original = WatchDeliveryEngine(session: session, store: store)
        unlocked(original)
        original.add(rawText: "Buy milk tomorrow", listID: nil)
        let id = try #require(original.overlay.pendingAdds.first?.id)
        let restarted = WatchDeliveryEngine(session: session, store: store)
        #expect(restarted.overlay.pendingOperations?.first?.id == id)
        let task = WatchTask(id: "phone", uid: "phone", title: "Buy milk", dueDate: nil,
            isDueDateOnly: true, priorityRaw: 0, isCompleted: false, listID: "", parentUID: nil)
        restarted.apply(WatchSnapshot(schemaVersion: 1, isProUnlocked: true, generatedAt: Date(),
            lists: [], tasks: [task], truncated: false, defaultListID: nil,
            receipts: [WatchOperationReceipt(id: id, result: WatchEditReply.applied)]))
        #expect(restarted.overlay.pendingAdds.isEmpty)
        #expect(restarted.overlay.pendingOperations?.isEmpty == true)
        #expect(restarted.displayTasks.map(\.title) == ["Buy milk"])
        #expect(store.loadOverlay().pendingAdds.isEmpty)
    }

    @Test(arguments: [WatchEditReply.locked, WatchEditReply.invalid, WatchEditReply.unknownTask,
                      WatchEditReply.unsupportedRecurrence, WatchEditReply.applied])
    func everyTerminalReceiptClearsOnlyItsOperation(result: String) throws {
        let session = DeliverySpy()
        session.isReachable = false
        let engine = WatchDeliveryEngine(session: session, store: WatchSnapshotStore(containerURL: nil))
        unlocked(engine)
        engine.complete(uid: "first")
        engine.add(rawText: "Other", listID: nil)
        let id = try #require(engine.overlay.pendingOperations?.first?.id)
        unlocked(engine, receipts: [WatchOperationReceipt(id: id, result: result)])
        #expect(engine.overlay.pendingCompletes.isEmpty)
        #expect(engine.overlay.pendingAdds.count == 1)
        #expect(engine.overlay.pendingOperations?.count == 1)
        if result == WatchEditReply.unsupportedRecurrence { #expect(engine.showingUnsupportedRecurrence) }
    }

    @Test func boundsRejectBeforeTransportOrOptimism() throws {
        let session = DeliverySpy()
        session.isReachable = false
        let engine = WatchDeliveryEngine(session: session, store: WatchSnapshotStore(containerURL: nil))
        unlocked(engine)
        for raw in [String(repeating: "a", count: 50_000), "a" + String(repeating: "\u{301}", count: 16_000)] {
            #expect(!engine.add(rawText: raw, listID: nil))
            #expect(engine.lastSendFailure == .tooLong)
            #expect(engine.overlay.pendingAdds.isEmpty)
            #expect(session.transfers.isEmpty)
            #expect(throws: WatchEdit.ValidationError.self) {
                try WatchEdit.add(rawText: raw, listID: nil, dueDate: nil, priorityRaw: nil).userInfoDictionary()
            }
        }
        for _ in 0..<64 { #expect(engine.add(rawText: "Milk", listID: nil)) }
        #expect(!engine.add(rawText: "Overflow", listID: nil))
        #expect(engine.overlay.pendingAdds.count == 64)
        #expect(session.transfers.count == 64)
        #expect(engine.lastSendFailure == .queueFull)
    }

    @Test func unknownLookupKeepsOutstandingQueueThenReportsUncertaintyAfterFinish() async throws {
        let session = DeliverySpy()
        session.isReachable = false
        let engine = WatchDeliveryEngine(session: session, store: WatchSnapshotStore(containerURL: nil))
        unlocked(engine)
        engine.add(rawText: "Milk", listID: nil)
        let id = try #require(engine.overlay.pendingAdds.first?.id)
        session.outstandingOperationIDs = [id]
        session.isReachable = true
        unlocked(engine) // cached snapshot may precede queued application
        session.reply?([WatchEdit.receiptReplyKey: try JSONEncoder().encode([
            WatchOperationReceipt(id: id, result: WatchEditReply.unconfirmed)])])
        for _ in 0..<10 { await Task.yield() }
        #expect(engine.overlay.pendingAdds.count == 1)
        #expect(engine.lastSendFailure == nil)
        session.outstandingOperationIDs = []
        engine.transferFinished(operationID: id, failed: false)
        session.reply?([WatchEdit.receiptReplyKey: try JSONEncoder().encode([WatchOperationReceipt]())])
        for _ in 0..<10 { await Task.yield() }
        #expect(engine.overlay.pendingAdds.isEmpty)
        #expect(engine.lastSendFailure == .unconfirmed)
        #expect(session.transfers.count == 1)
    }

    @Test func retainedLookupClearsPendingAndOldPhoneIgnoresQuery() async throws {
        let session = DeliverySpy()
        session.isReachable = false
        let engine = WatchDeliveryEngine(session: session, store: WatchSnapshotStore(containerURL: nil))
        unlocked(engine)
        engine.add(rawText: "Milk", listID: nil)
        let id = try #require(engine.overlay.pendingAdds.first?.id)
        session.isReachable = true
        engine.requestPendingReceipts()
        session.reply?([WatchEditReply.key: WatchEditReply.unknownTask])
        for _ in 0..<10 { await Task.yield() }
        #expect(engine.overlay.pendingAdds.count == 1)
        engine.requestPendingReceipts()
        session.reply?([WatchEdit.receiptReplyKey: try JSONEncoder().encode([
            WatchOperationReceipt(id: id, result: WatchEditReply.applied)])])
        for _ in 0..<10 { await Task.yield() }
        #expect(engine.overlay.pendingAdds.isEmpty)
        #expect(engine.lastSendFailure == nil)
        #expect(session.transfers.count == 1)
    }

    @Test func legacyOverlayAndSnapshotStillDecode() throws {
        let overlay = try JSONDecoder().decode(WatchOverlayState.self, from: Data(
            #"{"pendingAdds":[],"pendingCompletes":["old"],"pendingUncompletes":[]}"#.utf8))
        #expect(overlay.pendingCompletes == ["old"])
        #expect(overlay.pendingOperations == nil)
        let edit = WatchEdit.complete(uid: "old")
        #expect(WatchEdit(userInfoDictionary: try edit.userInfoDictionary()) == edit)
    }

    @Test func lockedSnapshotStaysReadableAndRejectsAllWrites() {
        let session = DeliverySpy()
        let engine = WatchDeliveryEngine(session: session, store: WatchSnapshotStore(containerURL: nil))
        let task = WatchTask(id: "t", uid: "t", title: "Read me", dueDate: nil, isDueDateOnly: false,
            priorityRaw: 0, isCompleted: false, listID: "", parentUID: nil)
        engine.apply(WatchSnapshot(schemaVersion: 1, isProUnlocked: false, generatedAt: Date(),
            lists: [], tasks: [task], truncated: false, defaultListID: nil))
        engine.complete(uid: "t")
        engine.uncomplete(uid: "t")
        #expect(!engine.add(rawText: "No", listID: nil))
        #expect(engine.displayTasks == [task])
        #expect(engine.overlay.pendingOperations == nil)
        #expect(session.messages.isEmpty && session.transfers.isEmpty)
    }

    @Test(arguments: [0, 1])
    func lookupFailureIsNotShownAgainByApplicationContext(failureIndex: Int) async throws {
        let session = DeliverySpy()
        session.isReachable = false
        let store = WatchSnapshotStore(containerURL: nil)
        let suiteName = "watch-lookup-failure-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = WatchDeliveryEngine(session: session, store: store, failureDefaults: defaults)
        unlocked(engine)
        engine.complete(uid: "first")
        engine.complete(uid: "second")
        let pending = try #require(engine.overlay.pendingOperations)
        #expect(pending.count == 2)
        let receipts = pending.map {
            WatchOperationReceipt(id: $0.id, result: WatchEditReply.unsupportedRecurrence)
        }
        session.isReachable = true
        engine.requestPendingReceipts()
        session.reply?([WatchEdit.receiptReplyKey: try JSONEncoder().encode(receipts)])
        for _ in 0..<10 { await Task.yield() }
        #expect(engine.showingUnsupportedRecurrence)
        #expect(engine.overlay.pendingOperations?.isEmpty == true)
        engine.showingUnsupportedRecurrence = false

        // Match PhoneBridge's application-context order: snapshot, then legacy fields.
        let failureID = pending[failureIndex].id.uuidString
        let failureUID = failureIndex == 0 ? "first" : "second"
        let restarted = WatchDeliveryEngine(session: session, store: store, failureDefaults: defaults)
        unlocked(restarted, receipts: receipts)
        restarted.handleCompletionFailure(id: failureID, uid: failureUID)
        #expect(!restarted.showingUnsupportedRecurrence)
        unlocked(engine, receipts: receipts)
        engine.handleCompletionFailure(id: failureID, uid: failureUID)
        #expect(!engine.showingUnsupportedRecurrence)
    }

    @Test func failureFeedbackHistoryMigratesAndBoundsRetainedIDs() throws {
        let suiteName = "watch-failure-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("legacy-event", forKey: "watchCompletionFailureID")
        defaults.set([
            ["id": "expired", "handledAt": Date().addingTimeInterval(-31 * 24 * 60 * 60)],
            ["id": String(repeating: "x", count: 65), "handledAt": Date()],
            ["id": "malformed", "handledAt": "yesterday"]
        ], forKey: "watchHandledCompletionFailures")
        let engine = WatchDeliveryEngine(session: DeliverySpy(), store: WatchSnapshotStore(containerURL: nil),
                                         failureDefaults: defaults)
        engine.handleCompletionFailure(id: "legacy-event", uid: "task")
        #expect(!engine.showingUnsupportedRecurrence)
        #expect(defaults.object(forKey: "watchCompletionFailureID") == nil)
        #expect(defaults.array(forKey: "watchHandledCompletionFailures")?.count == 1)
        for id in ["", String(repeating: "x", count: 65), String(repeating: "é", count: 33)] {
            engine.handleCompletionFailure(id: id, uid: "task")
            #expect(!engine.showingUnsupportedRecurrence)
        }
        engine.handleCompletionFailure(id: "expired", uid: "task")
        #expect(engine.showingUnsupportedRecurrence)
        for index in 0..<512 { engine.handleCompletionFailure(id: "event-\(index)", uid: "task") }
        #expect(defaults.array(forKey: "watchHandledCompletionFailures")?.count == 512)
        let restarted = WatchDeliveryEngine(session: DeliverySpy(), store: WatchSnapshotStore(containerURL: nil),
                                            failureDefaults: defaults)
        restarted.handleCompletionFailure(id: "event-511", uid: "task")
        #expect(!restarted.showingUnsupportedRecurrence)
        restarted.handleCompletionFailure(id: "legacy-event", uid: "task")
        #expect(restarted.showingUnsupportedRecurrence) // Evicted feedback is explicitly outside the guarantee.
    }

    @Test func legacyDirectFailureEventIsNotShownTwice() async throws {
        let session = DeliverySpy()
        let engine = WatchDeliveryEngine(session: session, store: WatchSnapshotStore(containerURL: nil))
        unlocked(engine, receipts: nil)
        engine.complete(uid: "task")
        let failureID = UUID().uuidString
        session.reply?([WatchEditReply.key: WatchEditReply.unsupportedRecurrence,
                        WatchEditReply.completionFailureIDKey: failureID,
                        WatchEditReply.completionFailureUIDKey: "task"])
        for _ in 0..<10 { await Task.yield() }
        #expect(engine.showingUnsupportedRecurrence)
        engine.showingUnsupportedRecurrence = false
        engine.handleCompletionFailure(id: failureID, uid: "task")
        #expect(!engine.showingUnsupportedRecurrence)
    }

    @Test func delayedInvalidAddIsRecoverableAfterRelaunchWithoutReplay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WatchSnapshotStore(containerURL: directory)
        let session = DeliverySpy()
        session.isReachable = false
        let engine = WatchDeliveryEngine(session: session, store: store)
        unlocked(engine)
        let raw = String(repeating: "x", count: 501)
        let due = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(engine.add(rawText: raw, listID: "original-list", dueDate: due, priorityRaw: 1))
        let operation = try #require(engine.overlay.pendingOperations?.first)
        // Real phone validation arrives after the add sheet has already dismissed.
        let container = try DAVSyncScenario.container()
        let list = TaskList(serverURL: "", name: "Inbox", colorHex: "")
        list.id = "original-list"
        container.mainContext.insert(list)
        try container.mainContext.save()
        let receipt = WatchEditTransaction.apply(operation.edit, operationID: operation.id,
            container: container, isProUnlocked: true)
        #expect(receipt == WatchEditReply.invalid)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).isEmpty)
        unlocked(engine, receipts: [WatchOperationReceipt(id: operation.id, result: receipt)])
        #expect(engine.overlay.pendingAdds.isEmpty)
        #expect(engine.rejectedAdds == [operation])
        let restarted = WatchDeliveryEngine(session: session, store: store)
        #expect(restarted.rejectedAdds == [operation])
        #expect(session.transfers.count == 1 && session.messages.isEmpty)
        #expect(restarted.recoverAdd(id: operation.id, rawText: "Corrected", listID: "original-list",
            dueDate: due, priorityRaw: 1))
        #expect(restarted.rejectedAdds.isEmpty)
        let replacement = try #require(restarted.overlay.pendingOperations?.first)
        #expect(replacement.id != operation.id)
        #expect(replacement.edit == .add(rawText: "Corrected", listID: "original-list", dueDate: due, priorityRaw: 1))
        #expect(session.transfers.count == 2)
    }

    @Test(arguments: ["direct", "snapshot", "lookup"])
    func readOnlyAddRetainsDraftAndExplainsItsRefusal(_ delivery: String) async throws {
        struct FutureReceipt: Encodable {
            let id: UUID
            let result = WatchEditReply.invalid
            let refusalReason = "readOnlyList"
        }
        let session = DeliverySpy()
        session.isReachable = delivery == "direct"
        let engine = WatchDeliveryEngine(session: session, store: WatchSnapshotStore(containerURL: nil))
        unlocked(engine)
        let due = Date(timeIntervalSince1970: 2_000_000_000)
        let edit = WatchEdit.add(rawText: "Keep my original text", listID: "read-only", dueDate: due, priorityRaw: 1)
        #expect(engine.add(rawText: "Keep my original text", listID: "read-only", dueDate: due, priorityRaw: 1))
        let operation = try #require(engine.overlay.pendingOperations?.first)
        let reason = FutureReceipt(id: operation.id)
        switch delivery {
        case "direct":
            session.reply?([WatchEditReply.key: WatchEditReply.invalid, "refusalReason": reason.refusalReason])
        case "snapshot":
            let data = try JSONEncoder().encode(reason)
            let receipt = try JSONDecoder().decode(WatchOperationReceipt.self, from: data)
            unlocked(engine, receipts: [receipt])
        default:
            session.isReachable = true
            engine.requestPendingReceipts()
            #expect(session.messages.last?[WatchEdit.receiptQueryKey] as? [String] == [operation.id.uuidString])
            session.reply?([WatchEdit.receiptReplyKey: try JSONEncoder().encode([reason])])
        }
        for _ in 0..<100 {
            if engine.overlay.pendingOperations?.isEmpty == true { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(engine.overlay.pendingAdds.isEmpty)
        #expect(engine.overlay.pendingOperations?.isEmpty == true)
        #expect(engine.rejectedAdds == [operation])
        #expect(engine.rejectedAdds.first?.edit == edit)
        #expect(engine.lastSendFailure != nil)
        #expect(engine.lastSendFailure != .invalidDraft, "The known denial must guide list selection instead of suggesting a title edit.")
        #expect(session.messages.count + session.transfers.count == (delivery == "lookup" ? 2 : 1))
    }

    @Test func unknownWatchRefusalReasonKeepsLegacyInvalidDraft() async throws {
        let session = DeliverySpy()
        let engine = WatchDeliveryEngine(session: session, store: WatchSnapshotStore(containerURL: nil))
        unlocked(engine)
        #expect(engine.add(rawText: "Original", listID: "old-list"))
        let operation = try #require(engine.overlay.pendingOperations?.first)
        session.reply?([WatchEditReply.key: WatchEditReply.invalid, "refusalReason": "future-case"])
        for _ in 0..<100 {
            if engine.overlay.pendingOperations?.isEmpty == true { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(engine.rejectedAdds == [operation])
        #expect(engine.lastSendFailure == .invalidDraft)
    }

    @Test func fullDraftCapacityAllowsOnlyExplicitReplacementAndRetainsOnAdmissionFailure() throws {
        let session = DeliverySpy()
        session.isReachable = false
        let engine = WatchDeliveryEngine(session: session, store: WatchSnapshotStore(containerURL: nil))
        unlocked(engine)
        for index in 0..<64 { #expect(engine.add(rawText: "Draft \(index)", listID: nil)) }
        let pending = engine.overlay.pendingOperations ?? []
        unlocked(engine, receipts: pending.map { WatchOperationReceipt(id: $0.id, result: WatchEditReply.invalid) })
        #expect(engine.rejectedAdds.count == 64)
        #expect(!engine.add(rawText: "Overflow", listID: nil))
        let original = try #require(pending.first)
        session.isActivated = false
        #expect(!engine.recoverAdd(id: original.id, rawText: "Corrected", listID: nil, dueDate: nil, priorityRaw: nil))
        #expect(engine.rejectedAdds.count == 64)
        session.isActivated = true
        #expect(!engine.recoverAdd(id: original.id, rawText: String(repeating: "x", count: 2_001), listID: nil, dueDate: nil, priorityRaw: nil))
        #expect(engine.rejectedAdds.count == 64)
        #expect(engine.recoverAdd(id: original.id, rawText: "Corrected", listID: nil, dueDate: nil, priorityRaw: nil))
        #expect(engine.rejectedAdds.count == 63)
        #expect(engine.overlay.pendingOperations?.count == 1)
        #expect(session.transfers.count == 65)
    }

    @Test func failedRecoveryStorageRetainsDraftAndSendsNothing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WatchSnapshotStore(containerURL: directory)
        let session = DeliverySpy()
        session.isReachable = false
        let engine = WatchDeliveryEngine(session: session, store: store)
        unlocked(engine)
        #expect(engine.add(rawText: "Original", listID: nil))
        let operation = try #require(engine.overlay.pendingOperations?.first)
        unlocked(engine, receipts: [WatchOperationReceipt(id: operation.id, result: WatchEditReply.invalid)])
        try FileManager.default.removeItem(at: directory)
        #expect(!engine.recoverAdd(id: operation.id, rawText: "Corrected", listID: nil,
            dueDate: nil, priorityRaw: nil))
        #expect(engine.rejectedAdds == [operation])
        #expect(engine.overlay.pendingOperations?.isEmpty == true)
        #expect(session.transfers.count == 1)
        engine.discardRejectedAdd(id: operation.id)
        #expect(engine.rejectedAdds == [operation])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        engine.discardRejectedAdd(id: operation.id)
        #expect(engine.rejectedAdds.isEmpty)
        #expect(WatchDeliveryEngine(session: session, store: store).rejectedAdds.isEmpty)
        #expect(session.transfers.count == 1)
    }

}

@MainActor
private final class DeliverySpy: WatchEditTransport {
    var isActivated = true
    var isReachable = true
    var outstandingOperationIDs: Set<UUID> = []
    var messages: [[String: Any]] = []
    var transfers: [[String: Any]] = []
    var reply: (@Sendable ([String: Any]) -> Void)?
    var fail: (@Sendable () -> Void)?
    func sendMessage(_ message: [String: Any], replyHandler: @escaping @Sendable ([String: Any]) -> Void,
                     errorHandler: @escaping @Sendable () -> Void) {
        messages.append(message)
        reply = replyHandler
        fail = errorHandler
    }
    func transferUserInfo(_ userInfo: [String: Any]) { transfers.append(userInfo) }
}
