import Foundation

/// Parses natural language task input to extract metadata tokens.
///
/// Supports:
/// - `!high`, `!medium`/`!med`, `!low` → priority
/// - `#ListName` → task list assignment
/// - `@tagname` → tag assignment (multiple allowed)
/// - Date phrases: "today", "tomorrow", "next monday", "in 3 days", etc.
/// - Clock times: "at 5pm", "5:30pm", "at 17:00", "noon", "midnight" → due time
///
/// All matched tokens are stripped from the title. Unmatched text becomes the clean title.
struct NaturalLanguageParser {

    struct ParseResult {
        var cleanTitle: String = ""
        var priority: TaskPriority?
        var listName: String?
        var tagNames: [String] = []
        var dueDate: Date?
        /// `true` when the input specified an explicit clock time (e.g. "at 5pm"),
        /// `false` for bare/keyword dates that should be treated as all-day.
        var dueHasTime: Bool = false
    }

    // MARK: - Public API

    static func parse(_ input: String) -> ParseResult {
        var text = input
        var result = ParseResult()

        result.priority = extractPriority(from: &text)
        result.listName = extractList(from: &text)
        result.tagNames = extractTags(from: &text)
        let dateResult = extractDate(from: &text)
        result.dueDate = dateResult.date
        result.dueHasTime = dateResult.hasTime

        result.cleanTitle = text
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        return result
    }

    // MARK: - Priority Extraction

    private static let priorityPattern = try! NSRegularExpression(
        pattern: #"(?:^|\s)!(high|medium|med|low)\b"#,
        options: .caseInsensitive
    )

    private static func extractPriority(from text: inout String) -> TaskPriority? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = priorityPattern.firstMatch(in: text, range: range),
              let keyRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        let keyword = text[keyRange].lowercased()
        let fullRange = Range(match.range, in: text)!
        text.replaceSubrange(fullRange, with: "")

        switch keyword {
        case "high": return .high
        case "medium", "med": return .medium
        case "low": return .low
        default: return nil
        }
    }

    // MARK: - List Extraction

    private static let listPattern = try! NSRegularExpression(
        pattern: #"(?:^|\s)#(\S+)"#
    )

    private static func extractList(from text: inout String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = listPattern.firstMatch(in: text, range: range),
              let nameRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        let name = String(text[nameRange])
        let fullRange = Range(match.range, in: text)!
        text.replaceSubrange(fullRange, with: "")
        return name
    }

    // MARK: - Tag Extraction

    private static let tagPattern = try! NSRegularExpression(
        pattern: #"(?:^|\s)@(\S+)"#
    )

    private static func extractTags(from text: inout String) -> [String] {
        var tags: [String] = []
        // Process matches in reverse to preserve indices
        let range = NSRange(text.startIndex..., in: text)
        let matches = tagPattern.matches(in: text, range: range).reversed()

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let fullRange = Range(match.range, in: text) else { continue }
            tags.insert(String(text[nameRange]), at: 0)
            text.replaceSubrange(fullRange, with: "")
        }

        return tags
    }

    // MARK: - Date Extraction

    /// Keywords mapped to date generation closures.
    nonisolated(unsafe) private static let dateKeywords: [(pattern: String, resolve: () -> Date?)] = [
        ("today", { Calendar.current.startOfDay(for: Date()).addingTimeInterval(86399) }),
        ("tomorrow", {
            guard let d = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else { return nil }
            return Calendar.current.startOfDay(for: d).addingTimeInterval(86399)
        }),
        ("next monday", { nextWeekday(.monday) }),
        ("next tuesday", { nextWeekday(.tuesday) }),
        ("next wednesday", { nextWeekday(.wednesday) }),
        ("next thursday", { nextWeekday(.thursday) }),
        ("next friday", { nextWeekday(.friday) }),
        ("next saturday", { nextWeekday(.saturday) }),
        ("next sunday", { nextWeekday(.sunday) }),
    ]

    /// Regex for "in N days" / "in N day".
    private static let inNDaysPattern = try! NSRegularExpression(
        pattern: #"(?:^|\s)in\s+(\d+)\s+days?\b"#,
        options: .caseInsensitive
    )

    private static func extractDate(from text: inout String) -> (date: Date?, hasTime: Bool) {
        // Pull out an explicit clock time first ("at 5pm"), so it neither pollutes
        // the title nor loses to a bare date keyword.
        let time = extractTimeOfDay(from: &text)

        // 1. Check "in N days"
        let nsRange = NSRange(text.startIndex..., in: text)
        if let match = inNDaysPattern.firstMatch(in: text, range: nsRange),
           let numRange = Range(match.range(at: 1), in: text),
           let days = Int(text[numRange]),
           let fullRange = Range(match.range, in: text) {
            text.replaceSubrange(fullRange, with: "")
            if let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) {
                let day = Calendar.current.startOfDay(for: date).addingTimeInterval(86399)
                return applyTime(to: day, time: time)
            }
        }

        // 2. Check keywords (today, tomorrow, next X)
        let lower = text.lowercased()
        for keyword in dateKeywords {
            if let range = lower.range(of: keyword.pattern) {
                // Find the corresponding range in the original text
                let startDist = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let endDist = lower.distance(from: lower.startIndex, to: range.upperBound)
                let origStart = text.index(text.startIndex, offsetBy: startDist)
                let origEnd = text.index(text.startIndex, offsetBy: endDist)
                text.replaceSubrange(origStart..<origEnd, with: "")
                if let day = keyword.resolve() {
                    return applyTime(to: day, time: time)
                }
                return (nil, time != nil)
            }
        }

        // 3. Fallback: NSDataDetector for natural date expressions
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let detectorRange = NSRange(text.startIndex..., in: text)
            if let match = detector.firstMatch(in: text, range: detectorRange),
               let date = match.date,
               let swiftRange = Range(match.range, in: text) {
                // Only strip if the matched text looks date-like (not the entire title)
                let matchedText = String(text[swiftRange]).trimmingCharacters(in: .whitespaces)
                if matchedText.count < text.count {
                    text.replaceSubrange(swiftRange, with: "")
                    // Combine the detected day with any explicit spoken time.
                    return time != nil ? applyTime(to: date, time: time) : (date, false)
                }
            }
        }

        // 4. A time with no date defaults to today at that time.
        if let time {
            let today = Calendar.current.startOfDay(for: Date())
            let timed = Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: today)
            return (timed, true)
        }

        return (nil, false)
    }

    /// Applies an explicit clock time to a resolved day. When no time is given,
    /// the day is returned unchanged (preserving the existing end-of-day value).
    private static func applyTime(to dayDate: Date, time: (hour: Int, minute: Int)?) -> (date: Date?, hasTime: Bool) {
        guard let time else { return (dayDate, false) }
        let start = Calendar.current.startOfDay(for: dayDate)
        let timed = Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: start)
        return (timed ?? dayDate, true)
    }

    // MARK: - Time-of-Day Extraction

    /// "noon" / "midnight", optionally preceded by "at".
    private static let namedTimePattern = try! NSRegularExpression(
        pattern: #"(?:^|\s)(?:at\s+)?(noon|midnight)\b"#,
        options: .caseInsensitive
    )

    /// 12-hour clock: "at 5pm", "5:30 pm", optionally preceded by "at".
    private static let ampmTimePattern = try! NSRegularExpression(
        pattern: #"(?:^|\s)(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#,
        options: .caseInsensitive
    )

    /// 24-hour clock: "at 17:00", "9:15".
    private static let clock24Pattern = try! NSRegularExpression(
        pattern: #"(?:^|\s)(?:at\s+)?([01]?\d|2[0-3]):([0-5]\d)\b"#
    )

    /// Extracts an unambiguous clock time and strips it from `text`.
    /// Returns nil when no explicit time is present (bare numbers stay in the title).
    private static func extractTimeOfDay(from text: inout String) -> (hour: Int, minute: Int)? {
        // "noon" / "midnight"
        let namedRange = NSRange(text.startIndex..., in: text)
        if let match = namedTimePattern.firstMatch(in: text, range: namedRange),
           let wordRange = Range(match.range(at: 1), in: text),
           let fullRange = Range(match.range, in: text) {
            let isMidnight = text[wordRange].lowercased() == "midnight"
            text.replaceSubrange(fullRange, with: "")
            return isMidnight ? (0, 0) : (12, 0)
        }

        // 12-hour am/pm
        let ampmRange = NSRange(text.startIndex..., in: text)
        if let match = ampmTimePattern.firstMatch(in: text, range: ampmRange),
           let hourRange = Range(match.range(at: 1), in: text),
           let meridiemRange = Range(match.range(at: 3), in: text),
           let fullRange = Range(match.range, in: text),
           var hour = Int(text[hourRange]), (1...12).contains(hour) {
            var minute = 0
            if let minRange = Range(match.range(at: 2), in: text) {
                minute = Int(text[minRange]) ?? 0
            }
            let isPM = text[meridiemRange].lowercased() == "pm"
            if isPM && hour < 12 { hour += 12 }
            if !isPM && hour == 12 { hour = 0 }
            text.replaceSubrange(fullRange, with: "")
            return (hour, minute)
        }

        // 24-hour hh:mm
        let clockRange = NSRange(text.startIndex..., in: text)
        if let match = clock24Pattern.firstMatch(in: text, range: clockRange),
           let hourRange = Range(match.range(at: 1), in: text),
           let minRange = Range(match.range(at: 2), in: text),
           let fullRange = Range(match.range, in: text),
           let hour = Int(text[hourRange]), let minute = Int(text[minRange]) {
            text.replaceSubrange(fullRange, with: "")
            return (hour, minute)
        }

        return nil
    }

    // MARK: - Helpers

    private static func nextWeekday(_ weekday: Weekday) -> Date? {
        let cal = Calendar.current
        let today = cal.component(.weekday, from: Date())
        var daysAhead = weekday.calendarValue - today
        if daysAhead <= 0 { daysAhead += 7 }
        guard let date = cal.date(byAdding: .day, value: daysAhead, to: Date()) else { return nil }
        return cal.startOfDay(for: date).addingTimeInterval(86399)
    }

    private enum Weekday {
        case sunday, monday, tuesday, wednesday, thursday, friday, saturday

        var calendarValue: Int {
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
}
