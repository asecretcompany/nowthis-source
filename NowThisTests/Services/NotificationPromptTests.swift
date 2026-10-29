import Foundation
import Testing

@testable import NowThis

/// **Nobody can answer the notification prompt in a test host.**
///
/// `requestAuthorization` does not return until someone taps Allow or Don't Allow. On a simulator
/// that has never been asked, the app puts the prompt up at launch, and the first test to reach a
/// request awaits an answer that never comes. On a new iOS 27 simulator
/// `BadgePermissionTests.updateBadgeCountIsAsync` hung until xcodebuild killed it ("Test crashed
/// with signal term"), and the relaunch hung again in `CreateTaskIntent` until someone tapped
/// Allow. `simctl privacy` has no notifications service, so the simulator cannot be pre-answered,
/// and the app's own launch-time request races anything a test could do first.
///
/// So the app never shows the prompt in a process XCTest launched, and every request goes through
/// that one check.
@Suite("Notification prompt in a test host")
struct NotificationPromptTests {

    @Test("An inactive or background app cannot request notification authorization")
    func backgroundWakeCannotPrompt() {
        #expect(!NotificationPrompt.isAllowed(environment: [:], applicationIsActive: false))
        #expect(NotificationPrompt.isAllowed(environment: [:], applicationIsActive: true))
        #expect(!NotificationPrompt.isAllowed(environment: ["XCTestConfigurationFilePath": "host"],
            applicationIsActive: true))
    }

    @Test("Every permission request checks activity immediately before calling the system")
    func everyRequestChecksCurrentActivity() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var examined = 0
        for file in try LocalizationCatalogFixture.swiftSourceFiles() {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let lines = SwiftSourceScanner.strippingComments(source).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains(".requestAuthorization(") {
                examined += 1
                let gate = lines[max(0, index - 3)...index].joined(separator: "\n")
                #expect(gate.contains("applicationIsActive: UIApplication.shared.applicationState == .active"),
                    "\(file) must read current app activity after async settings lookup and before requesting authorization")
            }
        }
        #expect(examined == 4)
    }

    @Test("A process XCTest launched never shows the notification prompt")
    func xctestHostNeverPrompts() {
        let host = ["XCTestConfigurationFilePath": "/tmp/NowThisTests.xctestconfiguration"]
        #expect(NotificationPrompt.isAllowed(environment: host) == false)
    }

    @Test("The app on its own still asks")
    func appStillAsks() {
        #expect(NotificationPrompt.isAllowed(environment: [:]))
    }

    /// The two tests above prove the rule; this one proves the premise — that the runner really
    /// sets the variable the rule reads. If a future Xcode stops setting it, the prompt comes back
    /// and the suite hangs on every new simulator, so it fails here first.
    @Test("This test host is recognised as one")
    func thisHostIsRecognised() {
        let xctestKeys = ProcessInfo.processInfo.environment.keys
            .filter { $0.contains("XCTest") }
            .sorted()
        #expect(NotificationPrompt.isAllowed() == false, """
            The running test host is not recognised, so a request here would put the prompt on \
            screen and wait for an answer. XCTest keys in this environment: \(xctestKeys)
            """)
    }

    @Test("Every notification permission request is gated on the prompt check")
    func everyRequestIsGated() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var examined = 0
        var ungated: [String] = []

        for file in try LocalizationCatalogFixture.swiftSourceFiles() {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let lines = SwiftSourceScanner.strippingComments(source).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains(".requestAuthorization(") {
                examined += 1
                let window = lines[max(0, index - 3)...index].joined(separator: "\n")
                if !window.contains("NotificationPrompt.isAllowed(") {
                    ungated.append("\(file): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        #expect(examined >= 4, """
            Found \(examined) `.requestAuthorization(` calls; there were 4 when this guard was \
            written (three in ReminderScheduler, one in GeofenceManager). Fewer means the scan \
            stopped seeing them, not that they went away.
            """)
        #expect(ungated.isEmpty, """
            These requests can put the notification prompt up inside a test host, where nothing \
            can answer it and the await never returns: \(ungated). Gate each on \
            `NotificationPrompt.isAllowed()` within the three lines above the call.
            """)
    }
}
