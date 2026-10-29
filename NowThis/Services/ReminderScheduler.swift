@preconcurrency import UserNotifications
import UIKit
import SwiftData
import os

/// The scheduler's window onto `UNUserNotificationCenter`.
///
/// It exists so `reconcileScheduledNotifications` can be tested on the thing that actually
/// matters — the *order* of the reads, writes and cancellations it issues. End state alone
/// cannot show a window in which the user has no pending notifications at all, and that window
/// is the defect the reconcile was written to close.
@MainActor
protocol NotificationStore {
    /// Stores sharing a system center also share one mutation queue across containers.
    var coordinationDomain: String? { get }
    /// Whether the app may schedule at all. Prompts once when the user has not yet decided.
    func authorizationAllowsScheduling(allowPrompt: Bool) async -> Bool
    /// Everything currently pending, including requests other components own.
    func pendingSnapshots() async -> [ReminderScheduler.PendingSnapshot]
    /// Registers a request, replacing any pending one with the same identifier.
    func add(_ request: UNNotificationRequest) async throws
    func remove(identifiers: [String])
}

extension NotificationStore {
    var coordinationDomain: String? { nil }
}

/// Whether this process may put the notification permission prompt on screen.
///
/// `requestAuthorization` does not return until someone answers the prompt. Inside a process
/// XCTest launched nobody can, so on a simulator that has never been asked the first request
/// waits forever and the test run hangs until xcodebuild kills it. Only an active app may ask.
enum NotificationPrompt {
    static func isAllowed(environment: [String: String] = ProcessInfo.processInfo.environment,
                          applicationIsActive: Bool = true) -> Bool {
        applicationIsActive && environment["XCTestConfigurationFilePath"] == nil
    }
}

/// The live `UNUserNotificationCenter` conformance.
struct SystemNotificationStore: NotificationStore {
    var coordinationDomain: String? { "system-notification-center" }

    // `nonisolated` because this type is `@MainActor` by inference from
    // `NotificationStore`, while `add(_:)` logs from `UNUserNotificationCenter`'s completion
    // handler — a `@Sendable` closure that runs off the main actor and cannot read
    // main-actor-isolated state. `Logger` is `Sendable` and this is a `let`, so there is
    // nothing to isolate. (`ReminderScheduler` below needs no such annotation: it is not
    // actor-isolated in the first place.)
    private nonisolated static let logger = Logger(subsystem: "com.nowthis", category: "reminders")

    private var center: UNUserNotificationCenter { .current() }

    func authorizationAllowsScheduling(allowPrompt: Bool) async -> Bool {
        var settings = await center.notificationSettings()
        if allowPrompt, settings.authorizationStatus == .notDetermined, NotificationPrompt.isAllowed(applicationIsActive: UIApplication.shared.applicationState == .active) {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            settings = await center.notificationSettings()
        }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    func pendingSnapshots() async -> [ReminderScheduler.PendingSnapshot] {
        await center.pendingNotificationRequests().map { request in
            ReminderScheduler.PendingSnapshot(
                identifier: request.identifier,
                // Only calendar triggers have a fire date worth comparing. A repeating nag has
                // no fixed one, and the delta never compares it.
                fireDate: (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(),
                badge: request.content.badge?.intValue,
                title: request.content.userInfo["title"] as? String,
                body: request.content.body, repeats: request.trigger?.repeats,
                interval: (request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval
            )
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        do {
            try await center.add(request)
        } catch {
            Self.logger.error("Notification registration failed: \(error.localizedDescription)")
            throw error
        }
    }

    func remove(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

/// Schedules and manages local notification reminders for tasks.
///
/// Uses `UNUserNotificationCenter` to schedule time-based reminders
/// derived from each task's `dueDate` and `reminderOffset`.
///
/// **iOS Limit:** Maximum 64 pending notifications. This scheduler
/// reserves 60 slots for reminders, leaving headroom for geofence
/// notifications.
struct ReminderScheduler {

    private static let logger = Logger(subsystem: "com.nowthis", category: "reminders")
    private static let maxReminders = 60
    private static let identifierPrefix = NotificationIdentifiers.reminderPrefix
    private static let overdueIdentifierPrefix = NotificationIdentifiers.overduePrefix
    private static let nagIdentifierPrefix = NotificationIdentifiers.nagPrefix
    @MainActor private static let systemCoordinator = ReminderReconciliationCoordinator()
    @MainActor private static var namedCoordinators: [String: ReminderReconciliationCoordinator] = [:]
    @MainActor private static var isolatedCoordinators: [ObjectIdentifier: CoordinatorEntry] = [:]

    @MainActor
    private final class CoordinatorEntry {
        weak var container: ModelContainer?
        let coordinator = ReminderReconciliationCoordinator()
        init(container: ModelContainer) { self.container = container }
    }

    @MainActor
    private static func coordinator(for context: ModelContext?, store: any NotificationStore) -> ReminderReconciliationCoordinator {
        if store.coordinationDomain == "system-notification-center" { return systemCoordinator }
        if let domain = store.coordinationDomain {
            if let existing = namedCoordinators[domain] { return existing }
            let owner = ReminderReconciliationCoordinator()
            namedCoordinators[domain] = owner
            return owner
        }
        guard let context else { return systemCoordinator }
        let container = context.container
        isolatedCoordinators = isolatedCoordinators.filter { $0.value.container != nil }
        let key = ObjectIdentifier(container)
        if let entry = isolatedCoordinators[key] { return entry.coordinator }
        let entry = CoordinatorEntry(container: container)
        isolatedCoordinators[key] = entry
        return entry.coordinator
    }
    @MainActor private static let badgeCoalescer = ReminderProjectionCoalescer()

    // MARK: - Permission

    /// Requests notification permission if not already granted.
    /// Call when the user first sets a reminder on a task.
    @MainActor static func requestPermissionIfNeeded() {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined,
                  NotificationPrompt.isAllowed(applicationIsActive: UIApplication.shared.applicationState == .active) else { return }
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                Self.logger.error("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Schedule / Cancel

    /// Schedules a local notification for a task's reminder.
    ///
    /// Computes fire date as `dueDate - reminderOffset` seconds.
    /// Skips scheduling if the fire date is in the past.
    ///
    /// - Parameters:
    ///   - task: The task to schedule a reminder for.
    ///   - badge: The app icon badge count to apply when the notification fires.
    ///     Passing a value lets the badge update even while the app is closed.
    ///     `nil` leaves the badge untouched (used by single-task edit paths and
    ///     when the user has disabled badges).
    @MainActor
    static func scheduleReminder(
        for task: TaskItem,
        badge: Int? = nil,
        store: NotificationStore = SystemNotificationStore()
    ) async throws {
        guard let dueDate = task.dueDate,
              let offset = task.reminderOffset else { return }

        let fireDate = computeFireDate(
            dueDate: dueDate,
            isDueDateOnly: task.isDueDateOnly,
            reminderOffset: offset,
            allDayReminderMinutes: TaskDefaultsPreferences.allDayReminderMinutes
        )

        guard fireDate > Date() else {
            logger.debug("Skipping past reminder for task \(task.id)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "⏰ \(task.title)"
        content.body = bodyText(for: offset)
        content.sound = .default
        content.userInfo = ["taskID": task.id, "title": task.title]
        if let badge { content.badge = NSNumber(value: badge) }

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: "\(identifierPrefix)\(task.id)",
            content: content,
            trigger: trigger
        )

        let snapshot = ReminderTaskInput(task: task)
        try await coordinator(for: task.modelContext, store: store).withMutation {
            try await store.add(request)
            if snapshot.isNaggingReminder {
                try await scheduleNagReminder(for: snapshot, badge: badge, store: store)
            } else {
                store.remove(identifiers: [nagIdentifierPrefix + snapshot.id])
            }
        }
    }

    /// Schedules an hourly repeating notification for a task.
    ///
    /// Uses `UNTimeIntervalNotificationTrigger(repeats: true)`, which consumes only one
    /// notification slot but **fires until it is explicitly removed** — there is no natural end.
    /// Cancellation is therefore the caller's job, on three paths: `cancelReminder(for:)` when
    /// the task is completed or deleted, the same call when the nag toggle is switched off, and
    /// the `refreshAllReminders` sweep. All three exist; an earlier version of this comment
    /// claimed they did while only the third was even attempted, and it excluded `nag-`.
    @MainActor
    private static func scheduleNagReminder(
        for task: ReminderTaskInput,
        badge: Int?,
        store: NotificationStore
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = "🔔 \(task.title)"
        content.body = String(
            localized: "notification.nag.body",
            defaultValue: "Hourly reminder — still pending",
            comment: "Body of the repeating hourly reminder. The notification's title is the task's own name.")
        content.sound = .default
        content.userInfo = ["taskID": task.id, "title": task.title]
        if let badge { content.badge = NSNumber(value: badge) }

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: 3600,
            repeats: true
        )

        let request = UNNotificationRequest(
            identifier: "\(nagIdentifierPrefix)\(task.id)",
            content: content,
            trigger: trigger
        )

        try await store.add(request)
    }

    /// Cancels the hourly nag reminder for a task.
    @MainActor
    static func cancelNagReminder(
        for taskID: String,
        store: NotificationStore = SystemNotificationStore()
    ) {
        coordinator(for: nil, store: store).requestRemoval(
            identifiers: ["\(nagIdentifierPrefix)\(taskID)"], store: store)
    }

    /// Schedules a "now overdue" notification at a task's deadline.
    ///
    /// Used for tasks that have a due date but no reminder offset, so the app
    /// icon badge updates the moment the task becomes overdue — even while the
    /// app is closed. The notification both informs the user and carries the
    /// badge count as of the deadline.
    ///
    /// - Parameters:
    ///   - task: The task whose deadline to notify on.
    ///   - fireDate: The effective deadline (already validated to be in the future).
    ///   - badge: The app icon badge count to apply when the notification fires.
    @MainActor
    static func scheduleOverdueBadge(
        for task: TaskItem,
        fireDate: Date,
        badge: Int?,
        store: NotificationStore = SystemNotificationStore()
    ) async throws {
        guard fireDate > Date() else {
            logger.debug("Skipping past overdue notification for task \(task.id)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = String(
            localized: "notification.overdue.body",
            defaultValue: "Now overdue",
            comment: "Body of the notification sent the moment a task passes its due date. The title is the task's own name.")
        content.sound = .default
        content.userInfo = ["taskID": task.id, "title": task.title]
        if let badge { content.badge = NSNumber(value: badge) }

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: "\(overdueIdentifierPrefix)\(task.id)",
            content: content,
            trigger: trigger
        )

        try await coordinator(for: task.modelContext, store: store).withMutation {
            try await store.add(request)
        }
    }

    /// Cancels a pending reminder, overdue-badge, and nag notification for a task.
    @MainActor
    static func cancelReminder(for taskID: String) {
        systemCoordinator.requestCancellation(taskIDs: [taskID], store: SystemNotificationStore())
    }

    /// Await cancellation through the same mutation owner as reconciliation.
    @MainActor
    static func cancelReminders(for taskIDs: [String], modelContext: ModelContext,
                                store: any NotificationStore = SystemNotificationStore()) async {
        await coordinator(for: modelContext, store: store).cancel(taskIDs: Set(taskIDs), store: store)
    }

    // MARK: - Bulk Refresh

    /// Brings the pending notification set in line with the current task database.
    ///
    /// Compares the plan against what is already pending and touches only the difference,
    /// writing before it cancels. The sweep this replaced removed everything first and rebuilt
    /// from scratch, which was survivable only because it ran once per sync; the badge fix runs
    /// this on every local edit and on backgrounding, where a wipe-and-rebuild would leave the
    /// user with no pending notifications every time — and permanently, on the fetch's early
    /// return.
    ///
    /// - Parameters:
    ///   - modelContext: The context to plan from.
    ///   - store: Seam for tests. Defaults to the live notification centre.
    ///   - badgesEnabled: Whether the user wants badges. A parameter rather than a direct read
    ///     of `NotificationPreferences` for the same reason `planNotifications` takes one: it is
    ///     a `UserDefaults` global, and a test that cannot set it cannot test this function.
    @MainActor
    @discardableResult
    static func reconcileScheduledNotifications(
        modelContext: ModelContext,
        store: NotificationStore = SystemNotificationStore(),
        badgesEnabled: Bool = NotificationPreferences.isBadgeEnabled,
        allDayReminderMinutes: Int = TaskDefaultsPreferences.allDayReminderMinutes,
        worker: (any ReminderProjectionWorking)? = nil,
        policy: ReminderReconcilePolicy = .foreground
    ) async -> ReminderReconciliationOutcome {
        let outcome = await coordinator(for: modelContext, store: store).reconcile(
            modelContext: modelContext, policy: policy, store: store,
            worker: worker ?? ReminderProjectionWorker(container: modelContext.container),
            badgesEnabled: badgesEnabled, allDayReminderMinutes: allDayReminderMinutes)
        let runID = BackgroundRunBudget.current?.runID.uuidString ?? "-"
        logger.info("Reminder reconciliation status=\(String(describing: outcome.status), privacy: .public) requested=\(outcome.requestedCount) confirmed=\(outcome.confirmedCount) deferred=\(outcome.deferredTaskIDs.count) expired=\(outcome.expiredTaskIDs.count) run=\(runID, privacy: .public)")
        return outcome
    }

    /// Re-schedules all reminders from the current task database.
    ///
    /// Retained under its original name because the sync engine calls it; it is now a thin
    /// alias for `reconcileScheduledNotifications`.
    @MainActor
    static func refreshAllReminders(modelContext: ModelContext) async {
        await reconcileScheduledNotifications(modelContext: modelContext)
    }

    // MARK: - Re-plan Triggers

    /// The coalescing pass in flight, if any.
    @MainActor private static var pendingReconcile: Task<Void, Never>?

    /// How long to wait for further edits before re-planning. A date picker writes on every
    /// tick of the wheel; without this, each tick would cost a fetch, a plan and a round trip
    /// to `UNUserNotificationCenter`.
    private static let coalescingWindow = Duration.milliseconds(400)

    /// Asks for a re-plan after the current burst of edits settles.
    ///
    /// Every path that writes a task's due date calls this. Scheduling used to happen only as
    /// a side effect of a successful CalDAV sync, which meant a Vault-Mode account never
    /// scheduled the "now overdue" notification at all — and that notification is the only
    /// thing that can move the app icon badge while the app is closed.
    ///
    /// Fire-and-forget on purpose: the callers are button actions and intent bodies that must
    /// not block on notification work.
    @MainActor
    static func requestReconcile(modelContext: ModelContext) {
        // Persist before the debounce. Suspension or termination must leave recoverable work.
        do {
            try BackgroundRunBudget.protectingCurrent {
                try ReminderSchedulingJournal.saveTaskChanges(in: modelContext, needsRecovery: true)
            }
        } catch {
            logger.error("Failed to save reminder recovery intent: \(error.localizedDescription)")
            return
        }
        coordinator(for: modelContext, store: SystemNotificationStore()).invalidate(taskIDs: [])
        pendingReconcile?.cancel()
        // ModelContext does not retain its container. Own the store through deferred work;
        // the saved transaction above lets the pass use the container's main context.
        let container = modelContext.container
        pendingReconcile = Task { @MainActor in
            try? await Task.sleep(for: coalescingWindow)
            guard !Task.isCancelled else { return }
            pendingReconcile = nil
            await reconcileNow(modelContainer: container)
        }
    }

    /// Re-plans immediately, superseding any coalescing pass in flight.
    ///
    /// For the app-lifecycle callers that must finish before the process is suspended — a
    /// `requestReconcile` scheduled on the way to the background would be cancelled with the
    /// process, losing exactly the edits the user made last.
    @MainActor
    @discardableResult
    static func reconcileNow(modelContext: ModelContext,
                             policy: ReminderReconcilePolicy = .foreground) async -> ReminderReconciliationOutcome {
        pendingReconcile?.cancel()
        pendingReconcile = nil
        let result = await reconcileScheduledNotifications(modelContext: modelContext, policy: policy)
        if !policy.shouldStop && (result.status == .confirmed || result.status == .capacityLimited) {
            await updateBadgeCount(modelContext: modelContext, allowPrompt: policy.allowsPermissionPrompt)
        }
        return result
    }

    /// Re-plans from a container rather than a context.
    ///
    /// `SyncEngine` runs off the main actor and `mainContext` may only be touched on it, so the
    /// hop belongs here — the alternative was a `MainActor.run` at each call site wrapping an
    /// unstructured `Task` that nothing awaited.
    @MainActor
    @discardableResult
    static func reconcileNow(modelContainer: ModelContainer,
                             policy: ReminderReconcilePolicy = .foreground) async -> ReminderReconciliationOutcome {
        await reconcileNow(modelContext: modelContainer.mainContext, policy: policy)
    }

    // MARK: - Notification Planning

    /// A notification the scheduler intends to register. Produced purely (no
    /// `UNUserNotificationCenter` interaction) so the scheduling policy —
    /// ordering, the iOS pending-notification cap, and the badge count carried
    /// by each notification — is unit-testable.
    struct PlannedNotification: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// A visible reminder alert for a task with a `reminderOffset`.
            case reminder
            /// A "now overdue" alert at a task's deadline (no reminder set),
            /// scheduled so the app icon badge updates while the app is closed.
            case overdue
        }

        let taskID: String
        let fireDate: Date
        /// App icon badge count as of `fireDate`, or `nil` when badges are off.
        let badge: Int?
        let kind: Kind
        /// Whether the task also wants the hourly repeating nag. `scheduleReminder`
        /// creates that request as a side effect, so the plan has to know about it
        /// or the delta below would never notice one appearing or disappearing.
        let isNagging: Bool
        /// The task's title, which is the notification's title. Carried so the delta can
        /// notice a rename — nothing else about a renamed task changes.
        let title: String

        /// The request identifier this entry registers under. Built from the same
        /// prefixes `cancelReminder(for:)` removes, so scheduling and cancellation
        /// can never drift apart.
        var identifier: String {
            switch kind {
            case .reminder: NotificationIdentifiers.reminderPrefix + taskID
            case .overdue: NotificationIdentifiers.overduePrefix + taskID
            }
        }

        /// Every request this entry owns — two for a nagging reminder.
        var identifiers: [String] {
            isNagging ? [identifier, NotificationIdentifiers.nagPrefix + taskID] : [identifier]
        }
    }

    // MARK: - Schedule Delta

    /// A notification already registered with the system, reduced to the fields the
    /// delta compares. Built from a `UNNotificationRequest` at the call site so the
    /// delta itself stays pure.
    struct PendingSnapshot: Equatable {
        let identifier: String
        /// The request's next fire date, or `nil` for a trigger that has none —
        /// a repeating nag, or a geofence.
        let fireDate: Date?
        let badge: Int?
        /// The task title this request was built from, read back from `userInfo`. `nil` for a
        /// request the scheduler did not write.
        let title: String?
        var body: String? = nil
        var repeats: Bool? = nil
        var interval: TimeInterval? = nil
    }

    /// The difference between the plan and what is already pending.
    struct ScheduleDelta: Equatable {
        /// Entries to register. Adding a request whose identifier already exists
        /// replaces it in place, so an entry here never needs a matching removal.
        let toAdd: [PlannedNotification]
        /// Identifiers to cancel, sorted. Only ever identifiers the scheduler owns.
        let toRemove: [String]
    }

    /// Computes what to add and what to cancel to make the pending set match the plan.
    ///
    /// The sweep this replaces removed everything first and rebuilt from scratch, which
    /// left a window with no pending notifications at all — survivable when it ran only
    /// after a sync, not when it runs on every local edit. Comparing instead means an
    /// already-correct notification is never touched.
    ///
    /// An entry is rewritten when any request it owns is missing, or when the pending
    /// request carries a different fire date or badge. Identifiers outside
    /// `NotificationIdentifiers.allPrefixes` — geofence alerts — are never removed.
    static func scheduleDelta(
        desired: [PlannedNotification],
        pending: [PendingSnapshot]
    ) -> ScheduleDelta {
        var pendingByID: [String: PendingSnapshot] = [:]
        for snapshot in pending { pendingByID[snapshot.identifier] = snapshot }

        var desiredIdentifiers: Set<String> = []
        var toAdd: [PlannedNotification] = []

        for entry in desired {
            desiredIdentifiers.formUnion(entry.identifiers)

            // Missing outright — including a nag that has not been created yet.
            guard entry.identifiers.allSatisfy({ pendingByID[$0] != nil }) else {
                toAdd.append(entry)
                continue
            }
            // Present, but carrying a stale deadline or a stale badge count.
            let existing = pendingByID[entry.identifier]
            if !fireDatesMatch(existing?.fireDate, entry.fireDate)
                || existing?.badge != entry.badge
                || existing?.title != entry.title {
                toAdd.append(entry)
            }
        }

        let toRemove = pending
            .map(\.identifier)
            .filter { identifier in
                NotificationIdentifiers.allPrefixes.contains { identifier.hasPrefix($0) }
                    && !desiredIdentifiers.contains(identifier)
            }
            .sorted()

        return ScheduleDelta(toAdd: toAdd, toRemove: toRemove)
    }

    /// Compares a pending request's fire date against a planned one, to the second.
    ///
    /// `UNCalendarNotificationTrigger` is built from date components down to `.second`, so the
    /// date it reports back has no sub-second part while the planned date usually does. Exact
    /// equality would therefore call every pending notification stale and rewrite the entire
    /// set on every pass.
    private static func fireDatesMatch(_ pending: Date?, _ planned: Date) -> Bool {
        guard let pending else { return false }
        return abs(pending.timeIntervalSince(planned)) < 1
    }

    /// Builds the prioritized notification schedule for the given tasks.
    ///
    /// - Reminders fire at `dueDate - reminderOffset`.
    /// - A task with a due date but no reminder gets an `.overdue` notification
    ///   at its effective deadline, so the badge updates the moment it becomes
    ///   overdue even with the app closed (skipped entirely when badges are off).
    /// - Entries whose fire date is in the past are dropped.
    /// - The result is sorted nearest-first and capped at `maxCount` (the shared
    ///   iOS pending-notification budget), so the soonest notifications win.
    /// - Each entry's `badge` is the count computed as of its own fire date.
    static func planNotifications(
        tasks: [TaskItem],
        now: Date,
        maxCount: Int,
        badgesEnabled: Bool,
        allDayReminderMinutes: Int = TaskDefaultsPreferences.allDayReminderMinutes,
        calendar: Calendar = .current
    ) -> [PlannedNotification] {
        return ReminderNotificationPlanner.plan(
            tasks: tasks.map(ReminderTaskInput.init(task:)),
            now: now,
            maxCount: maxCount,
            badgesEnabled: badgesEnabled,
            allDayReminderMinutes: allDayReminderMinutes,
            calendar: calendar
        )
    }

    // MARK: - Fire Date Computation

    /// Computes the notification fire date for a task.
    ///
    /// - Date-only (all-day) tasks fire at a configurable time-of-day on the due
    ///   day (`allDayReminderMinutes` since local midnight, default 9:00 AM) —
    ///   matching Apple Reminders — rather than at end-of-local-day, so an all-day
    ///   reminder pings in the morning instead of at midnight. The `reminderOffset`
    ///   then shifts earlier from that anchor (e.g. 86400 = the day before at the
    ///   same time).
    /// - Date+time tasks fire at `dueDate - reminderOffset`, unchanged.
    static func computeFireDate(
        dueDate: Date,
        isDueDateOnly: Bool,
        reminderOffset: Int,
        allDayReminderMinutes: Int = TaskDefaultsPreferences.defaultAllDayReminderMinutes,
        calendar: Calendar = .current
    ) -> Date {
        guard isDueDateOnly else {
            return dueDate.addingTimeInterval(-Double(reminderOffset))
        }
        let anchor = DueDateHelper.localStartOfDay(
            for: dueDate, isDateOnly: true, regionCalendar: calendar)
            .addingTimeInterval(Double(allDayReminderMinutes) * 60)
        return anchor.addingTimeInterval(-Double(reminderOffset))
    }

    // MARK: - Helpers

    /// The lead-time line under a reminder's title.
    ///
    /// The six named offsets are the ones the picker offers and are separate keys rather than one
    /// counted template, because a translator seeing *"Due in 15 minutes"* whole can choose the
    /// natural phrasing; a language that says *"in a quarter of an hour"* has nowhere to put a
    /// number. The two fallback branches carry an arbitrary count and are plural-varied in the
    /// catalog instead — the `minutes == 1` and `hours == 1` sub-branches that used to sit here
    /// were English's rule written in Swift, and they got French's zero wrong.
    static func bodyText(for offset: Int) -> String {
        switch offset {
        case 0:
            return String(localized: "notification.due.now",
                          defaultValue: "Due now",
                          comment: "Reminder body when the task is due at this moment.")
        case 300:
            return String(localized: "notification.due.in5Minutes",
                          defaultValue: "Due in 5 minutes",
                          comment: "Reminder body for the 5-minutes-before lead time.")
        case 900:
            return String(localized: "notification.due.in15Minutes",
                          defaultValue: "Due in 15 minutes",
                          comment: "Reminder body for the 15-minutes-before lead time.")
        case 1800:
            return String(localized: "notification.due.in30Minutes",
                          defaultValue: "Due in 30 minutes",
                          comment: "Reminder body for the 30-minutes-before lead time.")
        case 3600:
            return String(localized: "notification.due.in1Hour",
                          defaultValue: "Due in 1 hour",
                          comment: "Reminder body for the 1-hour-before lead time.")
        case 86400:
            return String(localized: "notification.due.in1Day",
                          defaultValue: "Due in 1 day",
                          comment: "Reminder body for the 1-day-before lead time.")
        default:
            let minutes = offset / 60
            if minutes < 60 {
                return String(localized: "notification.due.inMinutes",
                              defaultValue: "Due in \(minutes) minutes",
                              comment: "Reminder body for a custom lead time. The placeholder is a whole number of minutes.")
            }
            let hours = minutes / 60
            return String(localized: "notification.due.inHours",
                          defaultValue: "Due in \(hours) hours",
                          comment: "Reminder body for a custom lead time. The placeholder is a whole number of hours.")
        }
    }

    // MARK: - Badge Count

    /// Computes the app badge count: overdue tasks + tasks with fired reminders.
    ///
    /// Pure function for testability. Does not interact with UNUserNotificationCenter.
    ///
    /// - Parameters:
    ///   - tasks: Active (non-completed, non-cancelled, non-deleted) tasks to evaluate.
    ///   - now: The current date (injectable for testing).
    /// - Returns: The badge count.
    static func computeBadgeCount(
        tasks: [TaskItem],
        now: Date = Date(),
        allDayReminderMinutes: Int = TaskDefaultsPreferences.allDayReminderMinutes,
        calendar: Calendar = .current
    ) -> Int {
        var count = 0
        for task in tasks {
            // Skip completed/cancelled tasks
            guard task.status != .completed && task.status != .cancelled else { continue }

            var shouldCount = false

            // Check if overdue
            if let dueDate = task.dueDate {
                let effectiveDeadline = DueDateHelper.effectiveDeadline(
                    for: dueDate, isDateOnly: task.isDueDateOnly, regionCalendar: calendar
                )
                if effectiveDeadline <= now {
                    shouldCount = true
                }
            }

            // Check if reminder has fired (even if not yet overdue)
            if !shouldCount, let dueDate = task.dueDate, let offset = task.reminderOffset {
                let fireDate = computeFireDate(
                    dueDate: dueDate,
                    isDueDateOnly: task.isDueDateOnly,
                    reminderOffset: offset,
                    allDayReminderMinutes: allDayReminderMinutes,
                    calendar: calendar
                )
                if fireDate <= now {
                    shouldCount = true
                }
            }

            if shouldCount {
                count += 1
            }
        }
        return count
    }

    /// Fetches active tasks and updates the app icon badge count.
    ///
    /// Requests notification permission if not yet determined, then sets the
    /// badge count. Without this permission check, `setBadgeCount` silently
    /// fails for new users who haven't triggered a reminder prompt yet.
    @MainActor
    static func updateBadgeCount(modelContext: ModelContext, allowPrompt: Bool = true) async {
        guard !ReminderReconcilePolicy.background.shouldStop else { return }
        let center = UNUserNotificationCenter.current()
        let generation = badgeCoalescer.beginRequest()
        let badgesEnabled = NotificationPreferences.isBadgeEnabled

        // If the user disabled badges in app settings, clear and return.
        guard badgesEnabled else {
            try? await center.setBadgeCount(0)
            return
        }

        // Freeze the main-context edit overlay and all calendar/preference inputs before any
        // notification-center suspension. The worker reads committed state in its own context.
        guard !Task.isCancelled else { return }
        let overlay: ReminderTaskOverlay
        do {
            overlay = try BackgroundRunBudget.protectingCurrent {
                ReminderTaskOverlay(modelContext: modelContext)
            }
        } catch { return }
        let request = ReminderProjectionRequest(
            now: Date(),
            calendar: .current,
            allDayReminderMinutes: TaskDefaultsPreferences.allDayReminderMinutes,
            maxCount: maxReminders,
            badgesEnabled: true,
            overlay: overlay
        )
        let worker = ReminderProjectionWorker(container: modelContext.container)

        // Request permission if not yet determined — this is the fix for
        // new users who never see badge counts because setBadgeCount
        // requires authorization.
        let settings = await center.notificationSettings()
        guard badgeCoalescer.isCurrent(generation), !ReminderReconcilePolicy.background.shouldStop else { return }
        if allowPrompt, settings.authorizationStatus == .notDetermined, NotificationPrompt.isAllowed(applicationIsActive: UIApplication.shared.applicationState == .active) {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }

        // Check if permission was denied (either before or after the prompt)
        let updatedSettings = await center.notificationSettings()
        guard badgeCoalescer.isCurrent(generation), !ReminderReconcilePolicy.background.shouldStop else { return }
        guard updatedSettings.authorizationStatus != .denied else {
            return
        }

        guard let result = await worker.project(request) else {
            logger.error("Failed to update badge count: task fetch failed")
            return
        }
        guard badgeCoalescer.isCurrent(generation), !ReminderReconcilePolicy.background.shouldStop else { return }
        try? await center.setBadgeCount(result.badgeCount)
    }
}
