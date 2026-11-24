import Foundation
import SwiftData
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
    @discardableResult
    static func syncTaskIfEnabled(
        _ task: TaskItem, accounts: [ServerAccount],
        manager: NextcloudCalendarSyncManager = NextcloudCalendarSyncManager(),
        appleSync: @MainActor (TaskItem) throws -> Bool = syncToAppleCalendar,
        onCommit: @escaping @MainActor () -> Void = {}
    ) -> Task<Void, Never>? {
        guard let container = task.modelContext?.container, !task.isDeleted else { return nil }
        // Resolve model values synchronously, before either integration can suspend.
        let taskID = task.id
        let title = task.title
        let appleEnabled = UserDefaults.standard.bool(forKey: "appleCalendarSyncEnabled")
        let nextcloudEnabled = shouldSyncToNextcloudCalendar(task)
        let accountIDs = accounts.filter { $0.modelContext != nil && !$0.isDeleted && $0.mode != .vault }.map(\.id)

        if appleEnabled {
            do {
                if try syncAppleTask(taskID: taskID, container: container, sync: appleSync) {
                    onCommit()
                    logger.debug("Auto-synced task '\(title)' to Apple Calendar")
                }
            } catch {
                logger.error("Apple Calendar auto-sync failed: \(error.localizedDescription)")
            }
        }

        guard nextcloudEnabled else { return nil }
        return Task { @MainActor in
            for accountID in accountIDs {
                do {
                    if try await manager.syncSingleTask(taskID: taskID, accountID: accountID, role: .managedMirror,
                                                        container: container, onCommit: onCommit) {
                        logger.debug("Auto-synced task '\(title)' to Nextcloud Calendar")
                    }
                } catch {
                    logger.error("Nextcloud Calendar auto-sync failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Apple sync acknowledges its own sidecar transaction. Never save the caller's
    /// task context or leave it dirty before the subsequent Nextcloud request.
    private static func syncAppleTask(taskID: String, container: ModelContainer,
                                      sync: @MainActor (TaskItem) throws -> Bool) throws -> Bool {
        guard !container.mainContext.hasChanges else { return false }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let task = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first,
              !task.isDeletedLocally else { return false }
        return try sync(task)
    }

    private static func syncToAppleCalendar(_ task: TaskItem) throws -> Bool {
        let permissionManager = CalendarPermissionManager()
        permissionManager.refreshStatus()
        guard permissionManager.hasAccess else { return false }
        return try AppleCalendarSyncManager(permissionManager: permissionManager).syncSingleTask(task)
    }
}
