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
        now: Date = Date()
    ) -> Bool {
        guard !isCompleted else { return false }

        let endOfToday = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
        let deadline = DueDateHelper.effectiveDeadline(for: dueDate, isDateOnly: isDueDateOnly)

        // Include if overdue OR due by end of today (inclusive)
        return deadline <= endOfToday
    }
}
