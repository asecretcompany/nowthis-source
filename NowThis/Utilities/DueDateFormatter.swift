import Foundation

/// Formats due dates for display in task row badges.
///
/// Shows date-only for midnight dates (iCalendar DATE values) and
/// date+time for dates with a specific time component.
enum DueDateFormatter {

    /// Formats a due date for display in the task row badge.
    ///
    /// - Returns: `"May 28"` for date-only, `"May 28, 2:00 PM"` for date+time.
    static func format(_ date: Date) -> String {
        if hasTimeComponent(date) {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        } else {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    /// Formats a due date using the explicit date-only flag from the model.
    ///
    /// Prefer this overload when `isDueDateOnly` is available — it avoids
    /// the midnight-heuristic edge case where a task is actually due at
    /// exactly midnight local time.
    static func format(_ date: Date, isDateOnly: Bool) -> String {
        if isDateOnly {
            return date.formatted(.dateTime.month(.abbreviated).day())
        } else {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
    }

    /// Returns true if the date has a non-midnight time in the user's local timezone.
    ///
    /// iCalendar DATE values (no time) are stored as midnight UTC.
    /// We check against the local calendar to determine if the user
    /// set a specific time or if it's a date-only value.
    private static func hasTimeComponent(_ date: Date) -> Bool {
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return (components.hour ?? 0) != 0 || (components.minute ?? 0) != 0
    }
}
