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

    @Test("Redirected request preserves the no-cache policy")
    func preservesCachePolicy() {
        let result = CalDAVClient.makeRedirectRequest(
            from: originalRequest(),
            proposed: proposedRequest(url: "https://cloud.example.com/new/path/")
        )
        #expect(result.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("Redirected request preserves the original HTTP method")
    func preservesMethod() {
        let result = CalDAVClient.makeRedirectRequest(
            from: originalRequest(),
            proposed: proposedRequest(url: "https://cloud.example.com/new/path/")
        )
        #expect(result.httpMethod == "PROPFIND")
    }

    @Test("Same-origin redirect keeps Authorization and Depth")
    func sameOriginKeepsHeaders() {
        let result = CalDAVClient.makeRedirectRequest(
            from: originalRequest(),
            proposed: proposedRequest(url: "https://cloud.example.com/new/path/")
        )
        #expect(result.value(forHTTPHeaderField: "Authorization") == "Basic dXNlcjpwYXNz")
        #expect(result.value(forHTTPHeaderField: "Depth") == "1")
    }

    @Test("Cross-origin redirect drops Authorization but still preserves cache policy")
    func crossOriginDropsAuth() {
        let result = CalDAVClient.makeRedirectRequest(
            from: originalRequest(),
            proposed: proposedRequest(url: "https://evil.example.net/path/")
        )
        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(result.cachePolicy == .reloadIgnoringLocalCacheData)
    }
}
