import AuthenticationServices
import SwiftUI
import os

/// Coordinates Nextcloud Login Flow v2 with `ASWebAuthenticationSession`.
///
/// Handles the full three-phase flow:
/// 1. **Initiate** — get login URL + poll token from the server.
/// 2. **Browser** — open `ASWebAuthenticationSession` for user authentication.
/// 3. **Poll** — receive `appPassword` when the user grants access.
///
/// The coordinator is an `ObservableObject` that publishes its state for the UI.
///
/// **Usage:**
/// ```swift
/// @StateObject private var coordinator = LoginFlowCoordinator()
///
/// coordinator.startLoginFlow(serverURL: "https://cloud.example.com")
/// // Observe coordinator.state for UI updates
/// ```
@MainActor
final class LoginFlowCoordinator: NSObject, ObservableObject,
                                   ASWebAuthenticationPresentationContextProviding {

    /// The current state of the login flow.
    enum State: Equatable {
        case idle
        case initiating
        case waitingForBrowser
        case success(server: String, loginName: String, appPassword: String)
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.initiating, .initiating), (.waitingForBrowser, .waitingForBrowser):
                return true
            case (.success(let a, let b, _), .success(let c, let d, _)):
                return a == c && b == d
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    @Published var state: State = .idle

    /// The URL scheme passed to `ASWebAuthenticationSession`.
    ///
    /// Must NOT match the app's registered deep-link scheme (`nowthis`)
    /// or iOS will intercept the redirect and immediately dismiss the auth sheet.
    static let callbackURLScheme = "nowthis-auth"

    private static let logger = Logger(
        subsystem: "com.asecretcompany.nowthis",
        category: "LoginFlow"
    )

    private let loginFlowClient = LoginFlowClient()
    private var flowTask: Task<Void, Never>?
    private var webAuthSession: ASWebAuthenticationSession?

    deinit {
        flowTask?.cancel()
    }

    // MARK: - Public API

    /// Starts the full Login Flow v2 sequence.
    ///
    /// - Parameter serverURL: Normalized HTTPS server URL (e.g. `https://cloud.example.com`).
    func startLoginFlow(serverURL: String) {
        Self.logger.info("startLoginFlow: beginning for \(serverURL, privacy: .private)")
        state = .initiating

        // Cancel any previous flow + web session
        flowTask?.cancel()
        webAuthSession?.cancel()
        webAuthSession = nil

        flowTask = Task { [weak self] in
            guard let self else { return }

            do {
                // Phase 1: Initiate — get poll token + login URL
                Self.logger.info("Phase 1: initiating login flow")
                let session = try await loginFlowClient.initiate(serverURL: serverURL)
                Self.logger.info("Phase 1 complete: got login URL \(session.loginURL, privacy: .private)")

                // Phase 2: Open browser + start polling concurrently
                state = .waitingForBrowser
                openBrowser(loginURL: session.loginURL)

                // Phase 3: Poll until user grants access or timeout
                Self.logger.info("Phase 3: starting poll")
                let result = try await loginFlowClient.poll(session: session)

                // Success — dismiss browser and report credentials
                Self.logger.info("Phase 3 complete: login successful for \(result.loginName, privacy: .private)")
                webAuthSession?.cancel()
                state = .success(
                    server: result.server,
                    loginName: result.loginName,
                    appPassword: result.appPassword
                )
            } catch is CancellationError {
                Self.logger.info("Login flow cancelled")
                state = .idle
            } catch {
                Self.logger.error("Login flow error: \(error.localizedDescription)")
                state = .error(error.localizedDescription)
            }
        }
    }

    /// Cancels any in-progress login flow.
    func cancel() {
        Self.logger.info("cancel() called")
        flowTask?.cancel()
        webAuthSession?.cancel()
        state = .idle
    }

    // MARK: - Browser

    /// Opens `ASWebAuthenticationSession` for the user to authenticate in-browser.
    ///
    /// We detect flow completion via polling, not via the callback URL.
    /// The callback scheme uses `nowthis-auth` (not the app's `nowthis` deep-link
    /// scheme) to prevent iOS from intercepting the redirect and dismissing
    /// the auth sheet before the user can log in.
    private func openBrowser(loginURL: URL) {
        Self.logger.info("openBrowser: creating ASWebAuthenticationSession")

        let session = ASWebAuthenticationSession(
            url: loginURL,
            callbackURLScheme: Self.callbackURLScheme
        ) { [weak self] callbackURL, error in
            // Log everything about the completion
            if let callbackURL {
                Self.logger.warning("ASWebAuthSession completed with callbackURL: \(callbackURL, privacy: .private)")
            }
            if let error {
                Self.logger.warning("ASWebAuthSession completed with error: \(error.localizedDescription) (code: \((error as NSError).code))")
            }
            if callbackURL == nil && error == nil {
                Self.logger.warning("ASWebAuthSession completed with nil URL and nil error")
            }

            // If user tapped Cancel in the browser sheet
            if let error = error as? ASWebAuthenticationSessionError,
               error.code == .canceledLogin {
                Self.logger.info("User cancelled login in browser")
                self?.cancel()
            }
            // Otherwise, we rely on polling to detect completion.
            // The sheet has been dismissed by iOS, but polling continues.
        }

        // Allow SSO cookies to work by not using ephemeral session
        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = self

        // Store the reference BEFORE starting so it's retained
        webAuthSession = session

        let started = session.start()
        Self.logger.info("ASWebAuthSession.start() returned \(started)")

        if !started {
            Self.logger.error("ASWebAuthSession failed to start")
            state = .error("Could not open login page. Please try again.")
        }
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let anchor = UIApplication.shared
                .connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
            Self.logger.info("presentationAnchor: returning window (isKeyWindow=\(anchor.isKeyWindow))")
            return anchor
        }
    }
}
