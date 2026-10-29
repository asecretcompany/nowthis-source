import Testing
import Foundation

@testable import NowThis

/// A list shared with the user read-only must not be offered as a place to move a
/// task to — the PUT would be refused and the move rolled back. Discovery reads
/// `current-user-privilege-set` (RFC 3744) for that. A server that does not
/// report it answers 404 for the property; the set stays empty, and an empty set
/// means writable, which is how every list behaved before.
@Suite("CalDAV calendar privilege discovery")
struct CalendarPrivilegeDiscoveryTests {

    private static let home = "/remote.php/dav/calendars/sam/"

    private static func response(_ path: String, name: String, privileges: String?) -> String {
        let privilegeProp: String
        if let privileges {
            privilegeProp = "<d:current-user-privilege-set>\(privileges)</d:current-user-privilege-set>"
        } else {
            privilegeProp = ""
        }
        return """
          <d:response>
            <d:href>\(path)</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>\(name)</d:displayname>
                <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
                <c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set>
                \(privilegeProp)
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        """
    }

    private static func multistatus(_ responses: String...) -> Data {
        Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        \(responses.joined(separator: "\n"))
        </d:multistatus>
        """.utf8)
    }

    private static func privilege(_ names: String...) -> String {
        names.map { "<d:privilege><d:\($0)/></d:privilege>" }.joined()
    }

    private func discover(_ data: Data) throws -> [CalDAVClient.RemoteCalendar] {
        let resources = try DAVXMLParser().parse(data: data)
        return CalDAVClient.partitionTrashed(resources, calendarHomePath: Self.home).live
    }

    @Test("Privileges are read per calendar")
    func privilegesAreParsed() throws {
        let calendars = try discover(Self.multistatus(
            Self.response("\(Self.home)own/", name: "Own",
                          privileges: Self.privilege("read", "write", "write-properties", "write-content", "bind", "unbind")),
            Self.response("\(Self.home)shared-ro/", name: "Shared read-only",
                          privileges: Self.privilege("read", "read-current-user-privilege-set"))
        ))

        #expect(calendars.count == 2, "examined \(calendars.count) calendars")
        let own = calendars.first { $0.displayName == "Own" }
        let readOnly = calendars.first { $0.displayName == "Shared read-only" }
        #expect(own?.privileges.contains("write") == true)
        #expect(own?.privileges.contains("unbind") == true)
        #expect(readOnly?.privileges == ["read", "read-current-user-privilege-set"])
    }

    @Test("Writability follows the privileges; silence means writable")
    func writability() throws {
        let calendars = try discover(Self.multistatus(
            Self.response("\(Self.home)a/", name: "Write", privileges: Self.privilege("read", "write")),
            Self.response("\(Self.home)b/", name: "All", privileges: Self.privilege("all")),
            Self.response("\(Self.home)c/", name: "Content", privileges: Self.privilege("read", "write-content")),
            Self.response("\(Self.home)d/", name: "Read", privileges: Self.privilege("read")),
            Self.response("\(Self.home)e/", name: "Silent", privileges: nil)
        ))

        #expect(calendars.count == 5, "examined \(calendars.count) calendars")
        let writable = Dictionary(uniqueKeysWithValues: calendars.map { ($0.displayName, $0.isReadOnly) })
        #expect(writable["Write"] == false)
        #expect(writable["All"] == false)
        #expect(writable["Content"] == false)
        #expect(writable["Read"] == true)
        #expect(writable["Silent"] == false, "a server that reports no ACL keeps today's behaviour")
    }

    @Test("An href nested inside a property does not replace the calendar's own")
    func nestedHrefDoesNotOverwriteTheResourceHref() throws {
        // Nextcloud's owner-principal, and several RFC 3744 properties, carry a
        // <d:href> of their own after the response's. Taking the last href seen
        // would rename every calendar to its owner's principal path.
        let data = Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:response>
            <d:href>\(Self.home)shared/</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>Shared</d:displayname>
                <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
                <c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set>
                <d:owner><d:href>/remote.php/dav/principals/users/alex/</d:href></d:owner>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8)

        let calendars = try discover(data)
        #expect(calendars.count == 1, "examined \(calendars.count) calendars")
        #expect(calendars.first?.href == "\(Self.home)shared/")
    }
}
