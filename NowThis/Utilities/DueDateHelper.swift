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

    /// Builds a date-only (all-day) due value for the local calendar date of `date`.
    ///
    /// Date-only values are stored as midnight UTC carrying the intended calendar
    /// date's year/month/day — the inverse of `effectiveDeadline`'s extraction —
    /// so a "due today" all-day task round-trips to `DUE;VALUE=DATE` correctly
    /// regardless of the user's timezone.
    static func dateOnlyValue(for date: Date, calendar: Calendar = .current) -> Date {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return utcCalendar.date(from: comps) ?? date
    }

    /// Builds a timed (date+time) due value on `date`'s local calendar day at
    /// `minutesSinceMidnight` minutes past local midnight.
    ///
    /// Used to bake a concrete due time onto quick due-date selections and to
    /// convert an all-day task to a timed one — the result is an exact `Date`, so
    /// it round-trips to a `DUE` datetime (not `DUE;VALUE=DATE`) and its row shows
    /// a clock time rather than "All day".
    static func timedValue(for date: Date, minutesSinceMidnight: Int, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .minute, value: minutesSinceMidnight, to: start) ?? start
    }

    /// The local start-of-day for a task's due date.
    ///
    /// For date-only values, resolves the calendar date carried by the midnight-UTC
    /// value into the user's timezone; for date+time values, the local start of the
    /// due day. Used as the anchor for all-day reminder fire times.
    static func localStartOfDay(for dueDate: Date, isDateOnly: Bool) -> Date {
        guard isDateOnly else { return Calendar.current.startOfDay(for: dueDate) }

        let comps = utcCalendar.dateComponents([.year, .month, .day], from: dueDate)
        var localCalendar = Calendar.current
        localCalendar.timeZone = .current
        guard let localDay = localCalendar.date(from: comps) else { return dueDate }
        return localCalendar.startOfDay(for: localDay)
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
