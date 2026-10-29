import Foundation

/// One monotonic allowance shared by every phase and account in a refresh delivery.
/// SQL admission and expiration share a lock: completion cannot race an admitted section.
final class BackgroundRunBudget: @unchecked Sendable {
    enum Phase: Sendable { case remote, final }
    @TaskLocal static var current: BackgroundRunBudget?
    @TaskLocal static var phase: Phase = .final
    let startedAt: ContinuousClock.Instant
    let runID: UUID
    private let now: @Sendable () -> ContinuousClock.Instant
    private let lock = NSLock()
    private var expired = false
    private var remoteStopped = false
    private var activeSections = 0
    private var drainWaiters: [@Sendable () -> Void] = []

    init(startedAt: ContinuousClock.Instant = ContinuousClock().now, runID: UUID = UUID(),
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        self.startedAt = startedAt; self.runID = runID; self.now = now
    }
    var remoteCutoff: ContinuousClock.Instant { startedAt + .seconds(15) }
    var finalCutoff: ContinuousClock.Instant { startedAt + .seconds(20) }
    var remainingRemoteTime: Duration { max(.zero, remoteCutoff - now()) }
    var remainingFinalTime: Duration { max(.zero, finalCutoff - now()) }
    var hasActiveCriticalSection: Bool { lock.withLock { activeSections > 0 } }

    func checkRemoteAdmission() throws {
        try lock.withLock {
            try checkFinalLocked()
            if remoteStopped || now() >= remoteCutoff { throw CancellationError() }
        }
    }
    func checkFinalAdmission() throws { try lock.withLock { try checkFinalLocked() } }
    private func checkFinalLocked() throws {
        if expired || Task.isCancelled || now() >= finalCutoff { throw CancellationError() }
    }
    func stopRemote() { lock.withLock { remoteStopped = true } }
    func expire() { lock.withLock { expired = true; remoteStopped = true } }

    func beginCriticalSection() throws -> CriticalSection {
        try lock.withLock {
            try checkFinalLocked()
            if Self.phase == .remote && (remoteStopped || now() >= remoteCutoff) { throw CancellationError() }
            activeSections += 1
        }
        return CriticalSection(budget: self)
    }
    func withCriticalSection<Value>(isolation: isolated (any Actor)? = #isolation,
                                    _ body: () throws -> Value) throws -> Value {
        let section = try beginCriticalSection()
        defer { section.end() }
        return try body()
    }
    static func protectingCurrent<Value>(isolation: isolated (any Actor)? = #isolation,
                                         _ body: () throws -> Value) throws -> Value {
        if let current { return try current.withCriticalSection(isolation: isolation, body) }
        try Task.checkCancellation()
        return try body()
    }
    /// Used only after admission is closed (expiration or remote cutoff), or after
    /// the worker has returned. Never wait for unrelated asynchronous callbacks.
    func whenDrained(_ action: @escaping @Sendable () -> Void) {
        let ready = lock.withLock {
            if activeSections == 0 { return true }
            drainWaiters.append(action)
            return false
        }
        if ready { action() }
    }
    private func endSection() {
        let callbacks: [@Sendable () -> Void] = lock.withLock {
            activeSections -= 1
            guard activeSections == 0 else { return [] }
            let callbacks = drainWaiters
            drainWaiters.removeAll()
            return callbacks
        }
        callbacks.forEach { $0() }
    }
    final class CriticalSection: @unchecked Sendable {
        private let lock = NSLock()
        private var budget: BackgroundRunBudget?
        fileprivate init(budget: BackgroundRunBudget) { self.budget = budget }
        func end() {
            let owner = lock.withLock { let owner = budget; budget = nil; return owner }
            owner?.endSection()
        }
        deinit { end() }
    }
}
