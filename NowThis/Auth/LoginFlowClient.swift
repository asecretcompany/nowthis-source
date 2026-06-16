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

    // MARK: - Initiate

    /// Initiates Login Flow v2 by requesting a poll token and login URL from the server.
    ///
    /// - Parameter serverURL: The normalized base URL (e.g. `https://cloud.example.com`).
    /// - Returns: A `LoginFlowSession` containing the poll token and browser login URL.
    func initiate(serverURL: String) async throws -> LoginFlowSession {
        guard let url = URL(string: "\(serverURL)/index.php/login/v2") else {
            throw LoginFlowError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("true", forHTTPHeaderField: "OCS-APIREQUEST")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LoginFlowError.serverRejected
        }

        let decoded = try JSONDecoder().decode(InitiateResponse.self, from: data)

        guard let pollURL = URL(string: decoded.poll.endpoint),
              let loginURL = URL(string: decoded.login) else {
            throw LoginFlowError.invalidResponse
        }

        return LoginFlowSession(
            pollToken: decoded.poll.token,
            pollEndpoint: pollURL,
            loginURL: loginURL
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
            request.httpBody = "token=\(session.pollToken)".data(using: .utf8)

            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let result = try JSONDecoder().decode(PollResponse.self, from: data)
                // Normalize: strip trailing slashes to match ServerURLValidator behavior.
                // The server field can include a trailing slash (e.g., "https://example.com/")
                // which produces double-slash CalDAV paths that some servers reject with 415.
                var normalizedServer = result.server
                while normalizedServer.hasSuffix("/") {
                    normalizedServer = String(normalizedServer.dropLast())
                }

                return LoginFlowResult(
                    server: normalizedServer,
                    loginName: result.loginName,
                    appPassword: result.appPassword
                )
            }

            // 404 = user hasn't granted access yet — keep polling
            try await Task.sleep(for: Self.pollInterval)
        }

        throw LoginFlowError.timeout
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
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid server URL.")
        case .serverRejected:
            return String(localized: "Server does not support automatic login. Use an app password instead.")
        case .invalidResponse:
            return String(localized: "Unexpected response from server.")
        case .timeout:
            return String(localized: "Login timed out. Please try again.")
        }
    }
}
