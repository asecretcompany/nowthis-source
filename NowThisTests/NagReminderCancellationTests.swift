import Foundation
import Testing
@testable import NowThis

/// **"Repeat Hourly Until Done" never stopped.**
///
/// `TaskDetailView`'s toggle is labelled *Repeat Hourly Until Done* and
/// `scheduleNagReminder`'s doc comment claimed *"Auto-cancelled when the task is completed or
/// deleted."* Neither was true. `cancelReminder(for:)` cancels the nag correctly, but nothing on
/// the completion or deletion path called it: `TaskRowView.toggleCompletion` and
/// `CompleteTaskIntent` both only updated the badge.
///
/// The one bulk sweep that could have cleaned up, `refreshAllReminders`, filtered pending
/// notifications by the `reminder-` and `overdue-` prefixes and **not** `nag-` — and it only runs
/// after a sync, so completing a task locally swept nothing at all. The user completed the task
/// and kept being reminded about it every hour, forever, with no way to stop it short of turning
/// off notifications for the whole app.
///
/// This is a plain bug, not a localization one. It is here because translating a label that
/// promises the opposite of what the code does is the expensive way to find out the label is
/// wrong — and five translators would each have asked.
@Suite("Nag reminder cancellation")
struct NagReminderCancellationTests {

    @Test("A task's notification identifiers cover all three kinds")
    func identifiersCoverAllThreeKinds() {
        let ids = NotificationIdentifiers.all(forTaskID: "abc-123")
        #expect(ids == ["reminder-abc-123", "overdue-abc-123", "nag-abc-123"])
        #expect(Set(ids).count == 3, "Identifiers must be distinct or one cancel would clear another.")
    }

    /// The bug, stated as an invariant: anything the scheduler can *create* it must be able to
    /// *sweep*. A prefix that can be scheduled but not swept leaks notifications forever.
    @Test("Every schedulable prefix is also swept")
    func everySchedulablePrefixIsSwept() {
        let swept = Set(NotificationIdentifiers.allPrefixes)
        #expect(swept.contains("reminder-"))
        #expect(swept.contains("overdue-"))
        #expect(swept.contains("nag-"), """
            The bulk sweep does not remove `nag-` notifications. An hourly repeating reminder on a
            completed or deleted task is never cleaned up, and UNTimeIntervalNotificationTrigger
            (repeats: true) fires until the app is deleted.
            """)

        // Anti-vacuity: every prefix the scheduler can produce must be in the swept set. Adding a
        // fourth notification kind without adding it here re-creates exactly this bug.
        let produced = Set(NotificationIdentifiers.all(forTaskID: "x")
            .map { String($0.dropLast("x".count)) })
        #expect(produced == swept, """
            Prefixes the scheduler can create: \(produced.sorted())
            Prefixes the sweep removes:        \(swept.sorted())
            These must be the same set.
            """)
    }

    /// The sweep only runs after a sync. Completing a task has to cancel immediately, or the nag
    /// keeps firing until the next sync — which, on a Vault (local-only) account, is never.
    @Test("The completion and deletion paths cancel notifications")
    func completionAndDeletionPathsCancel() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()

        for (file, context) in [
            ("NowThis/Views/Tasks/TaskRowView.swift", "the task list's own complete/delete actions"),
            ("NowThis/Intents/CompleteTaskIntent.swift", "Siri, the widget, and Shortcuts"),
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            // Either form is fine, and both exist for a reason: CompleteTaskIntent.swift is
            // compiled into NowThisWidget, whose sources do not include NowThis/Services/, so it
            // cannot reach ReminderScheduler and goes through UNUserNotificationCenter directly.
            let cancels = source.contains("ReminderScheduler.cancelReminder")
                || source.contains("NotificationIdentifiers.all(forTaskID:")
            #expect(cancels, """
                \(file) completes or deletes tasks (\(context)) without cancelling their
                notifications. `refreshAllReminders` only runs after a sync, and never at all on a
                local-only Vault account.
                """)
        }
    }

    /// The doc comment claimed the cancellation already happened. A comment that describes
    /// behaviour the code does not have is worse than no comment: it is why nobody looked.
    @Test("The scheduler's doc comment matches its behaviour")
    func docCommentMatchesBehaviour() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("NowThis/Services/ReminderScheduler.swift"),
            encoding: .utf8)
        #expect(source.contains("nagIdentifierPrefix"), "Scanning the wrong file.")
        #expect(!source.contains("only 1 notification slot. Auto-cancelled when the task is completed or deleted."), """
            ReminderScheduler still carries the doc comment that claimed nag reminders are
            auto-cancelled. Either the behaviour or the comment must change; both changed here,
            so this string should be gone.
            """)
    }
}
