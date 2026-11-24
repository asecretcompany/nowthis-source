import Foundation

/// Validates and normalizes Nextcloud server URLs.
///
/// Handles common user input patterns:
/// - Missing scheme → prepends `https://`
/// - Trailing slashes → stripped
/// - HTTP scheme → rejected as invalid (the app has no App Transport Security
///   exception, so iOS blocks cleartext HTTP; we surface a clear error rather
///   than letting the connection fail later as an opaque ATS error)
struct ServerURLValidator {

    /// The result of URL validation.
    struct ValidationResult {
        let normalizedURL: String
        let isHTTPS: Bool
        let isValid: Bool
        let errorMessage: String?
    }

    /// Validates and normalizes a user-entered server URL.
    ///
    /// - Parameter input: Raw user input (e.g., "cloud.example.com", "http://myserver.local")
    /// - Returns: A `ValidationResult` with the normalized URL and security status.
    static func validate(_ input: String) -> ValidationResult {
        do {
            let address = try NextcloudServerAddress.parse(input)
            return ValidationResult(normalizedURL: address.baseURL.absoluteString, isHTTPS: true, isValid: true, errorMessage: nil)
        } catch {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let message: String
            if trimmed.isEmpty {
                message = String(localized: "Please enter a server URL.")
            } else if trimmed.lowercased().hasPrefix("http://") {
                message = String(localized: "HTTPS is required. Please use a server URL starting with https://.")
            } else {
                message = String(localized: "Invalid URL format. Example: cloud.example.com")
            }
            return ValidationResult(normalizedURL: input, isHTTPS: false, isValid: false, errorMessage: message)
        }
    }

    /// Checks the same read-only discovery stages that sync uses. Principal
    /// authentication alone cannot establish that the list home is reachable.
    /// An empty list home is valid; this probe never imports or modifies data.
    static func testConnection(
        baseURL: String,
        username: String,
        password: String,
        configuration: URLSessionConfiguration? = nil
    ) async throws -> Bool {
        let validation = validate(baseURL)
        guard validation.isValid else { throw CalDAVError.invalidURL }
        let config = configuration ?? URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 45
        let client = CalDAVClient(configuration: config,
            retryPolicy: .connectionSetup)
        let credentials = CalDAVClient.Credentials(username: username, password: password)
        let address = try NextcloudServerAddress.parse(baseURL)
        _ = try await CalDAVDiscovery(client: client).discover(address: address, credentials: credentials)
        return true
    }
}
