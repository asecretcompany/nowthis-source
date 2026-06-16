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
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return ValidationResult(
                normalizedURL: "",
                isHTTPS: false,
                isValid: false,
                errorMessage: String(localized: "Please enter a server URL.")
            )
        }

        // Add scheme if missing
        var urlString = trimmed
        if !urlString.contains("://") {
            urlString = "https://\(urlString)"
        }

        // Strip trailing slashes
        while urlString.hasSuffix("/") {
            urlString = String(urlString.dropLast())
        }

        // Validate URL structure
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else {
            return ValidationResult(
                normalizedURL: urlString,
                isHTTPS: false,
                isValid: false,
                errorMessage: String(localized: "Invalid URL format. Example: cloud.example.com")
            )
        }

        // Enforce HTTPS
        guard scheme == "https" else {
            return ValidationResult(
                normalizedURL: urlString,
                isHTTPS: false,
                isValid: false,
                errorMessage: String(localized: "HTTPS is required. Please use a server URL starting with https://.")
            )
        }

        return ValidationResult(
            normalizedURL: urlString,
            isHTTPS: true,
            isValid: true,
            errorMessage: nil
        )
    }

    /// Attempts a basic connectivity check against the Nextcloud server.
    ///
    /// Tries to reach `/.well-known/caldav` which should redirect to the
    /// CalDAV principal URL on a properly configured Nextcloud server.
    ///
    /// - Parameters:
    ///   - baseURL: The normalized server base URL.
    ///   - username: The Nextcloud username.
    ///   - password: The app-password.
    /// - Returns: `true` if the server responds with a success or redirect status.
    static func testConnection(
        baseURL: String,
        username: String,
        password: String
    ) async throws -> Bool {
        // Use the direct Nextcloud CalDAV endpoint instead of /.well-known/caldav.
        // The well-known URL can redirect to HTTP on misconfigured servers,
        // triggering ATS failures even when the actual sync path works fine.
        guard let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/remote.php/dav/principals/users/\(encodedUsername)/") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")

        // Basic auth header
        let credentials = "\(username):\(password)"
        if let credentialData = credentials.data(using: .utf8) {
            let base64 = credentialData.base64EncodedString()
            request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
        }

        // Minimal PROPFIND body
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:current-user-principal />
          </d:prop>
        </d:propfind>
        """
        request.httpBody = body.data(using: .utf8)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        let delegate = CalDAVRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        let (_, response) = try await session.data(for: request)
        session.finishTasksAndInvalidate()

        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }

        // 429 = rate limited. Throw a specific error so the UI can show
        // "Too many requests" instead of the misleading "check credentials".
        if httpResponse.statusCode == 429 {
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw CalDAVError.rateLimited(retryAfter: retryAfter)
        }

        // 200 or 207 Multi-Status indicates a working CalDAV endpoint.
        let successCodes = [200, 207]
        return successCodes.contains(httpResponse.statusCode)
    }
}

/// URLSession delegate that preserves the HTTP method (e.g., PROPFIND) across redirects.
///
/// By default, `URLSession` changes non-standard HTTP methods to GET when following
/// 301/302 redirects. This delegate rebuilds the redirected request to keep the
/// original method and headers, which is required for CalDAV PROPFIND requests.
private final class CalDAVRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Rebuild the redirect request preserving the original method and headers
        guard let originalRequest = task.originalRequest else {
            completionHandler(request)
            return
        }

        var redirectRequest = request
        redirectRequest.httpMethod = originalRequest.httpMethod
        redirectRequest.httpBody = originalRequest.httpBody

        // Only forward credentials to same-origin redirects to prevent leaking
        let sameOrigin = originalRequest.url?.host == request.url?.host
            && originalRequest.url?.scheme == request.url?.scheme
            && originalRequest.url?.port == request.url?.port

        if sameOrigin {
            if let auth = originalRequest.value(forHTTPHeaderField: "Authorization") {
                redirectRequest.setValue(auth, forHTTPHeaderField: "Authorization")
            }
        }

        // Non-sensitive headers — always preserve for CalDAV compatibility
        if let contentType = originalRequest.value(forHTTPHeaderField: "Content-Type") {
            redirectRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let depth = originalRequest.value(forHTTPHeaderField: "Depth") {
            redirectRequest.setValue(depth, forHTTPHeaderField: "Depth")
        }

        completionHandler(redirectRequest)
    }
}
