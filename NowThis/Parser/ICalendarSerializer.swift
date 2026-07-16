import Foundation

/// Serializes `TaskItem` models to RFC-5545 VTODO iCalendar format.
///
/// Generates `.ics` file content suitable for PUT to a CalDAV server.
/// All date-time values are emitted in UTC with the `Z` suffix.
struct ICalendarSerializer {

    // MARK: - Public API

    /// Serializes a set of VTODO properties to a complete `.ics` string.
    ///
    /// - Parameters:
    ///   - uid: The globally unique iCalendar UID.
    ///   - summary: VTODO SUMMARY (task title).
    ///   - description: VTODO DESCRIPTION (optional).
    ///   - status: VTODO STATUS string (e.g., "NEEDS-ACTION").
    ///   - priority: VTODO PRIORITY (0-9).
    ///   - percentComplete: VTODO PERCENT-COMPLETE (0-100).
    ///   - dueDate: VTODO DUE (optional).
    ///   - startDate: VTODO DTSTART (optional).
    ///   - completedDate: VTODO COMPLETED (optional).
    ///   - createdDate: VTODO CREATED.
    ///   - lastModifiedDate: VTODO LAST-MODIFIED.
    ///   - categories: VTODO CATEGORIES (array).
    ///   - location: VTODO LOCATION (optional).
    ///   - latitude: GEO latitude component (optional).
    ///   - longitude: GEO longitude component (optional).
    ///   - url: VTODO URL (optional).
    ///   - parentUID: RELATED-TO;RELTYPE=PARENT UID (optional).
    ///   - recurrenceRule: VTODO RRULE (optional).
    /// - Returns: A complete `.ics` file string.
    static func serialize(
        uid: String,
        summary: String,
        description: String? = nil,
        status: String = "NEEDS-ACTION",
        priority: Int = 0,
        percentComplete: Int = 0,
        dueDate: Date? = nil,
        startDate: Date? = nil,
        completedDate: Date? = nil,
        createdDate: Date = Date(),
        lastModifiedDate: Date = Date(),
        categories: [String] = [],
        location: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        url: String? = nil,
        parentUID: String? = nil,
        recurrenceRule: String? = nil,
        alarmTriggerSeconds: Int? = nil,
        isDueDateOnly: Bool = false,
        isStartDateOnly: Bool = false,
        manualSortOrder: Int? = nil
    ) -> String {
        var lines: [String] = []

        lines.append("BEGIN:VCALENDAR")
        lines.append("VERSION:2.0")
        lines.append("PRODID:-//NowThis//NowThis iOS//EN")
        lines.append("BEGIN:VTODO")

        lines.append("UID:\(uid)")
        lines.append("DTSTAMP:\(formatDate(Date()))")
        lines.append("CREATED:\(formatDate(createdDate))")
        lines.append("LAST-MODIFIED:\(formatDate(lastModifiedDate))")
        lines.append("SUMMARY:\(escapeText(summary))")

        if let desc = description, !desc.isEmpty {
            lines.append("DESCRIPTION:\(escapeText(desc))")
        }

        lines.append("STATUS:\(status)")

        if priority != 0 {
            lines.append("PRIORITY:\(priority)")
        }

        if percentComplete > 0 {
            lines.append("PERCENT-COMPLETE:\(percentComplete)")
        }

        if let due = dueDate {
            if isDueDateOnly {
                lines.append("DUE;VALUE=DATE:\(formatDateOnly(due))")
            } else {
                lines.append("DUE:\(formatDate(due))")
            }
        }

        if let start = startDate {
            // RFC 5545: DUE must occur after DTSTART when both are present.
            // Sabre/DAV (snapd Nextcloud) rejects VTODOs that violate this.
            // Omit DTSTART if it's >= DUE to avoid server-side 415 errors.
            let shouldEmit = dueDate.map { start < $0 } ?? true
            if shouldEmit {
                if isStartDateOnly {
                    lines.append("DTSTART;VALUE=DATE:\(formatDateOnly(start))")
                } else {
                    lines.append("DTSTART:\(formatDate(start))")
                }
            }
        }


        if let completed = completedDate {
            lines.append("COMPLETED:\(formatDate(completed))")
        }

        if !categories.isEmpty {
            let escaped = categories.map { escapeText($0) }
            lines.append("CATEGORIES:\(escaped.joined(separator: ","))")
        }

        if let loc = location, !loc.isEmpty {
            lines.append("LOCATION:\(escapeText(loc))")
        }

        if let lat = latitude, let lon = longitude {
            lines.append("GEO:\(lat);\(lon)")
        }

        if let urlString = url, !urlString.isEmpty {
            lines.append("URL:\(urlString)")
        }

        if let parentUID = parentUID, !parentUID.isEmpty {
            lines.append("RELATED-TO;RELTYPE=PARENT:\(parentUID)")
        }

        if let rrule = recurrenceRule, !rrule.isEmpty {
            lines.append("RRULE:\(rrule)")
        }

        // X-APPLE-SORT-ORDER mirrors Nextcloud Tasks' manual ordering so
        // drag-reordering round-trips. Only emitted when a value is known,
        // to avoid overwriting the server's order on tasks we never reordered.
        if let manualSortOrder = manualSortOrder {
            lines.append("X-APPLE-SORT-ORDER:\(manualSortOrder)")
        }

        if let alarm = alarmTriggerSeconds {
            lines.append("BEGIN:VALARM")
            lines.append("TRIGGER;VALUE=DURATION:\(formatDuration(seconds: alarm))")
            lines.append("ACTION:DISPLAY")
            lines.append("DESCRIPTION:Reminder")
            lines.append("END:VALARM")
        }

        lines.append("END:VTODO")
        lines.append("END:VCALENDAR")

        // Apply line folding (RFC-5545 §3.1): lines > 75 octets
        let folded = lines.map { foldLine($0) }
        return folded.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Date Formatting

    /// Formats a Date to iCalendar UTC date-time: `YYYYMMDDTHHmmssZ`.
    static func formatDate(_ date: Date) -> String {
        return utcFormatter.string(from: date) + "Z"
    }

    // MARK: - Text Escaping (RFC-5545 §3.3.11)

    /// Escapes text for iCalendar property values.
    ///
    /// - Backslash → `\\`
    /// - Semicolon → `\;`
    /// - Comma → `\,`
    /// - Newline → `\n`
    static func escapeText(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: ";", with: "\\;")
        result = result.replacingOccurrences(of: ",", with: "\\,")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        result = result.replacingOccurrences(of: "\r", with: "")
        return result
    }

    // MARK: - Line Folding (RFC-5545 §3.1)

    /// Folds a line to comply with the 75-octet limit.
    ///
    /// Lines longer than 75 bytes are split with CRLF + space.
    static func foldLine(_ line: String) -> String {
        let maxOctets = 75
        let data = Data(line.utf8)

        guard data.count > maxOctets else { return line }

        var result = ""
        var currentByteCount = 0
        var isFirstLine = true

        for char in line {
            let charBytes = String(char).utf8.count
            let limit = isFirstLine ? maxOctets : (maxOctets - 1) // continuation lines have leading space

            if currentByteCount + charBytes > limit {
                result += "\r\n "
                currentByteCount = 1 // the leading space
                isFirstLine = false
            }

            result.append(char)
            currentByteCount += charBytes
        }

        return result
    }

    // MARK: - Formatter

    private static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Formats a Date to iCalendar date-only: `YYYYMMDD`.
    static func formatDateOnly(_ date: Date) -> String {
        return dateOnlyFormatter.string(from: date)
    }

    // MARK: - Duration Formatting

    /// Formats seconds to an iCalendar duration string (RFC-5545 §3.3.6).
    ///
    /// - 0 → `PT0S` (at due time)
    /// - 900 → `-PT15M`
    /// - 3600 → `-PT1H`
    /// - 86400 → `-P1D`
    /// - 5400 → `-PT1H30M`
    static func formatDuration(seconds: Int) -> String {
        if seconds == 0 { return "PT0S" }

        var remaining = seconds
        var parts = ""
        var hasDatePart = false

        let days = remaining / 86400
        if days > 0 {
            parts += "\(days)D"
            remaining %= 86400
            hasDatePart = true
        }

        var timeParts = ""
        let hours = remaining / 3600
        if hours > 0 {
            timeParts += "\(hours)H"
            remaining %= 3600
        }

        let minutes = remaining / 60
        if minutes > 0 {
            timeParts += "\(minutes)M"
            remaining %= 60
        }

        if remaining > 0 {
            timeParts += "\(remaining)S"
        }

        var result = "-P"
        if hasDatePart {
            result += parts
        }
        if !timeParts.isEmpty {
            result += "T\(timeParts)"
        }

        return result
    }
}
