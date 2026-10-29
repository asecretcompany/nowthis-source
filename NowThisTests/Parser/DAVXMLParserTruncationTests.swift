import Testing
import Foundation

@testable import NowThis

/// Cover for **a truncated multistatus being read as a shorter list.**
///
/// `DAVXMLParser.parse` discarded the `Bool` that `XMLParser.parse()` returns
/// and handed back whatever `resources` had accumulated before the document
/// went wrong. A body cut off mid-response therefore produced a well-formed
/// *short* list, indistinguishable from a server that genuinely holds fewer
/// tasks.
///
/// That was survivable while the pull could only add and update: the missing
/// entries were simply not refreshed that time round. It stopped being
/// survivable when `SyncEngine.tasksDeletedOnServer` started treating "absent
/// from the fetched set" as "deleted on the server" — at which point a
/// truncated response deletes every task it failed to mention, and the user
/// loses data because a connection dropped.
///
/// So the parse now fails loudly. `fetchAllTasks` throws, the sync for that
/// calendar ends, and the reconciliation never runs on a set it cannot trust.
/// A sync that fails is a sync that runs again in a minute; a sync that
/// silently deletes is permanent.
@Suite("DAV multistatus truncation")
struct DAVXMLParserTruncationTests {

    private func response(href: String, etag: String, uid: String) -> String {
        """
        <d:response>
          <d:href>\(href)</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>"\(etag)"</d:getetag>
              <c:calendar-data>BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:\(uid)
        SUMMARY:Task
        END:VTODO
        END:VCALENDAR</c:calendar-data>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        """
    }

    private func multistatus(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        \(body)
        </d:multistatus>
        """
    }

    @Test("A complete multistatus parses to every response in it")
    func aCompleteBodyParses() throws {
        let xml = multistatus(
            response(href: "/c/1.ics", etag: "e1", uid: "one")
            + response(href: "/c/2.ics", etag: "e2", uid: "two"))

        let resources = try DAVXMLParser().parse(data: Data(xml.utf8))

        #expect(resources.count == 2, "the fixture itself must parse, or the truncation test proves nothing")
        #expect(Set(resources.map(\.href)) == ["/c/1.ics", "/c/2.ics"])
    }

    /// The failure this exists for: a body cut off partway, which used to
    /// return the responses that had already been read.
    @Test("A truncated multistatus fails instead of returning a short list")
    func aTruncatedBodyFails() {
        let complete = multistatus(
            response(href: "/c/1.ics", etag: "e1", uid: "one")
            + response(href: "/c/2.ics", etag: "e2", uid: "two"))
        // Cut inside the second response, after the first has fully closed.
        let cut = complete.range(of: "<d:href>/c/2.ics</d:href>")!
        let truncated = String(complete[complete.startIndex..<cut.upperBound])

        #expect(throws: (any Error).self) {
            _ = try DAVXMLParser().parse(data: Data(truncated.utf8))
        }
    }

    @Test("Bytes that are not XML at all fail")
    func nonXMLFails() {
        #expect(throws: (any Error).self) {
            _ = try DAVXMLParser().parse(data: Data("<html><body>502 Bad Gateway".utf8))
        }
    }

    @Test("An empty body fails rather than reading as an empty calendar")
    func anEmptyBodyFails() {
        #expect(throws: (any Error).self) {
            _ = try DAVXMLParser().parse(data: Data())
        }
    }

    /// A valid multistatus that genuinely contains nothing is not an error —
    /// it is a calendar with no tasks, and it must stay distinguishable from a
    /// failed read. `tasksDeletedOnServer` refuses to act on an empty set
    /// anyway, but the two must not arrive by the same route.
    @Test("A valid but empty multistatus parses to no resources")
    func aValidEmptyBodyParsesToNothing() throws {
        let resources = try DAVXMLParser().parse(data: Data(multistatus("").utf8))
        #expect(resources.isEmpty)
    }
}
