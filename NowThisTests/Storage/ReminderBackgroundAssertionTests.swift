import Foundation
import Testing
import UIKit
@testable import NowThis

@Suite("Reminder background assertion")
@MainActor
struct ReminderBackgroundAssertionTests {
    @Test func deniedAssertionStartsNoWork() async {
        var operations = 0
        var ends = 0
        let assertion = ReminderBackgroundAssertion(begin: { _ in .invalid }, end: { _ in ends += 1 })
        let result = await assertion.run { operations += 1 }
        #expect(!result)
        #expect(operations == 0)
        #expect(ends == 0)
    }

    @Test func startAcquiresAssertionSynchronously() async {
        var begins = 0
        var ends = 0
        let assertion = ReminderBackgroundAssertion(begin: { _ in
            begins += 1; return UIBackgroundTaskIdentifier(rawValue: 42)
        }, end: { _ in ends += 1 })
        let run = assertion.start {}
        #expect(begins == 1)
        #expect(await run.value)
        #expect(ends == 1)
    }

    @Test func expirationWaitsForActiveProtectedBatchToDrain() async {
        let gate = DeliveryGate()
        var expiration: (@MainActor @Sendable () -> Void)?
        var ends = 0
        let assertion = ReminderBackgroundAssertion(begin: {
            expiration = $0; return UIBackgroundTaskIdentifier(rawValue: 42)
        }, end: { _ in ends += 1 })
        let run = assertion.start {
            let section = try? BackgroundRunBudget.current?.beginCriticalSection()
            defer { section?.end() }
            await gate.block()
        }
        await gate.waitForEntry()
        expiration?()
        #expect(ends == 0)
        await gate.release()
        #expect(await run.value == false)
        expiration?()
        #expect(ends == 1)
    }

    @Test func expirationDoesNotWaitForUncooperativeAsyncCallback() async {
        let gate = DeliveryGate()
        var expiration: (@MainActor @Sendable () -> Void)?
        var ends = 0
        var lateWork = 0
        let assertion = ReminderBackgroundAssertion(begin: {
            expiration = $0; return UIBackgroundTaskIdentifier(rawValue: 42)
        }, end: { _ in ends += 1 })
        let run = assertion.start {
            await gate.block()
            do { try BackgroundRunBudget.current?.withCriticalSection { lateWork += 1 } } catch {}
            await gate.markFinished()
        }
        await gate.waitForEntry()
        expiration?()
        #expect(ends == 1)
        await gate.release()
        #expect(await run.value == false)
        await gate.waitForFinish()
        #expect(lateWork == 0)
        #expect(ends == 1)
    }

    @Test func finalCutoffDuringSynchronousBatchCannotReportSuccess() async {
        let clock = AssertionTestClock()
        let budget = BackgroundRunBudget(startedAt: clock.now, now: { clock.now })
        var ends = 0
        let assertion = ReminderBackgroundAssertion(budget: budget, begin: { _ in
            UIBackgroundTaskIdentifier(rawValue: 42)
        }, end: { _ in ends += 1 })
        let result = await assertion.run {
            try! budget.withCriticalSection {
                // Synchronous MainActor SQL can hold the executor beyond the cutoff;
                // its queued timer cannot run before the worker returns from this batch.
                clock.advance(by: .seconds(21))
            }
        }
        #expect(result == false)
        #expect(ends == 1)
    }

    @Test func expirationDuringBeginStartsNoWorkAndEndsOnce() async {
        var ends = 0
        var operations = 0
        let assertion = ReminderBackgroundAssertion(begin: {
            $0(); return UIBackgroundTaskIdentifier(rawValue: 42)
        }, end: { _ in ends += 1 })
        #expect(await assertion.run { operations += 1 } == false)
        #expect(operations == 0)
        #expect(ends == 1)
    }
}

private final class AssertionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(by duration: Duration) { lock.withLock { instant += duration } }
}
