import Testing
import Foundation

@testable import NowThis

/// CalDAV PROPFIND/REPORT responses are context-dependent and (per RFC 4918 §9)
/// must never be served from a cache: a stale `getctag` makes `SyncEngine`'s
/// delta check believe nothing changed and silently skip the inbound pull, so
/// server-created tasks and manual-order changes never reach the device.
/// These tests pin the read requests to a no-cache policy.
@Suite("CalDAV request cache policy")
struct CalDAVRequestCacheTests {

    private let credentials = CalDAVClient.Credentials(username: "user", password: "pass")

    @Test("PROPFIND read requests bypass the local URL cache")
    func propfindIgnoresCache() throws {
        let request = try #require(
            CalDAVClient.makeDAVRequest(
                method: "PROPFIND",
                url: "https://cloud.example.com/remote.php/dav/calendars/user/",
                body: "<d:propfind xmlns:d=\"DAV:\"><d:prop/></d:propfind>",
                credentials: credentials,
                depth: "1"
            )
        )

        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.httpMethod == "PROPFIND")
        #expect(request.value(forHTTPHeaderField: "Depth") == "1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == credentials.basicAuthHeader)
        #expect(request.httpBody != nil)
    }

    @Test("REPORT (calendar-query) read requests bypass the local URL cache")
    func reportIgnoresCache() throws {
        let request = try #require(
            CalDAVClient.makeDAVRequest(
                method: "REPORT",
                url: "https://cloud.example.com/remote.php/dav/calendars/user/tasks/",
                body: "<c:calendar-query/>",
                credentials: credentials,
                depth: "1"
            )
        )

        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.httpMethod == "REPORT")
    }

    @Test("Depth header is omitted when no depth is supplied")
    func depthOptional() throws {
        let request = try #require(
            CalDAVClient.makeDAVRequest(
                method: "PROPFIND",
                url: "https://cloud.example.com/.well-known/caldav",
                body: nil,
                credentials: credentials,
                depth: nil
            )
        )

        #expect(request.value(forHTTPHeaderField: "Depth") == nil)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("An invalid URL yields no request")
    func invalidURL() {
        let request = CalDAVClient.makeDAVRequest(
            method: "PROPFIND",
            url: "",
            body: nil,
            credentials: credentials,
            depth: nil
        )

        #expect(request == nil)
    }
}
