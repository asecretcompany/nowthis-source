import Foundation
import Testing

@testable import NowThis

/// **The last edits before the phone goes in a pocket are the ones that matter.**
///
/// Local edits ask for a coalesced re-plan. That pass is an unstructured `Task`, so backgrounding
/// within the coalescing window kills it — and `cancelInflightSync()` in the same branch already
/// kills the debounced sync that used to be the only other thing that scheduled anything. Create
/// a task with a due date, swipe home, and nothing was ever registered with iOS.
///
/// The `.background` branch therefore has to re-plan itself, and has to ask UIKit for the seconds
/// it needs — an unprotected `await` after the scene deactivates is a suspension waiting to
/// happen, and the reconcile is what writes the notifications.
@Suite("Backgrounding re-plans notifications")
struct BackgroundReplanGuardTests {

    private func backgroundBranch() throws -> String {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("NowThis/App/NowThisApp.swift"),
            encoding: .utf8)
        let parts = source.components(separatedBy: "newPhase == .background")
        #expect(parts.count == 2, """
            Expected exactly one `newPhase == .background` branch in NowThisApp.swift, found
            \(parts.count - 1). The scan is anchored on it — re-anchor it rather than deleting it.
            """)
        return try #require(parts.last)
    }

    @Test("Backgrounding re-plans notifications before it cancels anything")
    func backgroundingReplans() throws {
        let branch = try backgroundBranch()

        #expect(branch.contains("scheduleBackgroundSync"), """
            Scanning the wrong slice: the .background branch has always scheduled the next
            background sync, so its absence means the anchor moved.
            """)

        #expect(branch.contains("ReminderScheduler.reconcileNow"), """
            Backgrounding does not re-plan notifications. A task created seconds earlier still has
            its re-plan sitting in the coalescing window, and that unstructured Task dies with the
            scene — so the due date passes with nothing pending and the badge never moves.
            """)

        // Qualified, so a passing mention of either name in a comment cannot satisfy or
        // trip this — only the calls themselves count.
        let reconcileAt = try #require(
            branch.range(of: "await ReminderScheduler.reconcileNow")?.lowerBound)
        let cancelAt = try #require(
            branch.range(of: "syncScheduler.cancelInflightSync")?.lowerBound)
        #expect(reconcileAt < cancelAt, """
            `cancelInflightSync()` runs before the re-plan is even requested. It cancels the
            debounce that would otherwise have carried the edit, so the ordering has to put the
            re-plan first.
            """)
    }

    @Test("The backgrounding re-plan asks UIKit for time to finish")
    func backgroundingProtectsTheReplan() throws {
        let branch = try backgroundBranch()

        let acquire = try #require(branch.range(of: "let assertion = ReminderBackgroundAssertion()"))
        let start = try #require(branch.range(of: "assertion.start {"))
        let reconcile = try #require(branch.range(of: "await ReminderScheduler.reconcileNow"))
        #expect(acquire.lowerBound < start.lowerBound && start.lowerBound < reconcile.lowerBound,
            "The synchronous assertion start must precede protected reminder work")
        #expect(branch.contains("allowsPermissionPrompt: false"),
            "Background recovery must check permission without presenting a prompt")
        // Denial, exactly-once end, and expiration during SQL/async callbacks are
        // exercised behaviorally in ReminderBackgroundAssertionTests.
    }
    @Test("Launch and activation recover reminders independently of remote sync settings")
    func localRecoveryDoesNotDependOnRemoteSync() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let source = try String(contentsOf: root.appendingPathComponent("NowThis/App/NowThisApp.swift"), encoding: .utf8)
        let launch = try #require(source.range(of: ".task {"))
        let activation = try #require(source.range(of: "if newPhase == .active {"))
        let background = try #require(source.range(of: "} else if newPhase == .background {"))
        let launchBody = source[launch.upperBound..<activation.lowerBound]
        let activeBody = source[activation.upperBound..<background.lowerBound]
        for body in [launchBody, activeBody] {
            #expect(body.contains("await ReminderScheduler.reconcileNow(modelContainer: modelContainer, policy: .background)"))
            #expect(!body.contains("isForegroundRefreshEnabled"))
            let recovery = try #require(body.range(of: "await ReminderScheduler.reconcileNow"))
            let remote = try #require(body.range(of: "syncScheduler.syncOnForeground"))
            #expect(recovery.lowerBound < remote.lowerBound)
        }
    }

}
