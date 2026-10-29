import UIKit
import os

/// Acquire synchronously in the scene callback, before creating protected async work.
@MainActor
final class ReminderBackgroundAssertion {
    typealias Begin = (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    private let logger = Logger(subsystem: "com.nowthis", category: "reminder-background-assertion")
    let budget: BackgroundRunBudget
    private let begin: Begin
    private let end: (UIBackgroundTaskIdentifier) -> Void
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private var started = false
    private var installing = false
    private var expired = false
    private var finished = false
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private let result = BackgroundRunResult()

    init(budget: BackgroundRunBudget = BackgroundRunBudget(), begin: @escaping Begin = {
        UIApplication.shared.beginBackgroundTask(withName: "reconcile-notifications", expirationHandler: $0)
    }, end: @escaping (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }) {
        self.budget = budget; self.begin = begin; self.end = end
    }
    @discardableResult
    func start(operation: @escaping @MainActor () async -> Void) -> Task<Bool, Never> {
        guard !started else { return Task { await result.value() } }
        started = true
        installing = true
        identifier = begin { [weak self] in self?.expire() }
        installing = false
        if identifier == .invalid || expired {
            logger.notice("Assertion unavailable run=\(self.budget.runID.uuidString, privacy: .public)")
            expire()
        } else {
            worker = Task { [self] in
                await BackgroundRunBudget.$current.withValue(budget) {
                    guard (try? budget.checkFinalAdmission()) != nil else { finish(false); return }
                    await operation()
                    finish(!expired && !Task.isCancelled)
                }
            }
            timer = Task { [self] in
                do { try await Task.sleep(until: budget.finalCutoff, clock: .continuous) }
                catch { return }
                expire()
            }
        }
        return Task { await result.value() }
    }
    func run(operation: @escaping @MainActor () async -> Void) async -> Bool {
        let run = start(operation: operation)
        return await withTaskCancellationHandler { await run.value } onCancel: {
            Task { @MainActor in self.expire() }
        }
    }
    private func expire() {
        expired = true
        budget.expire()
        worker?.cancel(); timer?.cancel()
        guard !installing else { return }
        if !budget.hasActiveCriticalSection {
            finish(false)
        } else {
            budget.whenDrained { [self] in Task { @MainActor in self.finish(false) } }
        }
    }
    private func finish(_ success: Bool) {
        guard !finished else { return }
        if budget.hasActiveCriticalSection {
            budget.whenDrained { [self] in Task { @MainActor in self.finish(success) } }
            return
        }
        finished = true
        timer?.cancel(); timer = nil; worker = nil
        if identifier != .invalid {
            let completed = identifier; identifier = .invalid
            end(completed)
        }
        // The MainActor timer may still be queued behind the just-finished SQL batch.
        // Validate the monotonic deadline here as well, before reporting success.
        let completed = success && !expired && (try? budget.checkFinalAdmission()) != nil
        logger.info("Assertion ended run=\(self.budget.runID.uuidString, privacy: .public) success=\(completed)")
        result.resolve(completed)
    }
}
