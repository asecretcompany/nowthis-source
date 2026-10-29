import Foundation
import os

/// Owns installation, cancellation, and exactly-once completion of one BG delivery.
/// The worker may outlive an uncooperative async callback; its expired budget prevents
/// it from entering any new protected SQL section when that callback eventually returns.
final class BackgroundDeliveryCoordinator: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.nowthis", category: "background-delivery")
    let budget: BackgroundRunBudget
    private let resubmit: @Sendable () -> Void
    private let lock = NSLock()
    private var started = false
    private var expired = false
    private var finished = false
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var completion: (@Sendable (Bool) -> Void)?
    private let result = BackgroundRunResult()

    init(budget: BackgroundRunBudget = BackgroundRunBudget(), resubmit: @escaping @Sendable () -> Void = {}) {
        self.budget = budget; self.resubmit = resubmit
    }
    @discardableResult
    func start(operation: @escaping @Sendable (BackgroundRunBudget) async -> Bool,
               completion: @escaping @Sendable (Bool) -> Void) -> Task<Void, Never> {
        let install = lock.withLock {
            guard !started else { return false }
            started = true; self.completion = completion
            return true
        }
        if install {
            // Replace the delivery even when the store is unavailable or already expired.
            resubmit()
            logger.info("Delivery started run=\(self.budget.runID.uuidString, privacy: .public)")
            let worker = Task.detached { [self] in
                await BackgroundRunBudget.$current.withValue(budget) {
                    do { try budget.checkFinalAdmission() } catch { finish(false); return }
                    let success = await operation(budget)
                    budget.whenDrained { self.finish(success) }
                }
            }
            let timer = Task.detached { [self] in
                do { try await Task.sleep(until: budget.finalCutoff, clock: .continuous) }
                catch { return }
                expire()
            }
            let cancel = lock.withLock {
                if finished || expired { return true }
                self.worker = worker; self.timer = timer
                return false
            }
            if cancel { worker.cancel(); timer.cancel(); expire() }
        }
        return Task { _ = await result.value() }
    }
    func expire() {
        budget.expire()
        let tasks = lock.withLock {
            expired = true
            return (worker, timer)
        }
        tasks.0?.cancel(); tasks.1?.cancel()
        budget.whenDrained { self.finish(false) }
    }
    private func finish(_ success: Bool) {
        let accepted = (try? budget.checkFinalAdmission()) != nil
        let state: ((@Sendable (Bool) -> Void), Bool, Task<Void, Never>?)? = lock.withLock {
            guard !finished, let completion else { return nil }
            finished = true
            let value = success && accepted && !expired
            let timer = timer
            self.completion = nil; self.worker = nil; self.timer = nil
            return (completion, value, timer)
        }
        guard let state else { return }
        state.2?.cancel()
        logger.info("Delivery completed run=\(self.budget.runID.uuidString, privacy: .public) success=\(state.1)")
        state.0(state.1)
        result.resolve(state.1)
    }
}

/// A one-shot result independent of the canceled worker's asynchronous lifetime.
final class BackgroundRunResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    func value() async -> Bool {
        await withCheckedContinuation { continuation in
            let ready: Bool? = lock.withLock {
                if let result { return result }
                waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
    func resolve(_ value: Bool) {
        let ready: [CheckedContinuation<Bool, Never>] = lock.withLock {
            guard result == nil else { return [] }
            result = value
            let ready = waiters; waiters.removeAll()
            return ready
        }
        ready.forEach { $0.resume(returning: value) }
    }
}
