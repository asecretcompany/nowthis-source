import Foundation
import Observation
import WatchConnectivity
import WidgetKit

/// Minimal abstraction over the `WCSession` calls `PhoneBridge` needs, so a fake
/// session can be injected (see the Task 7 `WatchSessionProtocol`/`SpySession`
/// precedent in `NowThis/Watch/WatchBridge.swift`) to exercise the reply/rollback
/// logic without a live WatchConnectivity session.
@MainActor
protocol PhoneSessionProtocol: WatchEditTransport {
    var activationState: WCSessionActivationState { get }
    func activate(delegate: WCSessionDelegate)
}

/// Adapter over `WCSession.default`. Kept separate from `PhoneSessionProtocol`
/// (rather than an `extension WCSession: PhoneSessionProtocol {}`) because
/// `WCSession.sendMessage`/`transferUserInfo` have default parameters and a
/// discardable return value that a fake session couldn't reproduce exactly.
final class LivePhoneSession: PhoneSessionProtocol {
    private let session: WCSession
    init(_ session: WCSession = .default) { self.session = session }

    var isReachable: Bool { session.isReachable }
    var outstandingOperationIDs: Set<UUID> {
        Set(session.outstandingUserInfoTransfers.compactMap {
            ($0.userInfo[WatchEdit.operationIDKey] as? String).flatMap(UUID.init(uuidString:))
        })
    }
    var activationState: WCSessionActivationState { session.activationState }
    var isActivated: Bool { activationState == .activated }

    func activate(delegate: WCSessionDelegate) {
        session.delegate = delegate
        session.activate()
    }

    func sendMessage(_ message: [String: Any], replyHandler: @escaping @Sendable ([String: Any]) -> Void,
                     errorHandler: @escaping @Sendable () -> Void) {
        session.sendMessage(message, replyHandler: replyHandler, errorHandler: { _ in errorHandler() })
    }

    func transferUserInfo(_ userInfo: [String: Any]) {
        session.transferUserInfo(userInfo)
    }
}

/// WCSession and widget adapter; all delivery and optimistic state is shared with iOS tests.
@MainActor
@Observable
final class PhoneBridge: NSObject, WCSessionDelegate {
    static let shared = PhoneBridge()
    let delivery: WatchDeliveryEngine
    private let session: PhoneSessionProtocol
    var snapshot: WatchSnapshot? { delivery.snapshot }
    var displayTasks: [WatchTask] { delivery.displayTasks }
    var isProUnlocked: Bool { delivery.isProUnlocked }
    var showingUnsupportedRecurrence: Bool {
        get { delivery.showingUnsupportedRecurrence }
        set { delivery.showingUnsupportedRecurrence = newValue }
    }

    init(session: PhoneSessionProtocol = LivePhoneSession(), store: WatchSnapshotStore = WatchSnapshotStore()) {
        self.session = session
        delivery = WatchDeliveryEngine(session: session, store: store)
        super.init()
    }
    func reconcileProDeadline() { delivery.reconcileProDeadline() }
    func activate() {
        session.activate(delegate: self)
        delivery.reconcileProDeadline()
        delivery.requestPendingReceipts()
    }
    func complete(uid: String) { delivery.complete(uid: uid) }
    func uncomplete(uid: String) { delivery.uncomplete(uid: uid) }
    @discardableResult
    func add(rawText: String, listID: String?, dueDate: Date? = nil, priorityRaw: Int? = nil) -> Bool {
        delivery.add(rawText: rawText, listID: listID, dueDate: dueDate, priorityRaw: priorityRaw)
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in delivery.requestPendingReceipts() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in delivery.requestPendingReceipts() }
    }
    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        guard let rawID = userInfoTransfer.userInfo[WatchEdit.operationIDKey] as? String,
              let id = UUID(uuidString: rawID) else { return }
        let failed = error != nil
        Task { @MainActor in delivery.transferFinished(operationID: id, failed: failed) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let decoded = WatchSnapshot(contextDictionary: applicationContext) else { return }
        let failureID = applicationContext[WatchEditReply.completionFailureIDKey] as? String
        let failureUID = applicationContext[WatchEditReply.completionFailureUIDKey] as? String
        Task { @MainActor in
            delivery.apply(decoded)
            delivery.handleCompletionFailure(id: failureID, uid: failureUID)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
