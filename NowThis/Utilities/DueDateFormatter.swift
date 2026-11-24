import Foundation

/// Formats due dates for display in task row badges.
///
/// Shows date-only for midnight dates (iCalendar DATE values) and
/// date+time for dates with a specific time component.
enum DueDateFormatter {

    /// The date-only badge, e.g. `"Jul 6 · All day"` beside `"Jul 6 at 7:00 PM"`.
    ///
    /// A **template**, not a suffix. `" · All day"` glued onto a locale-formatted date puts the
    /// separator and the phrase in an order English chose, with no way for a translator to move
    /// either — and the two shipped as English text appended to a correctly localized date, which
    /// is the worst of both.
    private static func allDayBadge(_ formattedDate: String) -> String {
        String(localized: "dueDate.badge.allDay",
               defaultValue: "\(formattedDate) · All day",
               comment: "Due-date badge for a task due on a whole day rather than at a time. The placeholder is the already-formatted date; the middle dot is a visual separator and may be changed to whatever reads correctly.")
    }

    /// The spoken form of the same badge.
    ///
    /// Separate from ``allDayBadge(_:)`` because VoiceOver can announce `·` as "middle dot" at
    /// higher punctuation verbosity, so the spoken label uses a comma while the badge keeps the
    /// dot. Two renderings, therefore two keys — a translator changing one must not silently
    /// change the other.
    private static func allDaySpoken(_ formattedDate: String) -> String {
        String(localized: "dueDate.a11y.allDay",
               defaultValue: "\(formattedDate), All day",
               comment: "VoiceOver reading of a due date for a task due on a whole day rather than at a time. The placeholder is the already-formatted date. Use a spoken separator here, not a punctuation glyph.")
    }

    /// Formats a due date for display in the task row badge.
    ///
    /// - Returns: `"May 28 · All day"` for date-only, `"May 28, 2:00 PM"` for date+time.
    static func format(_ date: Date) -> String {
        if hasTimeComponent(date) {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        } else {
            return allDayBadge(date.formatted(.dateTime.month(.abbreviated).day()))
        }
    }

    /// Formats a due date using the explicit date-only flag from the model.
    ///
    /// Prefer this overload when `isDueDateOnly` is available — it avoids
    /// the midnight-heuristic edge case where a task is actually due at
    /// exactly midnight local time. A compact surface can supply a style
    /// for timed dates while keeping the same all-day rendering.
    static func format(_ date: Date, isDateOnly: Bool, timeZone: TimeZone = .current,
                       timedStyle: Date.FormatStyle? = nil) -> String {
        let day = formattedDate(date, isDateOnly: isDateOnly, timeZone: timeZone, timedStyle: timedStyle)
        return isDateOnly ? allDayBadge(day) : day
    }

    /// A VoiceOver-friendly rendering of a due date.
    ///
    /// Mirrors the explicit formatter for display, but uses a spoken comma
    /// separator instead of the visual middle dot — VoiceOver can announce "·"
    /// as "middle dot" at higher punctuation verbosity, so the badge keeps the
    /// dot while the accessibility label reads plain text. Date-only dates read
    /// `"Jul 6, All day"`; timed dates read the same clock time as the badge.
    static func accessibilityLabel(_ date: Date, isDateOnly: Bool, timeZone: TimeZone = .current,
                                   timedStyle: Date.FormatStyle? = nil) -> String {
        let day = formattedDate(date, isDateOnly: isDateOnly, timeZone: timeZone, timedStyle: timedStyle)
        return isDateOnly ? allDaySpoken(day) : day
    }

    /// Midnight UTC carries the civil day for DATE values. Timed instants render locally.
    static func formattingTimeZone(isDateOnly: Bool, localTimeZone: TimeZone) -> TimeZone {
        isDateOnly ? .gmt : localTimeZone
    }

    private static func formattedDate(_ date: Date, isDateOnly: Bool, timeZone: TimeZone,
                                      timedStyle: Date.FormatStyle?) -> String {
        let day = Date.FormatStyle.dateTime.month(.abbreviated).day()
        var style = isDateOnly ? day : (timedStyle ?? day.hour().minute())
        style.timeZone = formattingTimeZone(isDateOnly: isDateOnly, localTimeZone: timeZone)
        return date.formatted(style)
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
