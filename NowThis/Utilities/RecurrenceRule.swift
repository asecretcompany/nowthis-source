import Foundation

/// Parses, generates, and computes next occurrences for RFC-5545 RRULE strings.
///
/// Supports a practical subset of RRULE used by CalDAV task apps:
/// - FREQ: DAILY, WEEKLY, MONTHLY, YEARLY
/// - INTERVAL: repeat every N periods
/// - BYDAY: plain weekdays and monthly/yearly ordinals (1...53, positive or negative)
/// - COUNT: max occurrences
/// - UNTIL: end date
struct RecurrenceRule {

    enum Frequency: String, CaseIterable, Identifiable {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly = "YEARLY"

        var id: String { rawValue }

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

        /// The abbreviated weekday name in the reader's language.
        ///
        /// **Resolved by deletion, not by translation.** These were seven hardcoded English
        /// literals — `"Mon"`…`"Sun"` — which would have needed seven keys × five languages and
        /// would then have disagreed with `CalendarMonthView`, which already reads its headers
        /// from `Calendar`. Foundation ships every locale's weekday names; asking for them is
        /// both correct and less code.
        ///
        /// `shortWeekdaySymbols` is indexed 0…6 from **Sunday**, which is what `calendarWeekday`
        /// already numbers 1…7 from.
        func shortName(in calendar: Calendar = .current) -> String {
            calendar.shortWeekdaySymbols[calendarWeekday - 1]
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

    struct ByDay: Equatable {
        var ordinal: Int? = nil
        var weekday: Weekday
        // Preserve an explicit positive sign when a custom rule is round-tripped.
        var explicitPlus = false

        var rawValue: String {
            guard let ordinal else { return weekday.rawValue }
            return (explicitPlus && ordinal > 0 ? "+" : "") + String(ordinal) + weekday.rawValue
        }
    }

    var frequency: Frequency
    var interval: Int
    var byDay: [ByDay]
    var count: Int?
    var until: Date?

    var plainWeekdays: [Weekday] { byDay.filter { $0.ordinal == nil }.map(\.weekday) }

    /// The picker only represents these rules without discarding restrictions.
    var isPickerRepresentable: Bool {
        count == nil && until == nil && (1...99).contains(interval)
            && byDay.allSatisfy { $0.ordinal == nil }
            && (byDay.isEmpty || frequency == .weekly)
    }

    static func isPickerRepresentable(_ raw: String?) -> Bool {
        guard let raw, !raw.isEmpty else { return true }
        return parse(raw)?.isPickerRepresentable == true
    }

    // MARK: - Parsing

    /// Unsupported clauses fail the whole parse: ignoring one would compute a different rule.
    static func parse(_ rrule: String) -> RecurrenceRule? {
        var freq: Frequency?
        var interval = 1
        var byDay: [ByDay] = []
        var count: Int?
        var until: Date?
        var seen = Set<String>()
        for part in rrule.components(separatedBy: ";") {
            let pair = part.components(separatedBy: "=")
            guard pair.count == 2 else { return nil }
            let key = pair[0].uppercased()
            let value = pair[1].uppercased()
            guard seen.insert(key).inserted, !value.isEmpty else { return nil }
            switch key {
            case "FREQ":
                guard let parsed = Frequency(rawValue: value) else { return nil }
                freq = parsed
            case "INTERVAL", "COUNT":
                guard value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let number = Int(value), number > 0 else { return nil }
                if key == "INTERVAL" { interval = number } else { count = number }
            case "BYDAY":
                for token in value.components(separatedBy: ",") {
                    guard token.count >= 2,
                          let weekday = Weekday(rawValue: String(token.suffix(2))) else { return nil }
                    let prefix = String(token.dropLast(2))
                    var ordinal: Int?
                    if !prefix.isEmpty {
                        let digits = prefix.first == "+" || prefix.first == "-" ? String(prefix.dropFirst()) : prefix
                        guard !digits.isEmpty, digits.count <= 2, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                              let number = Int(prefix), number != 0, (-53...53).contains(number) else { return nil }
                        ordinal = number
                    }
                    byDay.append(ByDay(ordinal: ordinal, weekday: weekday, explicitPlus: prefix.hasPrefix("+")))
                }
            case "UNTIL":
                guard let date = ICalendarParser.parseDate(value) else { return nil }
                until = date
            default:
                return nil
            }
        }
        guard let frequency = freq, !(count != nil && until != nil),
              !byDay.contains(where: { $0.ordinal != nil && (frequency == .weekly || frequency == .daily) }),
              !(frequency == .daily && !byDay.isEmpty) else { return nil }
        return RecurrenceRule(frequency: frequency, interval: interval, byDay: byDay, count: count, until: until)
    }

    func toRRULEString() -> String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval > 1 { parts.append("INTERVAL=\(interval)") }
        if !byDay.isEmpty { parts.append("BYDAY=\(byDay.map(\.rawValue).joined(separator: ","))") }
        if let count { parts.append("COUNT=\(count)") }
        if let until { parts.append("UNTIL=\(ICalendarSerializer.formatDate(until))") }
        return parts.joined(separator: ";")
    }

    enum NextOccurrence: Equatable {
        case date(Date)
        case exhausted
        case unsupported
    }

    func nextDate(after: Date, completionCount: Int = 0, calendar: Calendar = .current) -> Date? {
        guard case .date(let date) = nextOccurrence(after: after, completionCount: completionCount, calendar: calendar) else { return nil }
        return date
    }

    /// Separates a valid exhausted series from an evaluation that cannot safely be performed.
    func nextOccurrence(after: Date, completionCount: Int = 0, calendar: Calendar = .current) -> NextOccurrence {
        guard interval > 0, count.map({ $0 > 0 }) ?? true,
              byDay.allSatisfy({ $0.ordinal.map { $0 != 0 && (-53...53).contains($0) } ?? true }) else { return .unsupported }
        if let count, completionCount >= count { return .exhausted }
        if let until, after >= until { return .exhausted }
        // Foundation calendar arithmetic takes machine integers but cannot safely evaluate
        // unbounded additions. Keep such imported rules intact and block local completion.
        guard interval <= Int(Int32.max) else { return .unsupported }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = calendar.timeZone
        let next: Date?
        switch frequency {
        case .daily:
            guard byDay.isEmpty else { return .unsupported }
            next = cal.date(byAdding: .day, value: interval, to: after)
        case .weekly:
            guard byDay.allSatisfy({ $0.ordinal == nil }) else { return .unsupported }
            if byDay.isEmpty {
                next = cal.date(byAdding: .weekOfYear, value: interval, to: after)
            } else {
                // With WKST omitted, RFC 5545 starts the week on Monday.
                func daysFromMonday(_ weekday: Int) -> Int {
                    (weekday - Weekday.monday.calendarWeekday + 7) % 7
                }
                let weekday = daysFromMonday(cal.component(.weekday, from: after))
                let targets = plainWeekdays.map { daysFromMonday($0.calendarWeekday) }.sorted()
                if let later = targets.first(where: { $0 > weekday }) {
                    next = cal.date(byAdding: .day, value: later - weekday, to: after)
                } else if let first = targets.first {
                    // interval is bounded above, so this addition cannot overflow Int.
                    next = cal.date(byAdding: .day, value: 7 - weekday + first + (interval - 1) * 7, to: after)
                } else { return .unsupported }
            }
        case .monthly, .yearly:
            let component: Calendar.Component = frequency == .monthly ? .month : .year
            if byDay.isEmpty {
                return nextOnAnchorDay(after: after, component: component, calendar: cal)
            } else {
                return nextByDay(after: after, component: component, calendar: cal)
            }
        }
        guard let next, next > after, next.timeIntervalSinceReferenceDate.isFinite else { return .unsupported }
        return checkedOccurrence(next)
    }

    private func nextOnAnchorDay(after: Date, component: Calendar.Component, calendar: Calendar) -> NextOccurrence {
        guard after.timeIntervalSinceReferenceDate.isFinite,
              let initial = calendar.dateInterval(of: component, for: after)?.start,
              let initialIndex = Self.periodIndex(calendar.dateComponents([.era, .year, .month], from: initial),
                                                  component: component) else { return .unsupported }
        let anchor = calendar.dateComponents([.month, .day, .hour, .minute, .second, .nanosecond], from: after)
        var period = initial
        var periodIndex = initialIndex
        // Bound evaluation by a Gregorian civil cycle. Time-zone rules can change
        // outside the search, so reaching this bound cannot establish exhaustion.
        let attemptLimit = component == .month ? 4800 : 400
        for _ in 0..<attemptLimit {
            guard let advanced = calendar.date(byAdding: component, value: interval, to: period),
                  advanced.timeIntervalSinceReferenceDate.isFinite,
                  let following = calendar.dateInterval(of: component, for: advanced)?.start,
                  following > period else { return .unsupported }
            var civilDate = calendar.dateComponents([.era, .year, .month], from: following)
            // Foundation can saturate large additions to a different future period.
            guard let followingIndex = Self.periodIndex(civilDate, component: component),
                  followingIndex - periodIndex == interval else { return .unsupported }
            if let until, following > until { return .exhausted }
            period = following
            periodIndex = followingIndex

            if component == .year { civilDate.month = anchor.month }
            civilDate.day = anchor.day
            guard let day = calendar.date(from: civilDate),
                  calendar.dateComponents([.era, .year, .month, .day], from: day) == civilDate,
                  let next = Self.date(on: day, matchingClock: anchor, calendar: calendar) else { continue }
            guard next > after, next.timeIntervalSinceReferenceDate.isFinite else { return .unsupported }
            return checkedOccurrence(next)
        }
        return .unsupported
    }

    private func checkedOccurrence(_ date: Date) -> NextOccurrence {
        if let until, date > until { return .exhausted }
        // DATE and DATE-TIME use four-digit Gregorian years on the wire.
        var wireCalendar = Calendar(identifier: .gregorian)
        wireCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let wireDate = wireCalendar.dateComponents([.era, .year], from: date)
        guard wireDate.era == 1, let year = wireDate.year, (1...9999).contains(year) else { return .unsupported }
        return .date(date)
    }

    private static func periodIndex(_ date: DateComponents, component: Calendar.Component) -> Int? {
        guard let era = date.era, let year = date.year, let month = date.month else { return nil }
        let signedYear = era == 0 ? 1 - year : year
        return component == .month ? signedYear * 12 + month - 1 : signedYear
    }

    private static func date(on day: Date, matchingClock time: DateComponents, calendar: Calendar) -> Date? {
        guard let candidate = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                             second: time.second ?? 0, of: day,
                                             matchingPolicy: .strict, repeatedTimePolicy: .first),
              calendar.isDate(candidate, inSameDayAs: day) else { return nil }
        // Strict matching can search beyond a missing local time. Accept only
        // the intended civil day and clock; RFC 5545 ignores DST-gap candidates.
        let clock = calendar.dateComponents([.hour, .minute, .second], from: candidate)
        guard clock.hour == time.hour, clock.minute == time.minute, clock.second == time.second else { return nil }
        return candidate.addingTimeInterval(Double(time.nanosecond ?? 0) / 1_000_000_000)
    }

    private func nextByDay(after: Date, component: Calendar.Component, calendar: Calendar) -> NextOccurrence {
        if component == .month, byDay.allSatisfy({ $0.ordinal.map { abs($0) > 5 } ?? false }) {
            return .exhausted
        }
        guard let initial = calendar.dateInterval(of: component, for: after)?.start else { return .unsupported }
        var period = initial
        let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: after)
        // Gregorian weekday/month patterns repeat every 400 years. One complete cycle
        // proves that a missing ordinal will never occur, even with an interval > 1.
        let cycle = component == .month ? 4800 : 400
        for _ in 0...cycle {
            guard let span = calendar.dateInterval(of: component, for: period),
                  let last = calendar.date(byAdding: .day, value: -1, to: span.end),
                  let days = calendar.dateComponents([.day], from: span.start, to: span.end).day else { return .unsupported }
            var candidates: [Date] = []
            for day in byDay {
                let firstOffset = (day.weekday.calendarWeekday - calendar.component(.weekday, from: span.start) + 7) % 7
                let offsets: [Int]
                if let ordinal = day.ordinal {
                    guard ordinal != 0, (-53...53).contains(ordinal) else { return .unsupported }
                    if ordinal > 0 {
                        offsets = [firstOffset + (ordinal - 1) * 7]
                    } else {
                        let lastOffset = (calendar.component(.weekday, from: last) - day.weekday.calendarWeekday + 7) % 7
                        offsets = [days - 1 - lastOffset + (ordinal + 1) * 7]
                    }
                } else {
                    offsets = Array(stride(from: firstOffset, to: days, by: 7))
                }
                for offset in offsets where (0..<days).contains(offset) {
                    guard let dayDate = calendar.date(byAdding: .day, value: offset, to: span.start),
                          let candidate = Self.date(on: dayDate, matchingClock: time, calendar: calendar),
                          candidate > after else { continue }
                    candidates.append(candidate)
                }
            }
            if let next = candidates.min() {
                return checkedOccurrence(next)
            }
            guard let following = calendar.date(byAdding: component, value: interval, to: period), following > period else { return .unsupported }
            if let until, following > until { return .exhausted }
            period = following
        }
        return .exhausted
    }

    func nextDates(after: Date, through: Date? = nil, limit: Int = 52, calendar: Calendar = .current) -> [Date] {
        guard limit > 0 else { return [] }
        var dates: [Date] = []
        var current = after
        for completionCount in 0..<limit {
            guard let next = nextDate(after: current, completionCount: completionCount, calendar: calendar),
                  through.map({ next <= $0 }) ?? true else { break }
            dates.append(next)
            current = next
        }
        return dates
    }
}
