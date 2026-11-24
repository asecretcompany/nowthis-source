import Foundation

/// Manages the Nextcloud Login Flow v2 HTTP protocol.
///
/// The flow has two phases:
/// 1. **Initiate** — `POST /index.php/login/v2` returns a poll token and login URL.
/// 2. **Poll** — `POST /login/v2/poll` with the token until the user grants access
///    or the 20-minute token expires.
///
/// On success, the server returns a `loginName` and `appPassword` that are used
/// identically to a manually-created app password for CalDAV Basic Auth.
///
/// **Reference:** https://docs.nextcloud.com/server/latest/developer_manual/client_apis/LoginFlow/index.html
actor LoginFlowClient {

    /// The result of a successful `POST /index.php/login/v2` initiation.
    struct LoginFlowSession {
        let pollToken: String
        let pollEndpoint: URL
        let loginURL: URL
        let serverBaseURL: URL
    }

    /// The credentials returned after a successful Login Flow grant.
    struct LoginFlowResult {
        let server: String
        let loginName: String
        let appPassword: String
    }

    private static let userAgent = "NowThis/1.0 (iOS)"
    private static let pollInterval: Duration = .seconds(2)
    private static let tokenTimeout: TimeInterval = 20 * 60 // 20 minutes

    private let transport: URLSession
    private let maxResponseBytes: Int

    init(configuration: URLSessionConfiguration = .default, maxResponseBytes: Int = 1_048_576) {
        precondition(maxResponseBytes > 0)
        self.maxResponseBytes = maxResponseBytes
        transport = URLSession(configuration: configuration, delegate: LoginFlowRedirectDelegate(), delegateQueue: nil)
    }

    deinit {
        transport.invalidateAndCancel()
    }

    // MARK: - Initiate

    /// Initiates Login Flow v2 by requesting a poll token and login URL from the server.
    ///
    /// - Parameter serverURL: The normalized base URL (e.g. `https://cloud.example.com`).
    /// - Returns: A `LoginFlowSession` containing the poll token and browser login URL.
    func initiate(serverURL: String) async throws -> LoginFlowSession {
        guard let serverBaseURL = LoginFlowURLPolicy.normalizedBaseURL(serverURL),
              let url = URL(string: "\(serverBaseURL.absoluteString)/index.php/login/v2") else {
            throw LoginFlowError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("true", forHTTPHeaderField: "OCS-APIREQUEST")

        let (data, response) = try await boundedResponse(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LoginFlowError.serverRejected
        }

        let decoded = try JSONDecoder().decode(InitiateResponse.self, from: data)

        guard let pollURL = URL(string: decoded.poll.endpoint),
              LoginFlowURLPolicy.sameOrigin(pollURL, serverBaseURL) else {
            throw LoginFlowError.untrustedEndpoint
        }
        // An HTTPS SSO host is allowed only for the browser. No poll token or
        // app password is added to this URL or sent to it by this client.
        guard let loginURL = URL(string: decoded.login),
              LoginFlowURLPolicy.isHTTPS(loginURL) else {
            throw LoginFlowError.invalidResponse
        }

        return LoginFlowSession(
            pollToken: decoded.poll.token,
            pollEndpoint: pollURL,
            loginURL: loginURL,
            serverBaseURL: serverBaseURL
        )
    }

    // MARK: - Poll

    /// Polls the Login Flow endpoint until the user grants access or the token expires.
    ///
    /// Polls every 2 seconds. The server returns `404` while the user hasn't
    /// completed login, and `200` exactly once with the credentials.
    ///
    /// - Parameter session: The session from `initiate()`.
    /// - Returns: The `LoginFlowResult` containing server URL, login name, and app password.
    func poll(session: LoginFlowSession) async throws -> LoginFlowResult {
        guard LoginFlowURLPolicy.sameOrigin(session.pollEndpoint, session.serverBaseURL) else {
            throw LoginFlowError.untrustedEndpoint
        }
        let deadline = Date().addingTimeInterval(Self.tokenTimeout)

        while Date() < deadline {
            try Task.checkCancellation()

            var request = URLRequest(url: session.pollEndpoint)
            request.httpMethod = "POST"
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("true", forHTTPHeaderField: "OCS-APIREQUEST")
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
            // '+' is a literal plus in URL queries, but means space in form bodies.
            let tokenCharacters = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
            let encodedToken = session.pollToken.addingPercentEncoding(withAllowedCharacters: tokenCharacters)!
            request.httpBody = "token=\(encodedToken)".data(using: .utf8)

            let (data, response) = try await boundedResponse(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw LoginFlowError.serverRejected
            }
            if http.statusCode == 200 {
                let result = try JSONDecoder().decode(PollResponse.self, from: data)
                guard let returnedBaseURL = LoginFlowURLPolicy.returnedBaseURL(result.server),
                      LoginFlowURLPolicy.sameOrigin(returnedBaseURL, session.serverBaseURL),
                      returnedBaseURL.path(percentEncoded: true) == session.serverBaseURL.path(percentEncoded: true) else {
                    throw LoginFlowError.serverMismatch
                }

                return LoginFlowResult(
                    server: session.serverBaseURL.absoluteString,
                    loginName: result.loginName,
                    appPassword: result.appPassword
                )
            }

            guard http.statusCode == 404 else {
                throw LoginFlowError.serverRejected
            }
            // 404 = user hasn't granted access yet — keep polling
            try await Task.sleep(for: Self.pollInterval)
        }

        throw LoginFlowError.timeout
    }

    private func boundedResponse(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await DAVResponseLimit(maxBytes: maxResponseBytes).data(
                for: request, configuration: transport.configuration, session: transport
            ) { proposed in
                LoginFlowRedirectDelegate.redirectRequest(originalURL: request.url, proposed: proposed)
            }
        } catch is DAVRedirectRejection {
            throw LoginFlowError.untrustedEndpoint
        }
    }

    // MARK: - Codable Response Types

    private struct InitiateResponse: Codable {
        let poll: PollInfo
        let login: String

        struct PollInfo: Codable {
            let token: String
            let endpoint: String
        }
    }

    private struct PollResponse: Codable {
        let server: String
        let loginName: String
        let appPassword: String
    }
}

// MARK: - Errors

/// Errors from the Nextcloud Login Flow v2 protocol.
enum LoginFlowError: Error, LocalizedError {
    case invalidURL
    case serverRejected
    case invalidResponse
    case untrustedEndpoint
    case serverMismatch
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid server URL.")
        case .serverRejected:
            return String(localized: "Server does not support automatic login. Use an app password instead.")
        case .invalidResponse:
            return String(localized: "Unexpected response from server.")
        case .untrustedEndpoint, .serverMismatch:
            return String(localized: "The server returned an unexpected address. Check the URL and try again.")
        case .timeout:
            return String(localized: "Login timed out. Please try again.")
        }
    }
}

/// Redirect decisions for Login Flow requests, which may carry a poll token body.
final class LoginFlowRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.redirectRequest(originalURL: task.originalRequest?.url, proposed: request))
    }

    static func redirectRequest(originalURL: URL?, proposed: URLRequest) -> URLRequest? {
        guard let originalURL, let destinationURL = proposed.url,
              LoginFlowURLPolicy.sameOrigin(originalURL, destinationURL) else {
            // Returning nil blocks the whole redirect, including any POST token body.
            return nil
        }
        return proposed
    }
}

/// Validation shared by JSON endpoints and the HTTP redirect boundary.
private enum LoginFlowURLPolicy {
    static func isHTTPS(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.isEmpty == false
            && components.user == nil && components.password == nil
    }

    private static func isEndpoint(_ url: URL) -> Bool {
        guard isHTTPS(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.query == nil && components.fragment == nil
    }

    static func normalizedBaseURL(_ value: String) -> URL? {
        try? NextcloudServerAddress.parse(value).baseURL
    }

    // Returned server addresses are checked as supplied, never treated as pasted DAV input.
    static func returnedBaseURL(_ value: String) -> URL? {
        guard let url = URL(string: value), isEndpoint(url) else { return nil }
        var normalized = url.absoluteString
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return URL(string: normalized)
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        NextcloudServerAddress.sameOrigin(lhs, rhs)
    }

}
