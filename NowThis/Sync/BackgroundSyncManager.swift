import BackgroundTasks
import Foundation
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
/// 1. Register during UIKit's launch callback, before scene connection.
/// 2. Configure the store after it opens, including successful recovery retries.
/// 3. Call `scheduleBackgroundSync()` when the app enters the background.
final class BackgroundSyncManager: @unchecked Sendable {

    /// The BGTaskScheduler task identifier. Must match the value in Info.plist's
    /// `BGTaskSchedulerPermittedIdentifiers` array.
    static let taskIdentifier = "com.asecretcompany.nowthis.sync.refresh"

    /// Minimum interval between background syncs (15 minutes — iOS minimum).
    static let minimumInterval: TimeInterval = 15 * 60

    private let logger = Logger(subsystem: "com.nowthis", category: "background-sync")

    /// The shared SyncEngine instance — must be the same actor instance used
    /// by the foreground SyncScheduler so the `isRunning` gate works.
    private var syncEngine: SyncEngine?
    private let storeLock = NSLock()
    private var configuredStore: ModelContainer?

    /// True when the background sync handler uses a background `ModelContext`
    /// instead of `mainContext`. Testable flag for crash fix verification.
    let usesBackgroundContext = true

    /// True after `scheduleBackgroundSync()` has attempted to submit a task request.
    /// Will be `true` even if the OS rejects the submission (e.g., in simulator).
    private var scheduled = false
    var didSchedule: Bool { storeLock.withLock { scheduled } }

    /// The last error from `BGTaskScheduler.submit()`, if any.
    /// Nil on success or before the first scheduling attempt.
    private var schedulingError: Error?
    var lastSchedulingError: Error? { storeLock.withLock { schedulingError } }

    /// Registers the background refresh task handler with `BGTaskScheduler`.
    ///
    /// Register before launch finishes, even if store opening will be deferred.
    /// A delivery without an opened store fails safely without accessing SQLite.
    func registerBackgroundTask(syncEngine: SyncEngine) {
        storeLock.withLock { self.syncEngine = syncEngine }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            guard let self else { refreshTask.setTaskCompleted(success: false); return }
            // Capture the one budget at handler entry, before resubmission or store access.
            let budget = BackgroundRunBudget()
            self.handleBackgroundSync(refreshTask, budget: budget)
        }
        logger.info("Registered background sync task: \(Self.taskIdentifier)")
    }

    /// Attach an opened store without registering another launch handler on Retry.
    func configureStore(modelContainer: ModelContainer) {
        storeLock.withLock { configuredStore = modelContainer }
    }

    /// Schedules a `BGAppRefreshTaskRequest` for the next background sync window.
    ///
    /// Call this when the app enters the background. iOS decides when to actually
    /// run the task based on usage patterns, battery, and network availability.
    func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.minimumInterval)

        storeLock.withLock { scheduled = true; schedulingError = nil }

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled background sync (earliest: +\(Int(Self.minimumInterval))s)")
        } catch {
            storeLock.withLock { schedulingError = error }
            logger.error("Failed to schedule background sync: \(error.localizedDescription)")
        }
    }

    /// Recover local scheduling first. A remote cutoff cancels only remote admission;
    /// final expiration closes both phases and never admits a fresh flush.
    static func performRun(
        budget: BackgroundRunBudget = BackgroundRunBudget(),
        operation: @escaping @Sendable () async throws -> Bool,
        flush: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await BackgroundRunBudget.$current.withValue(budget) {
            do { try budget.checkFinalAdmission() } catch { return false }
            await flush()
            do { try budget.checkRemoteAdmission() } catch { return false }
            let completed = await performRemote(budget: budget, operation: operation)
            do { try budget.checkFinalAdmission() } catch { return false }
            await flush()
            do { try budget.checkFinalAdmission() } catch { return false }
            return completed
        }
    }

    private static func performRemote(budget: BackgroundRunBudget,
        operation: @escaping @Sendable () async throws -> Bool) async -> Bool {
        let result = BackgroundRunResult()
        let remote = Task {
            await BackgroundRunBudget.$phase.withValue(.remote) {
                let completed: Bool
                do { try budget.checkRemoteAdmission(); completed = try await operation() }
                catch { completed = false }
                budget.whenDrained { result.resolve(completed) }
            }
        }
        let timer = Task {
            do { try await Task.sleep(until: budget.remoteCutoff, clock: .continuous) }
            catch { return }
            budget.stopRemote()
            remote.cancel()
            budget.whenDrained { result.resolve(false) }
        }
        let completed = await withTaskCancellationHandler {
            await result.value()
        } onCancel: {
            budget.expire()
            remote.cancel()
            budget.whenDrained { result.resolve(false) }
        }
        timer.cancel()
        return completed
    }

    /// Runs the eligible remote accounts under the delivery's existing allowance.
    static func performAccounts(accountIDs: [String], modelContainer: ModelContainer,
        budget: BackgroundRunBudget,
        operation: @escaping @Sendable (String) async throws -> Bool) async throws -> Bool {
        try await BackgroundRunBudget.$current.withValue(budget) {
            try await BackgroundRunBudget.$phase.withValue(.remote) {
                try budget.checkRemoteAdmission()
                var completed = true
                let ordered = try budget.withCriticalSection {
                    let context = ModelContext(modelContainer); context.autosaveEnabled = false
                    let cursor = try BackgroundSyncCursor.load(scope: "accounts", in: context)
                    return BackgroundSyncCursor.rotated(accountIDs, after: cursor)
                }
                for id in ordered {
                    try budget.checkRemoteAdmission()
                    try budget.withCriticalSection {
                        let context = ModelContext(modelContainer); context.autosaveEnabled = false
                        try BackgroundSyncCursor.recordAttempt(id: id, scope: "accounts", in: context)
                    }
                    if try await operation(id) == false { completed = false }
                }
                return completed
            }
        }
    }

    private func handleBackgroundSync(_ task: BGAppRefreshTask, budget: BackgroundRunBudget) {
        let delivery = BackgroundDeliveryCoordinator(budget: budget, resubmit: { [self] in
            scheduleBackgroundSync()
        })
        // Install before start: expiration can arrive before the worker handle exists.
        task.expirationHandler = { delivery.expire() }
        nonisolated(unsafe) let bgTask = task
        delivery.start(operation: { [self] budget in
            guard let modelContainer = storeLock.withLock({ configuredStore }) else { return false }
            let syncEngine = storeLock.withLock { self.syncEngine }
            return await Self.performRun(budget: budget, operation: {
                guard let syncEngine else { return false }
                let keychainManager = KeychainManager()
                struct AccountSnapshot: Sendable {
                    let id: String
                    let username: String
                    let serverBaseURL: String
                }
                let snapshots = try budget.withCriticalSection {
                    let context = ModelContext(modelContainer)
                    return try context.fetch(FetchDescriptor<ServerAccount>())
                        .filter { $0.mode == .nextcloud }
                        .map { AccountSnapshot(id: $0.id, username: $0.username, serverBaseURL: $0.serverBaseURL) }
                }
                let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
                let completed = try await Self.performAccounts(accountIDs: snapshots.map(\.id),
                    modelContainer: modelContainer, budget: budget) { id in
                    guard let snapshot = byID[id] else { return true }
                    try budget.checkRemoteAdmission()
                    guard let password = try await keychainManager.retrieve(for: snapshot.id) else { return true }
                    try budget.checkRemoteAdmission()
                    let credentials = CalDAVClient.Credentials(username: snapshot.username, password: password)
                    let outcome = await syncEngine.performBackgroundSyncOutcome(
                        accountID: snapshot.id, serverBaseURL: snapshot.serverBaseURL,
                        credentials: credentials, modelContainer: modelContainer,
                        syncWindowMonths: SyncPreferences.windowMonths(), reconcileNotifications: false, runBudget: budget)
                    if outcome.status == .cancelled { throw CancellationError() }
                    return outcome.status == .completed
                }
                if !snapshots.isEmpty { WidgetCenter.shared.reloadAllTimelines() }
                try budget.checkRemoteAdmission()
                return completed
            }, flush: {
                // Local-only accounts receive the same prompt-free recovery pass.
                await ReminderScheduler.reconcileNow(modelContainer: modelContainer,
                    policy: ReminderReconcilePolicy(allowsPermissionPrompt: false, deadline: budget.finalCutoff))
            })
        }, completion: { success in
            bgTask.setTaskCompleted(success: success)
        })
    }
}
