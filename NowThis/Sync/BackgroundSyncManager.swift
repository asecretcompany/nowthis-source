import BackgroundTasks
import SwiftData
import WidgetKit
import os

/// Manages iOS Background App Refresh for periodic CalDAV sync.
///
/// Registers a `BGAppRefreshTask` that performs a lightweight sync
/// when iOS grants background execution time. Each completion
/// schedules the next refresh request.
///
/// Usage:
/// 1. Call `registerBackgroundTask()` in the app's `init()` (before scene loads)
/// 2. Call `scheduleBackgroundSync()` when the app enters the background
final class BackgroundSyncManager {

    /// The BGTaskScheduler task identifier. Must match the value in Info.plist's
    /// `BGTaskSchedulerPermittedIdentifiers` array.
    static let taskIdentifier = "com.asecretcompany.nowthis.sync.refresh"

    /// Minimum interval between background syncs (15 minutes — iOS minimum).
    static let minimumInterval: TimeInterval = 15 * 60

    private let logger = Logger(subsystem: "com.nowthis", category: "background-sync")

    /// The shared SyncEngine instance — must be the same actor instance used
    /// by the foreground SyncScheduler so the `isRunning` gate works.
    private var syncEngine: SyncEngine?

    /// True when the background sync handler uses a background `ModelContext`
    /// instead of `mainContext`. Testable flag for crash fix verification.
    let usesBackgroundContext = true

    /// True after `scheduleBackgroundSync()` has attempted to submit a task request.
    /// Will be `true` even if the OS rejects the submission (e.g., in simulator).
    private(set) var didSchedule = false

    /// The last error from `BGTaskScheduler.submit()`, if any.
    /// Nil on success or before the first scheduling attempt.
    private(set) var lastSchedulingError: Error?

    /// Registers the background refresh task handler with `BGTaskScheduler`.
    ///
    /// Must be called during app initialization, before the first scene connects.
    /// The handler performs a sync using the provided `ModelContainer` and
    /// schedules the next background refresh upon completion.
    func registerBackgroundTask(modelContainer: ModelContainer, syncEngine: SyncEngine) {
        self.syncEngine = syncEngine
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            self?.handleBackgroundSync(refreshTask, modelContainer: modelContainer)
        }
        logger.info("Registered background sync task: \(Self.taskIdentifier)")
    }

    /// Schedules a `BGAppRefreshTaskRequest` for the next background sync window.
    ///
    /// Call this when the app enters the background. iOS decides when to actually
    /// run the task based on usage patterns, battery, and network availability.
    func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.minimumInterval)

        didSchedule = true
        lastSchedulingError = nil

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled background sync (earliest: +\(Int(Self.minimumInterval))s)")
        } catch {
            lastSchedulingError = error
            logger.error("Failed to schedule background sync: \(error.localizedDescription)")
        }
    }

    /// Handles the background sync when iOS fires the `BGAppRefreshTask`.
    ///
    /// Uses `Task.detached` with a fresh `ModelContext` to avoid blocking
    /// the main thread — fixing the `0x8BADF00D` watchdog crash.
    private func handleBackgroundSync(
        _ task: BGAppRefreshTask,
        modelContainer: ModelContainer
    ) {
        // Schedule the next refresh before starting work
        scheduleBackgroundSync()

        let syncTask = Task.detached { [syncEngine = self.syncEngine] in
            guard let syncEngine else { return }
            let context = ModelContext(modelContainer)
            let keychainManager = KeychainManager()

            let accounts = try context.fetch(FetchDescriptor<ServerAccount>())

            // Snapshot account data to avoid cross-thread @Model access
            struct AccountSnapshot {
                let id: String
                let username: String
                let serverBaseURL: String
            }
            let snapshots = accounts
                .filter { $0.mode == .nextcloud }
                .map { AccountSnapshot(id: $0.id, username: $0.username, serverBaseURL: $0.serverBaseURL) }

            for snapshot in snapshots {
                try Task.checkCancellation()

                guard let password = try await keychainManager.retrieve(for: snapshot.id) else {
                    continue
                }

                let credentials = CalDAVClient.Credentials(
                    username: snapshot.username,
                    password: password
                )

                let syncWindowMonths = UserDefaults.standard.integer(forKey: "syncWindowMonths")

                try await syncEngine.performBackgroundSync(
                    accountID: snapshot.id,
                    serverBaseURL: snapshot.serverBaseURL,
                    credentials: credentials,
                    modelContainer: modelContainer,
                    syncWindowMonths: syncWindowMonths
                )
            }

            // Background pull finished — refresh widgets so server-side changes
            // appear without waiting for the widget's own timeline refresh.
            if !snapshots.isEmpty {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }

        // If iOS revokes our time, cancel the sync cleanly
        task.expirationHandler = {
            syncTask.cancel()
        }

        nonisolated(unsafe) let bgTask = task
        Task.detached {
            do {
                try await syncTask.value
                bgTask.setTaskCompleted(success: true)
            } catch {
                bgTask.setTaskCompleted(success: false)
            }
        }
    }
}
