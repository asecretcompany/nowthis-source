import Foundation

/// Parses, generates, and computes next occurrences for RFC-5545 RRULE strings.
///
/// Supports a practical subset of RRULE used by CalDAV task apps:
/// - FREQ: DAILY, WEEKLY, MONTHLY, YEARLY
/// - INTERVAL: repeat every N periods
/// - BYDAY: MO,TU,WE,TH,FR,SA,SU (weekly only)
/// - COUNT: max occurrences
/// - UNTIL: end date
struct RecurrenceRule {

    enum Frequency: String, CaseIterable, Identifiable {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly = "YEARLY"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            case .yearly: return "Yearly"
            }
        }
    }

    enum Weekday: String, CaseIterable, Identifiable {
        case monday = "MO"
        case tuesday = "TU"
        case wednesday = "WE"
        case thursday = "TH"
        case friday = "FR"
        case saturday = "SA"
        case sunday = "SU"

        var id: String { rawValue }

        var shortName: String {
            switch self {
            case .monday: return "Mon"
            case .tuesday: return "Tue"
            case .wednesday: return "Wed"
            case .thursday: return "Thu"
            case .friday: return "Fri"
            case .saturday: return "Sat"
            case .sunday: return "Sun"
            }
        }

        var calendarWeekday: Int {
            switch self {
            case .sunday: return 1
            case .monday: return 2
            case .tuesday: return 3
            case .wednesday: return 4
            case .thursday: return 5
            case .friday: return 6
            case .saturday: return 7
            }
        }
    }

    var frequency: Frequency
    var interval: Int
    var byDay: [Weekday]
    var count: Int?
    var until: Date?

    // MARK: - Parsing

    /// Parses an RRULE string like `FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR`.
    static func parse(_ rrule: String) -> RecurrenceRule? {
        var freq: Frequency?
        var interval = 1
        var byDay: [Weekday] = []
        var count: Int?
        var until: Date?

        let parts = rrule.components(separatedBy: ";")
        for part in parts {
            let keyValue = part.components(separatedBy: "=")
            guard keyValue.count == 2 else { continue }
            let key = keyValue[0].uppercased()
            let value = keyValue[1]

            switch key {
            case "FREQ":
                freq = Frequency(rawValue: value.uppercased())
            case "INTERVAL":
                interval = max(1, Int(value) ?? 1)
            case "BYDAY":
                byDay = value.components(separatedBy: ",").compactMap {
                    Weekday(rawValue: $0.trimmingCharacters(in: .whitespaces).uppercased())
                }
            case "COUNT":
                count = Int(value)
            case "UNTIL":
                until = ICalendarParser.parseDate(value)
            default:
                break
            }
        }

        guard let frequency = freq else { return nil }
        return RecurrenceRule(
            frequency: frequency,
            interval: interval,
            byDay: byDay,
            count: count,
            until: until
        )
    }

    // MARK: - Serialization

    /// Generates the RRULE string for iCalendar serialization.
    func toRRULEString() -> String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval > 1 {
            parts.append("INTERVAL=\(interval)")
        }
        if !byDay.isEmpty && frequency == .weekly {
            parts.append("BYDAY=\(byDay.map(\.rawValue).joined(separator: ","))")
        }
        if let count {
            parts.append("COUNT=\(count)")
        }
        if let until {
            let formatted = ICalendarSerializer.formatDate(until)
            parts.append("UNTIL=\(formatted)")
        }
        return parts.joined(separator: ";")
    }

    // MARK: - Display

    /// Human-readable description of the recurrence.
    var displayText: String {
        var text: String
        if interval == 1 {
            text = frequency.displayName
        } else {
            switch frequency {
            case .daily: text = "Every \(interval) days"
            case .weekly: text = "Every \(interval) weeks"
            case .monthly: text = "Every \(interval) months"
            case .yearly: text = "Every \(interval) years"
            }
        }

        if !byDay.isEmpty && frequency == .weekly {
            let dayNames = byDay.map(\.shortName).joined(separator: ", ")
            text += " on \(dayNames)"
        }

        return text
    }

    // MARK: - Next Occurrence

    /// Computes the next due date after the given reference date.
    ///
    /// If the recurrence has expired (COUNT exhausted or UNTIL passed),
    /// returns nil.
    ///
    /// - Parameters:
    ///   - after: The reference date (typically the current due date).
    ///   - completionCount: How many times the task has been completed (for COUNT check).
    /// - Returns: The next due date, or nil if the recurrence is finished.
    func nextDate(after: Date, completionCount: Int = 0) -> Date? {
        // Check COUNT limit
        if let count, completionCount >= count {
            return nil
        }

        let cal = Calendar.current
        var next: Date?

        switch frequency {
        case .daily:
            next = cal.date(byAdding: .day, value: interval, to: after)

        case .weekly:
            if byDay.isEmpty {
                next = cal.date(byAdding: .weekOfYear, value: interval, to: after)
            } else {
                next = nextWeekdayDate(after: after, calendar: cal)
            }

        case .monthly:
            next = cal.date(byAdding: .month, value: interval, to: after)

        case .yearly:
            next = cal.date(byAdding: .year, value: interval, to: after)
        }

        // Check UNTIL limit
        if let until, let nextDate = next, nextDate > until {
            return nil
        }

        return next
    }

    /// For BYDAY weekly rules, finds the next matching weekday.
    private func nextWeekdayDate(after date: Date, calendar: Calendar) -> Date? {
        let currentWeekday = calendar.component(.weekday, from: date)
        let targetWeekdays = byDay.map(\.calendarWeekday).sorted()

        // Find the next weekday in the current week
        for target in targetWeekdays {
            let diff = target - currentWeekday
            if diff > 0 {
                return calendar.date(byAdding: .day, value: diff, to: date)
            }
        }

        // Wrap to the first target day of the next interval-week
        guard let firstTarget = targetWeekdays.first else { return nil }
        let daysToEndOfWeek = 7 - currentWeekday + firstTarget
        let extraWeeks = (interval - 1) * 7
        return calendar.date(byAdding: .day, value: daysToEndOfWeek + extraWeeks, to: date)
    }

    /// Computes multiple future dates after the given reference date.
    ///
    /// Generates up to `limit` dates, stopping early if `through` is exceeded
    /// or the recurrence ends (COUNT/UNTIL).
    ///
    /// - Parameters:
    ///   - after: The starting reference date.
    ///   - through: Optional cutoff date — no dates past this are generated.
    ///   - limit: Maximum number of dates to return (default 52).
    /// - Returns: Array of future occurrence dates.
    func nextDates(after: Date, through: Date? = nil, limit: Int = 52) -> [Date] {
        var dates: [Date] = []
        var current = after
        var completionCount = 0

        for _ in 0..<limit {
            guard let next = nextDate(after: current, completionCount: completionCount) else {
                break
            }
            if let through, next > through {
                break
            }
            dates.append(next)
            current = next
            completionCount += 1
        }

        return dates
    }
}
