@preconcurrency import UserNotifications
import SwiftData
import os

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
    private static let identifierPrefix = "reminder-"
    private static let overdueIdentifierPrefix = "overdue-"

    // MARK: - Permission

    /// Requests notification permission if not already granted.
    /// Call when the user first sets a reminder on a task.
    static func requestPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
                if let error {
                    Self.logger.error("Notification permission error: \(error.localizedDescription)")
                }
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
    static func scheduleReminder(for task: TaskItem, badge: Int? = nil) {
        guard let dueDate = task.dueDate,
              let offset = task.reminderOffset else { return }

        let fireDate = computeFireDate(dueDate: dueDate, isDueDateOnly: task.isDueDateOnly, reminderOffset: offset)

        guard fireDate > Date() else {
            logger.debug("Skipping past reminder for task \(task.id)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "⏰ \(task.title)"
        content.body = bodyText(for: offset)
        content.sound = .default
        content.userInfo = ["taskID": task.id]
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

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.logger.error("Failed to schedule reminder: \(error.localizedDescription)")
            }
        }
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
    static func scheduleOverdueBadge(for task: TaskItem, fireDate: Date, badge: Int?) {
        guard fireDate > Date() else {
            logger.debug("Skipping past overdue notification for task \(task.id)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = "Now overdue"
        content.sound = .default
        content.userInfo = ["taskID": task.id]
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

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.logger.error("Failed to schedule overdue notification: \(error.localizedDescription)")
            }
        }
    }

    /// Cancels a pending reminder and any overdue-badge notification for a task.
    static func cancelReminder(for taskID: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(
                withIdentifiers: [
                    "\(identifierPrefix)\(taskID)",
                    "\(overdueIdentifierPrefix)\(taskID)"
                ]
            )
    }

    // MARK: - Bulk Refresh

    /// Re-schedules all reminders from the current task database.
    ///
    /// Removes all existing `reminder-*` notifications, then re-schedules
    /// up to 60 (leaving headroom for geofence notifications under the
    /// iOS 64-notification cap). Tasks are sorted by fire date so the
    /// nearest reminders get priority.
    @MainActor
    static func refreshAllReminders(modelContext: ModelContext) async {
        let center = UNUserNotificationCenter.current()

        // Ensure notification permission before scheduling synced alarms
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            settings = await center.notificationSettings()
        }
        guard settings.authorizationStatus != .denied else {
            logger.info("Notification permission denied, skipping reminder refresh")
            return
        }

        // Remove all existing reminder and overdue notifications — must
        // complete before scheduling new ones to avoid a race where removal
        // deletes freshly-added notifications with the same identifiers.
        let pending = await center.pendingNotificationRequests()
        let staleIDs = pending
            .filter {
                $0.identifier.hasPrefix(identifierPrefix) ||
                $0.identifier.hasPrefix(overdueIdentifierPrefix)
            }
            .map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: staleIDs)

        // Fetch all tasks with a due date (reminder or not), excluding deleted.
        // Tasks without a reminder still get an overdue-badge notification.
        let duePredicate = #Predicate<TaskItem> {
            $0.dueDate != nil && !$0.isDeletedLocally
        }
        let descriptor = FetchDescriptor<TaskItem>(predicate: duePredicate)
        guard let candidates = try? modelContext.fetch(descriptor) else { return }

        let plan = planNotifications(
            tasks: candidates,
            now: Date(),
            maxCount: maxReminders,
            badgesEnabled: NotificationPreferences.isBadgeEnabled
        )

        // Recover each task from its id so we can build notification content.
        var tasksByID: [String: TaskItem] = [:]
        for task in candidates { tasksByID[task.id] = task }

        for entry in plan {
            guard let task = tasksByID[entry.taskID] else { continue }
            switch entry.kind {
            case .reminder:
                scheduleReminder(for: task, badge: entry.badge)
            case .overdue:
                scheduleOverdueBadge(for: task, fireDate: entry.fireDate, badge: entry.badge)
            }
        }

        logger.info("Refreshed notifications: scheduled \(plan.count) of \(candidates.count) candidates")
    }

    // MARK: - Notification Planning

    /// A notification the scheduler intends to register. Produced purely (no
    /// `UNUserNotificationCenter` interaction) so the scheduling policy —
    /// ordering, the iOS pending-notification cap, and the badge count carried
    /// by each notification — is unit-testable.
    struct PlannedNotification: Equatable {
        enum Kind: Equatable {
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
        badgesEnabled: Bool
    ) -> [PlannedNotification] {
        let active = tasks.filter {
            $0.status != .completed && $0.status != .cancelled && !$0.isDeletedLocally
        }

        var entries: [(fireDate: Date, taskID: String, kind: PlannedNotification.Kind)] = []
        for task in active {
            guard let due = task.dueDate else { continue }
            if let offset = task.reminderOffset {
                let fire = computeFireDate(dueDate: due, isDueDateOnly: task.isDueDateOnly, reminderOffset: offset)
                guard fire > now else { continue }
                entries.append((fire, task.id, .reminder))
            } else {
                // Overdue-badge notifications exist only to update the badge.
                guard badgesEnabled else { continue }
                let deadline = DueDateHelper.effectiveDeadline(for: due, isDateOnly: task.isDueDateOnly)
                guard deadline > now else { continue }
                entries.append((deadline, task.id, .overdue))
            }
        }

        entries.sort { $0.fireDate < $1.fireDate }

        return entries.prefix(maxCount).map { entry in
            PlannedNotification(
                taskID: entry.taskID,
                fireDate: entry.fireDate,
                badge: badgesEnabled ? computeBadgeCount(tasks: active, now: entry.fireDate) : nil,
                kind: entry.kind
            )
        }
    }

    // MARK: - Fire Date Computation

    /// Computes the notification fire date for a task.
    ///
    /// Uses `DueDateHelper.effectiveDeadline` so date-only tasks fire
    /// relative to end-of-local-day rather than midnight UTC.
    static func computeFireDate(dueDate: Date, isDueDateOnly: Bool, reminderOffset: Int) -> Date {
        let effectiveDue = DueDateHelper.effectiveDeadline(for: dueDate, isDateOnly: isDueDateOnly)
        return effectiveDue.addingTimeInterval(-Double(reminderOffset))
    }

    // MARK: - Helpers

    private static func bodyText(for offset: Int) -> String {
        switch offset {
        case 0: return "Due now"
        case 300: return "Due in 5 minutes"
        case 900: return "Due in 15 minutes"
        case 1800: return "Due in 30 minutes"
        case 3600: return "Due in 1 hour"
        case 86400: return "Due in 1 day"
        default:
            let minutes = offset / 60
            if minutes < 60 {
                return "Due in \(minutes) minutes"
            }
            let hours = minutes / 60
            return "Due in \(hours) hour\(hours == 1 ? "" : "s")"
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
    static func computeBadgeCount(tasks: [TaskItem], now: Date = Date()) -> Int {
        var count = 0
        for task in tasks {
            // Skip completed/cancelled tasks
            guard task.status != .completed && task.status != .cancelled else { continue }

            var shouldCount = false

            // Check if overdue
            if let dueDate = task.dueDate {
                let effectiveDeadline = DueDateHelper.effectiveDeadline(
                    for: dueDate, isDateOnly: task.isDueDateOnly
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
                    reminderOffset: offset
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
    static func updateBadgeCount(modelContext: ModelContext) async {
        let center = UNUserNotificationCenter.current()

        // If the user disabled badges in app settings, clear and return.
        guard NotificationPreferences.isBadgeEnabled else {
            try? await center.setBadgeCount(0)
            return
        }

        // Request permission if not yet determined — this is the fix for
        // new users who never see badge counts because setBadgeCount
        // requires authorization.
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }

        // Check if permission was denied (either before or after the prompt)
        let updatedSettings = await center.notificationSettings()
        guard updatedSettings.authorizationStatus != .denied else {
            return
        }

        do {
            let badgePredicate = #Predicate<TaskItem> {
                !$0.isDeletedLocally
            }
            let descriptor = FetchDescriptor<TaskItem>(
                predicate: badgePredicate
            )
            let allTasks = try modelContext.fetch(descriptor)
            let activeTasks = allTasks.filter {
                $0.status != .completed && $0.status != .cancelled
            }
            let count = computeBadgeCount(tasks: activeTasks)
            try? await center.setBadgeCount(count)
        } catch {
            logger.error("Failed to update badge count: \(error.localizedDescription)")
        }
    }
}
