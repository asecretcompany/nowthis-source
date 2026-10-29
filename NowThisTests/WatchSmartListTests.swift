import Foundation
import Testing
@testable import NowThis

@Suite("WatchSmartList")
struct WatchSmartListTests {

    /// A fixed "now" of today at 3:00 PM local time, so overdue/upcoming math
    /// is deterministic without freezing the calendar day itself.
    private var now: Date {
        Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!
    }

    private func makeTask(
        uid: String = "uid-1",
        dueDate: Date? = nil,
        isDueDateOnly: Bool = false,
        isCompleted: Bool = false
    ) -> WatchTask {
        WatchTask(id: "T-\(uid)", uid: uid, title: "Buy milk", dueDate: dueDate,
                  isDueDateOnly: isDueDateOnly, priorityRaw: 0, isCompleted: isCompleted,
                  listID: "L1", parentUID: nil)
    }

    /// Builds a date-only (VALUE=DATE) due value — stored as midnight UTC — for
    /// the local calendar date `daysFromToday` days from today, mirroring
    /// OverdueInTodayFilterTests' construction so effectiveDeadline's timezone
    /// handling is exercised the same way.
    private func dateOnlyDue(daysFromToday: Int) -> Date {
        // Extract and recompose with the SAME calendar. Reading components from
        // `Calendar.current` and rebuilding them with a Gregorian one shifts the date by the
        // era offset on any non-Gregorian device: under th_TH the extract yields year 2569
        // and the Gregorian compose reads that as 2569 AD, putting the fixture 543 years out.
        // The local calendar still supplies the time zone, which is what this helper is about.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Calendar.current.timeZone
        let day = cal.date(byAdding: .day, value: daysFromToday, to: Date())!
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let components = cal.dateComponents([.year, .month, .day], from: day)
        return utcCal.date(from: components)!
    }

    // MARK: - today

    @Test func todayIncludesTimedTaskOverdueByDays() {
        let cal = Calendar.current
        let fiveDaysAgo = cal.date(byAdding: .day, value: -5, to: Date())!
        let due = cal.date(bySettingHour: 10, minute: 0, second: 0, of: fiveDaysAgo)!
        let task = makeTask(dueDate: due)

        #expect(WatchSmartList.today.includes(task, now: now))
    }

    @Test func todayIncludesTaskDueLaterToday() {
        let cal = Calendar.current
        let due = cal.date(bySettingHour: 17, minute: 0, second: 0, of: Date())!
        let task = makeTask(dueDate: due)

        #expect(WatchSmartList.today.includes(task, now: now))
    }

    @Test func todayExcludesCompletedTask() {
        let cal = Calendar.current
        let due = cal.date(bySettingHour: 17, minute: 0, second: 0, of: Date())!
        let task = makeTask(dueDate: due, isCompleted: true)

        #expect(!WatchSmartList.today.includes(task, now: now))
    }

    @Test func todayExcludesNoDueDateTask() {
        let task = makeTask(dueDate: nil)

        #expect(!WatchSmartList.today.includes(task, now: now))
    }

    /// The falsifying case: a VALUE=DATE task due tomorrow (local) must NOT be
    /// in Today. A raw-`dueDate` comparison (stored as midnight UTC) can land
    /// on "today" or "tomorrow" depending on the device's UTC offset — only
    /// routing through `DueDateHelper.effectiveDeadline` gets this right.
    @Test func todayExcludesDateOnlyTaskDueTomorrow() {
        let task = makeTask(dueDate: dateOnlyDue(daysFromToday: 1), isDueDateOnly: true)

        #expect(!WatchSmartList.today.includes(task, now: now))
    }

    @Test func todayIncludesDateOnlyTaskDueToday() {
        let task = makeTask(dueDate: dateOnlyDue(daysFromToday: 0), isDueDateOnly: true)

        #expect(WatchSmartList.today.includes(task, now: now))
    }

    // MARK: - overdue

    @Test func overdueIncludesTimedTaskDueOneHourAgo() {
        let due = now.addingTimeInterval(-3_600)
        let task = makeTask(dueDate: due)

        #expect(WatchSmartList.overdue.includes(task, now: now))
    }

    @Test func overdueExcludesFutureTask() {
        let due = now.addingTimeInterval(3_600)
        let task = makeTask(dueDate: due)

        #expect(!WatchSmartList.overdue.includes(task, now: now))
    }

    @Test func overdueExcludesCompletedTask() {
        let due = now.addingTimeInterval(-3_600)
        let task = makeTask(dueDate: due, isCompleted: true)

        #expect(!WatchSmartList.overdue.includes(task, now: now))
    }

    // MARK: - upcoming

    @Test func upcomingIncludesTaskDueInTwoDays() {
        let due = now.addingTimeInterval(2 * 86_400)
        let task = makeTask(dueDate: due)

        #expect(WatchSmartList.upcoming.includes(task, now: now))
    }

    @Test func upcomingExcludesTaskDueInEightDays() {
        let due = now.addingTimeInterval(8 * 86_400)
        let task = makeTask(dueDate: due)

        #expect(!WatchSmartList.upcoming.includes(task, now: now))
    }

    @Test func upcomingExcludesTaskDueOneHourAgo() {
        let due = now.addingTimeInterval(-3_600)
        let task = makeTask(dueDate: due)

        #expect(!WatchSmartList.upcoming.includes(task, now: now))
    }

    @Test func upcomingExcludesCompletedTask() {
        let due = now.addingTimeInterval(2 * 86_400)
        let task = makeTask(dueDate: due, isCompleted: true)

        #expect(!WatchSmartList.upcoming.includes(task, now: now))
    }

    // MARK: - all

    @Test func allIncludesNoDueDateIncompleteTask() {
        let task = makeTask(dueDate: nil)

        #expect(WatchSmartList.all.includes(task, now: now))
    }

    @Test func allExcludesCompletedTask() {
        let task = makeTask(dueDate: nil, isCompleted: true)

        #expect(!WatchSmartList.all.includes(task, now: now))
    }
}
