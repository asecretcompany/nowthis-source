import XCTest
@testable import NowThis

final class OverdueInTodayFilterTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a "now" of today at 3:00 PM local time.
    private var now: Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!
    }

    /// A due date that was 2 hours ago today (1:00 PM).
    private var overdueTodayDate: Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: 13, minute: 0, second: 0, of: Date())!
    }

    /// A due date later today (5:00 PM) — not yet overdue.
    private var dueLaterTodayDate: Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: 17, minute: 0, second: 0, of: Date())!
    }

    /// A due date yesterday at 2:00 PM — overdue from a previous day.
    private var overdueYesterdayDate: Date {
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        return cal.date(bySettingHour: 14, minute: 0, second: 0, of: yesterday)!
    }

    /// A due date 5 days ago — overdue from well before today.
    private var overdueFiveDaysAgoDate: Date {
        let cal = Calendar.current
        let past = cal.date(byAdding: .day, value: -5, to: Date())!
        return cal.date(bySettingHour: 10, minute: 0, second: 0, of: past)!
    }

    // MARK: - Tests

    /// A task that became overdue today should appear in Today.
    func testOverdueTodayTask_includedInToday() {
        let result = TaskListFilter.shouldIncludeInToday(
            dueDate: overdueTodayDate,
            isDueDateOnly: false,
            isCompleted: false,
            now: now
        )
        XCTAssertTrue(result, "Overdue-today task should be included in Today")
    }

    /// A task overdue from *yesterday* SHOULD appear in Today (new behavior).
    func testOverdueYesterdayTask_includedInToday() {
        let result = TaskListFilter.shouldIncludeInToday(
            dueDate: overdueYesterdayDate,
            isDueDateOnly: false,
            isCompleted: false,
            now: now
        )
        XCTAssertTrue(result, "Overdue-yesterday task should be included in Today")
    }

    /// A task overdue from 5 days ago SHOULD appear in Today.
    func testOverdueFiveDaysAgoTask_includedInToday() {
        let result = TaskListFilter.shouldIncludeInToday(
            dueDate: overdueFiveDaysAgoDate,
            isDueDateOnly: false,
            isCompleted: false,
            now: now
        )
        XCTAssertTrue(result, "Task overdue from 5 days ago should be included in Today")
    }

    /// A task not yet overdue and due later today should always be included.
    func testDueLaterToday_alwaysIncluded() {
        let result = TaskListFilter.shouldIncludeInToday(
            dueDate: dueLaterTodayDate,
            isDueDateOnly: false,
            isCompleted: false,
            now: now
        )
        XCTAssertTrue(result, "Task due later today should appear in Today")
    }

    /// Completed tasks never appear in Today.
    func testCompletedTask_alwaysExcluded() {
        let result = TaskListFilter.shouldIncludeInToday(
            dueDate: dueLaterTodayDate,
            isDueDateOnly: false,
            isCompleted: true,
            now: now
        )
        XCTAssertFalse(result, "Completed task should never appear in Today")
    }

    /// Date-only task from yesterday should appear in Today (new behavior).
    /// Date-only tasks become overdue at end-of-local-day. Once past midnight,
    /// the task is overdue from yesterday and should still show in Today.
    func testDateOnlyOverdueYesterday_includedInToday() {
        let cal = Calendar.current

        // The stored UTC midnight for yesterday
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let yesterdayComponents = cal.dateComponents([.year, .month, .day], from: yesterday)
        let dateOnlyDueDate = utcCal.date(from: yesterdayComponents)!

        let result = TaskListFilter.shouldIncludeInToday(
            dueDate: dateOnlyDueDate,
            isDueDateOnly: true,
            isCompleted: false,
            now: now
        )
        XCTAssertTrue(result, "Date-only task overdue from yesterday should appear in Today")
    }

    /// A date-only task due TODAY should appear in Today.
    /// This is the core regression: effectiveDeadline for a date-only task due today
    /// equals endOfToday exactly, so a strict `<` comparison incorrectly excludes it.
    func testDateOnlyDueToday_includedInToday() {
        let cal = Calendar.current

        // Build a date-only due date for today (stored as UTC midnight)
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let todayComponents = cal.dateComponents([.year, .month, .day], from: Date())
        let dateOnlyDueDate = utcCal.date(from: todayComponents)!

        let result = TaskListFilter.shouldIncludeInToday(
            dueDate: dateOnlyDueDate,
            isDueDateOnly: true,
            isCompleted: false,
            now: now
        )
        XCTAssertTrue(result, "Date-only task due TODAY should appear in Today view")
    }

    /// A task due tomorrow should NOT appear in Today.
    func testDueTomorrow_excludedFromToday() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
        let dueTomorrow = cal.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow)!

        let result = TaskListFilter.shouldIncludeInToday(
            dueDate: dueTomorrow,
            isDueDateOnly: false,
            isCompleted: false,
            now: now
        )
        XCTAssertFalse(result, "Task due tomorrow should NOT appear in Today")
    }
}
