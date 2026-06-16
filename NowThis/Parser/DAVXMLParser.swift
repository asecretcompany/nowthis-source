import Foundation

/// Parses WebDAV/CalDAV XML responses (PROPFIND, REPORT).
///
/// Uses Foundation's `XMLParser` (SAX-style) to extract relevant data
/// from CalDAV PROPFIND multi-status responses and calendar-multiget
/// REPORT responses. Zero third-party dependencies.
final class DAVXMLParser: NSObject, XMLParserDelegate {

    // MARK: - Parsed Output Types

    /// A single resource from a DAV multi-status response.
    struct DAVResource {
        var href: String = ""
        var etag: String = ""
        var calendarData: String = ""
        var displayName: String = ""
        var ctag: String = ""
        var isCalendar: Bool = false
        var isVTODOSupported: Bool = false
        var calendarColor: String = ""
        var currentUserPrincipal: String = ""
        var calendarHomeSet: String = ""
        var syncToken: String = ""
        var statusCode: Int = 200
    }

    // MARK: - State

    private var resources: [DAVResource] = []
    private var currentResource: DAVResource?
    private var currentElement = ""
    private var currentText = ""
    private var inResponse = false
    private var inProp = false
    private var inSupportedCalendarComponentSet = false

    // MARK: - Public API

    /// Parses a CalDAV XML response body.
    ///
    /// - Parameter data: Raw XML data from the server.
    /// - Returns: Array of parsed `DAVResource` entries.
    func parse(data: Data) -> [DAVResource] {
        resources = []
        currentResource = nil
        currentElement = ""
        currentText = ""
        inResponse = false
        inProp = false

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.parse()

        return resources
    }

    /// Convenience: parse and return the first resource.
    func parseFirst(data: Data) -> DAVResource? {
        return parse(data: data).first
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        currentElement = localName
        currentText = ""

        switch localName {
        case "response":
            inResponse = true
            currentResource = DAVResource()
        case "prop":
            inProp = true
        case "supported-calendar-component-set":
            inSupportedCalendarComponentSet = true
        case "comp":
            if inSupportedCalendarComponentSet {
                let compName = attributes["name"] ?? ""
                if compName.uppercased() == "VTODO" {
                    currentResource?.isVTODOSupported = true
                }
            }
        case "calendar", "vevent-collection":
            if inProp {
                currentResource?.isCalendar = true
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch localName {
        case "response":
            if let resource = currentResource {
                // Ensure we store the resource
                resources.append(resource)
            }
            currentResource = nil
            inResponse = false

        case "href":
            if inResponse {
                currentResource?.href = trimmed
            }

        case "getetag":
            currentResource?.etag = trimmed
                .replacingOccurrences(of: "\"", with: "")

        case "calendar-data":
            currentResource?.calendarData = trimmed

        case "displayname":
            currentResource?.displayName = trimmed

        case "getctag":
            currentResource?.ctag = trimmed

        case "calendar-color":
            currentResource?.calendarColor = trimmed

        case "current-user-principal":
            // The href is nested, handled via href in the principal context
            break

        case "calendar-home-set":
            break

        case "sync-token":
            currentResource?.syncToken = trimmed

        case "status":
            // Parse status line like "HTTP/1.1 200 OK"
            let parts = trimmed.components(separatedBy: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                currentResource?.statusCode = code
            }

        case "prop":
            inProp = false

        case "supported-calendar-component-set":
            inSupportedCalendarComponentSet = false

        default:
            break
        }

        // Special: handle nested href inside current-user-principal or calendar-home-set
        if localName == "href" && !inResponse {
            // This could be the user principal or calendar home
            if !trimmed.isEmpty {
                if resources.isEmpty {
                    // Pre-response context — this is likely a top-level property
                    var resource = DAVResource()
                    resource.currentUserPrincipal = trimmed
                    resource.calendarHomeSet = trimmed
                    resources.append(resource)
                }
            }
        }

        currentElement = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
}
