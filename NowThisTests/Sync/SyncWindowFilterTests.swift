import Testing
import Foundation

@testable import NowThis

@Suite("SyncEngine Completed Task Window Filter")
struct SyncWindowFilterTests {

    // MARK: - Helpers

    /// Creates a fake RemoteTask with a COMPLETED timestamp.
    private func makeCompletedTask(
        completedDate: Date,
        uid: String = UUID().uuidString
    ) -> CalDAVClient.RemoteTask {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let completedString = formatter.string(from: completedDate)

        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:\(uid)
        SUMMARY:Test Task
        STATUS:COMPLETED
        COMPLETED:\(completedString)
        END:VTODO
        END:VCALENDAR
        """
        return CalDAVClient.RemoteTask(href: "/\(uid).ics", etag: "etag", icsData: ics)
    }

    /// Creates a fake RemoteTask with no COMPLETED date (active task).
    private func makeActiveTask(uid: String = UUID().uuidString) -> CalDAVClient.RemoteTask {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:\(uid)
        SUMMARY:Active Task
        STATUS:NEEDS-ACTION
        END:VTODO
        END:VCALENDAR
        """
        return CalDAVClient.RemoteTask(href: "/\(uid).ics", etag: "etag", icsData: ics)
    }

    // MARK: - Tests

    @Test("Window of 0 (All) keeps everything")
    func windowZeroKeepsAll() {
        let oldTask = makeCompletedTask(
            completedDate: Calendar.current.date(byAdding: .year, value: -5, to: Date())!
        )
        let recentTask = makeCompletedTask(
            completedDate: Date()
        )

        let result = SyncEngine.filterCompletedByWindow([oldTask, recentTask], months: 0)

        #expect(result.count == 2, "Window of 0 should keep all completed tasks")
    }

    @Test("Completed task within window is kept")
    func completedWithinWindowIsKept() {
        // Completed 1 month ago, window is 3 months
        let task = makeCompletedTask(
            completedDate: Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        )

        let result = SyncEngine.filterCompletedByWindow([task], months: 3)

        #expect(result.count == 1, "Task completed 1 month ago should be kept with 3-month window")
    }

    @Test("Completed task outside window is filtered out")
    func completedOutsideWindowIsFiltered() {
        // Completed 6 months ago, window is 3 months
        let task = makeCompletedTask(
            completedDate: Calendar.current.date(byAdding: .month, value: -6, to: Date())!
        )

        let result = SyncEngine.filterCompletedByWindow([task], months: 3)

        #expect(result.count == 0, "Task completed 6 months ago should be filtered with 3-month window")
    }

    @Test("Task without COMPLETED date is kept (defensive)")
    func taskWithoutCompletedDateIsKept() {
        // A task marked STATUS:COMPLETED but missing the COMPLETED timestamp
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:no-date
        SUMMARY:No Date Task
        STATUS:COMPLETED
        END:VTODO
        END:VCALENDAR
        """
        let task = CalDAVClient.RemoteTask(href: "/no-date.ics", etag: "etag", icsData: ics)

        let result = SyncEngine.filterCompletedByWindow([task], months: 3)

        #expect(result.count == 1, "Task without COMPLETED date should be kept (can't determine age)")
    }

    @Test("Boundary: task completed exactly at cutoff is kept")
    func boundaryTaskIsKept() {
        // Truncate to whole seconds since ICS format is second-precision
        let now = Date(timeIntervalSinceReferenceDate: floor(Date.timeIntervalSinceReferenceDate))
        let exactCutoff = Calendar.current.date(byAdding: .month, value: -3, to: now)!
        let task = makeCompletedTask(completedDate: exactCutoff)

        let result = SyncEngine.filterCompletedByWindow([task], months: 3, now: now)

        #expect(result.count == 1, "Task at exact boundary should be kept (inclusive)")
    }
}
