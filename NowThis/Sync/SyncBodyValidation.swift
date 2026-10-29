import Foundation

/// Validates resource completeness before allowing import or checkpoint accounting.
enum SyncBodyValidation {
    /// Non-task calendars return a nil todo while preserving their accounting metadata.
    /// A VTODO that cannot be parsed is an invalid response, never a non-task receipt.
    static func parse(
        _ resource: CalDAVClient.RemoteTask,
        using formatterCache: ICalendarParser.FormatterCache
    ) throws -> ParsedRemoteTask {
        let unfolded = ICalendarParser.unfoldLines(resource.icsData)
        var components: [String] = []
        var root: String?
        var hasCalendarComponent = false
        var hasTodo = false

        for rawLine in unfolded.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("BEGIN:") {
                let component = String(line.dropFirst("BEGIN:".count))
                guard isName(component) else { throw CalDAVError.invalidResponse }
                if components.isEmpty {
                    // Bare VTODOs are supported by the parser and existing fixtures.
                    guard root == nil, component == "VCALENDAR" || component == "VTODO" else {
                        throw CalDAVError.invalidResponse
                    }
                    root = component
                } else {
                    guard component != "VCALENDAR",
                          component != "VTODO" || components == ["VCALENDAR"] else {
                        throw CalDAVError.invalidResponse
                    }
                    if components == ["VCALENDAR"] {
                        hasCalendarComponent = true
                    }
                }
                hasTodo = hasTodo || component == "VTODO"
                components.append(component)
            } else if line.hasPrefix("END:") {
                let component = String(line.dropFirst("END:".count))
                guard components.last == component else { throw CalDAVError.invalidResponse }
                components.removeLast()
            } else {
                let (name, _) = ICalendarParser.splitProperty(line)
                guard !components.isEmpty, isName(name), name != "BEGIN", name != "END" else {
                    throw CalDAVError.invalidResponse
                }
            }
        }

        guard components.isEmpty, root != nil,
              root == "VTODO" || hasCalendarComponent else {
            throw CalDAVError.invalidResponse
        }

        // The structural scan does not parse UIDs, dates or task properties. Parse
        // the task once with the worker's cache, after checking every component end.
        let todo = try ICalendarParser.parseSingleVTODO(from: unfolded, using: formatterCache)
        guard !hasTodo || todo != nil else { throw CalDAVError.invalidResponse }
        return ParsedRemoteTask(href: resource.href, etag: resource.etag, todo: todo)
    }

    private static func isName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }
    }
}
