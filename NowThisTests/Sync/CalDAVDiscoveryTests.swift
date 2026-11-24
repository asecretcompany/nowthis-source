import Foundation
import Testing
@testable import NowThis

struct CalDAVDiscoveryTests {
    private let credentials = CalDAVClient.Credentials(username: "person@example.com", password: "secret")
    private func prop(_ href: String, _ content: String) -> String { DAVSyncScenario.prop(href, content) }
    private func multi(_ body: String) -> String { DAVSyncScenario.multistatus(body) }
    private func client(_ host: String, _ responses: [ScriptedDAVProtocol.Response]) -> CalDAVClient {
        CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host, responses: responses), retryPolicy: .init(maxAttempts: 1, baseDelay: 0))
    }

    @Test func emailLoginUsesAdvertisedPrincipal() async throws {
        let host = "discovery-" + UUID().uuidString.lowercased() + ".invalid"
        let root = "/remote.php/dav/"
        let principal = "/principals/a1b2/"
        let home = "/calendars/a1b2/"
        let client = client(host, [
            .init(body: multi(prop(root, "<d:current-user-principal><d:href>\(principal)</d:href></d:current-user-principal>"))),
            .init(body: multi(prop(principal, "<c:calendar-home-set><d:href>\(home)</d:href></c:calendar-home-set>"))),
            .init(body: multi(prop(home, "<d:resourcetype/>")))
        ])
        let address = try NextcloudServerAddress.parse("https://\(host)")
        let result = try await CalDAVDiscovery(client: client).discover(address: address, credentials: credentials)
        #expect(result.principalURL?.absoluteString == "https://\(host)\(principal)")
        #expect(result.calendarHomeURL.absoluteString == "https://\(host)\(home)")
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.path) == ["/remote.php/dav", "/principals/a1b2", "/calendars/a1b2"])
    }

    @Test func ignoresUnrelatedPrincipal() async throws {
        let host = "binding-" + UUID().uuidString.lowercased() + ".invalid"
        let body = multi(prop("/unrelated/", "<d:current-user-principal><d:href>/wrong/</d:href></d:current-user-principal>"))
        let client = client(host, [.init(body: body), .init(status: 404, body: ""), .init(status: 404, body: "")])
        let address = try NextcloudServerAddress.parse("https://\(host)")
        do { _ = try await CalDAVDiscovery(client: client).discover(address: address, credentials: credentials); Issue.record("Unexpected discovery success") } catch { }
        #expect(!ScriptedDAVProtocol.requests(host: host).map(\.path).contains("/wrong/"))
    }

    @Test func directHomeWithEmptyListingIsAuthoritative() async throws {
        let host = "empty-" + UUID().uuidString.lowercased() + ".invalid"
        let client = client(host, [
            .init(body: multi(prop("/remote.php/dav/", "<c:calendar-home-set><d:href>/home/</d:href></c:calendar-home-set>"))),
            .init(body: multi(prop("/home/", "<d:resourcetype/>")))
        ])
        let result = try await CalDAVDiscovery(client: client).discover(address: NextcloudServerAddress.parse("https://\(host)"), credentials: credentials)
        #expect(result.principalURL == nil)
        #expect(result.calendars.live.isEmpty)
    }

    @Test(arguments: [401, 403, 429, 500])
    func deniedPrincipalPropertyStopsTraversal(_ status: Int) async throws {
        let host = "denied-" + UUID().uuidString.lowercased() + ".invalid"
        let body = multi("<d:response><d:href>/remote.php/dav/</d:href><d:propstat><d:prop><d:current-user-principal/></d:prop><d:status>HTTP/1.1 \(status) Denied</d:status></d:propstat></d:response>")
        let client = client(host, [.init(body: body)])
        do { _ = try await CalDAVDiscovery(client: client).discover(address: NextcloudServerAddress.parse("https://\(host)"), credentials: credentials); Issue.record("Unexpected discovery success") } catch { }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
    }

    @Test func missingHomeResourceFailsClosed() async throws {
        let host = "incomplete-" + UUID().uuidString.lowercased() + ".invalid"
        let client = client(host, [
            .init(body: multi(prop("/remote.php/dav/", "<c:calendar-home-set><d:href>/home/</d:href></c:calendar-home-set>"))),
            .init(body: multi(prop("/home/tasks/", "<d:resourcetype><c:calendar/></d:resourcetype><c:supported-calendar-component-set><c:comp name=\"VTODO\"/></c:supported-calendar-component-set>")))
        ])
        do { _ = try await CalDAVDiscovery(client: client).discover(address: NextcloudServerAddress.parse("https://\(host)"), credentials: credentials); Issue.record("Incomplete listing succeeded") } catch { }
    }

    private func runListing(_ listing: String, host: String) async throws -> CalDAVDiscoveryResult {
        let client = client(host, [
            .init(body: multi(prop("/remote.php/dav/", "<c:calendar-home-set><d:href>/home/</d:href></c:calendar-home-set>"))),
            .init(body: multi(listing))
        ])
        return try await CalDAVDiscovery(client: client).discover(address: NextcloudServerAddress.parse("https://\(host)"), credentials: credentials)
    }

    @Test(arguments: ["/other-user/tasks/", "../outside/", "/home/nested/tasks/", "/home//tasks/", "/home/%2e%2e/"])
    func rejectsOutOfScopeCollection(_ href: String) async throws {
        let host = "scope-" + UUID().uuidString.lowercased() + ".invalid"
        let collection = prop(href, "<d:resourcetype><c:calendar/></d:resourcetype><c:supported-calendar-component-set><c:comp name=\"VTODO\"/></c:supported-calendar-component-set>")
        do { _ = try await runListing(prop("/home/", "<d:resourcetype/>") + collection, host: host); Issue.record("Out-of-scope collection accepted") } catch { }
    }

    @Test(arguments: ["current-user-privilege-set", "sync-token", "deleted-at"])
    func deniedOptionalPropertyFailsClosed(_ name: String) async throws {
        let host = "optional-" + UUID().uuidString.lowercased() + ".invalid"
        let prefix = name == "deleted-at" ? "nc" : "d"
        let denied = "<d:propstat><d:prop><\(prefix):\(name) xmlns:nc=\"http://nextcloud.com/ns\"/></d:prop><d:status>HTTP/1.1 403 Forbidden</d:status></d:propstat>"
        let home = "<d:response><d:href>/home/</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>\(denied)</d:response>"
        do { _ = try await runListing(home, host: host); Issue.record("Denied optional property accepted") } catch { }
    }

    @Test func optional404AllowsCollection() async throws {
        let host = "optional404-" + UUID().uuidString.lowercased() + ".invalid"
        let child = "<d:response><d:href>/home/tasks/</d:href><d:propstat><d:prop><d:resourcetype><c:calendar/></d:resourcetype><c:supported-calendar-component-set><c:comp name=\"VTODO\"/></c:supported-calendar-component-set></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat><d:propstat><d:prop><d:current-user-privilege-set/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>"
        let result = try await runListing(prop("/home/", "<d:resourcetype/>") + child, host: host)
        #expect(result.calendars.live.count == 1)
    }

    @Test func htmlStopsCandidateTraversal() async throws {
        let host = "html-" + UUID().uuidString.lowercased() + ".invalid"
        let client = client(host, [.init(body: "<html>Not DAV</html>")])
        do { _ = try await CalDAVDiscovery(client: client).discover(address: NextcloudServerAddress.parse("https://\(host)"), credentials: credentials); Issue.record("HTML accepted") } catch { }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
    }

    @Test func boundedFallbackOrder() async throws {
        let host = "fallback-" + UUID().uuidString.lowercased() + ".invalid"
        let fallback = "/cloud/remote.php/dav/principals/users/person%40example.com/"
        let client = client(host, [
            .init(status: 404, body: ""), .init(status: 405, body: ""), .init(status: 404, body: ""),
            .init(body: multi(prop(fallback, "<c:calendar-home-set><d:href>/home/</d:href></c:calendar-home-set>"))),
            .init(body: multi(prop("/home/", "<d:resourcetype/>")))
        ])
        let address = try NextcloudServerAddress.parse("https://\(host)/cloud/remote.php/dav/principals/users/seed/")
        let result = try await CalDAVDiscovery(client: client).discover(address: address, credentials: credentials)
        #expect(result.calendarHomeURL.absoluteString == "https://\(host)/home/")
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.path) == ["/cloud/remote.php/dav/principals/users/seed", "/cloud/remote.php/dav", "/.well-known/caldav", "/cloud/remote.php/dav/principals/users/person@example.com", "/home"])
    }

    @Test func expiredOuterDeadlinePreventsRequests() async throws {
        let host = "expired-" + UUID().uuidString.lowercased() + ".invalid"
        let client = client(host, [.init(body: "")])
        let address = try NextcloudServerAddress.parse("https://\(host)")
        do {
            _ = try await DAVDiscoveryContext.$deadline.withValue(ContinuousClock.now.advanced(by: .seconds(-1))) {
                try await CalDAVDiscovery(client: client).discover(address: address, credentials: credentials)
            }
            Issue.record("Expired deadline accepted")
        } catch { }
        #expect(ScriptedDAVProtocol.requests(host: host).isEmpty)
    }

    @Test func missingPropertiesAdvanceToNextCandidate() async throws {
        let host = "missing-properties-" + UUID().uuidString.lowercased() + ".invalid"
        let missing = "<d:response><d:href>/remote.php/dav/</d:href><d:propstat><d:prop><d:current-user-principal/><c:calendar-home-set/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>"
        let client = client(host, [
            .init(body: multi(missing)),
            .init(body: multi(prop("/.well-known/caldav", "<c:calendar-home-set><d:href>/home/</d:href></c:calendar-home-set>"))),
            .init(body: multi(prop("/home/", "<d:resourcetype><d:collection/></d:resourcetype>")))
        ])
        let result = try await CalDAVDiscovery(client: client).discover(address: NextcloudServerAddress.parse("https://\(host)"), credentials: credentials)
        #expect(result.calendarHomeURL.absoluteString == "https://\(host)/home/")
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.path) == ["/remote.php/dav", "/.well-known/caldav", "/home"])
    }

    @Test func homeRedirectSetsCreateCalendarDestination() async throws {
        let host = "redirect-home-" + UUID().uuidString.lowercased() + ".invalid"
        let effective = URL(string: "https://\(host)/dav/home/")!
        let client = client(host, [
            .init(body: multi(prop("/remote.php/dav/", "<c:calendar-home-set><d:href>/home/</d:href></c:calendar-home-set>"))),
            .init(body: multi(prop("/dav/home/", "<d:resourcetype><d:collection/></d:resourcetype>")), responseURL: effective),
            .init(status: 201, body: "")
        ])
        let result = try await CalDAVDiscovery(client: client).discover(address: NextcloudServerAddress.parse("https://\(host)"), credentials: credentials)
        _ = try await client.createCalendar(baseURL: "https://\(host)", calendarHomePath: result.calendarHomeURL.absoluteString, listID: "fixture", name: "New list", color: nil, credentials: credentials)
        let create = try #require(ScriptedDAVProtocol.requests(host: host).last)
        #expect(create.method == "MKCALENDAR")
        #expect(create.url.deletingLastPathComponent().path == "/dav/home")
        #expect(create.url.lastPathComponent.hasPrefix("nowthis-"))
    }

    @Test func homeWithoutSuccessfulResourceTypeIsIncomplete() async throws {
        let host = "empty-home-" + UUID().uuidString.lowercased() + ".invalid"
        let bare = "<d:response><d:href>/home/</d:href><d:propstat><d:prop><d:displayname>Home</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>"
        do { _ = try await runListing(bare, host: host); Issue.record("Incomplete home accepted") } catch { }
    }

    @Test func escapedSlashInHomePrefixRemainsOpaque() async throws {
        let host = "escaped-home-" + UUID().uuidString.lowercased() + ".invalid"
        let client = client(host, [
            .init(body: multi(prop("/remote.php/dav/", "<c:calendar-home-set><d:href>/cloud/a%2Fb/</d:href></c:calendar-home-set>"))),
            .init(body: multi(prop("/cloud/a%2Fb/", "<d:resourcetype><d:collection/></d:resourcetype>") + prop("/cloud/a%2Fb/tasks/", "<d:resourcetype><c:calendar/></d:resourcetype><c:supported-calendar-component-set><c:comp name=\"VTODO\"/></c:supported-calendar-component-set>")))
        ])
        let result = try await CalDAVDiscovery(client: client).discover(address: NextcloudServerAddress.parse("https://\(host)"), credentials: credentials)
        #expect(result.calendars.live.count == 1)
    }

    @Test func equivalentAuthorityBindsMetadataAndHome() async throws {
        let host = "authority-" + UUID().uuidString.lowercased() + ".invalid"
        let client = client(host, [
            .init(body: multi(prop("https://\(host.uppercased()):443/remote.php/dav/", "<c:calendar-home-set><d:href>/home/</d:href></c:calendar-home-set>"))),
            .init(body: multi(prop("https://\(host.uppercased()):443/home/", "<d:resourcetype><d:collection/></d:resourcetype>")))
        ])
        let result = try await CalDAVDiscovery(client: client).discover(address: NextcloudServerAddress.parse("https://\(host)"), credentials: credentials)
        #expect(result.calendars.live.isEmpty)
    }

    @Test func duplicateEquivalentAuthoritiesFailClosed() async throws {
        let host = "duplicate-authority-" + UUID().uuidString.lowercased() + ".invalid"
        let properties = "<d:resourcetype><c:calendar/></d:resourcetype><c:supported-calendar-component-set><c:comp name=\"VTODO\"/></c:supported-calendar-component-set>"
        let listing = prop("/home/", "<d:resourcetype><d:collection/></d:resourcetype>") + prop("/home/tasks/", properties) + prop("https://\(host.uppercased()):443/home/tasks/", properties)
        do { _ = try await runListing(listing, host: host); Issue.record("Duplicate aliases accepted") } catch { }
    }

    @Test func exhaustedPrincipalHomeLookupReportsHomePhase() async throws {
        let host = "home-phase-" + UUID().uuidString.lowercased() + ".invalid"
        let client = client(host, [
            .init(body: multi(prop("/remote.php/dav/", "<d:current-user-principal><d:href>/principal/</d:href></d:current-user-principal>"))),
            .init(status: 404, body: ""), .init(status: 404, body: ""), .init(status: 404, body: "")
        ])
        do {
            _ = try await CalDAVDiscovery(client: client).discover(address: NextcloudServerAddress.parse("https://\(host)"), credentials: credentials)
            Issue.record("Expected home discovery failure")
        } catch let error as DAVDiscoveryFailure {
            #expect(error.stage == .home)
            #expect(error.httpStatus == 404)
        }
    }

    @Test func foreignCollectionReportsCollectionPhase() async throws {
        let host = "foreign-collection-" + UUID().uuidString.lowercased() + ".invalid"
        let listing = prop("/home/", "<d:resourcetype><d:collection/></d:resourcetype>") + prop("https://other.invalid/tasks/", "<d:resourcetype/>")
        do { _ = try await runListing(listing, host: host); Issue.record("Expected foreign collection failure") }
        catch let error as DAVDiscoveryFailure { #expect(error.stage == .collections) }
    }

    @Test func foreignPrincipalReportsPrincipalPhase() async throws {
        let host = "foreign-principal-" + UUID().uuidString.lowercased() + ".invalid"
        let client = client(host, [.init(body: multi(prop("/remote.php/dav/", "<d:current-user-principal><d:href>https://other.invalid/principal/</d:href></d:current-user-principal>")))])
        do {
            _ = try await CalDAVDiscovery(client: client).discover(address: NextcloudServerAddress.parse("https://\(host)"), credentials: credentials)
            Issue.record("Expected foreign principal failure")
        } catch let error as DAVDiscoveryFailure { #expect(error.stage == .principal) }
    }

    @Test func rejectsCrossOriginReference() {
        #expect(throws: (any Error).self) {
            try CalDAVDiscovery.resolveHref("//other.example/path", responseURL: URL(string: "https://example.com/dav/")!, allowedOrigin: URL(string: "https://example.com")!)
        }
    }
    @Test(arguments: [404, 405])
    func exhaustedDiscoveryKeepsHTTPStatus(_ status: Int) async throws {
        let host = "exhausted-" + UUID().uuidString.lowercased() + ".invalid"
        let client = client(host, Array(repeating: .init(status: status, body: ""), count: 3))
        do {
            _ = try await CalDAVDiscovery(client: client).discover(address: NextcloudServerAddress.parse("https://" + host), credentials: credentials)
            Issue.record("Expected discovery failure")
        } catch let error as DAVDiscoveryFailure {
            #expect(error.httpStatus == status)
            #expect(error.reason == (status == 405 ? .methodNotAllowed : .metadataMissing))
        }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 3)
    }

    @Test func missingCollectionHomeReportsItsPhase() async throws {
        let host = "home404-" + UUID().uuidString.lowercased() + ".invalid"
        let client = client(host, [
            .init(body: multi(prop("/remote.php/dav/", "<c:calendar-home-set><d:href>/home/</d:href></c:calendar-home-set>"))),
            .init(status: 404, body: "")])
        do {
            _ = try await CalDAVDiscovery(client: client).discover(address: NextcloudServerAddress.parse("https://" + host), credentials: credentials)
            Issue.record("Expected collection discovery failure")
        } catch let error as DAVDiscoveryFailure {
            #expect(error.httpStatus == 404)
            #expect(error.stage == .collections)
        }
    }

    @Test func discoveryPROPFINDUsesStreamingBodyLimit() async throws {
        let host = "cap-" + UUID().uuidString.lowercased() + ".invalid"
        let config = ScriptedDAVProtocol.install(host: host, responses: [.init(body: String(repeating: "x", count: 64))])
        let limited = CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0), maxResponseBytes: 8)
        await #expect(throws: DAVResponseLimitError.self) {
            try await CalDAVDiscovery(client: limited).discover(address: NextcloudServerAddress.parse("https://" + host), credentials: credentials)
        }
    }

    @Test(arguments: [URLError.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost])
    func connectionProbeRecoversFromVPNStartup(code: URLError.Code) async throws {
        let host = "vpn-start-" + UUID().uuidString.lowercased() + ".invalid"
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(body: "", errorCode: code),
            .init(body: multi(prop("/cloud/remote.php/dav/", "<c:calendar-home-set><d:href>/cloud/home/</d:href></c:calendar-home-set>"))),
            .init(body: multi(prop("/cloud/home/", "<d:resourcetype/>")))
        ])
        #expect(try await ServerURLValidator.testConnection(baseURL: "https://\(host):8443/cloud",
            username: "fixture", password: "secret", configuration: config))
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.url.absoluteString) ==
            ["https://\(host):8443/cloud/remote.php/dav/", "https://\(host):8443/cloud/remote.php/dav/", "https://\(host):8443/cloud/home/"])
    }

    @Test func connectionProbeBoundsPersistentDNSFailure() async throws {
        let host = "vpn-fail-" + UUID().uuidString.lowercased() + ".invalid"
        let config = ScriptedDAVProtocol.install(host: host,
            responses: Array(repeating: .init(body: "", errorCode: .dnsLookupFailed), count: 4))
        await #expect(throws: URLError.self) {
            try await ServerURLValidator.testConnection(baseURL: "https://\(host)",
                username: "fixture", password: "secret", configuration: config)
        }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 3)
    }

    @Test(arguments: [URLError.serverCertificateUntrusted, .serverCertificateHasBadDate,
                      .secureConnectionFailed, .cancelled])
    func connectionProbeDoesNotRetryTrustOrCancellation(code: URLError.Code) async throws {
        let host = "vpn-no-retry-" + UUID().uuidString.lowercased() + ".invalid"
        let config = ScriptedDAVProtocol.install(host: host,
            responses: Array(repeating: .init(body: "", errorCode: code), count: 4))
        do {
            _ = try await ServerURLValidator.testConnection(baseURL: "https://\(host)",
                username: "fixture", password: "secret", configuration: config)
            Issue.record("Expected connection rejection")
        } catch is CancellationError { #expect(code == .cancelled) }
        catch let error as URLError { #expect(error.code == code) }
        catch { Issue.record("Unexpected error: \(error)") }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
    }

    @Test func rejectedRedirectReportsAddressMismatch() async throws {
        let host = "vpn-redirect-" + UUID().uuidString.lowercased() + ".invalid"
        let target = "lan-" + UUID().uuidString.lowercased() + ".invalid"
        _ = ScriptedDAVProtocol.install(host: target, responses: [.init(body: "private")])
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: 302, body: "", redirectURL: URL(string: "https://\(target)/internal"))
        ])
        do {
            _ = try await ServerURLValidator.testConnection(baseURL: "https://\(host)",
                username: "fixture", password: "secret", configuration: config)
            Issue.record("Cross-origin redirect accepted")
        } catch let error as DAVDiscoveryFailure {
            #expect(error.reason == .untrustedAddress)
            #expect(error.httpStatus == 302)
            #expect(error.stage == .principal)
        } catch { Issue.record("Expected address guidance, received \(error)") }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
        #expect(ScriptedDAVProtocol.requests(host: target).isEmpty)
    }

    @Test(arguments: [401, 403])
    func connectionProbeDoesNotRetryRejectedCredentials(status: Int) async throws {
        let host = "vpn-auth-" + UUID().uuidString.lowercased() + ".invalid"
        let config = ScriptedDAVProtocol.install(host: host,
            responses: Array(repeating: .init(status: status, body: ""), count: 4))
        await #expect(throws: CalDAVError.self) {
            try await ServerURLValidator.testConnection(baseURL: "https://\(host)",
                username: "fixture", password: "secret", configuration: config)
        }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
    }

    @Test func sameOriginRedirectStillDiscoversLists() async throws {
        let host = "vpn-safe-redirect-" + UUID().uuidString.lowercased() + ".invalid"
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: 301, body: "", redirectURL: URL(string: "https://\(host)/dav/")),
            .init(body: multi(prop("/dav/", "<c:calendar-home-set><d:href>/home/</d:href></c:calendar-home-set>"))),
            .init(body: multi(prop("/home/", "<d:resourcetype/>")))
        ])
        #expect(try await ServerURLValidator.testConnection(baseURL: "https://\(host)",
            username: "fixture", password: "secret", configuration: config))
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND"])
    }

    @Test func redirectLoopStopsWithUsefulError() async throws {
        let host = "vpn-loop-" + UUID().uuidString.lowercased() + ".invalid"
        let config = ScriptedDAVProtocol.install(host: host, responses: Array(repeating:
            .init(status: 302, body: "", redirectURL: URL(string: "https://\(host)/loop/")), count: 8))
        do {
            _ = try await ServerURLValidator.testConnection(baseURL: "https://\(host)",
                username: "fixture", password: "secret", configuration: config)
            Issue.record("Redirect loop succeeded")
        } catch let error as URLError {
            #expect(error.code == .httpTooManyRedirects)
        } catch { Issue.record("Expected redirect limit error, received \(error)") }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 6)
    }

    @Test func setupRetryAllowanceExhaustionHasDeadlineGuidance() async throws {
        let host = "vpn-deadline-" + UUID().uuidString.lowercased() + ".invalid"
        let config = ScriptedDAVProtocol.install(host: host, responses: [.init(body: "", errorCode: .dnsLookupFailed)])
        do {
            _ = try await DAVDiscoveryContext.$deadline.withValue(ContinuousClock.now.advanced(by: .milliseconds(100))) {
                try await ServerURLValidator.testConnection(baseURL: "https://\(host)",
                    username: "fixture", password: "secret", configuration: config)
            }
            Issue.record("Expected setup deadline failure")
        } catch let error as DAVDiscoveryFailure {
            #expect(error.reason == .deadlineExceeded)
            #expect(error.stage == .principal)
        } catch { Issue.record("Expected deadline guidance, received \(error)") }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
    }

}
