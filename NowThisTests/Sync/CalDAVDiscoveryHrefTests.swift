import Foundation
import Testing
@testable import NowThis

struct CalDAVDiscoveryHrefTests {
    @Test(arguments: [
        ("https://example.com/a%2Fb/", "https://example.com/a%2Fb/"),
        ("/a%25b/", "https://example.com/a%25b/"),
        ("child/a+b/", "https://example.com/nested/dav/child/a+b/"),
        ("child/a%20b/", "https://example.com/nested/dav/child/a%20b/"),
        ("child/%E2%98%83/", "https://example.com/nested/dav/child/%E2%98%83/")
    ])
    func resolvesReferences(raw: String, expected: String) throws {
        let result = try CalDAVDiscovery.resolveHref(raw, responseURL: URL(string: "https://example.com/nested/dav/")!, allowedOrigin: URL(string: "https://example.com")!)
        #expect(result.rawHref == raw)
        #expect(result.requestURL.absoluteString == expected)
    }

    @Test(arguments: ["//other.example/path", "http://example.com/path", "https://user:pass@example.com/path", "https://example.com:444/path"])
    func rejectsUnsafeReference(_ raw: String) {
        #expect(throws: (any Error).self) {
            try CalDAVDiscovery.resolveHref(raw, responseURL: URL(string: "https://example.com/nested/dav/")!, allowedOrigin: URL(string: "https://example.com")!)
        }
    }
}
