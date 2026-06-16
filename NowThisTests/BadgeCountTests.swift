import Testing
import Foundation

@testable import NowThis

@Suite("ReminderScheduler Badge Count")
struct BadgeCountTests {

    // MARK: - Helpers

    /// Creates a TaskItem with the given properties for badge count testing.
    private func makeTask(
        dueDate: Date? = nil,
        isDueDateOnly: Bool = false,
        reminderOffset: Int? = nil,
        status: TaskStatus = .needsAction
    ) -> TaskItem {
        let task = TaskItem(title: "Test Task")
        task.dueDate = dueDate
        task.isDueDateOnly = isDueDateOnly
        task.reminderOffset = reminderOffset
        task.status = status
        return task
    }

    // MARK: - Tests

    @Test("Overdue task increments badge count")
    func overdueTaskIncrementsBadge() {
        // Due yesterday
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let task = makeTask(dueDate: yesterday)

        let count = ReminderScheduler.computeBadgeCount(tasks: [task])

        #expect(count >= 1, "Overdue task should increment badge count")
    }

    @Test("Future task does not increment badge count")
    func futureTaskDoesNotIncrementBadge() {
        // Due next week
        let nextWeek = Calendar.current.date(byAdding: .day, value: 7, to: Date())!
        let task = makeTask(dueDate: nextWeek)

        let count = ReminderScheduler.computeBadgeCount(tasks: [task])

        #expect(count == 0, "Future task should not increment badge count")
    }

    @Test("Task with no due date does not increment badge count")
    func noDueDateDoesNotIncrementBadge() {
        let task = makeTask(dueDate: nil)

        let count = ReminderScheduler.computeBadgeCount(tasks: [task])

        #expect(count == 0, "Task without due date should not increment badge count")
    }

    @Test("Completed task does not increment badge count")
    func completedTaskDoesNotIncrementBadge() {
        // Overdue but completed — should NOT count
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let task = makeTask(dueDate: yesterday, status: .completed)

        let count = ReminderScheduler.computeBadgeCount(tasks: [task])

        #expect(count == 0, "Completed task should not increment badge count even if overdue")
    }

    @Test("Task with fired reminder increments badge count")
    func firedReminderIncrementsBadge() {
        // Due in 2 hours, reminder was 3 hours before → fire date was 1 hour ago
        let now = Date()
        let dueDate = now.addingTimeInterval(2 * 3600) // 2 hours from now
        let task = makeTask(dueDate: dueDate, reminderOffset: 3 * 3600) // 3 hours before

        let count = ReminderScheduler.computeBadgeCount(tasks: [task], now: now)

        #expect(count >= 1, "Task with fired reminder should increment badge count")
    }

    @Test("Task with future reminder does not increment badge count")
    func futureReminderDoesNotIncrementBadge() {
        // Due tomorrow, reminder 1 hour before → fire date is tomorrow
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let task = makeTask(dueDate: tomorrow, reminderOffset: 3600)

        let count = ReminderScheduler.computeBadgeCount(tasks: [task])

        #expect(count == 0, "Task with future reminder should not increment badge count")
    }

    @Test("Date-only overdue task uses effective deadline")
    func dateOnlyOverdueUsesEffectiveDeadline() {
        // Date-only task "due today" stored as midnight UTC — should NOT be overdue
        // during the day (effective deadline is end of local day)
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let midnightUTC = utcCal.startOfDay(for: Date())

        let task = makeTask(dueDate: midnightUTC, isDueDateOnly: true)

        // Use a "now" time in the middle of the local day
        var localCal = Calendar.current
        localCal.timeZone = .current
        let components = localCal.dateComponents([.year, .month, .day], from: Date())
        let noon = localCal.date(bySettingHour: 12, minute: 0, second: 0, of: localCal.date(from: components)!)!

        let effectiveDeadline = DueDateHelper.effectiveDeadline(for: midnightUTC, isDateOnly: true)

        // Only check if the effective deadline is still in the future at noon
        if effectiveDeadline > noon {
            let count = ReminderScheduler.computeBadgeCount(tasks: [task], now: noon)
            #expect(count == 0, "Date-only task due today should not be overdue at noon")
        }
    }

    @Test("Empty task list returns zero")
    func emptyTaskListReturnsZero() {
        let count = ReminderScheduler.computeBadgeCount(tasks: [])
        #expect(count == 0, "Empty task list should return 0")
    }
}
