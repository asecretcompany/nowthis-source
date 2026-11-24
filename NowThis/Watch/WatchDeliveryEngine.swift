import Foundation
import Observation

@MainActor
protocol WatchEditTransport: AnyObject {
    var isActivated: Bool { get }
    var isReachable: Bool { get }
    var outstandingOperationIDs: Set<UUID> { get }
    func sendMessage(_ message: [String: Any], replyHandler: @escaping @Sendable ([String: Any]) -> Void,
                     errorHandler: @escaping @Sendable () -> Void)
    func transferUserInfo(_ userInfo: [String: Any])
}

@MainActor
@Observable
final class WatchDeliveryEngine {

    private(set) var snapshot: WatchSnapshot?
    private(set) var overlay: WatchOverlayState
    /// Set whenever a `WatchEdit` comes back `locked` from the phone, so a
    /// future view can react to a server-confirmed lock (not consumed by
    /// Task 9's views, which gate optimistically on `isProUnlocked` instead).
    private(set) var lastLockedPrompt: Date?
    var showingUnsupportedRecurrence = false
    // Feedback deduplication is bounded like phone receipts, not a forever guarantee.
    @ObservationIgnored private var completionFailures: [String: Date] = [:]
    @ObservationIgnored private let failureDefaults: UserDefaults
    private static let failureHistoryKey = "watchHandledCompletionFailures"
    private static let failureRetention: TimeInterval = 30 * 24 * 60 * 60
    private static let failureCapacity = 512
    enum SendFailure: Equatable {
        case inactive, unconfirmed, tooLong, queueFull, rejected, invalidDraft, readOnly, readOnlyDraft
    }
    var lastSendFailure: SendFailure?
    private var receiptQueryInFlight = false
    private var accessRevision = 0
    @ObservationIgnored nonisolated(unsafe) private var deadlineTask: Task<Void, Never>?

    private let session: WatchEditTransport
    private let store: WatchSnapshotStore

    init(session: WatchEditTransport, store: WatchSnapshotStore = WatchSnapshotStore(),
         failureDefaults: UserDefaults = .standard) {
        self.session = session
        self.failureDefaults = failureDefaults
        self.store = store
        self.snapshot = store.load()
        self.overlay = store.loadOverlay()
        let now = Date()
        for entry in (failureDefaults.array(forKey: Self.failureHistoryKey) ?? []).suffix(Self.failureCapacity) {
            guard let entry = entry as? [String: Any], let id = entry["id"] as? String,
                  Self.validFailureID(id), let handledAt = entry["handledAt"] as? Date,
                  handledAt > now.addingTimeInterval(-Self.failureRetention) else { continue }
            completionFailures[id] = min(handledAt, now)
        }
        // The previous version stored one supplied legacy event ID. Migrate once;
        // removing the old key prevents an evicted ID being revived on every launch.
        if let oldID = failureDefaults.string(forKey: "watchCompletionFailureID"), Self.validFailureID(oldID) {
            completionFailures[oldID] = completionFailures[oldID] ?? now
        }
        persistCompletionFailures(at: now)
        failureDefaults.removeObject(forKey: "watchCompletionFailureID")
    }

    var displayTasks: [WatchTask] {
        guard let snapshot else { return [] }
        return overlay.displayTasks(from: snapshot)
    }

    var isProUnlocked: Bool {
        _ = accessRevision
        return snapshot?.canEditTasks(at: Date()) ?? false
    }

    func reconcileProDeadline(at now: Date = Date()) {
        accessRevision += 1
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let expiry = snapshot?.proAccessValidUntil, expiry > now else { return }
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(expiry.timeIntervalSince(now))) }
            catch { return }
            self?.reconcileProDeadline()
        }
    }


    func complete(uid: String) { _ = send(.complete(uid: uid)) }
    func uncomplete(uid: String) { _ = send(.uncomplete(uid: uid)) }

    @discardableResult
    func add(rawText: String, listID: String?, dueDate: Date? = nil, priorityRaw: Int? = nil) -> Bool {
        send(.add(rawText: rawText, listID: listID, dueDate: dueDate, priorityRaw: priorityRaw))
    }

    var rejectedAdds: [WatchPendingOperation] { overlay.rejectedAdds ?? [] }

    @discardableResult
    func recoverAdd(id: UUID, rawText: String, listID: String?, dueDate: Date?, priorityRaw: Int?) -> Bool {
        guard rejectedAdds.contains(where: { $0.id == id }) else { return false }
        return send(.add(rawText: rawText, listID: listID, dueDate: dueDate, priorityRaw: priorityRaw),
                    replacingRejectedID: id)
    }

    func discardRejectedAdd(id: UUID) {
        let previous = overlay
        overlay.rejectedAdds?.removeAll { $0.id == id }
        do { try store.save(overlay: overlay) }
        catch { overlay = previous; lastSendFailure = .unconfirmed }
    }

    @discardableResult
    private func send(_ edit: WatchEdit, replacingRejectedID: UUID? = nil) -> Bool {
        guard isProUnlocked else { lastLockedPrompt = Date(); return false }
        guard session.isActivated else { lastSendFailure = .inactive; return false }
        guard edit.hasValidRawText else { lastSendFailure = .tooLong; return false }
        let retainedDrafts = rejectedAdds.filter { $0.id != replacingRejectedID }.count
        guard (overlay.pendingOperations?.count ?? 0) + retainedDrafts < 64 else {
            lastSendFailure = .queueFull; return false
        }
        // Concurrent toggles of the same task cannot be represented by the set overlay;
        // wait for its receipt instead of allowing an old failure to undo a newer action.
        if let uid = edit.taskUID, (overlay.pendingOperations ?? []).contains(where: { $0.edit.taskUID == uid }) {
            lastSendFailure = .queueFull; return false
        }
        let operation = WatchPendingOperation(id: UUID(), edit: edit, createdAt: Date())
        guard let payload = try? edit.userInfoDictionary(operationID: operation.id) else {
            lastSendFailure = .unconfirmed; return false
        }
        let previous = overlay
        overlay.rejectedAdds?.removeAll { $0.id == replacingRejectedID }
        switch edit {
        case .complete(let uid): overlay.noteComplete(uid: uid)
        case .uncomplete(let uid): overlay.noteUncomplete(uid: uid)
        case .add(let rawText, _, _, _):
            overlay.noteAdd(WatchPendingAdd(id: operation.id, rawText: rawText, createdAt: operation.createdAt))
        }
        overlay.pendingOperations = (overlay.pendingOperations ?? []) + [operation]
        do { try store.save(overlay: overlay) }
        catch {
            overlay = previous
            lastSendFailure = .unconfirmed
            return false
        }
        lastSendFailure = nil
        if session.isReachable {
            session.sendMessage(payload, replyHandler: { [weak self] reply in
                let result = reply[WatchEditReply.key] as? String ?? WatchEditReply.unconfirmed
                let refusalReason = reply[WatchEditReply.refusalReasonKey] as? String
                let failureID = reply[WatchEditReply.completionFailureIDKey] as? String
                let failureUID = reply[WatchEditReply.completionFailureUIDKey] as? String
                Task { @MainActor in
                    self?.resolve(id: operation.id, result: result, refusalReason: refusalReason)
                    if result == WatchEditReply.unsupportedRecurrence {
                        self?.handleCompletionFailure(id: failureID, uid: failureUID)
                    }
                }
            }, errorHandler: { [weak self] in
                Task { @MainActor in self?.resolve(id: operation.id, result: WatchEditReply.unconfirmed) }
            })
        } else {
            session.transferUserInfo(payload)
        }
        return true
    }

    /// Delivery completion is NOT an application receipt. Only a failed queued transfer
    /// rolls back here; success waits for the phone's atomic terminal result.
    func transferFinished(operationID: UUID, failed: Bool) {
        if failed { resolve(id: operationID, result: WatchEditReply.unconfirmed) }
        else { requestPendingReceipts() }
    }

    private func resolve(id: UUID, result: String, refusalReason: String? = nil) {
        guard let operation = overlay.pendingOperations?.first(where: { $0.id == id }) else { return }
        overlay.pendingOperations?.removeAll { $0.id == id }
        switch operation.edit {
        case .complete(let uid): overlay.pendingCompletes.remove(uid)
        case .uncomplete(let uid): overlay.pendingUncompletes.remove(uid)
        case .add:
            // Only an explicit invalid receipt guarantees no task was created. Unknown
            // delivery outcomes keep their check-phone warning and are never replayed.
            if result == WatchEditReply.invalid {
                overlay.rejectedAdds = rejectedAdds + [operation]
            }
            overlay.confirmAdd(id: id)
        }
        switch result {
        case WatchEditReply.applied: break
        case WatchEditReply.locked: lastLockedPrompt = Date(); lastSendFailure = .rejected
        case WatchEditReply.unsupportedRecurrence:
            if recordCompletionFailure(id: id.uuidString) { showingUnsupportedRecurrence = true }
        case WatchEditReply.invalid:
            let readOnly = refusalReason == WatchEditRefusalReason.readOnlyList.rawValue
            if case .add = operation.edit { lastSendFailure = readOnly ? .readOnlyDraft : .invalidDraft }
            else { lastSendFailure = readOnly ? .readOnly : .rejected }
        case WatchEditReply.unknownTask: lastSendFailure = .rejected
        default: lastSendFailure = .unconfirmed
        }
        // A failed write leaves the original pending operation on disk, so the
        // next receipt lookup can recover it again after relaunch; keep this draft in memory.
        do { try store.save(overlay: overlay) }
        catch { lastSendFailure = .unconfirmed }
    }

    /// Read-only lookup, never a replay. Recent snapshots carry only 64 receipts, while
    /// the phone keeps up to 512 for 30 days. A missing result is explicitly uncertain.
    func requestPendingReceipts() {
        guard session.isActivated, session.isReachable, !receiptQueryInFlight,
              let pending = overlay.pendingOperations, !pending.isEmpty else { return }
        receiptQueryInFlight = true
        session.sendMessage([WatchEdit.receiptQueryKey: pending.prefix(64).map { $0.id.uuidString }],
            replyHandler: { [weak self] reply in
                let data = reply[WatchEdit.receiptReplyKey] as? Data
                let receipts = data.flatMap { try? JSONDecoder().decode([WatchOperationReceipt].self, from: $0) }
                Task { @MainActor in
                    guard let self else { return }
                    self.receiptQueryInFlight = false
                    // Old phones do not implement lookup: leave legacy reconciliation intact.
                    guard let receipts else { return }
                    for operation in pending.prefix(64) {
                        let receipt = receipts.first { $0.id == operation.id }
                        let result = receipt?.result ?? WatchEditReply.unconfirmed
                        if result == WatchEditReply.unconfirmed,
                           self.session.outstandingOperationIDs.contains(operation.id) { continue }
                        self.resolve(id: operation.id, result: result, refusalReason: receipt?.refusalReason)
                    }
                }
            }, errorHandler: { [weak self] in
                Task { @MainActor in self?.receiptQueryInFlight = false }
            })
    }

    func handleCompletionFailure(id: String?, uid: String?) {
        guard let id, let uid, recordCompletionFailure(id: id) else { return }
        // New-phone receipts already target the exact operation. Only the legacy
        // protocol needs the old UID fallback; it must not undo a newer identified edit.
        if snapshot?.receipts == nil {
            overlay.pendingCompletes.remove(uid)
            overlay.pendingOperations?.removeAll {
                if case .complete(let pendingUID) = $0.edit { return pendingUID == uid }
                return false
            }
            persistOverlay()
        }
        showingUnsupportedRecurrence = true
    }

    private static func validFailureID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64
    }

    private func recordCompletionFailure(id: String) -> Bool {
        guard Self.validFailureID(id) else { return false }
        let now = Date()
        if let handledAt = completionFailures[id], handledAt > now.addingTimeInterval(-Self.failureRetention) {
            return false
        }
        completionFailures[id] = now
        persistCompletionFailures(at: now)
        return true
    }

    private func persistCompletionFailures(at now: Date) {
        let retained = completionFailures
            .filter { $0.value > now.addingTimeInterval(-Self.failureRetention) }
            .sorted { $0.value < $1.value }
            .suffix(Self.failureCapacity)
        completionFailures = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        failureDefaults.set(retained.map { ["id": $0.key, "handledAt": $0.value] }, forKey: Self.failureHistoryKey)
    }

    private func persistOverlay() {
        try? store.save(overlay: overlay)
    }

    func apply(_ decoded: WatchSnapshot) {
        for receipt in decoded.receipts ?? [] {
            resolve(id: receipt.id, result: receipt.result, refusalReason: receipt.refusalReason)
        }
        overlay.reconcile(with: decoded)
        if decoded.receipts == nil {
            // A legacy peer has no identity protocol. Release IDs whose old overlay was reconciled.
            overlay.pendingOperations?.removeAll { operation in
                switch operation.edit {
                case .complete(let uid): return !overlay.pendingCompletes.contains(uid)
                case .uncomplete(let uid): return !overlay.pendingUncompletes.contains(uid)
                case .add: return !overlay.pendingAdds.contains { $0.id == operation.id }
                }
            }
        }
        snapshot = decoded
        reconcileProDeadline()
        try? store.save(decoded)
        try? store.save(overlay: overlay)
        requestPendingReceipts()
    }

    deinit { deadlineTask?.cancel() }
}

private extension WatchEdit {
    var taskUID: String? {
        switch self { case .complete(let uid), .uncomplete(let uid): uid; case .add: nil }
    }
}
