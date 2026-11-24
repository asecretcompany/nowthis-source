import Foundation
import Testing
@testable import NowThis

struct NextcloudServerAddressTests {
    @Test func recognizesCopiedEndpointWithoutDuplicatingPrefix() throws {
        for (suffix, kind) in [("remote.php/dav/", NextcloudServerAddress.InputKind.davRoot), ("remote.php/dav/principals/users/alice/", .principal), ("remote.php/dav/calendars/alice/tasks/", .collection)] {
            let input = "https://example.com/cloud/team/" + suffix
            let address = try NextcloudServerAddress.parse(input)
            #expect(address.baseURL.absoluteString == "https://example.com/cloud/team")
            #expect(address.discoverySeed?.absoluteString == input)
            #expect(address.inputKind == kind)
        }
    }
    @Test func rootAndNestedPrefixesSurvive() throws {
        #expect(try NextcloudServerAddress.parse("example.com/").baseURL.absoluteString == "https://example.com")
        #expect(try NextcloudServerAddress.parse("https://example.com/myremote.php/davish").baseURL.path == "/myremote.php/davish")
    }
    @Test func manualAndBrowserPolicyAgree() throws {
        let address = try NextcloudServerAddress.parse("example.com/cloud/remote.php/dav/")
        let validation = ServerURLValidator.validate("example.com/cloud/remote.php/dav/")
        #expect(validation.isValid)
        #expect(validation.normalizedURL == address.baseURL.absoluteString)
    }
    @Test func rejectsUserinfoQueryFragmentControlsMalformedEscape() {
        for input in ["https://u:p@example.com", "https://example.com/?q=x", "https://example.com/#x", "https://example.com/a%XX", "https://example.com/a\u{0001}b", "http://example.com"] {
            #expect(throws: (any Error).self) { try NextcloudServerAddress.parse(input) }
        }
    }
    @Test func preservesCaseAndEscapedPathSegments() throws {
        let address = try NextcloudServerAddress.parse("https://example.com/Cloud/a%2Fb/remote.php/dav/")
        #expect(address.baseURL.absoluteString == "https://example.com/Cloud/a%2Fb")
    }
    @Test func authorityMatrix() throws {
        #expect(NextcloudServerAddress.sameOrigin(URL(string: "https://[::1]:443/a")!, URL(string: "https://[::1]/b")!))
        #expect(!NextcloudServerAddress.sameOrigin(URL(string: "https://example.com:8443")!, URL(string: "https://example.com")!))
        let unicode = URL(string: "https://bücher.example")!
        let foundationHost = unicode.host()!
        #expect(NextcloudServerAddress.sameOrigin(unicode, URL(string: "https://\(foundationHost)")!))
    }
    @Test func encodesOnePathSegment() {
        #expect(NextcloudServerAddress.encodePathSegment("a/b%+?#") == "a%2Fb%25%2B%3F%23")
        let encoded = NextcloudServerAddress.encodePathSegment("café/猫")
        #expect(encoded.removingPercentEncoding == "café/猫")
        #expect(!encoded.contains("/"))
    }
    @Test func rejectsUnsupportedEndpoints() {
        for path in ["remote.php/dav/files/alice/", "s/token", "index.php/apps/files/", "apps/calendar/"] {
            #expect(throws: NextcloudServerAddress.ParseError.unsupported) { try NextcloudServerAddress.parse("https://example.com/" + path) }
        }
    }
    @Test(arguments: ["cloud.tail123.ts.net", "cloud", "100.64.1.2", "[fd7a:115c:a1e0::1234]"])
    func privateNetworkAuthorityIsPreserved(host: String) throws {
        let base = "https://\(host):8443/cloud"
        let address = try NextcloudServerAddress.parse(base + "/remote.php/dav/")
        #expect(address.baseURL.absoluteString == base)
        #expect(NextcloudServerAddress.sameOrigin(address.baseURL, URL(string: base + "/home")!))
        #expect(!NextcloudServerAddress.sameOrigin(address.baseURL, URL(string: "https://cloud.tail123.ts.net/cloud")!))
    }

    @Test(arguments: ["https://cloud", "https://100.64.1.2", "https://192.168.1.2", "https://[fd7a:115c:a1e0::1234]"])
    func namesAndPrivateIPsAreNotAssumedEquivalent(alias: String) {
        #expect(!NextcloudServerAddress.sameOrigin(URL(string: "https://cloud.tail123.ts.net")!, URL(string: alias)!))
    }

}
