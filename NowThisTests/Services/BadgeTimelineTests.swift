import Testing
import Foundation

@testable import NowThis

/// Tests for `BadgeTimeline`, the sorted equivalent of `ReminderScheduler.computeBadgeCount`.
///
/// `planNotifications` used to call the oracle once per planned entry — up to 60 times, each an
/// O(N) walk over every active task — just to answer "how many tasks count toward the badge as of
/// this fire date?" `BadgeTimeline` answers the same question with a binary search over badge
/// times computed once. These tests hold the two implementations against each other directly, so
/// they can never quietly drift apart.
@Suite("Badge Timeline")
struct BadgeTimelineTests {

    // MARK: - Helpers

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

    /// Mirrors the filter `planNotifications` applies before ever calling the oracle, so the
    /// comparison below feeds `computeBadgeCount` the same shape of input production does.
    private func isActive(_ task: TaskItem) -> Bool {
        task.status != .completed && task.status != .cancelled
    }

    @Test("Agrees with computeBadgeCount at every instant across a mixed task set")
    func agreesWithOracleAcrossInstants() {
        let now = Date()
        let day: TimeInterval = 86_400

        let tasks: [TaskItem] = [
            // Timed, no reminder: counts the moment it's overdue.
            makeTask(dueDate: now.addingTimeInterval(-3 * day)),
            // Timed, reminder fires exactly at due (offset 0).
            makeTask(dueDate: now.addingTimeInterval(-1 * day), reminderOffset: 0),
            // Date-only, no reminder, already overdue.
            makeTask(dueDate: now.addingTimeInterval(-2 * day), isDueDateOnly: true),
            // Timed, reminder 15 minutes before due (offset 900).
            makeTask(dueDate: now.addingTimeInterval(1 * day), reminderOffset: 900),
            // Date-only, reminder a day before due (offset 86_400) — fires before the
            // effective (end-of-day) deadline.
            makeTask(dueDate: now.addingTimeInterval(2 * day), isDueDateOnly: true, reminderOffset: 86_400),
            // Timed, no reminder, due later in the window.
            makeTask(dueDate: now.addingTimeInterval(3 * day)),
            // Date-only, reminder 15 minutes "before" the all-day anchor time.
            makeTask(dueDate: now.addingTimeInterval(9 * day), isDueDateOnly: true, reminderOffset: 900),
            // Timed, reminder fires exactly at due (offset 0), further out.
            makeTask(dueDate: now.addingTimeInterval(5 * day), reminderOffset: 0),
            // Completed — must never count, even though overdue.
            makeTask(dueDate: now.addingTimeInterval(-1 * day), status: .completed),
            // Cancelled — must never count, even though overdue.
            makeTask(dueDate: now.addingTimeInterval(1 * day), status: .cancelled),
            // No due date at all — never counts.
            makeTask(dueDate: nil),
            // Timed, due at the far edge of the window, no reminder.
            makeTask(dueDate: now.addingTimeInterval(9 * day)),
        ]

        // Passed explicitly (rather than relying on BadgeTimeline's default) so it is visibly the
        // exact same live value the oracle reads internally — see the report for why this test
        // does not write UserDefaults to pin it instead.
        let timeline = BadgeTimeline(
            tasks: tasks,
            allDayReminderMinutes: TaskDefaultsPreferences.allDayReminderMinutes
        )
        let activeTasks = tasks.filter(isActive)

        for step in 0..<60 {
            let t = now.addingTimeInterval(-4 * day + Double(step) * 4 * 3600)
            let expected = ReminderScheduler.computeBadgeCount(tasks: activeTasks, now: t)
            #expect(timeline.count(asOf: t) == expected, "Mismatch at step \(step), t=\(t)")
        }
    }

    @Test("A task counts at exactly its deadline, not a second before")
    func countsAtExactDeadlineBoundary() {
        let dueDate = Date()
        let task = makeTask(dueDate: dueDate)

        let timeline = BadgeTimeline(tasks: [task])

        #expect(timeline.count(asOf: dueDate) == 1)
        #expect(timeline.count(asOf: dueDate.addingTimeInterval(-1)) == 0)
    }

    @Test("An empty timeline counts nothing")
    func emptyTimelineCountsNothing() {
        let timeline = BadgeTimeline(tasks: [])
        #expect(timeline.count(asOf: Date()) == 0)
    }
}
