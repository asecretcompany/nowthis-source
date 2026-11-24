import AuthenticationServices
import SwiftUI
import os

@MainActor
protocol LoginBrowserSession: AnyObject, Sendable {
    func start() -> Bool
    func cancel()
}

@MainActor
private final class SystemLoginBrowserSession: LoginBrowserSession {
    private let session: ASWebAuthenticationSession

    init(loginURL: URL, provider: LoginFlowCoordinator, completion: @escaping LoginFlowCoordinator.BrowserCompletion) {
        session = ASWebAuthenticationSession(
            url: loginURL, callbackURLScheme: LoginFlowCoordinator.callbackURLScheme
        ) { callbackURL, error in
            Task { @MainActor in completion(callbackURL, error) }
        }
        // Keep SSO cookies available for the server's authentication page.
        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = provider
    }

    func start() -> Bool { session.start() }
    func cancel() { session.cancel() }
}

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

    @Published private(set) var state: State = .idle

    /// The URL scheme passed to `ASWebAuthenticationSession`.
    ///
    /// Must NOT match the app's registered deep-link scheme (`nowthis`)
    /// or iOS will intercept the redirect and immediately dismiss the auth sheet.
    static let callbackURLScheme = "nowthis-auth"

    private static let logger = Logger(
        subsystem: "com.asecretcompany.nowthis",
        category: "LoginFlow"
    )

    typealias Initiate = @MainActor (String) async throws -> LoginFlowClient.LoginFlowSession
    typealias Poll = @MainActor (LoginFlowClient.LoginFlowSession) async throws -> LoginFlowClient.LoginFlowResult
    typealias BrowserCompletion = @MainActor @Sendable (URL?, (any Error)?) -> Void
    typealias BrowserFactory = @MainActor (URL, LoginFlowCoordinator, @escaping BrowserCompletion) -> any LoginBrowserSession

    private let initiate: Initiate
    private let poll: Poll
    private let makeBrowser: BrowserFactory
    private var attempt: Attempt?

    private struct Attempt: Sendable {
        let id = UUID()
        var task: Task<Void, Never>?
        var browser: (any LoginBrowserSession)?

        @MainActor func cancel() {
            task?.cancel()
            browser?.cancel()
        }
    }

    init(client: LoginFlowClient = LoginFlowClient(), initiate: Initiate? = nil, poll: Poll? = nil,
         makeBrowser: BrowserFactory? = nil) {
        self.initiate = initiate ?? { try await client.initiate(serverURL: $0) }
        self.poll = poll ?? { try await client.poll(session: $0) }
        self.makeBrowser = makeBrowser ?? {
            SystemLoginBrowserSession(loginURL: $0, provider: $1, completion: $2)
        }
    }

    deinit {
        attempt?.task?.cancel()
        if let browser = attempt?.browser {
            Task { @MainActor in browser.cancel() }
        }
    }

    /// Starts the Login Flow v2 sequence for a normalized HTTPS server URL.
    func startLoginFlow(serverURL: String) {
        detachAttempt()?.cancel()
        var next = Attempt()
        let id = next.id
        next.task = Task { [weak self, initiate, poll] in
            do {
                try Task.checkCancellation()
                let session = try await initiate(serverURL)
                guard self?.startBrowser(loginURL: session.loginURL, for: id) == true else { return }

                let result = try await poll(session)
                self?.finish(id, with: .success(
                    server: result.server,
                    loginName: result.loginName,
                    appPassword: result.appPassword))
            } catch is CancellationError {
                self?.finish(id, with: .idle)
            } catch {
                self?.fail(id, error: error)
            }
        }
        attempt = next
        state = .initiating
    }

    /// Releases the current attempt before cancellation can call back into the coordinator.
    func cancel() {
        detachAttempt()?.cancel()
        if state != .idle { state = .idle }
    }

    private func detachAttempt() -> Attempt? {
        let detached = attempt
        attempt = nil
        return detached
    }

    private func finish(_ id: UUID, with state: State) {
        guard attempt?.id == id else { return }
        detachAttempt()?.cancel()
        self.state = state
    }

    private func fail(_ id: UUID, error: any Error) {
        guard attempt?.id == id else { return }
        Self.logger.error("Login flow error: \(error.localizedDescription, privacy: .private)")
        finish(id, with: .error(SyncFailure.connectionGuidance(for: error) ?? error.localizedDescription))
    }

    private func startBrowser(loginURL: URL, for id: UUID) -> Bool {
        guard attempt?.id == id else { return false }
        let browser = makeBrowser(loginURL, self) { [weak self] _, error in
            // A successful browser return leaves this attempt polling.
            guard let error else { return }
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                self?.finish(id, with: .idle)
            } else {
                self?.finish(id, with: Self.browserOpenError)
            }
        }
        guard attempt?.id == id else {
            browser.cancel()
            return false
        }
        attempt?.browser = browser
        state = .waitingForBrowser
        guard attempt?.id == id else { return false }

        let started = browser.start()
        guard attempt?.id == id else { return false }
        if !started {
            finish(id, with: Self.browserOpenError)
        }
        return started
    }

    private static var browserOpenError: State {
        .error(String(
            localized: "login.error.couldNotOpenBrowser",
            defaultValue: "Could not open login page. Please try again.",
            comment: "Shown on the Add Nextcloud screen when the in-app browser could not be opened to start sign-in."))
    }

    struct PresentationSceneDescriptor {
        let id: String
        let activationState: UIScene.ActivationState
        let hasKeyWindow: Bool
    }

    static func preferredPresentationSceneID(in scenes: [PresentationSceneDescriptor]) -> String? {
        let candidates = scenes.compactMap { scene -> (id: String, priority: Int)? in
            guard scene.hasKeyWindow else { return nil }
            switch scene.activationState {
            case .foregroundActive: return (scene.id, 0)
            case .foregroundInactive: return (scene.id, 1)
            default: return nil
            }
        }
        return candidates.min { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority < rhs.priority
        }?.id
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            presentationWindow() ?? ASPresentationAnchor()
        }
    }

    func presentationWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let selectedID = Self.preferredPresentationSceneID(in: scenes.map {
            PresentationSceneDescriptor(
                id: $0.session.persistentIdentifier,
                activationState: $0.activationState,
                hasKeyWindow: $0.windows.contains(where: \.isKeyWindow))
        })
        return selectedID.flatMap { id in
            scenes.first { $0.session.persistentIdentifier == id }?.windows.first(where: \.isKeyWindow)
        }
    }
}
