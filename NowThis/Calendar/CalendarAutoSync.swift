import Foundation
import os

/// Checks user preferences and triggers calendar sync for a single task.
///
/// Called after task creation/edit to automatically push the task to
/// Apple Calendar and/or Nextcloud Calendar when the user has enabled
/// those integrations in Settings.
@MainActor
enum CalendarAutoSync {

    private static let logger = Logger(subsystem: "com.nowthis", category: "calendar-auto-sync")

    /// Returns whether the task should be synced to Apple Calendar.
    ///
    /// True when `appleCalendarSyncEnabled` is on AND the task has a `dueDate`.
    static func shouldSyncToAppleCalendar(_ task: TaskItem) -> Bool {
        UserDefaults.standard.bool(forKey: "appleCalendarSyncEnabled") && task.dueDate != nil
    }

    /// Returns whether the task should be synced to Nextcloud Calendar.
    ///
    /// True when `nextcloudCalendarSyncEnabled` is on AND the task has a `dueDate`.
    static func shouldSyncToNextcloudCalendar(_ task: TaskItem) -> Bool {
        UserDefaults.standard.bool(forKey: "nextcloudCalendarSyncEnabled") && task.dueDate != nil
    }

    /// Syncs the task to all enabled calendars.
    ///
    /// - Parameters:
    ///   - task: The task to sync.
    ///   - accounts: Nextcloud accounts for Nextcloud Calendar sync.
    static func syncTaskIfEnabled(_ task: TaskItem, accounts: [ServerAccount]) async {
        // Apple Calendar
        if shouldSyncToAppleCalendar(task) {
            let permissionManager = CalendarPermissionManager()
            permissionManager.refreshStatus()
            if permissionManager.hasAccess {
                let appleSync = AppleCalendarSyncManager(permissionManager: permissionManager)
                do {
                    try appleSync.syncSingleTask(task)
                    logger.debug("Auto-synced task '\(task.title)' to Apple Calendar")
                } catch {
                    logger.error("Apple Calendar auto-sync failed: \(error.localizedDescription)")
                }
            }
        }

        // Nextcloud Calendar
        if shouldSyncToNextcloudCalendar(task) {
            let nextcloudSync = NextcloudCalendarSyncManager()
            for account in accounts where account.mode != .vault {
                do {
                    nonisolated(unsafe) let unsafeTask = task
                    nonisolated(unsafe) let unsafeAccount = account
                    try await nextcloudSync.syncSingleTask(unsafeTask, account: unsafeAccount)
                    logger.debug("Auto-synced task '\(task.title)' to Nextcloud Calendar")
                } catch {
                    logger.error("Nextcloud Calendar auto-sync failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
