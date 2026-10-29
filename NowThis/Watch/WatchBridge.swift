import Combine
import Foundation
import SwiftData
import WatchConnectivity
import os

@MainActor
protocol WatchSessionProtocol: AnyObject {
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    func updateApplicationContext(_ context: [String: Any]) throws
}
extension WCSession: WatchSessionProtocol {}

/// iOS side of the phone-mirror: pushes WatchSnapshots down, applies WatchEdits up.
@MainActor
final class WatchBridge: NSObject, ObservableObject {
    private let session: WatchSessionProtocol?
    private let entitlement: ProEntitlement
    private let syncScheduler: SyncScheduler
    private let modelContainer: ModelContainer
    private let snapshotWorker: WatchSnapshotWorker
    private lazy var snapshotJobs = makeSnapshotJobs()

    private func makeSnapshotJobs() -> WatchSnapshotJobQueue<WatchSnapshotBuildRequest, WatchEncodedSnapshot?> {
        let worker = snapshotWorker
        return WatchSnapshotJobQueue(
            build: { request in await worker.makeSnapshot(for: request) },
            apply: { [weak self] _, payload in self?.applySnapshot(payload) }
        )
    }
    private var cancellables = Set<AnyCancellable>()
    private var activated = false
    private var accessTask: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.asecretcompany.nowthis", category: "WatchBridge")

    init(session: WatchSessionProtocol? = WCSession.isSupported() ? WCSession.default : nil,
         entitlement: ProEntitlement, syncScheduler: SyncScheduler, modelContainer: ModelContainer) {
        self.session = session
        self.entitlement = entitlement
        self.syncScheduler = syncScheduler
        self.modelContainer = modelContainer
        self.snapshotWorker = WatchSnapshotWorker(modelContainer: modelContainer)
        super.init()
    }

    /// Whether a paired Apple Watch has the NowThis watch app installed —
    /// drives the Settings paywall's contextual "you have a watch" upsell.
    var isWatchPairedAndInstalled: Bool {
        guard let session else { return false }
        return session.isPaired && session.isWatchAppInstalled
    }

    func activate() {
        guard !activated else { return }
        activated = true
        (session as? WCSession)?.delegate = self
        (session as? WCSession)?.activate()
        syncScheduler.$dataRefreshToken
            .dropFirst()
            .sink { [weak self] _ in self?.handleDataRefresh() }
            .store(in: &cancellables)
        let changes = entitlement.accessChanges()
        accessTask = Task { [weak self] in
            for await _ in changes { self?.pushSnapshot() }
        }
    }

    func handleDataRefresh() { pushSnapshot() }   // internal for tests

    func pushSnapshot() {
        // Preserve the cheap eligibility guard: disconnected/unpaired sessions do no work.
        guard let session, session.isPaired, session.isWatchAppInstalled else { return }

        let now = Date()
        let access = entitlement.snapshot
        let request = WatchSnapshotBuildRequest(
            isProUnlocked: access.isUnlocked(at: now),
            savedDefaultListID: TaskDefaultsPreferences.defaultListID,
            now: now,
            calendar: .current,
            proAccessValidUntil: access.validUntil,
            testerProOverride: entitlement.testerUnlocked ? true : nil,
            overlay: WatchSnapshotPendingOverlay.capture(from: modelContainer.mainContext)
        )
        snapshotJobs.submit(request)
    }

    @MainActor
    private func applySnapshot(_ payload: WatchEncodedSnapshot?) {
        guard let payload,
              let session,
              session.isPaired,
              session.isWatchAppInstalled else { return }
        do { try session.updateApplicationContext(payload.contextDictionary) }
        catch { Self.log.error("Snapshot push failed: \(error)") }
    }

    private func handle(edit: WatchEdit) -> String {
        let outcome = WatchEditApplier.apply(edit, modelContext: modelContainer.mainContext,
                                             isProUnlocked: entitlement.isUnlocked)
        pushSnapshot()
        switch outcome {
        case .applied: return WatchEditReply.applied
        case .rejectedLocked: return WatchEditReply.locked
        case .unknownTask, .invalid: return WatchEditReply.unknownTask
        }
    }

    deinit { accessTask?.cancel() }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.pushSnapshot() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard let edit = WatchEdit(userInfoDictionary: message) else {
            replyHandler([WatchEditReply.key: WatchEditReply.unknownTask]); return
        }
        // `replyHandler` is a plain (non-`@Sendable`) closure, so it can't be
        // captured directly by the `@Sendable` closure `Task { @MainActor in }`
        // requires — box it in an `@unchecked Sendable` wrapper. Safe: the box
        // is only ever invoked once, from the single `Task` below.
        let box = ReplyBox(handler: replyHandler)
        Task { @MainActor in box.handler([WatchEditReply.key: self.handle(edit: edit)]) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let edit = WatchEdit(userInfoDictionary: userInfo) else { return }
        Task { @MainActor in _ = self.handle(edit: edit) }
    }
}

/// Wraps a non-`@Sendable` reply closure so it can cross into a `@Sendable`
/// `Task` closure. `@unchecked` because `WCSessionDelegate`'s `replyHandler`
/// isn't annotated `@Sendable` even though WatchConnectivity only ever calls
/// it once, from wherever the delegate callback fired.
private struct ReplyBox: @unchecked Sendable {
    let handler: ([String: Any]) -> Void
}
