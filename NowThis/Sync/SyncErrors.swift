import Foundation

/// Errors for CalDAV network operations.
///
/// Every case's text is shown to the user verbatim — `AccountEditView` and `AccountSetupView`
/// display `error.localizedDescription` inline under the server fields — so each one is a
/// catalog string, not a `return "…"`. A bare literal here compiles, renders, and ships English
/// to all five languages without any catalog guard noticing.
enum CalDAVError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case forbidden
    case notFound
    case conflict(etag: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(statusCode: Int)
    case networkError(underlying: Error)
    case invalidResponse
    case noCalendarHomeSet
    case noUserPrincipal

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(
                localized: "caldav.error.invalidURL",
                defaultValue: "Invalid server URL.",
                comment: "Sync error shown under the server address field when the address the user typed is not a usable URL.")
        case .unauthorized:
            return String(
                localized: "caldav.error.unauthorized",
                defaultValue: "Authentication failed. Check your username and password.",
                comment: "Sync error for HTTP 401. The server rejected the credentials.")
        case .forbidden:
            return String(
                localized: "caldav.error.forbidden",
                defaultValue: "Access denied to the requested resource.",
                comment: "Sync error for HTTP 403. The credentials are valid but the account is not allowed to read or write this item.")
        case .notFound:
            return String(
                localized: "caldav.error.notFound",
                defaultValue: "The requested resource was not found.",
                comment: "Sync error for HTTP 404. The item or address is gone from the server.")
        case .conflict:
            return String(
                localized: "caldav.error.conflict",
                defaultValue: "The task was modified on the server. Please refresh and try again.",
                comment: "Sync error for HTTP 412. Someone else changed the same task first, so this device's version was not saved.")
        case .rateLimited:
            return String(
                localized: "caldav.error.rateLimited",
                defaultValue: "Too many requests. Please wait a moment and try again.",
                comment: "Sync error for HTTP 429. The server is asking the app to slow down.")
        case .serverError(let code):
            return String(
                localized: "caldav.error.serverError",
                defaultValue: "Server error (\(code)). Please try again later.",
                comment: "Sync error for any HTTP 5xx. The number in parentheses is the status code, shown so support can identify the failure.")
        case .networkError(let error):
            return String(
                localized: "caldav.error.network",
                defaultValue: "Network error: \(error.localizedDescription)",
                comment: "Sync error when the request never reached the server. The placeholder is the system's own already-translated message.")
        case .invalidResponse:
            return String(
                localized: "caldav.error.invalidResponse",
                defaultValue: "Invalid response from server.",
                comment: "Sync error when the server replied with something the app cannot read as CalDAV.")
        case .noCalendarHomeSet:
            // Was "Could not discover calendar home on this server." — `calendar-home-set` is a
            // CalDAV property name, and the glossary reserves "Calendar" for the entirely
            // different EventKit feature in Settings.
            return String(
                localized: "caldav.error.noCollectionHome",
                defaultValue: "Couldn't find any lists on this server. Check the server address.",
                comment: "Sync error during account setup: the server answered, but advertised no place where lists are stored.")
        case .noUserPrincipal:
            // Was "Could not discover user principal URL." — `principal-URL` is a protocol term.
            return String(
                localized: "caldav.error.noUserPrincipal",
                defaultValue: "Couldn't identify your account on this server. Check the server address.",
                comment: "Sync error during account setup: the server answered, but did not say which account the credentials belong to.")
        }
    }
}

/// Errors for iCalendar parsing operations.
///
/// These reach the same inline error area as `CalDAVError`, wrapped in `SyncError.parserError`.
enum ParserError: Error, LocalizedError {
    case invalidFormat
    case missingUID
    case missingComponent(String)
    case unexpectedEncoding

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return String(
                localized: "parser.error.invalidFormat",
                defaultValue: "Invalid iCalendar format.",
                comment: "Sync error: the server sent data that is not valid iCalendar. iCalendar is the standard's own name and is not translated.")
        case .missingUID:
            // Was "VTODO is missing the required UID property." — VTODO and UID are wire-format
            // names the user has no way to act on.
            return String(
                localized: "parser.error.missingUID",
                defaultValue: "A task on the server is missing its unique identifier.",
                comment: "Sync error: an item on the server has no stable identity, so it cannot be matched to a task on this device.")
        case .missingComponent(let name):
            return String(
                localized: "parser.error.missingComponent",
                defaultValue: "Missing required component: \(name)",
                comment: "Sync error. The placeholder is an untranslated iCalendar component name such as VTODO or VCALENDAR.")
        case .unexpectedEncoding:
            return String(
                localized: "parser.error.unexpectedEncoding",
                defaultValue: "Unexpected character encoding in iCalendar data.",
                comment: "Sync error: the server's reply was not readable as text.")
        }
    }
}

/// Errors for sync orchestration.
enum SyncError: Error, LocalizedError {
    case noAccount
    case noCredentials
    case calDAVError(CalDAVError)
    case parserError(ParserError)
    case persistenceError(Error)

    var errorDescription: String? {
        switch self {
        case .noAccount:
            return String(
                localized: "sync.error.noAccount",
                defaultValue: "No account configured for sync.",
                comment: "Sync error shown when sync runs with no server account set up.")
        case .noCredentials:
            return String(
                localized: "sync.error.noCredentials",
                defaultValue: "Credentials not found. Please re-authenticate.",
                comment: "Sync error: the account exists but its saved password is gone from the Keychain, so the user must sign in again.")
        case .calDAVError(let error):
            return error.errorDescription
        case .parserError(let error):
            return error.errorDescription
        case .persistenceError(let error):
            return String(
                localized: "sync.error.persistence",
                defaultValue: "Database error: \(error.localizedDescription)",
                comment: "Sync error when saving to the on-device store failed. The placeholder is the system's own already-translated message.")
        }
    }
}
