import Foundation

/// Bespoke iCalendar parser for VTODO and VJOURNAL components (RFC-5545).
///
/// Parses raw `.ics` text into structured `VTODOData` records without
/// any third-party dependencies. Handles line unfolding, property parameters,
/// and multi-valued properties (e.g., CATEGORIES).
///
/// **Supported VTODO properties:**
/// UID, SUMMARY, DESCRIPTION, STATUS, PRIORITY, PERCENT-COMPLETE,
/// DUE, DTSTART, COMPLETED, CREATED, LAST-MODIFIED, CATEGORIES,
/// LOCATION, GEO, URL, RELATED-TO, RRULE, X-APPLE-SORT-ORDER
struct ICalendarParser {

    /// A parser-worker-owned cache of formatters for named timezone date-times.
    /// Formatting access is serialized; formatter instances never escape.
    final class FormatterCache: @unchecked Sendable {
        static let capacity = 32

        private let lock = NSLock()
        private var formatters: [String: DateFormatter] = [:]
        private var leastRecentlyUsedFirst: [String] = []
        private var creationCount = 0

        var cachedNamedTimeZoneFormatterCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return formatters.count
        }

        var namedTimeZoneFormatterCreationCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return creationCount
        }

        fileprivate func date(from value: String, in timeZone: TimeZone) -> Date? {
            lock.lock()
            defer { lock.unlock() }

            let identifier = timeZone.identifier
            let formatter: DateFormatter
            if let cached = formatters[identifier] {
                formatter = cached
                leastRecentlyUsedFirst.removeAll { $0 == identifier }
                leastRecentlyUsedFirst.append(identifier)
            } else {
                if formatters.count == Self.capacity,
                   let evictedIdentifier = leastRecentlyUsedFirst.first {
                    leastRecentlyUsedFirst.removeFirst()
                    formatters.removeValue(forKey: evictedIdentifier)
                }

                formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd'T'HHmmss"
                formatter.timeZone = timeZone
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatters[identifier] = formatter
                leastRecentlyUsedFirst.append(identifier)
                creationCount += 1
            }

            return formatter.date(from: value)
        }
    }

    // MARK: - Data Structures

    /// Parsed VTODO data extracted from an iCalendar component.
    struct VTODOData: Sendable {
        var uid: String = ""
        var summary: String = ""
        var description: String?
        var photos: [TaskPhotoAttachment] = []
        var opaqueAttachments: [String] = []
        var status: String?
        var priority: Int = 0
        var percentComplete: Int = 0
        var dueDate: Date?
        var startDate: Date?
        var completedDate: Date?
        var createdDate: Date?
        var lastModifiedDate: Date?
        /// `nil` when the VTODO carried no `CATEGORIES` property at all, `[]`
        /// when it carried an empty one. The distinction is load-bearing:
        /// silence is not a claim that the task has no categories, and treating
        /// it as one deletes the user's tags and then pushes the deletion.
        var categories: [String]?
        var location: String?
        var latitude: Double?
        var longitude: Double?
        var url: String?
        var parentUID: String?
        var recurrenceRule: String?
        var alarmTriggerSeconds: Int?
        var isDueDateOnly: Bool = false
        var isStartDateOnly: Bool = false
        /// X-APPLE-SORT-ORDER — manual sort position. Nil when the property
        /// is absent, so round-trips can avoid clobbering the server's order.
        var manualSortOrder: Int?
    }

    // MARK: - Public API

    /// Parses an iCalendar string and extracts all VTODO components.
    ///
    /// - Parameter icsString: Raw iCalendar text content.
    /// - Returns: An array of parsed `VTODOData` records.
    /// - Throws: `ParserError.invalidFormat` if the content is not valid iCalendar.
    static func parseVTODOs(from icsString: String) throws -> [VTODOData] {
        try parseVTODOs(from: icsString, using: FormatterCache())
    }

    /// Parses VTODOs using a cache owned by the calling parser worker.
    /// Reuse `formatterCache` across resources handled by that worker.
    static func parseVTODOs(from icsString: String, using formatterCache: FormatterCache) throws -> [VTODOData] {
        let unfolded = unfoldLines(icsString)
        let lines = unfolded.components(separatedBy: .newlines)

        var todos: [VTODOData] = []
        var currentTodo: VTODOData?
        var inVTODO = false
        var inVALARM = false
        var alarmTrigger: String?
        var alarmParsed = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed == "BEGIN:VTODO" {
                inVTODO = true
                inVALARM = false
                alarmParsed = false
                alarmTrigger = nil
                currentTodo = VTODOData()
                continue
            }

            if trimmed == "END:VTODO" {
                if let todo = currentTodo, !todo.uid.isEmpty {
                    todos.append(todo)
                }
                inVTODO = false
                inVALARM = false
                currentTodo = nil
                continue
            }

            // Handle nested VALARM component
            if inVTODO && trimmed == "BEGIN:VALARM" {
                inVALARM = true
                alarmTrigger = nil
                continue
            }

            if inVALARM && trimmed == "END:VALARM" {
                // Keep the first usable alarm. Malformed or unsupported triggers
                // must not suppress a later reminder we can actually schedule.
                if !alarmParsed, let trigger = alarmTrigger,
                   let seconds = parseDurationToSeconds(trigger) {
                    currentTodo?.alarmTriggerSeconds = seconds
                    alarmParsed = true
                }
                inVALARM = false
                continue
            }

            if inVALARM {
                // Parse VALARM properties (only TRIGGER needed)
                let (name, value) = splitProperty(trimmed)
                if name == "TRIGGER" {
                    alarmTrigger = value
                }
                continue
            }

            if inVTODO, var todo = currentTodo {
                if splitProperty(trimmed).name == "ATTACH" {
                    if let photo = try TaskPhotoAttachment.decode(trimmed) {
                        guard !todo.photos.contains(where: { $0.id == photo.id }) else {
                            throw TaskPhotoAttachmentError.duplicateIdentity
                        }
                        guard todo.photos.count < 5 else { throw TaskPhotoAttachmentError.invalid }
                        todo.photos.append(photo)
                    } else {
                        todo.opaqueAttachments.append(trimmed)
                    }
                }
                parseTodoProperty(line: trimmed, into: &todo, formatterCache: formatterCache)
                currentTodo = todo
            }
        }

        return todos
    }

    /// Convenience: parse a single VTODO from an .ics file.
    ///
    /// - Parameter icsString: Raw iCalendar text containing exactly one VTODO.
    /// - Returns: The parsed `VTODOData`, or `nil` if none found.
    static func parseSingleVTODO(from icsString: String) throws -> VTODOData? {
        try parseSingleVTODO(from: icsString, using: FormatterCache())
    }

    /// Parses one VTODO using a cache owned by the calling parser worker.
    static func parseSingleVTODO(from icsString: String, using formatterCache: FormatterCache) throws -> VTODOData? {
        let todos = try parseVTODOs(from: icsString, using: formatterCache)
        return todos.first
    }

    // MARK: - VJOURNAL Parsing

    /// Parsed VJOURNAL data extracted from an iCalendar component.
    struct VJOURNALData {
        var uid: String = ""
        var summary: String = ""
        var description: String?
        var createdDate: Date?
        var lastModifiedDate: Date?
        var relatedUIDs: [String] = []
    }

    /// Parses an iCalendar string and extracts all VJOURNAL components.
    ///
    /// - Parameter icsString: Raw iCalendar text content.
    /// - Returns: An array of parsed `VJOURNALData` records.
    static func parseVJOURNALs(from icsString: String) -> [VJOURNALData] {
        let unfolded = unfoldLines(icsString)
        let lines = unfolded.components(separatedBy: .newlines)

        var journals: [VJOURNALData] = []
        var current: VJOURNALData?
        var inJournal = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "BEGIN:VJOURNAL" {
                inJournal = true
                current = VJOURNALData()
            } else if trimmed == "END:VJOURNAL" {
                if let journal = current {
                    journals.append(journal)
                }
                inJournal = false
                current = nil
            } else if inJournal, current != nil {
                parseJournalProperty(line: trimmed, into: &current!)
            }
        }
        return journals
    }

    /// Parses a single VJOURNAL property line into a `VJOURNALData` record.
    private static func parseJournalProperty(line: String, into journal: inout VJOURNALData) {
        guard let colonIndex = line.firstIndex(of: ":") else { return }
        let propertyPart = String(line[line.startIndex..<colonIndex]).uppercased()
        let value = String(line[line.index(after: colonIndex)...])
        let unescaped = unescapeText(value)

        // Strip parameters (e.g., "RELATED-TO;RELTYPE=PARENT" → "RELATED-TO")
        let property = propertyPart.components(separatedBy: ";").first ?? propertyPart

        switch property {
        case "UID": journal.uid = unescaped
        case "SUMMARY": journal.summary = unescaped
        case "DESCRIPTION": journal.description = unescaped
        case "CREATED": journal.createdDate = parseDate(value)
        case "LAST-MODIFIED": journal.lastModifiedDate = parseDate(value)
        case "RELATED-TO": journal.relatedUIDs.append(unescaped)
        default: break
        }
    }

    // MARK: - Line Unfolding (RFC-5545 §3.1)

    /// Unfolds long lines per RFC-5545.
    ///
    /// iCalendar allows lines to be folded by inserting a CRLF followed by
    /// a single whitespace character (space or tab). This function reverses that.
    static func unfoldLines(_ input: String) -> String {
        // Normalize line endings to \n first
        let normalized = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Unfold: a newline followed by a space or tab is a continuation
        return normalized
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
    }

    // MARK: - Property Parsing

    /// Parses a single property line and updates the VTODO data.
    private static func parseTodoProperty(
        line: String,
        into todo: inout VTODOData,
        formatterCache: FormatterCache
    ) {
        let (name, value) = splitProperty(line)

        switch name {
        case "UID":
            todo.uid = value
        case "SUMMARY":
            todo.summary = unescapeText(value)
        case "DESCRIPTION":
            todo.description = unescapeText(value)
        case "STATUS":
            todo.status = value.uppercased()
        case "PRIORITY":
            todo.priority = Int(value) ?? 0
        case "PERCENT-COMPLETE":
            todo.percentComplete = min(100, max(0, Int(value) ?? 0))
        case "DUE":
            todo.dueDate = parseDate(value, tzid: parseTZID(from: line), formatterCache: formatterCache)
            todo.isDueDateOnly = !value.contains("T")
        case "DTSTART":
            todo.startDate = parseDate(value, tzid: parseTZID(from: line), formatterCache: formatterCache)
            todo.isStartDateOnly = !value.contains("T")
        case "COMPLETED":
            todo.completedDate = parseDate(value, tzid: parseTZID(from: line), formatterCache: formatterCache)
        case "CREATED":
            todo.createdDate = parseDate(value)
        case "LAST-MODIFIED":
            todo.lastModifiedDate = parseDate(value)
        case "CATEGORIES":
            // Split only at the commas between values, then unescape each one: a
            // comma inside a category arrives as `\,` (RFC 5545 §3.3.11), from
            // Thunderbird and from our own serializer alike.
            let cats = splitAtUnescapedCommas(value)
                .map { unescapeText($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // Seed on first sight, so a bare `CATEGORIES:` survives as [] rather
            // than nil. Presence is the signal; the content is the instruction.
            todo.categories = (todo.categories ?? []) + cats
        case "LOCATION":
            todo.location = unescapeText(value)
        case "GEO":
            let parts = value.components(separatedBy: ";")
            if parts.count == 2 {
                todo.latitude = Double(parts[0])
                todo.longitude = Double(parts[1])
            }
        case "URL":
            todo.url = value
        case "RELATED-TO":
            // Check for RELTYPE=PARENT parameter
            if line.uppercased().contains("RELTYPE=PARENT") || !line.contains("RELTYPE") {
                todo.parentUID = value
            }
        case "RRULE":
            todo.recurrenceRule = value
        case "X-APPLE-SORT-ORDER":
            todo.manualSortOrder = Int(value.trimmingCharacters(in: .whitespaces))
        default:
            break // Ignore unknown properties
        }
    }

    /// Splits a property line into name and value, handling parameters.
    ///
    /// Example: `DTSTART;VALUE=DATE:20240101` → name="DTSTART", value="20240101"
    ///          `SUMMARY:My Task` → name="SUMMARY", value="My Task"
    static func splitProperty(_ line: String) -> (name: String, value: String) {
        // Find the first colon that isn't inside a quoted parameter value
        guard let colonIndex = findPropertyColon(in: line) else {
            return ("", line)
        }

        let namePart = String(line[line.startIndex..<colonIndex])
        let value = String(line[line.index(after: colonIndex)...])

        // Extract just the property name (before any ;parameters)
        let name: String
        if let semicolonIndex = namePart.firstIndex(of: ";") {
            name = String(namePart[namePart.startIndex..<semicolonIndex])
        } else {
            name = namePart
        }

        return (name.uppercased(), value)
    }

    /// Finds the colon that separates the property name/params from the value.
    private static func findPropertyColon(in line: String) -> String.Index? {
        var inQuotes = false
        for index in line.indices {
            let char = line[index]
            if char == "\"" {
                inQuotes.toggle()
            } else if char == ":" && !inQuotes {
                return index
            }
        }
        return nil
    }

    /// Splits a multi-valued TEXT property at the commas that separate its
    /// values. Escapes are kept for `unescapeText`, so `\,` stays inside its
    /// value and `\\,` is an escaped backslash followed by a separator.
    private static func splitAtUnescapedCommas(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaping = false
        for char in value {
            if escaping {
                current.append(char)
                escaping = false
            } else if char == "\\" {
                current.append(char)
                escaping = true
            } else if char == "," {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        parts.append(current)
        return parts
    }

    // MARK: - Date Parsing

    /// Parses an iCalendar date or date-time string.
    ///
    /// Supports:
    /// - `YYYYMMDD` (DATE)
    /// - `YYYYMMDDTHHmmss` (DATE-TIME local / floating)
    /// - `YYYYMMDDTHHmmssZ` (DATE-TIME UTC)
    /// - `YYYYMMDDTHHmmss` with a `tzid` (DATE-TIME in a named timezone)
    ///
    /// - Parameters:
    ///   - value: The raw value portion (after the colon).
    ///   - tzid: The IANA timezone identifier from a `TZID=` parameter, if present.
    ///     When supplied, a date-time without a `Z` suffix is interpreted in that
    ///     zone rather than as floating local time.
    static func parseDate(_ value: String, tzid: String? = nil) -> Date? {
        parseDate(value, tzid: tzid, formatterCache: nil)
    }

    private static func parseDate(
        _ value: String,
        tzid: String?,
        formatterCache: FormatterCache?
    ) -> Date? {
        let cleanValue = value.trimmingCharacters(in: .whitespaces)

        // Try UTC format first: 20240115T120000Z
        if cleanValue.hasSuffix("Z") {
            let stripped = String(cleanValue.dropLast())
            return dateTimeFormatter.date(from: stripped)
        }

        // Date-time with an explicit TZID parameter → interpret in that zone.
        if cleanValue.contains("T"),
           let tzid = tzid,
           let timeZone = TimeZone(identifier: tzid) {
            return (formatterCache ?? FormatterCache()).date(from: cleanValue, in: timeZone)
        }

        // Floating local date-time: 20240115T120000
        // Per RFC-5545, date-times without Z or TZID are in local time.
        if cleanValue.contains("T") {
            return localDateTimeFormatter.date(from: cleanValue)
        }

        // Date-only: 20240115 — stored as midnight UTC representing a whole
        // calendar day (interpreted to the local day via DueDateHelper).
        return dateFormatter.date(from: cleanValue)
    }

    /// Extracts the `TZID` parameter from a property line, if present.
    ///
    /// Example: `DTSTART;TZID=Europe/Berlin:20240115T140000` → `"Europe/Berlin"`.
    /// The parameter name is matched case-insensitively and a quoted value is unquoted.
    static func parseTZID(from line: String) -> String? {
        guard let colonIndex = findPropertyColon(in: line) else { return nil }
        let namePart = line[line.startIndex..<colonIndex]

        // Skip the property name; inspect each ';'-separated parameter.
        for param in namePart.split(separator: ";").dropFirst() {
            guard let eqIndex = param.firstIndex(of: "=") else { continue }
            let key = param[param.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            guard key.uppercased() == "TZID" else { continue }

            var value = String(param[param.index(after: eqIndex)...])
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - Text Escaping (RFC-5545 §3.3.11)

    /// Unescapes iCalendar text values.
    ///
    /// Reverses the escaping rules:
    /// - `\\n` or `\\N` → newline
    /// - `\\,` → comma
    /// - `\\;` → semicolon
    /// - `\\\\` → backslash
    static func unescapeText(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()

        while let char = iterator.next() {
            if char == "\\" {
                if let next = iterator.next() {
                    switch next {
                    case "n", "N":
                        result.append("\n")
                    case ",":
                        result.append(",")
                    case ";":
                        result.append(";")
                    case "\\":
                        result.append("\\")
                    default:
                        result.append(char)
                        result.append(next)
                    }
                } else {
                    result.append(char)
                }
            } else {
                result.append(char)
            }
        }

        return result
    }

    // MARK: - Formatters

    /// UTC date-time formatter — for values with Z suffix.
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Local date-time formatter — for values without Z suffix.
    /// Per RFC-5545 §3.3.5, date-times without a Z suffix or TZID
    /// parameter represent "floating" local time.
    private static let localDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Duration Parsing

    /// Parses an iCalendar duration string (RFC-5545 §3.3.6) to seconds.
    ///
    /// Examples:
    /// - `-PT15M` → 900
    /// - `-PT1H` → 3600
    /// - `-P1D` → 86400
    /// - `PT0S` → 0
    ///
    /// The sign is stripped — all values are returned as positive seconds
    /// representing "time before the due date".
    static func parseDurationToSeconds(_ duration: String) -> Int? {
        var input = duration.trimmingCharacters(in: .whitespaces)
        // RFC 5545 duration grammar: weeks stand alone, days can precede a
        // time part, and time components occur once in descending order.
        // Validate before conversion so a partial duration cannot become zero.
        let pattern = #"^[+-]?P(?:(?:[0-9]+D)?T(?:[0-9]+H(?:[0-9]+M(?:[0-9]+S)?)?|[0-9]+M(?:[0-9]+S)?|[0-9]+S)|[0-9]+[DW])$"#
        guard input.range(of: pattern, options: .regularExpression) != nil else { return nil }

        // Strip optional sign
        if input.hasPrefix("-") || input.hasPrefix("+") {
            input = String(input.dropFirst())
        }

        // Must start with P
        guard input.hasPrefix("P") else { return nil }
        input = String(input.dropFirst())

        var total = 0
        var inTimePart = false
        var numberBuffer = ""

        for char in input {
            if char == "T" {
                inTimePart = true
                continue
            }

            if char.isNumber {
                numberBuffer.append(char)
                continue
            }

            guard let value = Int(numberBuffer), !numberBuffer.isEmpty else {
                return nil
            }
            numberBuffer = ""

            let multiplier: Int
            switch (char, inTimePart) {
            case ("D", false): multiplier = 86400
            case ("W", false): multiplier = 604800
            case ("H", true):  multiplier = 3600
            case ("M", true):  multiplier = 60
            case ("S", true):  multiplier = 1
            default: return nil
            }
            // Calendar data is untrusted. A large component or combined
            // duration must fail parsing rather than trap the entire sync.
            let component = value.multipliedReportingOverflow(by: multiplier)
            guard !component.overflow else { return nil }
            let sum = total.addingReportingOverflow(component.partialValue)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }

        return total
    }
}
