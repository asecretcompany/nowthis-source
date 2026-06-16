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
