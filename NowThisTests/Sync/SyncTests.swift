import Testing
import Foundation

@testable import NowThis

// MARK: - DAVXMLParser Tests

@Suite("DAVXMLParser")
struct DAVXMLParserTests {

    @Test("Parse PROPFIND multi-status response with calendars")
    func parsePropfindResponse() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:multistatus xmlns:d="DAV:"
                       xmlns:cs="http://calendarserver.org/ns/"
                       xmlns:c="urn:ietf:params:xml:ns:caldav"
                       xmlns:x="http://apple.com/ns/ical/">
          <d:response>
            <d:href>/remote.php/dav/calendars/user/tasks/</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>My Tasks</d:displayname>
                <cs:getctag>ctag-abc-123</cs:getctag>
                <d:sync-token>sync-token-xyz</d:sync-token>
                <x:calendar-color>#FF0000</x:calendar-color>
                <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
                <c:supported-calendar-component-set>
                  <c:comp name="VTODO"/>
                </c:supported-calendar-component-set>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

        let parser = DAVXMLParser()
        let resources = parser.parse(data: xml.data(using: .utf8)!)

        #expect(resources.count >= 1)

        let calendar = resources.first(where: {
            $0.href.contains("tasks")
        })
        #expect(calendar != nil)
        #expect(calendar?.displayName == "My Tasks")
        #expect(calendar?.ctag == "ctag-abc-123")
        #expect(calendar?.isVTODOSupported == true)
    }

    @Test("Parse calendar-multiget REPORT response")
    func parseCalendarMultiget() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:response>
            <d:href>/remote.php/dav/calendars/user/tasks/task1.ics</d:href>
            <d:propstat>
              <d:prop>
                <d:getetag>"etag-111"</d:getetag>
                <c:calendar-data>BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:task-1
        SUMMARY:Test Task
        END:VTODO
        END:VCALENDAR</c:calendar-data>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

        let parser = DAVXMLParser()
        let resources = parser.parse(data: xml.data(using: .utf8)!)

        #expect(resources.count >= 1)

        let task = resources.first(where: { !$0.calendarData.isEmpty })
        #expect(task != nil)
        #expect(task?.href.contains("task1.ics") == true)
        #expect(task?.etag == "etag-111")
        #expect(task?.calendarData.contains("VTODO") == true)
    }

    @Test("Parse ETag with surrounding quotes stripped")
    func parseETagQuotes() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/task.ics</d:href>
            <d:propstat>
              <d:prop>
                <d:getetag>"quoted-etag-value"</d:getetag>
              </d:prop>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

        let parser = DAVXMLParser()
        let resources = parser.parse(data: xml.data(using: .utf8)!)

        let first = resources.first
        #expect(first?.etag == "quoted-etag-value")
    }
}

// MARK: - ConflictResolver Tests

@Suite("ConflictResolver")
struct ConflictResolverTests {

    @Test("Default resolution is server wins")
    func defaultServerWins() {
        let resolution = ConflictResolver.resolve(
            localModified: Date(),
            remoteModified: Date()
        )
        #expect(resolution == .serverWins)
    }

    @Test("Resolution with nil dates still returns server wins")
    func nilDatesServerWins() {
        let resolution = ConflictResolver.resolve(
            localModified: nil,
            remoteModified: nil
        )
        #expect(resolution == .serverWins)
    }
}

// MARK: - SyncError Tests

@Suite("SyncErrors")
struct SyncErrorTests {

    @Test("CalDAVError has localized descriptions")
    func calDAVErrorDescriptions() {
        let errors: [CalDAVError] = [
            .invalidURL,
            .unauthorized,
            .forbidden,
            .notFound,
            .conflict(etag: "abc"),
            .serverError(statusCode: 500),
            .invalidResponse,
            .noCalendarHomeSet,
            .noUserPrincipal
        ]

        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test("ParserError has localized descriptions")
    func parserErrorDescriptions() {
        let errors: [ParserError] = [
            .invalidFormat,
            .missingUID,
            .missingComponent("VTODO"),
            .unexpectedEncoding
        ]

        for error in errors {
            #expect(error.errorDescription != nil)
        }
    }

    @Test("SyncError wraps CalDAV and parser errors")
    func syncErrorWrapping() {
        let caldavWrapped = SyncError.calDAVError(.unauthorized)
        #expect(caldavWrapped.errorDescription != nil)

        let parserWrapped = SyncError.parserError(.missingUID)
        #expect(parserWrapped.errorDescription != nil)
    }
}
