import Testing
import Foundation

@testable import NowThis

/// **The sweep must stop wiping what it is about to re-write.**
///
/// `refreshAllReminders` removes every `reminder-`/`overdue-`/`nag-` request *before* it fetches
/// the tasks it is going to reschedule — and the fetch is a `guard let … else { return }`. Today
/// that window is narrow because it only runs after a sync. The fix for the missing due-date
/// badge calls the same sweep on every local edit and on backgrounding, which would turn a rare
/// landmine into a routine one: every re-plan would briefly leave the user with no pending
/// notifications at all, and a fetch failure would leave them with none permanently.
///
/// `scheduleDelta` is the pure answer: compare what is desired against what is already pending,
/// and touch only the difference. Adding a request whose identifier already exists replaces it in
/// place, so nothing needs to be removed first.
@Suite("Notification schedule delta")
struct ScheduleDeltaTests {

    // MARK: - Helpers

    private func planned(
        _ taskID: String,
        fireDate: Date,
        badge: Int?,
        kind: ReminderScheduler.PlannedNotification.Kind = .overdue,
        isNagging: Bool = false,
        title: String = "Untitled"
    ) -> ReminderScheduler.PlannedNotification {
        ReminderScheduler.PlannedNotification(
            taskID: taskID, fireDate: fireDate, badge: badge, kind: kind,
            isNagging: isNagging, title: title
        )
    }

    private func pending(
        _ identifier: String,
        fireDate: Date? = nil,
        badge: Int? = nil,
        title: String? = "Untitled"
    ) -> ReminderScheduler.PendingSnapshot {
        ReminderScheduler.PendingSnapshot(
            identifier: identifier, fireDate: fireDate, badge: badge, title: title)
    }

    // MARK: - The invariant the destructive sweep violates

    @Test("An already-correct notification is neither removed nor re-added")
    func unchangedEntryIsLeftAlone() {
        let fire = Date(timeIntervalSince1970: 1_800_000_000)
        let desired = [planned("A", fireDate: fire, badge: 1)]
        let already = [pending("overdue-A", fireDate: fire, badge: 1)]

        let delta = ReminderScheduler.scheduleDelta(desired: desired, pending: already)

        #expect(delta.toAdd.isEmpty, """
            A notification that is already pending with the right fire date and badge must be left
            exactly as it is. Removing and re-adding it opens a window in which the user has no
            pending notification at all.
            """)
        #expect(delta.toRemove.isEmpty)
    }

    @Test("The delta never removes an identifier it is about to write")
    func neverRemovesWhatItAdds() {
        let fire = Date(timeIntervalSince1970: 1_800_000_000)
        let desired = [
            planned("B", fireDate: fire, badge: 2),
            planned("D", fireDate: fire.addingTimeInterval(3600), badge: 3),
        ]
        let already = [
            pending("reminder-A", fireDate: fire, badge: 1),
            pending("overdue-B", fireDate: fire, badge: 2),
        ]

        let delta = ReminderScheduler.scheduleDelta(desired: desired, pending: already)

        let addedIDs = Set(delta.toAdd.map(\.identifier))
        #expect(addedIDs.isDisjoint(with: Set(delta.toRemove)), """
            toAdd \(addedIDs.sorted()) and toRemove \(delta.toRemove.sorted()) overlap. Removing an
            identifier the same pass re-adds is the destructive sweep this function replaces.
            """)
        #expect(delta.toAdd.map(\.taskID) == ["D"], "Only the genuinely new entry needs writing.")
        #expect(delta.toRemove == ["reminder-A"], "Only the entry nothing desires any more.")
    }

    // MARK: - Staleness

    @Test("A pending notification carrying the wrong badge is re-written")
    func staleBadgeIsRewritten() {
        let fire = Date(timeIntervalSince1970: 1_800_000_000)
        let desired = [planned("A", fireDate: fire, badge: 4)]
        let already = [pending("overdue-A", fireDate: fire, badge: 1)]

        let delta = ReminderScheduler.scheduleDelta(desired: desired, pending: already)

        #expect(delta.toAdd.map(\.identifier) == ["overdue-A"], """
            The badge each notification carries is a snapshot computed at plan time. When the count
            changes the request must be re-written, or the icon shows the old number.
            """)
        #expect(delta.toRemove.isEmpty, "Adding the same identifier replaces it; no removal needed.")
    }

    @Test("A pending notification pinned to a stale fire date is re-written")
    func staleFireDateIsRewritten() {
        let fire = Date(timeIntervalSince1970: 1_800_000_000)
        let desired = [planned("A", fireDate: fire.addingTimeInterval(7200), badge: 1)]
        let already = [pending("overdue-A", fireDate: fire, badge: 1)]

        let delta = ReminderScheduler.scheduleDelta(desired: desired, pending: already)

        #expect(delta.toAdd.map(\.identifier) == ["overdue-A"], """
            Dragging a task to a new day in the calendar rewrites its due date. The already-pending
            notification stays pinned to the old deadline unless the delta notices the difference.
            """)
        #expect(delta.toRemove.isEmpty)
    }

    @Test("A renamed task's pending notification is re-written")
    func renamedTaskIsRewritten() {
        let fire = Date(timeIntervalSince1970: 1_800_000_000)
        let desired = [planned("A", fireDate: fire, badge: 1, title: "Call the plumber")]
        let already = [pending("overdue-A", fireDate: fire, badge: 1, title: "Call the plumer")]

        let delta = ReminderScheduler.scheduleDelta(desired: desired, pending: already)

        #expect(delta.toAdd.map(\.identifier) == ["overdue-A"], """
            The task's title is the notification's title. Neither its fire date nor its badge
            changes when the user fixes a typo, so a delta that compares only those two leaves the
            old name on the alert permanently — the sweep this replaced rebuilt it every pass.
            """)
        #expect(delta.toRemove.isEmpty)
    }

    // MARK: - Ownership

    @Test("Notifications the scheduler does not own are never removed")
    func foreignPrefixesAreUntouched() {
        let fire = Date(timeIntervalSince1970: 1_800_000_000)
        let desired = [planned("B", fireDate: fire, badge: 1)]
        let already = [
            pending("geofence-C"),
            pending("overdue-B", fireDate: fire, badge: 1),
        ]

        let delta = ReminderScheduler.scheduleDelta(desired: desired, pending: already)

        #expect(!delta.toRemove.contains("geofence-C"), """
            GeofenceManager schedules its own notifications. The sweep filters on
            NotificationIdentifiers.allPrefixes and must keep doing so.
            """)
        #expect(delta.toRemove.isEmpty)
    }

    // MARK: - Nag reminders

    @Test("Turning nagging off removes the nag without touching the reminder")
    func nagRemovedWhenTaskNoLongerNags() {
        let fire = Date(timeIntervalSince1970: 1_800_000_000)
        let desired = [planned("A", fireDate: fire, badge: 1, kind: .reminder, isNagging: false)]
        let already = [
            pending("reminder-A", fireDate: fire, badge: 1),
            pending("nag-A"),
        ]

        let delta = ReminderScheduler.scheduleDelta(desired: desired, pending: already)

        #expect(delta.toRemove == ["nag-A"], """
            UNTimeIntervalNotificationTrigger(repeats: true) fires until it is explicitly removed.
            A nag left behind after the toggle is switched off never stops.
            """)
        #expect(delta.toAdd.isEmpty, "The reminder itself is unchanged and must not be re-written.")
    }

    @Test("Turning nagging on re-writes the reminder so the nag gets created")
    func naggingOnRewritesTheReminder() {
        let fire = Date(timeIntervalSince1970: 1_800_000_000)
        let desired = [planned("A", fireDate: fire, badge: 1, kind: .reminder, isNagging: true)]
        let already = [pending("reminder-A", fireDate: fire, badge: 1)]

        let delta = ReminderScheduler.scheduleDelta(desired: desired, pending: already)

        #expect(delta.toAdd.map(\.identifier) == ["reminder-A"], """
            `scheduleReminder` creates the nag as a side effect. When the nag is missing the
            reminder must be re-written even though its own fire date and badge are unchanged.
            """)
        #expect(delta.toRemove.isEmpty)
    }

    // MARK: - Identifiers

    @Test("A planned notification's identifiers match what the scheduler cancels")
    func identifiersMatchCancellation() {
        let fire = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(planned("x", fireDate: fire, badge: nil, kind: .reminder).identifier == "reminder-x")
        #expect(planned("x", fireDate: fire, badge: nil, kind: .overdue).identifier == "overdue-x")
        #expect(
            planned("x", fireDate: fire, badge: nil, kind: .reminder, isNagging: true).identifiers
                == ["reminder-x", "nag-x"],
            "A nagging reminder owns two requests; the delta must account for both.")

        // Anti-vacuity: every identifier the plan can produce has to be one the sweep recognises,
        // or the delta would leave it pending forever.
        let owned = Set(NotificationIdentifiers.allPrefixes)
        for kind in [ReminderScheduler.PlannedNotification.Kind.reminder, .overdue] {
            for identifier in planned("x", fireDate: fire, badge: nil, kind: kind, isNagging: true).identifiers {
                #expect(owned.contains(where: { identifier.hasPrefix($0) }), "\(identifier) is unswept.")
            }
        }
    }
}
