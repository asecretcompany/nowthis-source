import Testing
import Foundation

@testable import NowThis

/// Tests for the pure notification-scheduling planner that drives both reminder
/// alerts and "now overdue" badge notifications. The planner is what lets the
/// app icon badge update while the app is closed: every entry it returns will
/// be scheduled as a local notification carrying the badge count as of its
/// fire date.
@Suite("ReminderScheduler Notification Plan")
struct NotificationPlanTests {

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

    // MARK: - Reminder entries

    @Test("Task with a reminder produces a reminder entry carrying the badge")
    func reminderTaskProducesReminderEntry() {
        let now = Date()
        // Due in 2h, reminder 1h before -> fires in 1h.
        let task = makeTask(dueDate: now.addingTimeInterval(2 * 3600), reminderOffset: 3600)

        let plan = ReminderScheduler.planNotifications(
            tasks: [task], now: now, maxCount: 60, badgesEnabled: true
        )

        #expect(plan.count == 1)
        #expect(plan.first?.kind == .reminder)
        // At the reminder fire time the task is "fired" -> badge counts it.
        #expect(plan.first?.badge == 1)
    }

    // MARK: - Overdue (badge) entries

    @Test("Due task without a reminder produces an overdue entry at the deadline")
    func bareDueTaskProducesOverdueEntry() {
        let now = Date()
        let due = now.addingTimeInterval(3600) // 1h from now, date+time
        let task = makeTask(dueDate: due)

        let plan = ReminderScheduler.planNotifications(
            tasks: [task], now: now, maxCount: 60, badgesEnabled: true
        )

        #expect(plan.count == 1)
        #expect(plan.first?.kind == .overdue)
        #expect(plan.first?.fireDate == due)
        #expect(plan.first?.badge == 1)
    }

    @Test("Already-past due task is excluded from the plan")
    func pastDueTaskExcluded() {
        let now = Date()
        let task = makeTask(dueDate: now.addingTimeInterval(-3600)) // overdue already

        let plan = ReminderScheduler.planNotifications(
            tasks: [task], now: now, maxCount: 60, badgesEnabled: true
        )

        #expect(plan.isEmpty)
    }

    @Test("Completed task is excluded from the plan")
    func completedTaskExcluded() {
        let now = Date()
        let task = makeTask(dueDate: now.addingTimeInterval(3600), status: .completed)

        let plan = ReminderScheduler.planNotifications(
            tasks: [task], now: now, maxCount: 60, badgesEnabled: true
        )

        #expect(plan.isEmpty)
    }

    // MARK: - Badge value reflects fire-time count

    @Test("Overdue badge value reflects the count as of each fire date")
    func badgeReflectsCountAtFireDate() {
        let now = Date()
        let taskA = makeTask(dueDate: now.addingTimeInterval(3600))      // overdue at +1h
        let taskB = makeTask(dueDate: now.addingTimeInterval(2 * 3600))  // overdue at +2h

        let plan = ReminderScheduler.planNotifications(
            tasks: [taskB, taskA], now: now, maxCount: 60, badgesEnabled: true
        )

        // Sorted nearest-first.
        #expect(plan.map(\.fireDate) == [taskA.dueDate!, taskB.dueDate!])
        // A fires first: only A overdue -> 1. B fires later: A + B overdue -> 2.
        #expect(plan.map(\.badge) == [1, 2])
    }

    // MARK: - Cap and ordering

    @Test("Plan is capped at maxCount, keeping the nearest fire dates")
    func planCappedAtMaxCount() {
        let now = Date()
        let tasks = (1...5).map { makeTask(dueDate: now.addingTimeInterval(Double($0) * 3600)) }

        let plan = ReminderScheduler.planNotifications(
            tasks: tasks, now: now, maxCount: 3, badgesEnabled: true
        )

        #expect(plan.count == 3)
        #expect(plan.map(\.fireDate) == tasks.prefix(3).map { $0.dueDate! })
    }

    // MARK: - Badges disabled

    @Test("When badges are disabled, reminders have no badge and overdue entries are dropped")
    func badgesDisabled() {
        let now = Date()
        let reminderTask = makeTask(dueDate: now.addingTimeInterval(2 * 3600), reminderOffset: 3600)
        let bareDueTask = makeTask(dueDate: now.addingTimeInterval(3600))

        let plan = ReminderScheduler.planNotifications(
            tasks: [reminderTask, bareDueTask], now: now, maxCount: 60, badgesEnabled: false
        )

        // Only the reminder survives; no overdue-badge notification when badges off.
        #expect(plan.count == 1)
        #expect(plan.first?.kind == .reminder)
        #expect(plan.first?.badge == nil)
    }
}
