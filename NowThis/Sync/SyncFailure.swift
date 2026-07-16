import Foundation

/// A user-facing classification of a sync failure.
///
/// The sync layer already detects *what* went wrong via typed `CalDAVError`s.
/// `SyncFailure` translates those technical errors into the small set of
/// categories a person can actually act on — wrong password vs. offline vs.
/// no permission — each with plain-language guidance. It drives the in-app
/// `SyncFailureBanner` and the Settings status line.
struct SyncFailure: Equatable {

    enum Category {
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
        guard !isCancellation(error) else { return nil }

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
            return SyncFailure(category: .connection, message: connectionMessage)
        }

        return SyncFailure(category: .unknown, message: unknownMessage)
    }

    private static func from(_ error: CalDAVError) -> SyncFailure {
        switch error {
        case .unauthorized:
            return SyncFailure(category: .authentication, message: authMessage)
        case .forbidden:
            return SyncFailure(category: .accessDenied, message: accessDeniedMessage)
        case .networkError:
            return SyncFailure(category: .connection, message: connectionMessage)
        case .serverError:
            return SyncFailure(category: .server, message: serverMessage)
        case .rateLimited:
            return SyncFailure(category: .busy, message: busyMessage)
        case .notFound, .invalidURL, .noCalendarHomeSet, .noUserPrincipal:
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

    // MARK: - Messages

    static let authMessage = String(localized:
        "Can't sign in — your username or password may be wrong. Tap to update your account in Settings.")
    static let accessDeniedMessage = String(localized:
        "Signed in, but your account doesn't have access to this calendar. Contact your server administrator.")
    static let connectionMessage = String(localized:
        "Can't reach the server. Check your internet connection.")
    static let serverMessage = String(localized:
        "The server is having problems. We'll keep trying.")
    static let busyMessage = String(localized:
        "The server is busy. We'll try again shortly.")
    static let configurationMessage = String(localized:
        "Couldn't find your calendars. Check your server address in Settings.")
    static let unknownMessage = String(localized:
        "Sync failed. Pull down to refresh and try again.")
}
