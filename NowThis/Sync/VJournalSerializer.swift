import Foundation

/// Serializes `JournalEntry` to RFC-5545 VJOURNAL `.ics` format.
///
/// Generates a complete `.ics` file suitable for PUT to a CalDAV server.
/// Uses `ICalendarSerializer` utilities for date formatting, text escaping,
/// and line folding.
///
/// **RFC-5545 References:**
/// - VJOURNAL: §3.6.3
/// - SUMMARY: §3.8.1.12
/// - DESCRIPTION: §3.8.1.5
/// - RELATED-TO: §3.8.4.5
enum VJournalSerializer {

    /// Serializes a journal entry to a VJOURNAL `.ics` string.
    ///
    /// - Parameters:
    ///   - entry: The journal entry to serialize.
    ///   - relatedTaskUIDs: UIDs of linked VTODO tasks (emitted as RELATED-TO properties).
    /// - Returns: A complete `.ics` file string.
    static func serialize(entry: JournalEntry, relatedTaskUIDs: [String] = []) -> String {
        return ICalendarSerializer.serialize(
            component: "VJOURNAL",
            uid: entry.uid,
            summary: entry.title,
            description: entry.content.isEmpty ? nil : entry.content,
            createdDate: entry.createdDate,
            lastModifiedDate: entry.lastModifiedDate,
            relatedUIDs: relatedTaskUIDs
        )
    }
}

// MARK: - ICalendarSerializer VJOURNAL Extension

extension ICalendarSerializer {

    /// Serializes a generic iCalendar component (VTODO, VJOURNAL, etc.).
    ///
    /// This overload supports custom component types beyond VTODO.
    static func serialize(
        component: String,
        uid: String,
        summary: String,
        description: String? = nil,
        createdDate: Date = Date(),
        lastModifiedDate: Date = Date(),
        relatedUIDs: [String] = []
    ) -> String {
        var lines: [String] = []

        lines.append("BEGIN:VCALENDAR")
        lines.append("VERSION:2.0")
        lines.append("PRODID:-//NowThis//NowThis iOS//EN")
        lines.append("BEGIN:\(component)")

        lines.append("UID:\(uid)")
        lines.append("DTSTAMP:\(formatDate(Date()))")
        lines.append("CREATED:\(formatDate(createdDate))")
        lines.append("LAST-MODIFIED:\(formatDate(lastModifiedDate))")
        lines.append("SUMMARY:\(escapeText(summary))")

        if let desc = description, !desc.isEmpty {
            lines.append("DESCRIPTION:\(escapeText(desc))")
        }

        for relatedUID in relatedUIDs {
            lines.append("RELATED-TO:\(relatedUID)")
        }

        lines.append("END:\(component)")
        lines.append("END:VCALENDAR")

        let folded = lines.map { foldLine($0) }
        return folded.joined(separator: "\r\n") + "\r\n"
    }
}
