import Testing
import Foundation
import UIKit
import AuthenticationServices
import Combine

@testable import NowThis

@Suite("LoginFlowCoordinator")
@MainActor
struct LoginFlowCoordinatorTests {

    enum LatePoll: CaseIterable { case success, failure, cancellation }

    @Test("A cancelled initiation cannot open a browser or change a retry")
    func lateInitiationIsIgnored() async throws {
        let script = LoginScript()
        let coordinator = script.makeCoordinator()
        defer { coordinator.cancel(); script.finishPendingRequests() }
        var states: [LoginFlowCoordinator.State] = []
        let observation = coordinator.$state.sink { states.append($0) }
        defer { observation.cancel() }

        coordinator.startLoginFlow(serverURL: "a")
        try await waitFor { script.isInitiating("a") }
        coordinator.cancel()
        coordinator.startLoginFlow(serverURL: "b")
        try await waitFor { script.isInitiating("b") }
        script.completeInitiation("b")
        try await waitFor { script.isPolling("b") }
        script.completeInitiation("a")
        await Task.yield()
        script.completePoll("b", result: .success)
        try await waitFor { coordinator.state == script.successState("b") }

        #expect(script.browserStarts == ["b"])
        #expect(script.pollStarts == ["b"])
        #expect(states == [.idle, .initiating, .idle, .initiating, .waitingForBrowser, script.successState("b")])
    }

    @Test("A stale poll and browser callback cannot mutate a retry", arguments: LatePoll.allCases)
    func latePollAndBrowserCancellationAreIgnored(result: LatePoll) async throws {
        let script = LoginScript()
        let coordinator = script.makeCoordinator()
        defer { coordinator.cancel(); script.finishPendingRequests() }
        var states: [LoginFlowCoordinator.State] = []
        let observation = coordinator.$state.sink { states.append($0) }
        defer { observation.cancel() }

        try await enterBrowser("a", coordinator: coordinator, script: script)
        coordinator.cancel()
        try await enterBrowser("b", coordinator: coordinator, script: script)
        script.completePoll("a", result: result)
        await Task.yield()
        script.completeBrowser("a", error: ASWebAuthenticationSessionError(.canceledLogin))

        #expect(coordinator.state == .waitingForBrowser)
        #expect(script.browserCancels == ["a"])
        #expect(!script.cancelledPolls.contains("b"))
        script.completePoll("b", result: .success)
        try await waitFor { coordinator.state == script.successState("b") }
        #expect(states == [.idle, .initiating, .waitingForBrowser, .idle,
                           .initiating, .waitingForBrowser, script.successState("b")])
        #expect(script.browserCancels == ["a", "b"])
    }

    @Test("Browser start failure reports the inline error, releases the browser and never polls")
    func failedBrowserStartNeverPolls() async throws {
        let script = LoginScript()
        script.failingBrowser = "a"
        let coordinator = script.makeCoordinator()
        defer { coordinator.cancel(); script.finishPendingRequests() }
        coordinator.startLoginFlow(serverURL: "a")
        try await waitFor { script.isInitiating("a") }
        script.completeInitiation("a")
        try await waitFor { script.browserStarts == ["a"] }

        #expect(coordinator.state == .error(String(localized: "login.error.couldNotOpenBrowser",
            defaultValue: "Could not open login page. Please try again.")))
        #expect(script.pollStarts.isEmpty)
        #expect(script.browser("a") == nil)

        try await enterBrowser("b", coordinator: coordinator, script: script)
        script.completePoll("b", result: .success)
        try await waitFor { coordinator.state == script.successState("b") }
        #expect(script.pollStarts == ["b"])
        #expect(script.browser("b") == nil)
    }

    @Test("Explicit and browser cancel release their current task and browser", arguments: [false, true])
    func cancellingReleasesCurrentAttempt(fromBrowser: Bool) async throws {
        let script = LoginScript()
        let coordinator = script.makeCoordinator()
        defer { coordinator.cancel(); script.finishPendingRequests() }
        try await enterBrowser("a", coordinator: coordinator, script: script)
        if fromBrowser {
            script.completeBrowser("a", error: ASWebAuthenticationSessionError(.canceledLogin))
        } else {
            coordinator.cancel()
        }
        try await waitFor { script.cancelledPolls.contains("a") }

        #expect(coordinator.state == .idle)
        #expect(script.browserCancels == ["a"])
        #expect(script.browser("a") == nil)
    }

    @Test("A successful browser callback keeps polling until the server returns credentials")
    func browserReturnKeepsPolling() async throws {
        let script = LoginScript()
        let coordinator = script.makeCoordinator()
        defer { coordinator.cancel(); script.finishPendingRequests() }
        try await enterBrowser("a", coordinator: coordinator, script: script)
        script.completeBrowser("a", error: nil)
        #expect(coordinator.state == .waitingForBrowser)
        #expect(script.browserCancels.isEmpty)
        script.completePoll("a", result: .success)
        try await waitFor { coordinator.state == script.successState("a") }
        #expect(script.browserCancels == ["a"])
        #expect(script.browser("a") == nil)
    }

    @Test("A terminal browser completion stops polling and leaves an immediate retry")
    func terminalBrowserFailureEndsOnlyItsAttempt() async throws {
        let script = LoginScript()
        let coordinator = script.makeCoordinator()
        defer { coordinator.cancel(); script.finishPendingRequests() }
        try await enterBrowser("a", coordinator: coordinator, script: script)
        let failure = ASWebAuthenticationSessionError(.presentationContextInvalid)
        script.completeBrowser("a", error: failure)

        #expect(coordinator.state == .error(String(localized: "login.error.couldNotOpenBrowser",
            defaultValue: "Could not open login page. Please try again.")))
        #expect(script.browser("a") == nil)
        #expect(script.browserCancels == ["a"])
        #expect(await waitUntil { script.cancelledPolls.contains("a") })

        try await enterBrowser("b", coordinator: coordinator, script: script)
        script.completeBrowser("a", error: failure)
        #expect(coordinator.state == .waitingForBrowser)
        #expect(script.browserCancels == ["a"])
        #expect(!script.cancelledPolls.contains("b"))
        script.completePoll("b", result: .success)
        try await waitFor { coordinator.state == script.successState("b") }
        #expect(script.browserCancels == ["a", "b"])
    }

    @Test("A suspended poll does not keep the owning coordinator alive")
    func droppingOwnerCancelsResources() async throws {
        let script = LoginScript()
        defer { script.finishPendingRequests() }
        var coordinator: LoginFlowCoordinator? = script.makeCoordinator()
        weak var owner = coordinator
        try await enterBrowser("a", coordinator: try #require(coordinator), script: script)
        coordinator = nil
        #expect(owner == nil)
        #expect(await waitUntil { script.cancelledPolls.contains("a") })
        #expect(script.browser("a") == nil)
    }

    private func enterBrowser(_ name: String, coordinator: LoginFlowCoordinator, script: LoginScript) async throws {
        coordinator.startLoginFlow(serverURL: name)
        try await waitFor { script.isInitiating(name) }
        script.completeInitiation(name)
        try await waitFor { script.isPolling(name) }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let satisfied = await waitUntil(condition)
        try #require(satisfied, "The scripted login did not reach the requested phase")
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("Callback scheme must not match the app's registered URL scheme")
    func callbackSchemeDoesNotConflictWithDeepLinks() {
        // The app registers "nowthis" as its deep-link scheme in Info.plist.
        // ASWebAuthenticationSession's callbackURLScheme must differ,
        // otherwise iOS's URL handling intercepts the redirect and
        // immediately dismisses the auth sheet before the user can log in.
        let appDeepLinkScheme = "nowthis"
        #expect(LoginFlowCoordinator.callbackURLScheme != appDeepLinkScheme,
                "callbackURLScheme must not equal the app's deep link scheme or the auth sheet will be dismissed immediately")
    }

    @Test("Callback scheme is non-empty")
    func callbackSchemeIsNonEmpty() {
        #expect(!LoginFlowCoordinator.callbackURLScheme.isEmpty,
                "callbackURLScheme must be non-empty for ASWebAuthenticationSession")
    }

    @Test("Presentation prefers an active scene over inactive and background candidates")
    func anchorPrefersActiveScene() {
        let scenes = [
            scene("background", .background), scene("inactive", .foregroundInactive),
            scene("active", .foregroundActive)
        ]
        #expect(LoginFlowCoordinator.preferredPresentationSceneID(in: scenes) == "active")
    }

    @Test("Scene selection is stable regardless of connected-scene iteration order")
    func anchorTieIsDeterministic() {
        let scenes = [scene("z", .foregroundActive), scene("a", .foregroundActive)]
        #expect(LoginFlowCoordinator.preferredPresentationSceneID(in: scenes) == "a")
        #expect(LoginFlowCoordinator.preferredPresentationSceneID(in: Array(scenes.reversed())) == "a")
    }

    @Test("An inactive key window is the fallback when active scenes have none")
    func anchorFallsBackToInactive() {
        let scenes = [
            scene("background", .background), scene("active", .foregroundActive, key: false),
            scene("inactive", .foregroundInactive)
        ]
        #expect(LoginFlowCoordinator.preferredPresentationSceneID(in: scenes) == "inactive")
    }

    @Test("Background, unattached and non-key windows cannot anchor authentication")
    func anchorRejectsIneligibleScenes() {
        #expect(LoginFlowCoordinator.preferredPresentationSceneID(in: []) == nil)
        #expect(LoginFlowCoordinator.preferredPresentationSceneID(in: [
            scene("background", .background), scene("unattached", .unattached),
            scene("active", .foregroundActive, key: false),
            scene("inactive", .foregroundInactive, key: false)
        ]) == nil)
    }

    @Test("Authentication callback returns the chosen live key window")
    func anchorUsesLiveWindow() throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let selectedID = LoginFlowCoordinator.preferredPresentationSceneID(in: scenes.map {
            .init(id: $0.session.persistentIdentifier, activationState: $0.activationState,
                  hasKeyWindow: $0.windows.contains(where: \.isKeyWindow))
        })
        let scene = try #require(scenes.first { $0.session.persistentIdentifier == selectedID })
        let liveKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let expected = try #require(liveKeyWindow)
        let session = ASWebAuthenticationSession(
            url: try #require(URL(string: "https://example.invalid/login")),
            callbackURLScheme: LoginFlowCoordinator.callbackURLScheme
        ) { _, _ in }
        // Constructing the session does not start a browser or make a network request.
        let anchor = LoginFlowCoordinator().presentationAnchor(for: session)
        #expect(anchor === expected)
    }

    private func scene(_ id: String, _ state: UIScene.ActivationState, key: Bool = true)
        -> LoginFlowCoordinator.PresentationSceneDescriptor {
        .init(id: id, activationState: state, hasKeyWindow: key)
    }

}

/// Deliberately holds cancelled requests until the test delivers their late result.
@MainActor
private final class LoginScript {
    private var initiations: [String: CheckedContinuation<LoginFlowClient.LoginFlowSession, any Error>] = [:]
    private var polls: [String: CheckedContinuation<LoginFlowClient.LoginFlowResult, any Error>] = [:]
    private var callbacks: [String: LoginFlowCoordinator.BrowserCompletion] = [:]
    private var browsers: [String: WeakBrowser] = [:]
    private(set) var pollStarts: [String] = []
    private(set) var cancelledPolls: Set<String> = []
    private(set) var browserStarts: [String] = []
    private(set) var browserCancels: [String] = []
    var failingBrowser: String?

    func makeCoordinator() -> LoginFlowCoordinator {
        LoginFlowCoordinator(initiate: initiate, poll: poll) { loginURL, _, completion in
            let name = loginURL.lastPathComponent
            let browser = TestBrowser(start: {
                self.browserStarts.append(name)
                return self.failingBrowser != name
            }, cancel: {
                self.browserCancels.append(name)
            })
            self.browsers[name] = WeakBrowser(browser)
            self.callbacks[name] = completion
            return browser
        }
    }

    func isInitiating(_ name: String) -> Bool { initiations[name] != nil }
    func isPolling(_ name: String) -> Bool { polls[name] != nil }
    func browser(_ name: String) -> TestBrowser? { browsers[name]?.value }

    func completeInitiation(_ name: String) {
        initiations.removeValue(forKey: name)?.resume(returning: .init(
            pollToken: name, pollEndpoint: URL(string: "https://login.invalid/poll")!,
            loginURL: URL(string: "https://login.invalid/browser/\(name)")!,
            serverBaseURL: URL(string: "https://login.invalid")!))
    }

    func completePoll(_ name: String, result: LoginFlowCoordinatorTests.LatePoll) {
        guard let continuation = polls.removeValue(forKey: name) else { return }
        switch result {
        case .success:
            continuation.resume(returning: .init(server: "https://login.invalid", loginName: name, appPassword: "fixture"))
        case .failure:
            continuation.resume(throwing: LoginFlowError.serverRejected)
        case .cancellation:
            continuation.resume(throwing: CancellationError())
        }
    }

    func completeBrowser(_ name: String, error: (any Error)?) {
        callbacks[name]?(error == nil ? URL(string: "nowthis-auth://fixture") : nil, error)
    }

    func successState(_ name: String) -> LoginFlowCoordinator.State {
        .success(server: "https://login.invalid", loginName: name, appPassword: "fixture")
    }

    func finishPendingRequests() {
        for continuation in initiations.values { continuation.resume(throwing: CancellationError()) }
        for continuation in polls.values { continuation.resume(throwing: CancellationError()) }
        initiations.removeAll()
        polls.removeAll()
    }

    private func initiate(_ name: String) async throws -> LoginFlowClient.LoginFlowSession {
        try await withCheckedThrowingContinuation { initiations[name] = $0 }
    }

    private func poll(_ session: LoginFlowClient.LoginFlowSession) async throws -> LoginFlowClient.LoginFlowResult {
        let name = session.pollToken
        pollStarts.append(name)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { polls[name] = $0 }
        } onCancel: {
            Task { @MainActor in self.cancelledPolls.insert(name) }
        }
    }

    private final class WeakBrowser {
        weak var value: TestBrowser?
        init(_ value: TestBrowser) { self.value = value }
    }

    @MainActor
    final class TestBrowser: LoginBrowserSession {
        let startAction: () -> Bool
        let cancelAction: () -> Void
        init(start: @escaping () -> Bool, cancel: @escaping () -> Void) {
            startAction = start
            cancelAction = cancel
        }
        func start() -> Bool { startAction() }
        func cancel() { cancelAction() }
    }
}
