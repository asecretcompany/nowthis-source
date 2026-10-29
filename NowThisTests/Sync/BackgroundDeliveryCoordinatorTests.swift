import Foundation
import Testing
@testable import NowThis

@Suite("Background delivery lifetime")
struct BackgroundDeliveryCoordinatorTests {
    @Test func oneBudgetReservesTimeForFlush() throws {
        let start = ContinuousClock().now
        let budget = BackgroundRunBudget(startedAt: start, now: { start + .seconds(16) })
        #expect(budget.remoteCutoff - start == .seconds(15))
        #expect(budget.finalCutoff - start == .seconds(20))
        #expect(budget.remainingRemoteTime == .zero)
        #expect(budget.remainingFinalTime == .seconds(4))
        #expect(throws: (any Error).self) { try budget.checkRemoteAdmission() }
        try budget.checkFinalAdmission()
        budget.expire()
        #expect(throws: (any Error).self) { try budget.checkFinalAdmission() }
    }

    @Test func noStoreDeliveryStillResubmits() async {
        let recorder = DeliveryRecorder()
        let delivery = BackgroundDeliveryCoordinator(resubmit: { recorder.submit() })
        await delivery.start(operation: { _ in
            #expect(recorder.submissions == 1)
            return false // Store unavailable: do not begin any SQLite work.
        }, completion: { recorder.complete($0) }).value
        #expect(recorder.submissions == 1)
        #expect(recorder.completions == [false])
    }

    @Test func expirationBeforeWorkerInstallation() async {
        let recorder = DeliveryRecorder()
        let delivery = BackgroundDeliveryCoordinator()
        delivery.expire()
        await delivery.start(operation: { _ in recorder.work(); return true },
                             completion: { recorder.complete($0) }).value
        #expect(recorder.operations == 0)
        #expect(recorder.completions == [false])
    }

    @Test func expirationDuringFlushSkipsFurtherWork() async {
        let gate = DeliveryGate()
        let recorder = DeliveryRecorder()
        let delivery = BackgroundDeliveryCoordinator()
        let run = delivery.start(operation: { budget in
            await gate.block()
            do { try budget.checkFinalAdmission() } catch { return false }
            recorder.work()
            return true
        }, completion: { recorder.complete($0) })
        await gate.waitForEntry()
        delivery.expire()
        await gate.release()
        await run.value
        #expect(recorder.operations == 0)
        #expect(recorder.completions == [false])
    }

    @Test func expirationWaitsForActiveProtectedBatchToDrain() async {
        let gate = DeliveryGate()
        let recorder = DeliveryRecorder()
        let delivery = BackgroundDeliveryCoordinator()
        let run = delivery.start(operation: { budget in
            let section = try! budget.beginCriticalSection()
            defer { section.end() }
            // A noncooperative bounded SQL section has already entered. Its owner
            // cannot declare completion until that section returns.
            await gate.block()
            return true
        }, completion: { recorder.complete($0) })
        await gate.waitForEntry()
        delivery.expire()
        #expect(recorder.completions.isEmpty)
        await gate.release()
        await run.value
        #expect(recorder.completions == [false])
    }

    @Test func expirationDoesNotWaitForUncooperativeAsyncCallback() async {
        let gate = DeliveryGate()
        let recorder = DeliveryRecorder()
        let delivery = BackgroundDeliveryCoordinator()
        let run = delivery.start(operation: { budget in
            await gate.block()
            do { try budget.withCriticalSection { recorder.work() } } catch {}
            await gate.markFinished()
            return true
        }, completion: { recorder.complete($0) })
        await gate.waitForEntry()
        delivery.expire()
        #expect(recorder.completions == [false])
        await gate.release()
        await run.value
        await gate.waitForFinish()
        #expect(recorder.operations == 0)
        #expect(recorder.completions == [false])
    }

    @Test func normalCompletionRacingExpirationCompletesOnce() async {
        let recorder = DeliveryRecorder()
        let delivery = BackgroundDeliveryCoordinator()
        let run = delivery.start(operation: { _ in true }, completion: { recorder.complete($0) })
        async let expire: Void = Task.detached { delivery.expire() }.value
        await run.value
        await expire
        delivery.expire()
        #expect(recorder.completions.count == 1)
    }
}

private final class DeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var submitted = 0
    private var worked = 0
    private var completed: [Bool] = []
    var submissions: Int { lock.withLock { submitted } }
    var operations: Int { lock.withLock { worked } }
    var completions: [Bool] { lock.withLock { completed } }
    func submit() { lock.withLock { submitted += 1 } }
    func work() { lock.withLock { worked += 1 } }
    func complete(_ value: Bool) { lock.withLock { completed.append(value) } }
}

actor DeliveryGate {
    private var entered = false
    private var finished = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func block() async {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func markFinished() {
        finished = true
        finishWaiters.forEach { $0.resume() }; finishWaiters.removeAll()
    }
    func waitForFinish() async {
        if finished { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }
}
