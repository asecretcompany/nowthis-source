import Foundation

/// Centralized date comparison logic for tasks with date-only vs date+time due dates.
///
/// Date-only tasks (iCalendar `VALUE=DATE`) are stored as midnight UTC but represent
/// an entire calendar day. Their effective deadline is the end of that day in the
/// user's local timezone. Date+time tasks use the exact stored `Date`.
enum DueDateHelper {

    /// Returns the effective deadline for overdue comparison.
    ///
    /// - Date-only: end of the local day (start of next day) for the calendar date
    ///   represented by the UTC midnight value.
    /// - Date+time: the date itself.
    static func effectiveDeadline(for dueDate: Date, isDateOnly: Bool) -> Date {
        guard isDateOnly else { return dueDate }

        // Extract the calendar date from UTC (the stored value represents this date)
        let utcCalendar = utcCalendar
        let dateComponents = utcCalendar.dateComponents([.year, .month, .day], from: dueDate)

        // Reconstruct in the local timezone as end-of-day (= start of next day)
        var localCalendar = Calendar.current
        localCalendar.timeZone = .current
        guard let localDay = localCalendar.date(from: dateComponents),
              let endOfDay = localCalendar.date(byAdding: .day, value: 1, to: localCalendar.startOfDay(for: localDay))
        else {
            return dueDate
        }

        return endOfDay
    }

    /// Whether the task is overdue right now.
    static func isOverdue(dueDate: Date, isDateOnly: Bool) -> Bool {
        return Date() >= effectiveDeadline(for: dueDate, isDateOnly: isDateOnly)
    }

    /// Whether the due date falls on the given calendar day (local timezone).
    ///
    /// For date-only tasks, compares the date components extracted in UTC
    /// (since the stored value directly represents the calendar date as midnight UTC)
    /// against the local day's date components.
    /// For date+time tasks, uses the local calendar comparison.
    static func isOnDay(_ dueDate: Date, isDateOnly: Bool, sameAs day: Date) -> Bool {
        guard isDateOnly else {
            return Calendar.current.isDate(dueDate, inSameDayAs: day)
        }

        // For date-only: the UTC date components ARE the intended calendar date
        let utcComponents = utcCalendar.dateComponents([.year, .month, .day], from: dueDate)
        let dayComponents = Calendar.current.dateComponents([.year, .month, .day], from: day)

        return utcComponents.year == dayComponents.year
            && utcComponents.month == dayComponents.month
            && utcComponents.day == dayComponents.day
    }

    // MARK: - Private

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
}
