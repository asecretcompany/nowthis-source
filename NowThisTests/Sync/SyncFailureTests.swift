import Testing
import Foundation

@testable import NowThis

/// Verifies that raw thrown errors are translated into the small set of
/// user-facing `SyncFailure` categories that drive the in-app banner and the
/// Settings status line.
@Suite("Sync Failure Classification")
struct SyncFailureTests {

    // MARK: - Authentication

    @Test("401 unauthorized maps to authentication (actionable)")
    func unauthorizedIsAuthentication() {
        let failure = SyncFailure.from(CalDAVError.unauthorized)
        #expect(failure?.category == .authentication)
        #expect(failure?.isUserActionable == true)
        #expect(failure?.message.isEmpty == false)
    }

    @Test("Missing credentials maps to authentication")
    func noCredentialsIsAuthentication() {
        #expect(SyncFailure.from(SyncError.noCredentials)?.category == .authentication)
        #expect(SyncFailure.from(SyncError.noAccount)?.category == .authentication)
    }

    @Test("Wrapped CalDAV unauthorized unwraps to authentication")
    func wrappedUnauthorizedUnwraps() {
        let failure = SyncFailure.from(SyncError.calDAVError(.unauthorized))
        #expect(failure?.category == .authentication)
    }

    // MARK: - Access denied

    @Test("403 forbidden maps to accessDenied (not self-serviceable)")
    func forbiddenIsAccessDenied() {
        let failure = SyncFailure.from(CalDAVError.forbidden)
        #expect(failure?.category == .accessDenied)
        #expect(failure?.isUserActionable == false)
    }

    // MARK: - Connection

    @Test("Network errors map to connection")
    func networkErrorIsConnection() {
        let failure = SyncFailure.from(
            CalDAVError.networkError(underlying: URLError(.timedOut)))
        #expect(failure?.category == .connection)
    }

    @Test("Bare URLError maps to connection")
    func bareURLErrorIsConnection() {
        #expect(SyncFailure.from(URLError(.notConnectedToInternet))?.category == .connection)
        #expect(SyncFailure.from(URLError(.cannotConnectToHost))?.category == .connection)
    }

    // MARK: - Server / busy

    @Test("5xx server errors map to server")
    func serverErrorIsServer() {
        for code in [500, 502, 503] {
            #expect(SyncFailure.from(CalDAVError.serverError(statusCode: code))?.category == .server)
        }
    }

    @Test("429 rate limited maps to busy")
    func rateLimitedIsBusy() {
        #expect(SyncFailure.from(CalDAVError.rateLimited(retryAfter: 5))?.category == .busy)
    }

    @Test("Sync error details retain the actual HTTP response code, including wrapped and retry errors")
    func retainsHTTPStatusForSupport() {
        let cases: [(any Error, Int)] = [
            (CalDAVError.serverError(statusCode: 400), 400),
            (CalDAVError.serverError(statusCode: 413), 413),
            (CalDAVError.serverError(statusCode: 500), 500),
            (SyncError.calDAVError(.serverError(statusCode: 503)), 503),
            (HTTPRetryError(statusCode: 502, retryAfter: 10), 502),
            (CalDAVError.unauthorized, 401),
            (CalDAVError.forbidden, 403),
            (CalDAVError.notFound, 404),
            (CalDAVError.conflict(etag: "private-etag"), 412),
            (CalDAVError.rateLimited(retryAfter: 5), 429)
        ]
        for (error, status) in cases {
            #expect(SyncFailure.from(error)?.httpStatusCode == status)
        }
    }

    @Test("Errors without an HTTP response do not invent a status or reveal private system details")
    func nonHTTPFailureHasNoStatus() {
        let privateError = NSError(domain: "private-server.example", code: 503,
            userInfo: [NSLocalizedDescriptionKey: "private username and task content"])
        for error: any Error in [privateError, URLError(.timedOut), CalDAVError.invalidResponse] {
            let failure = SyncFailure.from(error)
            #expect(failure?.httpStatusCode == nil)
            #expect(failure?.message.contains("private") == false)
        }
        #expect(SyncFailure.from(CancellationError()) == nil)
    }

    // MARK: - Configuration

    @Test("Discovery and addressing failures map to configuration (actionable)")
    func discoveryFailuresAreConfiguration() {
        let cases: [CalDAVError] = [
            .notFound, .invalidURL, .noCalendarHomeSet, .noUserPrincipal
        ]
        for error in cases {
            let failure = SyncFailure.from(error)
            #expect(failure?.category == .configuration, "\(error) should be configuration")
            #expect(failure?.isUserActionable == true)
        }
    }

    // MARK: - Unknown

    @Test("Conflict and invalid responses fall back to unknown")
    func miscErrorsAreUnknown() {
        #expect(SyncFailure.from(CalDAVError.conflict(etag: nil))?.category == .unknown)
        #expect(SyncFailure.from(CalDAVError.invalidResponse)?.category == .unknown)
        #expect(SyncFailure.from(SyncError.parserError(.invalidFormat))?.category == .unknown)
    }

    // MARK: - Cancellation is not a failure

    @Test("Cancellation returns nil (intentional stop, not a failure)")
    func cancellationIsNotAFailure() {
        #expect(SyncFailure.from(CancellationError()) == nil)
        #expect(SyncFailure.from(URLError(.cancelled)) == nil)
        #expect(SyncFailure.from(
            CalDAVError.networkError(underlying: URLError(.cancelled))) == nil)
    }

    // MARK: - Equatable (drives banner de-duplication / dismissal)

    @Test("Same underlying error produces equal failures")
    func equalFailuresForSameError() {
        #expect(SyncFailure.from(CalDAVError.unauthorized)
                == SyncFailure.from(CalDAVError.unauthorized))
        #expect(SyncFailure.from(CalDAVError.forbidden)
                != SyncFailure.from(CalDAVError.unauthorized))
    }

    // MARK: - Banner visibility logic

    @Test("Banner shows for a fresh failure, hides once dismissed")
    @MainActor
    func bannerVisibility() {
        let failure = SyncFailure.from(CalDAVError.unauthorized)
        #expect(SyncFailureBanner.isVisible(failure: failure, dismissed: nil) == true)
        #expect(SyncFailureBanner.isVisible(failure: failure, dismissed: failure) == false)
        #expect(SyncFailureBanner.isVisible(failure: nil, dismissed: failure) == false)
    }

    @Test("A new, different failure reappears after a prior dismissal")
    @MainActor
    func differentFailureReappears() {
        let dismissed = SyncFailure.from(CalDAVError.unauthorized)
        let fresh = SyncFailure.from(CalDAVError.forbidden)
        #expect(SyncFailureBanner.isVisible(failure: fresh, dismissed: dismissed) == true)
    }
}
