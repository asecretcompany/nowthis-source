import Foundation

/// Errors for CalDAV network operations.
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
            return "Invalid server URL."
        case .unauthorized:
            return "Authentication failed. Check your username and password."
        case .forbidden:
            return "Access denied to the requested resource."
        case .notFound:
            return "The requested resource was not found."
        case .conflict:
            return "The task was modified on the server. Please refresh and try again."
        case .rateLimited:
            return "Too many requests. Please wait a moment and try again."
        case .serverError(let code):
            return "Server error (\(code)). Please try again later."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server."
        case .noCalendarHomeSet:
            return "Could not discover calendar home on this server."
        case .noUserPrincipal:
            return "Could not discover user principal URL."
        }
    }
}

/// Errors for iCalendar parsing operations.
enum ParserError: Error, LocalizedError {
    case invalidFormat
    case missingUID
    case missingComponent(String)
    case unexpectedEncoding

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid iCalendar format."
        case .missingUID:
            return "VTODO is missing the required UID property."
        case .missingComponent(let name):
            return "Missing required component: \(name)"
        case .unexpectedEncoding:
            return "Unexpected character encoding in iCalendar data."
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
            return "No account configured for sync."
        case .noCredentials:
            return "Credentials not found. Please re-authenticate."
        case .calDAVError(let error):
            return error.errorDescription
        case .parserError(let error):
            return error.errorDescription
        case .persistenceError(let error):
            return "Database error: \(error.localizedDescription)"
        }
    }
}
