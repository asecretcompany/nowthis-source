import Foundation

/// Extracted filter predicates for smart list views. Testable without SwiftUI dependencies.
enum TaskListFilter {

    /// Whether a task should appear in the Today smart list.
    ///
    /// Includes tasks due today (not yet overdue) and ALL overdue tasks
    /// regardless of when they were originally due. Overdue tasks from
    /// previous days remain visible in Today until completed or rescheduled.
    ///
    /// - Parameters:
    ///   - dueDate: The task's due date.
    ///   - isDueDateOnly: Whether the due date is a date-only value.
    ///   - isCompleted: Whether the task is completed.
    ///   - now: The current date (injectable for testing).
    /// - Returns: `true` if the task belongs in the Today view.
    static func shouldIncludeInToday(
        dueDate: Date,
        isDueDateOnly: Bool,
        isCompleted: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard !isCompleted else { return false }

        let localCalendar = DueDateHelper.localCalendar(in: calendar)
        guard let endOfToday = localCalendar.date(byAdding: .day, value: 1,
                                                  to: localCalendar.startOfDay(for: now)) else { return false }
        let deadline = DueDateHelper.effectiveDeadline(for: dueDate, isDateOnly: isDueDateOnly, regionCalendar: calendar)

        // All-day deadlines equal next midnight; timed next-midnight tasks belong to tomorrow.
        return isDueDateOnly ? deadline <= endOfToday : deadline < endOfToday
    }
}
