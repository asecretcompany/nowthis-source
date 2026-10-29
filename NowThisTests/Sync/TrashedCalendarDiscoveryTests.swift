import Testing
import Foundation

@testable import NowThis

/// **Calendars in the server's trash must not arrive as ordinary task lists.**
///
/// Reported 2026-08-28 by a Murena user seeing triplicate lists: "Aufgaben" three times,
/// "Irgendwann" three times, "Eingang" twice — while other lists appeared exactly once.
/// Exact-duplicate names beside untouched singletons is the signature of delete-and-recreate,
/// not of distinct collections: Nextcloud keeps a deleted calendar retrievable in its trash,
/// and `discoverTaskCalendars` filtered only on `isVTODOSupported` and "not the home itself",
/// so every corpse was imported as a live list. The user confirmed the diagnosis — emptying
/// the server trash and re-adding the account was the only thing that cleared it, because
/// nothing prunes a `TaskList` whose remote calendar disappears.
///
/// The filter lives in a pure function rather than inside `discoverTaskCalendars` because the
/// suite has no `URLProtocol` stub anywhere — anything behind the network call ships untested.
@Suite("CalDAV trashed calendar discovery")
struct TrashedCalendarDiscoveryTests {

    private static let home = "/remote.php/dav/calendars/user%40murena.io/"

    /// Shaped like a real Nextcloud PROPFIND reply: the calendar home itself, one live
    /// calendar, and one in the trash. The live calendar carries the *second* propstat with a
    /// 404 and an empty `<nc:deleted-at/>`, exactly as a server reports a property it does not
    /// hold for that resource — the case that must not read as "deleted".
    private static let multistatus = """
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/"
                   xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:nc="http://nextcloud.com/ns">
      <d:response>
        <d:href>/remote.php/dav/calendars/user%40murena.io/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/calendars/user%40murena.io/medien-bilder/</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>Medien - Bilder</d:displayname>
            <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
            <c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set>
            <cs:getctag>ctag-live</cs:getctag>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
        <d:propstat>
          <d:prop><nc:deleted-at/></d:prop>
          <d:status>HTTP/1.1 404 Not Found</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/calendars/user%40murena.io/irgendwann/</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>Irgendwann</d:displayname>
            <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
            <c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set>
            <cs:getctag>ctag-trashed</cs:getctag>
            <nc:deleted-at>1755000000</nc:deleted-at>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private static func parsed() throws -> [DAVXMLParser.DAVResource] {
        try DAVXMLParser().parse(data: Data(multistatus.utf8))
    }

    // MARK: - The wire format

    @Test("The parser reads Nextcloud's deleted-at marker")
    func parserReadsDeletedAt() throws {
        let resources = try Self.parsed()
        let live = try #require(resources.first { $0.displayName == "Medien - Bilder" })
        let trashed = try #require(resources.first { $0.displayName == "Irgendwann" })

        #expect(live.deletedAt.isEmpty, """
            The live calendar reported <nc:deleted-at/> inside a 404 propstat, which means the \
            server does not hold that property for it. An empty element must not read as a date.
            """)
        #expect(trashed.deletedAt == "1755000000")
    }

    // MARK: - The filter

    @Test("Discovery keeps live calendars and sets trashed ones aside")
    func partitionSplitsTrashedFromLive() throws {
        let result = CalDAVClient.partitionTrashed(try Self.parsed(), calendarHomePath: Self.home)

        #expect(result.live.map(\.displayName) == ["Medien - Bilder"])
        #expect(result.trashed.map(\.displayName) == ["Irgendwann"])
    }

    @Test("The calendar home is still excluded from both halves")
    func homeIsNotACalendar() throws {
        let result = CalDAVClient.partitionTrashed(try Self.parsed(), calendarHomePath: Self.home)

        #expect(!result.live.contains { $0.href == Self.home })
        #expect(!result.trashed.contains { $0.href == Self.home })
    }

    /// The failure mode that matters most: this ships to every CalDAV server, and most are not
    /// Nextcloud. A server that has never heard of `deleted-at` must lose nothing.
    @Test("A server that omits the property filters nothing")
    func serverWithoutThePropertyFiltersNothing() throws {
        let plain = Self.multistatus
            .replacingOccurrences(of: "<nc:deleted-at>1755000000</nc:deleted-at>", with: "")
            .replacingOccurrences(of: "<nc:deleted-at/>", with: "")
        let resources = try DAVXMLParser().parse(data: Data(plain.utf8))

        let result = CalDAVClient.partitionTrashed(resources, calendarHomePath: Self.home)

        #expect(result.trashed.isEmpty)
        #expect(result.live.map(\.displayName).sorted() == ["Irgendwann", "Medien - Bilder"])
    }

    /// Belt and braces. The reporter's server was not available to inspect, so the exact shape
    /// Murena used is unconfirmed — a collection living under a `trashbin` path counts as
    /// trashed even when it carries no marker.
    @Test("A calendar under a trashbin path is trashed even without the marker")
    func trashbinPathIsTreatedAsTrashed() throws {
        let moved = Self.multistatus
            .replacingOccurrences(of: "<nc:deleted-at>1755000000</nc:deleted-at>", with: "")
            .replacingOccurrences(
                of: "/remote.php/dav/calendars/user%40murena.io/irgendwann/",
                with: "/remote.php/dav/calendars/user%40murena.io/trashbin/irgendwann/")
        let resources = try DAVXMLParser().parse(data: Data(moved.utf8))

        let result = CalDAVClient.partitionTrashed(resources, calendarHomePath: Self.home)

        #expect(result.trashed.map(\.displayName) == ["Irgendwann"])
        #expect(result.live.map(\.displayName) == ["Medien - Bilder"])
    }

    // MARK: - The deletion date

    /// Trashed-ness is decided by the marker being present, never by the date parsing. A format
    /// we do not recognise still hides the calendar; it just shows without a date.
    @Test("Unrecognised date formats still count as trashed")
    func unparseableDateStillTrashed() {
        let cal = CalDAVClient.RemoteCalendar(
            href: "/c/", displayName: "X", ctag: "", color: "", syncToken: "",
            deletedAtRaw: "sometime last Tuesday")

        #expect(cal.isTrashed)
        #expect(cal.deletedAt == nil)
    }

    @Test("Unix timestamps and ISO-8601 both parse")
    func deletedAtParsesKnownFormats() {
        func date(_ raw: String) -> Date? {
            CalDAVClient.RemoteCalendar(
                href: "/c/", displayName: "X", ctag: "", color: "", syncToken: "",
                deletedAtRaw: raw).deletedAt
        }

        #expect(date("1755000000") == Date(timeIntervalSince1970: 1_755_000_000))
        #expect(date("2026-08-12T14:40:00Z") != nil)
        #expect(date("") == nil)
    }

    // MARK: - Reporting once

    private func trashed(_ hrefs: String...) -> [TrashedList] {
        hrefs.map { TrashedList(href: $0, name: "L", deletedAt: nil) }
    }

    @Test("A list already reported is not reported again")
    func alreadyReportedIsSkipped() {
        let found = trashed("/a/", "/b/")

        #expect(TrashedListReporter.unreported(found, reported: []).count == 2)
        #expect(TrashedListReporter.unreported(found, reported: ["/a/", "/b/"]).isEmpty)
    }

    @Test("A newly trashed list is reported even after an earlier notice")
    func newlyTrashedIsReported() {
        let result = TrashedListReporter.unreported(trashed("/a/", "/b/"), reported: ["/a/"])

        #expect(result.map(\.href) == ["/b/"])
    }

    /// The separator must be a character an href cannot contain. A comma is legal unencoded in
    /// a URL path, so a comma-separated store would split one href into two and re-notify about
    /// a list forever.
    @Test("Reported hrefs survive a round trip through storage")
    func reportedHrefsRoundTrip() {
        let hrefs: Set<String> = [
            "/remote.php/dav/calendars/user%40murena.io/irgendwann/",
            "/remote.php/dav/calendars/user%40murena.io/notes,ideas/"
        ]

        #expect(TrashedListReporter.decode(TrashedListReporter.encode(hrefs)) == hrefs)
    }

    @Test("A stray separator does not register as a reported list")
    func blankEntriesAreDropped() {
        #expect(TrashedListReporter.decode("").isEmpty)
        #expect(TrashedListReporter.decode("\n\n/a/\n\n") == ["/a/"])
    }
}
