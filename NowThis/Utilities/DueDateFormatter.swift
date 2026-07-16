import Foundation

/// Formats due dates for display in task row badges.
///
/// Shows date-only for midnight dates (iCalendar DATE values) and
/// date+time for dates with a specific time component.
enum DueDateFormatter {

    /// Appended to date-only badges so every due date reads as a time slot —
    /// e.g. `"Jul 6 · All day"` sits alongside `"Jul 6 at 7:00 PM"`.
    private static let allDaySuffix = " · All day"

    /// Formats a due date for display in the task row badge.
    ///
    /// - Returns: `"May 28 · All day"` for date-only, `"May 28, 2:00 PM"` for date+time.
    static func format(_ date: Date) -> String {
        if hasTimeComponent(date) {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        } else {
            return date.formatted(.dateTime.month(.abbreviated).day()) + allDaySuffix
        }
    }

    /// Formats a due date using the explicit date-only flag from the model.
    ///
    /// Prefer this overload when `isDueDateOnly` is available — it avoids
    /// the midnight-heuristic edge case where a task is actually due at
    /// exactly midnight local time.
    static func format(_ date: Date, isDateOnly: Bool) -> String {
        if isDateOnly {
            // Date-only values are stored as midnight UTC and represent a whole
            // calendar day. Render the components in UTC so the stored day is
            // preserved — local formatting would shift it (e.g. midnight-UTC
            // Jun 29 reads as "Jun 28, 5:00 PM" in PDT). Mirrors DueDateHelper,
            // which also extracts the calendar day in UTC.
            var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            style.timeZone = TimeZone(identifier: "UTC")!
            return date.formatted(style) + allDaySuffix
        } else {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
    }

    /// A VoiceOver-friendly rendering of a due date.
    ///
    /// Mirrors ``format(_:isDateOnly:)`` for display, but uses a spoken comma
    /// separator instead of the visual middle dot — VoiceOver can announce "·"
    /// as "middle dot" at higher punctuation verbosity, so the badge keeps the
    /// dot while the accessibility label reads plain text. Date-only dates read
    /// `"Jul 6, All day"`; timed dates read the same clock time as the badge.
    static func accessibilityLabel(_ date: Date, isDateOnly: Bool) -> String {
        if isDateOnly {
            // Match the badge's UTC day extraction so the spoken day equals the
            // visible day — local formatting would shift it (see `format`).
            var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            style.timeZone = TimeZone(identifier: "UTC")!
            return date.formatted(style) + ", All day"
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
