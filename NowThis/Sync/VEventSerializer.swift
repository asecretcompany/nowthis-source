import Foundation

/// Generates RFC-5545 VEVENT `.ics` content from a `TaskItem`.
///
/// Used by both `AppleCalendarSyncManager` (for event data) and
/// `NextcloudCalendarSyncManager` (for CalDAV PUT body).
///
/// The VEVENT is linked to the original VTODO via `RELATED-TO`.
/// A 30-minute default duration is used when no explicit end time is available.
///
/// **RFC-5545 References:**
/// - VEVENT: §3.6.1
/// - DTSTART/DTEND: §3.8.2.4 / §3.8.2.2
/// - RELATED-TO: §3.8.4.5
/// - STATUS: §3.8.1.11 (CONFIRMED / CANCELLED / TENTATIVE)
enum VEventSerializer {

    /// Default event duration when only a due date (no start date) is available.
    private static let defaultDurationMinutes = 30

    /// Generates a VEVENT `.ics` string for the given task.
    ///
    /// - Parameters:
    ///   - task: The `TaskItem` to convert.
    ///   - eventUID: The UID for the VEVENT (typically `{task.uid}-event`).
    /// - Returns: A complete `.ics` file content string, or `nil` if the task has no due date.
    static func serialize(task: TaskItem, eventUID: String) -> String? {
        guard let dueDate = task.dueDate else { return nil }

        let startDate = task.startDate ?? dueDate
        let endDate = Calendar.current.date(
            byAdding: .minute,
            value: defaultDurationMinutes,
            to: startDate
        ) ?? startDate

        let now = Date()
        let status = veventStatus(for: task)
        let summary = veventSummary(for: task)

        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//NowThis//iOS//EN",
            "BEGIN:VEVENT",
            "UID:\(eventUID)",
            "DTSTAMP:\(formatDate(now))",
            "DTSTART:\(formatDate(startDate))",
            "DTEND:\(formatDate(endDate))",
            "SUMMARY:\(escapeICSText(summary))",
            "STATUS:\(status)",
            "RELATED-TO:\(task.uid)",
        ]

        // Optional description
        if let desc = task.descriptionText, !desc.isEmpty {
            lines.append("DESCRIPTION:\(escapeICSText(desc))")
        }

        // Priority mapping (RFC-5545 PRIORITY for VEVENT)
        if task.priority != .none {
            lines.append("PRIORITY:\(task.priority.rawValue)")
        }

        // Location
        if let location = task.locationName, !location.isEmpty {
            lines.append("LOCATION:\(escapeICSText(location))")
        }

        // URL
        if let url = task.url, !url.isEmpty {
            lines.append("URL:\(url)")
        }

        lines.append(contentsOf: [
            "END:VEVENT",
            "END:VCALENDAR"
        ])

        return lines.joined(separator: "\r\n")
    }

    // MARK: - Private Helpers

    /// Maps task status to VEVENT STATUS values.
    ///
    /// - CONFIRMED: active task
    /// - CANCELLED: completed or cancelled task
    private static func veventStatus(for task: TaskItem) -> String {
        switch task.status {
        case .completed, .cancelled:
            return "CANCELLED"
        case .needsAction, .inProcess:
            return "CONFIRMED"
        }
    }

    /// Generates the VEVENT SUMMARY, prefixing with ✓ for completed tasks.
    private static func veventSummary(for task: TaskItem) -> String {
        if task.status == .completed {
            return "✓ \(task.title)"
        }
        return task.title
    }

    private static let utcDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Formats a `Date` to iCalendar UTC datetime format (yyyyMMdd'T'HHmmss'Z').
    private static func formatDate(_ date: Date) -> String {
        utcDateTimeFormatter.string(from: date)
    }

    /// Escapes text for iCalendar property values per RFC-5545 §3.3.11.
    ///
    /// - Backslash-escapes: `\`, `;`, `,`
    /// - Newlines replaced with `\n` literal
    private static func escapeICSText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
