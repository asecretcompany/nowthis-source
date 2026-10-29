import Foundation

/// Parses complete DAV multistatus documents. Properties are committed only
/// after their own propstat succeeds; response status and property status differ.
final class DAVXMLParser: NSObject, XMLParserDelegate {
    struct DAVResource {
        var href = ""
        var etag = ""
        var calendarData = ""
        var displayName = ""
        var ctag = ""
        var isCalendar = false
        var isVTODOSupported = false
        var calendarColor = ""
        var currentUserPrincipal = ""
        var calendarHomeSet = ""
        var syncToken = ""
        var deletedAt = ""
        var privileges: Set<String> = []
        var supportsSyncCollection = false
        var statusCode = 200
        var responseStatusCode: Int?
        /// Keys use expanded XML names so a foreign namespace cannot impersonate DAV.
        var propertyStatusCodes: [String: Int] = [:]
        var propstatStatusCodes: [Int] = []

        func propertyStatus(_ name: String, namespace: String = "DAV:") -> Int? {
            propertyStatusCodes["{\(namespace)}\(name)"]
        }
    }

    /// The report token is the direct child of multistatus, never a discovered property.
    private(set) var syncToken = ""
    private var resources: [DAVResource] = []
    private var resource: DAVResource?
    private var properties = DAVResource()
    private var propertyNames: Set<String> = []
    private var propstatStatus: Int?
    private var invalidStructure = false
    private var tokenCount = 0
    private var rootIsMultistatus = false

    private struct Element {
        let name: String
        let namespace: String
        var text = ""
        var key: String { "{\(namespace)}\(name)" }
    }
    private var elements: [Element] = []

    func parse(data: Data) throws -> [DAVResource] {
        let interval = PerformanceTrace.begin("DAVXML", bytes: data.count)
        defer { PerformanceTrace.end("DAVXML", interval) }
        resources = []
        resource = nil
        elements = []
        properties = DAVResource()
        propertyNames = []
        propstatStatus = nil
        invalidStructure = false
        tokenCount = 0
        syncToken = ""
        rootIsMultistatus = false
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), rootIsMultistatus, !invalidStructure else {
            throw CalDAVError.invalidResponse
        }
        return resources
    }

    func parseFirst(data: Data) throws -> DAVResource? {
        try parse(data: data).first
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String] = [:]) {
        let element = Element(name: elementName, namespace: namespaceURI ?? "")
        if elements.isEmpty {
            rootIsMultistatus = element.key == "{DAV:}multistatus"
        }
        let parent = elements.last?.key
        if element.key == "{DAV:}response" {
            if parent != "{DAV:}multistatus" || resource != nil { invalidStructure = true }
            resource = DAVResource()
        } else if element.key == "{DAV:}propstat" {
            if parent != "{DAV:}response" { invalidStructure = true }
            properties = DAVResource()
            propertyNames = []
            propstatStatus = nil
        }
        if parent == "{DAV:}prop" { propertyNames.insert(element.key) }
        let ancestors = elements.map(\.key)
        if ancestors.contains("{DAV:}prop") {
            if element.key == "{urn:ietf:params:xml:ns:caldav}comp",
               ancestors.contains("{urn:ietf:params:xml:ns:caldav}supported-calendar-component-set"),
               attributes["name"]?.uppercased() == "VTODO" {
                properties.isVTODOSupported = true
            }
            if ["{urn:ietf:params:xml:ns:caldav}calendar", "{urn:ietf:params:xml:ns:caldav}vevent-collection"].contains(element.key),
               ancestors.contains("{DAV:}resourcetype") { properties.isCalendar = true }
            if parent == "{DAV:}privilege", ancestors.contains("{DAV:}current-user-privilege-set"), element.namespace == "DAV:" {
                properties.privileges.insert(element.name)
            }
            if element.key == "{DAV:}sync-collection", parent == "{DAV:}report",
               ancestors.contains("{DAV:}supported-report-set") {
                properties.supportsSyncCollection = true
            }
        }
        elements.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard let element = elements.popLast() else { invalidStructure = true; return }
        let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = elements.last?.key
        switch element.key {
        case "{DAV:}href":
            if parent == "{DAV:}response" {
                if resource?.href.isEmpty == false { invalidStructure = true }
                resource?.href = text
            } else if parent == "{DAV:}current-user-principal" {
                properties.currentUserPrincipal = text
            } else if parent == "{urn:ietf:params:xml:ns:caldav}calendar-home-set" {
                properties.calendarHomeSet = text
            }
        case "{DAV:}status":
            let parts = text.split(whereSeparator: \.isWhitespace)
            let code = parts.count >= 2 && parts[0].hasPrefix("HTTP/") ? Int(parts[1]) : nil
            if parent == "{DAV:}propstat" {
                if propstatStatus != nil { invalidStructure = true }
                propstatStatus = code
            } else if parent == "{DAV:}response" {
                if resource?.responseStatusCode != nil { invalidStructure = true }
                resource?.responseStatusCode = code
            }
            if code == nil { invalidStructure = true }
        case "{DAV:}sync-token" where parent == "{DAV:}multistatus":
            tokenCount += 1
            if tokenCount > 1 { invalidStructure = true }
            syncToken = text
        case "{DAV:}propstat":
            // Legacy parse callers accept an omitted status. Strict REPORT accounting
            // uses propertyStatusCodes and rejects that unspecified status (zero).
            let code = propstatStatus ?? 0
            resource?.propstatStatusCodes.append(code)
            for name in propertyNames where resource?.propertyStatusCodes[name] != 200 {
                resource?.propertyStatusCodes[name] = code
            }
            if code == 0 || (200..<300).contains(code) { mergeProperties() }
        case "{DAV:}response":
            if var found = resource {
                found.statusCode = found.responseStatusCode
                    ?? (found.propstatStatusCodes.contains(where: { (200..<300).contains($0) }) ? 200 : found.propstatStatusCodes.first ?? 200)
                resources.append(found)
            }
            resource = nil
        default:
            if parent == "{DAV:}prop" {
                switch element.key {
                case "{DAV:}getetag": properties.etag = text.replacingOccurrences(of: "\"", with: "")
                case "{urn:ietf:params:xml:ns:caldav}calendar-data": properties.calendarData = text
                case "{DAV:}displayname": properties.displayName = text
                case "{http://calendarserver.org/ns/}getctag": properties.ctag = text
                case "{http://apple.com/ns/ical/}calendar-color": properties.calendarColor = text
                case "{DAV:}sync-token": properties.syncToken = text
                case "{http://nextcloud.com/ns}deleted-at": properties.deletedAt = text
                default: break
                }
            }
        }
    }

    private func mergeProperties() {
        guard var found = resource else { return }
        for key in propertyNames {
            switch key {
            case "{DAV:}getetag": found.etag = properties.etag
            case "{urn:ietf:params:xml:ns:caldav}calendar-data": found.calendarData = properties.calendarData
            case "{DAV:}displayname": found.displayName = properties.displayName
            case "{http://calendarserver.org/ns/}getctag": found.ctag = properties.ctag
            case "{DAV:}resourcetype": found.isCalendar = properties.isCalendar
            case "{urn:ietf:params:xml:ns:caldav}supported-calendar-component-set": found.isVTODOSupported = properties.isVTODOSupported
            case "{http://apple.com/ns/ical/}calendar-color": found.calendarColor = properties.calendarColor
            case "{DAV:}current-user-principal": found.currentUserPrincipal = properties.currentUserPrincipal
            case "{urn:ietf:params:xml:ns:caldav}calendar-home-set": found.calendarHomeSet = properties.calendarHomeSet
            case "{DAV:}sync-token": found.syncToken = properties.syncToken
            case "{http://nextcloud.com/ns}deleted-at": found.deletedAt = properties.deletedAt
            case "{DAV:}current-user-privilege-set": found.privileges = properties.privileges
            case "{DAV:}supported-report-set": found.supportsSyncCollection = properties.supportsSyncCollection
            default: break
            }
        }
        resource = found
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !elements.isEmpty { elements[elements.count - 1].text += string }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { invalidStructure = true; return }
        self.parser(parser, foundCharacters: text)
    }

    /// Only a DAV error precondition qualifies a 403 as an expired token.
    static func isInvalidSyncTokenError(_ data: Data) -> Bool {
        let delegate = SyncTokenErrorParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        return parser.parse() && delegate.found
    }
}

private final class SyncTokenErrorParser: NSObject, XMLParserDelegate {
    private var path: [String] = []
    var found = false
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        path.append("{\(namespaceURI ?? "")}\(elementName)")
        if path == ["{DAV:}error", "{DAV:}valid-sync-token"] { found = true }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) { path.removeLast() }
}
