import Foundation
import Testing
@testable import NowThis

@Suite("CalDAV sync collection reports")
struct CalDAVDeltaTests {
    private let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
    private func xml(_ responses: String, token: String = "next") -> String {
        "<d:multistatus xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\">\(responses)<d:sync-token>\(token)</d:sync-token></d:multistatus>"
    }
    private func status(_ href: String, _ code: Int) -> String {
        "<d:response><d:href>\(href)</d:href><d:status>HTTP/1.1 \(code) Result</d:status></d:response>"
    }
    private func changed(_ href: String) -> String {
        "<d:response><d:href>\(href)</d:href><d:propstat><d:prop><d:getetag>e2</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }
    private func client(_ body: String, code: Int = 207) -> (CalDAVClient, String, String) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        return (CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host, responses: [.init(status: code, body: body)]), retryPolicy: .init(maxAttempts: 1, baseDelay: 0)), "https://" + host, host)
    }

    @Test("Delta separates changed resources, tombstones, and collection continuation")
    func continuedDelta() async throws {
        let (client, base, host) = client(xml(changed("/tasks/a.ics") + status("/tasks/b.ics", 404) + status("/tasks/", 507)))
        let page = try await client.fetchSyncDelta(baseURL: base, calendarPath: "/tasks/", syncToken: "old&amp;token", credentials: credentials)
        #expect(page.resources.map(\.href) == ["/tasks/a.ics"])
        #expect(page.resources.map(\.etag) == ["e2"])
        #expect(page.deletedHrefs == ["/tasks/b.ics"])
        #expect(page.nextToken == "next")
        #expect(page.hasMore)
        let body = String(decoding: try #require(ScriptedDAVProtocol.requests(host: host).first).body, as: UTF8.self)
        #expect(body.contains("sync-collection"))
        #expect(body.contains("<d:sync-level>1</d:sync-level>"))
        #expect(body.contains("old&amp;amp;token"))
        #expect(!body.contains("calendar-data"))
    }

    @Test("Empty delta retains a token and can explicitly delete the final resource", arguments: [false, true])
    func emptyOrFinalDeletion(deleted: Bool) async throws {
        let (client, base, _) = client(xml(deleted ? status("/tasks/last.ics", 404) : ""))
        let page = try await client.fetchSyncDelta(baseURL: base, calendarPath: "/tasks/", syncToken: "old", credentials: credentials)
        #expect(page.resources.isEmpty)
        #expect(page.deletedHrefs == (deleted ? ["/tasks/last.ics"] : []))
        #expect(page.nextToken == "next")
        #expect(!page.hasMore)
    }

    @Test("Delta failures cannot be mistaken for a complete page", arguments: ["top507", "resource403", "resource507", "collection404", "missingToken", "duplicate", "outside", "truncated", "stalledContinuation", "prop404", "propertyToken", "duplicateToken"])
    func invalidDelta(kind: String) async {
        let body: String
        switch kind {
        case "top507": body = "<d:error xmlns:d=\"DAV:\"><d:number-of-matches-within-limits/></d:error>"
        case "resource403": body = xml(status("/tasks/a.ics", 403))
        case "resource507": body = xml(status("/tasks/a.ics", 507))
        case "collection404": body = xml(status("/tasks/", 404))
        case "missingToken": body = xml(changed("/tasks/a.ics"), token: "")
        case "duplicate": body = xml(changed("/tasks/a.ics") + status("/tasks/a.ics", 404))
        case "outside": body = xml(changed("/other/a.ics"))
        case "prop404": body = xml(changed("/tasks/a.ics").replacingOccurrences(of: "HTTP/1.1 200 OK", with: "HTTP/1.1 404 Not Found"))
        case "propertyToken": body = xml(changed("/tasks/a.ics").replacingOccurrences(of: "<d:getetag>e2</d:getetag>", with: "<d:getetag>e2</d:getetag><d:sync-token>property</d:sync-token>"), token: "")
        case "duplicateToken": body = xml("<d:sync-token>first</d:sync-token>")
        case "stalledContinuation": body = xml(status("/tasks/", 507), token: "old")
        default: body = String(xml(changed("/tasks/a.ics")).dropLast(10))
        }
        let (client, base, _) = client(body, code: kind == "top507" ? 507 : 207)
        await #expect(throws: (any Error).self) {
            try await client.fetchSyncDelta(baseURL: base, calendarPath: "/tasks/", syncToken: "old", credentials: credentials)
        }
    }

    @Test("Invalid token DAV precondition is distinct from permission denial")
    func invalidToken() async {
        let (client, base, _) = client("<d:error xmlns:d=\"DAV:\"><d:valid-sync-token/></d:error>", code: 403)
        await #expect(throws: CalDAVSyncError.invalidSyncToken) {
            try await client.fetchSyncDelta(baseURL: base, calendarPath: "/tasks/", syncToken: "old", credentials: credentials)
        }
        let (denied, deniedBase, _) = self.client("<d:error xmlns:d=\"DAV:\"><d:need-privileges/></d:error>", code: 403)
        do {
            _ = try await denied.fetchSyncDelta(baseURL: deniedBase, calendarPath: "/tasks/", syncToken: "old", credentials: credentials)
            Issue.record("Permission denial must fail")
        } catch {
            guard case CalDAVError.forbidden = error else { Issue.record("Expected permission error, got \(error)"); return }
        }
    }

    @Test("Discovery capability requires a successful supported report property")
    func discoveryCapability() async throws {
        let property = "<d:supported-report-set><d:supported-report><d:report><d:sync-collection/></d:report></d:supported-report></d:supported-report-set>"
        let response = """
        <d:response><d:href>/home/tasks/</d:href><d:propstat><d:prop>
        <c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set><d:sync-token>discovery</d:sync-token>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        <d:propstat><d:prop>\(property)</d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
        """
        let (client, base, host) = client(xml(response))
        let calendars = try await client.discoverTaskCalendars(baseURL: base, calendarHomePath: "/home/", credentials: credentials)
        #expect(calendars.live.count == 1)
        #expect(calendars.live.first?.supportsSyncCollection == false)
        #expect(calendars.live.first?.syncToken == "discovery")
        let body = String(decoding: try #require(ScriptedDAVProtocol.requests(host: host).first).body, as: UTF8.self)
        #expect(body.contains("supported-report-set"))
        let resources = try DAVXMLParser().parse(data: Data(xml(response.replacingOccurrences(of: "HTTP/1.1 404 Not Found", with: "HTTP/1.1 200 OK")).utf8))
        #expect(CalDAVClient.partitionTrashed(resources, calendarHomePath: "/home/").live.first?.supportsSyncCollection == true)
    }
}
