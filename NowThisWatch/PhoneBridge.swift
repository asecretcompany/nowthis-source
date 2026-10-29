import Foundation
import Observation
import WatchConnectivity
import WidgetKit

/// Minimal abstraction over the `WCSession` calls `PhoneBridge` needs, so a fake
/// session can be injected (see the Task 7 `WatchSessionProtocol`/`SpySession`
/// precedent in `NowThis/Watch/WatchBridge.swift`) to exercise the reply/rollback
/// logic without a live WatchConnectivity session.
@MainActor
protocol PhoneSessionProtocol: AnyObject {
    var isReachable: Bool { get }
    func activate(delegate: WCSessionDelegate)
    func sendMessage(_ message: [String: Any], replyHandler: @escaping @Sendable ([String: Any]) -> Void)
    func transferUserInfo(_ userInfo: [String: Any])
}

/// Adapter over `WCSession.default`. Kept separate from `PhoneSessionProtocol`
/// (rather than an `extension WCSession: PhoneSessionProtocol {}`) because
/// `WCSession.sendMessage`/`transferUserInfo` have default parameters and a
/// discardable return value that a fake session couldn't reproduce exactly.
final class LivePhoneSession: PhoneSessionProtocol {
    private let session: WCSession
    init(_ session: WCSession = .default) { self.session = session }

    var isReachable: Bool { session.isReachable }

    func activate(delegate: WCSessionDelegate) {
        session.delegate = delegate
        session.activate()
    }

    func sendMessage(_ message: [String: Any], replyHandler: @escaping @Sendable ([String: Any]) -> Void) {
        session.sendMessage(message, replyHandler: replyHandler, errorHandler: nil)
    }

    func transferUserInfo(_ userInfo: [String: Any]) {
        session.transferUserInfo(userInfo)
    }
}

/// Watch side of the phone-mirror. The iPhone stays the only CalDAV client:
/// this class only receives `WatchSnapshot`s pushed down via
/// `updateApplicationContext` and relays `WatchEdit`s back up, layering
/// optimistic `WatchOverlayState` edits on top of the last snapshot so the UI
/// reacts instantly while the round-trip to the phone is in flight.
@MainActor
@Observable
final class PhoneBridge: NSObject, WCSessionDelegate {
    static let shared = PhoneBridge()

    private(set) var snapshot: WatchSnapshot?
    private(set) var overlay: WatchOverlayState
    /// Set whenever a `WatchEdit` comes back `locked` from the phone, so a
    /// future view can react to a server-confirmed lock (not consumed by
    /// Task 9's views, which gate optimistically on `isProUnlocked` instead).
    private(set) var lastLockedPrompt: Date?
    private var accessRevision = 0
    @ObservationIgnored nonisolated(unsafe) private var deadlineTask: Task<Void, Never>?

    private let session: PhoneSessionProtocol
    private let store: WatchSnapshotStore

    init(session: PhoneSessionProtocol = LivePhoneSession(), store: WatchSnapshotStore = WatchSnapshotStore()) {
        self.session = session
        self.store = store
        self.snapshot = store.load()
        self.overlay = store.loadOverlay()
        super.init()
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

    func activate() {
        session.activate(delegate: self)
        reconcileProDeadline()
    }

    func complete(uid: String) {
        guard isProUnlocked else { lastLockedPrompt = Date(); return }
        overlay.noteComplete(uid: uid)
        persistOverlay()
        send(.complete(uid: uid))
    }

    func uncomplete(uid: String) {
        guard isProUnlocked else { lastLockedPrompt = Date(); return }
        overlay.noteUncomplete(uid: uid)
        persistOverlay()
        send(.uncomplete(uid: uid))
    }

    func add(rawText: String, listID: String?, dueDate: Date? = nil, priorityRaw: Int? = nil) {
        guard isProUnlocked else { lastLockedPrompt = Date(); return }
        let pending = WatchPendingAdd(id: UUID(), rawText: rawText, createdAt: Date())
        overlay.noteAdd(pending)
        persistOverlay()
        send(.add(rawText: rawText, listID: listID, dueDate: dueDate, priorityRaw: priorityRaw),
             pendingAddID: pending.id)
    }

    private func send(_ edit: WatchEdit, pendingAddID: UUID? = nil) {
        guard let payload = try? edit.userInfoDictionary() else {
            // Encoding this String-only edit essentially cannot fail, but if it
            // ever did, the optimistic note was already applied + persisted above:
            // undo it so the UI doesn't stay stuck on an edit that never went out.
            undoOptimisticNote(for: edit, pendingAddID: pendingAddID)
            return
        }
        if session.isReachable {
            session.sendMessage(payload) { [weak self] reply in
                // Extract the Sendable result string from the non-Sendable
                // `[String: Any]` reply BEFORE hopping actors — capturing `reply`
                // itself into the `Task { @MainActor in }` closure risks a data
                // race (mirrors why WatchBridge decodes its payload before hopping).
                let result = reply[WatchEditReply.key] as? String
                Task { @MainActor in
                    guard let self else { return }
                    if result == WatchEditReply.locked {
                        self.rollback(edit, pendingAddID: pendingAddID)
                    } else if result == WatchEditReply.applied {
                        self.confirmApplied(edit, pendingAddID: pendingAddID)
                    }
                }
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    /// Undoes the optimistic overlay note for an edit the phone rejected as
    /// `.locked`, persists the rolled-back overlay, and timestamps the prompt
    /// so a future view can surface `WatchLockedSheet` reactively.
    private func rollback(_ edit: WatchEdit, pendingAddID: UUID? = nil) {
        undoOptimisticNote(for: edit, pendingAddID: pendingAddID)
        lastLockedPrompt = Date()
    }

    /// The phone acknowledged an edit as `.applied`. For an optimistic `.add`,
    /// clear its pending row now — the phone stores the natural-language-parsed
    /// title, not the dictated `rawText`, so `WatchOverlayState.reconcile`'s
    /// title-equality path never matches a voice add and the synthetic row would
    /// otherwise linger until the 5s grace (unbounded until the next snapshot).
    /// Completes/uncompletes need no action here: `reconcile` clears those once
    /// the next snapshot reflects the persisted state.
    private func confirmApplied(_ edit: WatchEdit, pendingAddID: UUID?) {
        guard case .add = edit, let pendingAddID else { return }
        overlay.confirmAdd(id: pendingAddID)
        persistOverlay()
    }

    /// Reverts exactly the optimistic overlay note that `edit` produced, and
    /// persists the result. For `.add` the entry is identified by its
    /// `WatchPendingAdd.id` — never by `rawText`, which would collapse two
    /// distinct pending adds that happen to share the same text.
    private func undoOptimisticNote(for edit: WatchEdit, pendingAddID: UUID?) {
        switch edit {
        case .complete(let uid): overlay.pendingCompletes.remove(uid)
        case .uncomplete(let uid): overlay.pendingUncompletes.remove(uid)
        case .add:
            guard let pendingAddID else { break }
            overlay.pendingAdds.removeAll { $0.id == pendingAddID }
        }
        persistOverlay()
    }

    private func persistOverlay() {
        try? store.save(overlay: overlay)
    }

    private func apply(_ decoded: WatchSnapshot) {
        overlay.reconcile(with: decoded)
        snapshot = decoded
        reconcileProDeadline()
        try? store.save(decoded)
        try? store.save(overlay: overlay)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - WCSessionDelegate

    // The only WCSessionDelegate method required on watchOS. Delegate callbacks
    // are nonisolated and can fire off the main actor, so — mirroring
    // NowThis/Watch/WatchBridge.swift — the incoming payload is decoded to a
    // Sendable value type first, then a `Task { @MainActor in }` hop performs
    // all mutation/publish of PhoneBridge's @Observable state.
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let decoded = WatchSnapshot(contextDictionary: applicationContext) else { return }
        Task { @MainActor in
            self.apply(decoded)
        }
    }

    deinit { deadlineTask?.cancel() }
}
