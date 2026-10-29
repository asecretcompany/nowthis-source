import Testing
import Foundation

@testable import NowThis

@Suite("BackgroundSyncManager")
struct BackgroundSyncManagerTests {

    @Test("Task identifier matches expected bundle-scoped value")
    func taskIdentifierIsCorrect() {
        #expect(
            BackgroundSyncManager.taskIdentifier == "com.asecretcompany.nowthis.sync.refresh",
            "Task identifier must match Info.plist BGTaskSchedulerPermittedIdentifiers"
        )
    }

    @Test("Minimum interval is 15 minutes (iOS minimum)")
    func minimumIntervalIs15Minutes() {
        #expect(BackgroundSyncManager.minimumInterval == 900)
    }

    @Test("scheduleBackgroundSync submits a BGAppRefreshTaskRequest")
    func scheduleSubmitsRequest() {
        let manager = BackgroundSyncManager()
        #expect(manager.didSchedule == false, "Should not be scheduled before first call")

        manager.scheduleBackgroundSync()

        // didSchedule tracks the scheduling attempt, not OS acceptance.
        // BGTaskScheduler.submit() throws in the simulator/test host because
        // the task identifier isn't registered in the test host's entitlements —
        // this is expected and the error is captured in lastSchedulingError.
        #expect(manager.didSchedule == true, "scheduleBackgroundSync must attempt to submit a task request")
    }
}

@Suite("Background sync notification flush")
struct BackgroundSyncNotificationFlushTests {
    private enum Failure: Error { case partial }

    @Test func servicesLocalWorkBeforePullAndFlushesCommittedProgressAfterFailure() async {
        let events = BackgroundRunEvents()
        let result = await BackgroundSyncManager.performRun(operation: {
            await events.record("pull")
            throw Failure.partial
        }, flush: { await events.record("flush") })
        #expect(!result)
        #expect(await events.values == ["flush", "pull", "flush"])
    }

    @Test func expirationSkipsFreshFlush() async {
        let events = BackgroundRunEvents()
        let budget = BackgroundRunBudget()
        let result = await BackgroundSyncManager.performRun(budget: budget, operation: {
            await events.record("pull")
            budget.expire()
            throw CancellationError()
        }, flush: { await events.record("flush") })
        #expect(!result)
        #expect(await events.values == ["flush", "pull"])
    }

    @Test func remoteCutoffPreservesLocalFlushAllowance() async {
        let start = ContinuousClock().now
        let budget = BackgroundRunBudget(startedAt: start, now: { start + .seconds(16) })
        let events = BackgroundRunEvents()
        let result = await BackgroundSyncManager.performRun(budget: budget, operation: {
            await events.record("pull")
            return true
        }, flush: { await events.record("flush") })
        #expect(!result)
        #expect(await events.values == ["flush"])
    }
}

private actor BackgroundRunEvents {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
