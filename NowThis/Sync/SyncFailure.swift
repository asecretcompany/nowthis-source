import Foundation

/// A user-facing classification of a sync failure.
///
/// The sync layer already detects *what* went wrong via typed `CalDAVError`s.
/// `SyncFailure` translates those technical errors into the small set of
/// categories a person can actually act on — wrong password vs. offline vs.
/// no permission — each with plain-language guidance. It drives the in-app
/// `SyncFailureBanner` and the Settings status line.
struct SyncFailure: Equatable, Sendable {

    enum Category: Sendable {
        /// Wrong username/password, or no credentials — the user must re-auth.
        case authentication
        /// Signed in, but the account lacks permission to this calendar (403).
        case accessDenied
        /// Can't reach the server (offline, timeout, DNS).
        case connection
        /// Server-side problem (5xx). Transient; sync keeps retrying.
        case server
        /// Server is rate-limiting us (429). Transient.
        case busy
        /// Bad server address or failed CalDAV discovery — fixable in Settings.
        case configuration
        /// Anything we can't classify more specifically.
        case unknown
    }

    let category: Category

    /// Plain-language, actionable guidance to show the user.
    let message: String

    /// The HTTP status only; never store response bodies, URLs or credentials.
    let httpStatusCode: Int?
    let discoveryStage: DAVDiscoveryFailure.Stage?
    let requestMethod: DAVDiscoveryFailure.Method?

    init(category: Category, message: String, httpStatusCode: Int? = nil, discoveryStage: DAVDiscoveryFailure.Stage? = nil, requestMethod: DAVDiscoveryFailure.Method? = nil) {
        self.category = category
        self.message = message
        self.httpStatusCode = httpStatusCode
        self.discoveryStage = discoveryStage
        self.requestMethod = requestMethod
    }

    /// `true` when the user can resolve this themselves by editing their
    /// account in Settings — drives the banner's "tap to fix" affordance.
    var isUserActionable: Bool {
        switch category {
        case .authentication, .configuration:
            return true
        case .accessDenied, .connection, .server, .busy, .unknown:
            return false
        }
    }

    // MARK: - Mapping

    /// Translates a thrown error into a user-facing failure, or `nil` if the
    /// error is a cancellation (an intentional stop, not a real failure).
    static func from(_ error: Error) -> SyncFailure? {
        guard let failure = classify(error) else { return nil }
        return SyncFailure(category: failure.category, message: failure.message,
                           httpStatusCode: httpStatus(for: error),
                           discoveryStage: (error as? DAVDiscoveryFailure)?.stage,
                           requestMethod: (error as? DAVDiscoveryFailure)?.method)
    }

    private static func httpStatus(for error: Error) -> Int? {
        if let discovery = error as? DAVDiscoveryFailure { return discovery.httpStatus }
        if let deferred = error as? RetryDeferredError { return deferred.httpStatusCode }
        if let retry = error as? HTTPRetryError { return retry.statusCode }
        if let redirect = error as? DAVRedirectRejection { return redirect.httpStatus }
        if let sync = error as? SyncError, case .calDAVError(let underlying) = sync {
            return httpStatus(for: underlying)
        }
        guard let dav = error as? CalDAVError else { return nil }
        switch dav {
        case .unauthorized: return 401
        case .forbidden: return 403
        case .notFound: return 404
        case .conflict: return 412
        case .rateLimited: return 429
        case .serverError(let status): return status
        case .networkError(let underlying): return httpStatus(for: underlying)
        default: return nil
        }
    }

    private static func classify(_ error: Error) -> SyncFailure? {
        guard !isCancellation(error) else { return nil }

        if let discovery = error as? DAVDiscoveryFailure {
            return SyncFailure(category: .unknown, message: discoveryMessage(discovery.reason))
        }
        if error is DAVRedirectRejection {
            return SyncFailure(category: .unknown, message: discoveryMessage(.untrustedAddress))
        }
        if let hold = error as? SyncResourceState.Hold {
            return SyncFailure(category: .unknown, message: hold.localizedDescription)
        }
        if error is TaskPhotoAttachmentError {
            return SyncFailure(category: .unknown, message: photoMessage)
        }
        if error is RetryDeferredError { return SyncFailure(category: .busy, message: busyMessage) }
        if error is HTTPRetryError { return SyncFailure(category: .server, message: serverMessage) }
        if let syncError = error as? SyncError {
            switch syncError {
            case .calDAVError(let calDAVError):
                return from(calDAVError)
            case .noAccount, .noCredentials:
                return SyncFailure(category: .authentication, message: authMessage)
            case .parserError, .persistenceError:
                return SyncFailure(category: .unknown, message: unknownMessage)
            }
        }

        if let calDAVError = error as? CalDAVError {
            return from(calDAVError)
        }

        if error is URLError {
            return SyncFailure(category: .connection, message: connectionGuidance(for: error) ?? connectionMessage)
        }

        return SyncFailure(category: .unknown, message: unknownMessage)
    }

    private static func from(_ error: CalDAVError) -> SyncFailure {
        switch error {
        case .unauthorized:
            return SyncFailure(category: .authentication, message: authMessage)
        case .forbidden:
            return SyncFailure(category: .accessDenied, message: accessDeniedMessage)
        case .networkError(let underlying) where underlying is DAVRedirectRejection:
            return SyncFailure(category: .unknown, message: discoveryMessage(.untrustedAddress))
        case .networkError:
            return SyncFailure(category: .connection, message: connectionGuidance(for: error) ?? connectionMessage)
        case .serverError(statusCode: 405):
            return SyncFailure(category: .server, message: discoveryMessage(.methodNotAllowed))
        case .serverError:
            return SyncFailure(category: .server, message: serverMessage)
        case .rateLimited:
            return SyncFailure(category: .busy, message: busyMessage)
        case .notFound:
            return SyncFailure(category: .unknown, message: notFoundMessage)
        case .invalidURL, .noCalendarHomeSet, .noUserPrincipal:
            return SyncFailure(category: .configuration, message: configurationMessage)
        case .conflict, .invalidResponse:
            return SyncFailure(category: .unknown, message: unknownMessage)
        }
    }

    /// A cancellation is an intentional stop (backgrounding, a newer sync
    /// superseding this one) — never surface it as a failure.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let calDAVError = error as? CalDAVError,
           case .networkError(let underlying) = calDAVError {
            return isCancellation(underlying)
        }
        return false
    }

    static func discoveryMessage(_ reason: DAVDiscoveryFailure.Reason) -> String {
        switch reason {
        case .metadataMissing: String(localized: "The server did not provide the information needed to find your lists.")
        case .untrustedAddress: String(localized: "The server returned an unexpected address. Check its proxy settings or contact its administrator.")
        case .incompleteListing: String(localized: "The server returned an incomplete list response. Your saved tasks have been kept.")
        case .unsupportedResponse: String(localized: "The server did not return a valid CalDAV response. A login page or proxy may be blocking access.")
        case .methodNotAllowed: String(localized: "The server or proxy blocked a required sync request. Contact its administrator.")
        case .deadlineExceeded: String(localized: "Server discovery took too long. Check the connection and try again.")
        case .ambiguousIdentity: String(localized: "The server returned conflicting list addresses. Your saved tasks have been kept.")
        }
    }

    /// Shared by setup, browser login, account checks and sync. Never reuse
    /// NSError descriptions: they may contain a private hostname or token.
    static func connectionGuidance(for error: Error) -> String? {
        if let sync = error as? SyncError, case .calDAVError(let underlying) = sync {
            return connectionGuidance(for: underlying)
        }
        if let dav = error as? CalDAVError, case .networkError(let underlying) = dav {
            return connectionGuidance(for: underlying)
        }
        if error is DAVRedirectRejection { return discoveryMessage(.untrustedAddress) }
        guard let urlError = error as? URLError else { return nil }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed:
            return String(localized: "Can't find the server. Check the server name, DNS settings and any VPN connection. For a Tailscale machine name, use the full name ending in .ts.net.",
                          comment: "DNS failure; custom split-DNS hostnames remain supported. Never include the user's actual server name.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return String(localized: "Couldn't establish a secure connection. Use the HTTPS server name that matches its certificate, not a replacement IP address. For Tailscale HTTPS, use the full name ending in .ts.net.",
                          comment: "TLS or certificate failure; do not suggest bypassing certificate validation.")
        case .cannotConnectToHost, .notConnectedToInternet, .networkConnectionLost, .timedOut:
            return String(localized: "Can't reach the server. Check your internet and VPN connections. For a local server, also check NowThis's Local Network access in Settings.",
                          comment: "Possible reachability causes, not a claim that Local Network permission is denied.")
        case .httpTooManyRedirects:
            return String(localized: "The server redirected too many times. Check its proxy settings or contact its administrator.",
                          comment: "The bounded redirect limit was exceeded; no destination URL is included.")
        default: return nil
        }
    }

    // MARK: - Messages

    static let photoMessage = String(localized:
        "A task photo could not be synced because its attachment is invalid or too large. Ask the list owner to replace it.")
    static let authMessage = String(localized:
        "Can't sign in — your username or password may be wrong. Tap to update your account in Settings.")
    static let accessDeniedMessage = String(localized:
        "Signed in, but your account doesn't have access to this list. Contact your server administrator.")
    static let connectionMessage = String(localized:
        "Can't reach the server. Check your internet connection.")
    static let serverMessage = String(localized:
        "The server is having problems. We'll keep trying.")
    static let busyMessage = String(localized:
        "The server is busy. We'll try again shortly.")
    static let configurationMessage = String(localized:
        "Couldn't find your lists. Check your server address in Settings.")
    static let notFoundMessage = String(localized:
        "The server could not find a requested list or task. Your other lists may still be available.")
    static let unknownMessage = String(localized:
        "Sync failed. Pull down to refresh and try again.")
}
