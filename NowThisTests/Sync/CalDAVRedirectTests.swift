import Testing
import Foundation

@testable import NowThis

/// When a CalDAV request follows a 301/302 redirect, the rebuilt request must
/// keep the original's method, same-origin credentials, AND its cache policy —
/// otherwise a redirected PROPFIND/REPORT silently reverts to the default cache
/// policy and can serve a stale `getctag`, reproducing the skipped-pull bug.
@Suite("CalDAV redirect request rebuilding")
struct CalDAVRedirectTests {

    private func originalRequest(
        url: String = "https://cloud.example.com/remote.php/dav/calendars/user/"
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "PROPFIND"
        request.setValue("Basic dXNlcjpwYXNz", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "Depth")
        return request
    }

    /// The new request URLSession proposes for a redirect — default cache policy,
    /// method downgraded to GET (the behavior this delegate exists to undo).
    private func proposedRequest(url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "GET"
        #expect(request.cachePolicy == .useProtocolCachePolicy)
        return request
    }

    @Test("Redirect rebuilding preserves the clamped request allowance")
    func preservesTimeoutAllowance() {
        var original = originalRequest()
        original.timeoutInterval = 0.25
        var proposed = proposedRequest(url: "https://cloud.example.com/new/path/")
        proposed.timeoutInterval = 60
        let result = CalDAVClient.makeRedirectRequest(from: original, proposed: proposed)
        #expect(result?.timeoutInterval == 0.25)
    }

    @Test("Redirected request preserves the no-cache policy")
    func preservesCachePolicy() {
        let result = CalDAVClient.makeRedirectRequest(
            from: originalRequest(),
            proposed: proposedRequest(url: "https://cloud.example.com/new/path/")
        )
        #expect(result?.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("Redirected request preserves the original HTTP method")
    func preservesMethod() {
        let result = CalDAVClient.makeRedirectRequest(
            from: originalRequest(),
            proposed: proposedRequest(url: "https://cloud.example.com/new/path/")
        )
        #expect(result?.httpMethod == "PROPFIND")
    }

    @Test("Same-origin redirect keeps Authorization and Depth")
    func sameOriginKeepsHeaders() {
        let result = CalDAVClient.makeRedirectRequest(
            from: originalRequest(),
            proposed: proposedRequest(url: "https://cloud.example.com/new/path/")
        )
        #expect(result?.value(forHTTPHeaderField: "Authorization") == "Basic dXNlcjpwYXNz")
        #expect(result?.value(forHTTPHeaderField: "Depth") == "1")
    }

    @Test("Cross-origin redirect is rejected")
    func crossOriginDropsAuth() {
        let result = CalDAVClient.makeRedirectRequest(
            from: originalRequest(),
            proposed: proposedRequest(url: "https://evil.example.net/path/")
        )
        #expect(result == nil)
    }
    @Test("Cross-origin redirect cannot carry a private PUT body")
    func rejectsPrivateBodyRedirect() {
        var original = originalRequest()
        original.httpMethod = "PUT"
        original.httpBody = Data("private task notes".utf8)
        let result = CalDAVClient.makeRedirectRequest(from: original,
            proposed: proposedRequest(url: "https://evil.example.net/task.ics"))
        #expect(result == nil)
    }

    @Test("Foreign absolute task href is rejected before transport")
    func foreignTaskHref() async throws {
        let host = "foreign-" + UUID().uuidString.lowercased() + ".invalid"
        let config = ScriptedDAVProtocol.install(host: host,
            responses: [.init(body: "BEGIN:VTODO\nUID:private\nSUMMARY:Private\nEND:VTODO")])
        let client = CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0))
        var rejected = false
        do {
            _ = try await client.fetchTask(baseURL: "https://trusted.invalid",
                taskPath: "https://" + host + "/private.ics",
                credentials: .init(username: "fixture", password: "secret"))
        } catch { rejected = true }
        #expect(rejected)
        #expect(ScriptedDAVProtocol.requests(host: host).isEmpty)
    }

    @Test("Redirect origin rejects changed scheme, port, host and URL credentials", arguments: [
        "http://cloud.example.com/task", "https://cloud.example.com:444/task",
        "https://other.example.com/task", "https://user:password@cloud.example.com/task"
    ])
    func rejectsUnsafeRedirect(url: String) {
        #expect(CalDAVClient.makeRedirectRequest(from: originalRequest(),
            proposed: proposedRequest(url: url)) == nil)
    }

    @Test("Explicit default port is the same origin and retains conditional PUT")
    func defaultPortRedirect() throws {
        var original = originalRequest()
        original.httpMethod = "PUT"
        original.httpBody = Data("private".utf8)
        original.setValue("\"latest\"", forHTTPHeaderField: "If-Match")
        let result = try #require(CalDAVClient.makeRedirectRequest(from: original,
            proposed: proposedRequest(url: "https://cloud.example.com:443/task")))
        #expect(result.httpBody == original.httpBody)
        #expect(result.value(forHTTPHeaderField: "If-Match") == "\"latest\"")
    }

    @Test("Same-origin absolute and relative task hrefs still work", arguments: [false, true])
    func trustedTaskHref(absolute: Bool) async throws {
        let host = "trusted-" + UUID().uuidString.lowercased() + ".invalid"
        let config = ScriptedDAVProtocol.install(host: host,
            responses: [.init(status: 200, body: "BEGIN:VTODO\nUID:safe\nSUMMARY:Safe\nEND:VTODO")])
        let client = CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0))
        _ = try await client.fetchTask(baseURL: "https://" + host,
            taskPath: (absolute ? "https://" + host : "") + "/safe.ics",
            credentials: .init(username: "fixture", password: "fixture"))
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.path) == ["/safe.ics"])
    }

}
