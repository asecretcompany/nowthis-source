import Foundation
import SwiftData
import WidgetKit
import os

/// Manages periodic and on-demand sync scheduling.
///
/// Coordinates with `SyncEngine` to trigger syncs at appropriate times:
/// - On app launch / foreground return
/// - After user-initiated pull-to-refresh
/// - After task mutations (add, complete, delete) with debounce
/// - On a periodic timer (when the app is in the foreground)
///
/// **Throttling:** To avoid overwhelming the server:
/// - `syncAfterChange()` debounces with a 2-second delay (coalesces rapid edits)
/// - `syncOnForeground()` enforces a 30-second minimum interval since last sync
@MainActor
final class SyncScheduler: ObservableObject {

    // MARK: - Published State

    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var lastError: String?

    // MARK: - Dependencies

    /// The shared sync engine. Exposed so `BackgroundSyncManager` can share
    /// the same actor instance for the process-wide sync gate.
    let syncEngine: SyncEngine
    private let keychainManager: KeychainManager

    /// Called after a successful sync to refresh widget timelines so changes
    /// pulled from the server (e.g. a task completed on another device) appear
    /// in the widget without waiting for its own 15-minute timeline refresh.
    /// Injectable for testing.
    private let onWidgetReload: @MainActor () -> Void

    private var syncTimer: Timer?
    private var debounceTask: Task<Void, Never>?
    private var foregroundSyncTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.nowthis", category: "sync-scheduler")

    /// Tracks accounts whose credentials the server rejected (401), so automatic
    /// syncs stop re-sending failing Basic-Auth and tripping Nextcloud's
    /// brute-force protection. Auto-clears when the stored password changes.
    private var authGate = AuthFailureGate()

    /// The interval between automatic syncs (in seconds). Default: 5 minutes.
    var autoSyncInterval: TimeInterval = 300

    /// Minimum seconds between foreground syncs. Prevents rapid syncs on
    /// quick app-switch cycles.
    private let foregroundMinInterval: TimeInterval = 30

    /// Debounce delay for change-triggered syncs. Coalesces rapid mutations
    /// (e.g. checking off several tasks quickly) into a single sync.
    private let changeDebounceInterval: TimeInterval = 2

    init(
        syncEngine: SyncEngine = SyncEngine(),
        keychainManager: KeychainManager = KeychainManager(),
        onWidgetReload: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.syncEngine = syncEngine
        self.keychainManager = keychainManager
        self.onWidgetReload = onWidgetReload
    }

    // MARK: - Public API

    /// Triggers a sync for all Nextcloud accounts.
    ///
    /// - Parameter modelContext: The SwiftData model context.
    func syncNow(modelContext: ModelContext) async {
        guard !isSyncing else { return }

        isSyncing = true
        lastError = nil

        do {
            let accounts = try modelContext.fetch(FetchDescriptor<ServerAccount>())
            let nextcloudAccounts = accounts.filter { $0.mode == .nextcloud }

            for account in nextcloudAccounts {
                try Task.checkCancellation()

                guard let password = try await keychainManager.retrieve(for: account.id) else {
                    lastError = String(localized: "Missing credentials for \(account.displayName)")
                    continue
                }

                // Circuit breaker: never re-send a password the server already
                // rejected. Repeated failed Basic-Auth trips Nextcloud's
                // brute-force protection and locks the user out. The gate
                // auto-clears once the stored password changes (re-auth).
                if authGate.shouldSkip(accountID: account.id, currentPassword: password) {
                    lastError = String(localized: "\(account.displayName) needs re-authentication. Sync is paused until you sign in again.")
                    continue
                }

                try Task.checkCancellation()

                let credentials = CalDAVClient.Credentials(
                    username: account.username,
                    password: password
                )

                let syncWindowMonths = UserDefaults.standard.integer(forKey: "syncWindowMonths")

                do {
                    try await syncEngine.performFullSync(
                        accountID: account.id,
                        serverBaseURL: account.serverBaseURL,
                        credentials: credentials,
                        modelContainer: modelContext.container,
                        syncWindowMonths: syncWindowMonths
                    )
                } catch CalDAVError.unauthorized {
                    // Pause this account so we don't keep hammering the server with
                    // a credential it has already rejected.
                    authGate.recordFailure(accountID: account.id, password: password)
                    lastError = String(localized: "\(account.displayName) needs re-authentication. Sync is paused until you sign in again.")
                    logger.error("Auth rejected (401) — pausing sync for account until re-auth")
                }
            }

            lastSyncDate = Date()

            // Sync succeeded — refresh widgets so server-side changes appear.
            onWidgetReload()

        } catch is CancellationError {
            logger.info("Sync cancelled")
        } catch {
            lastError = error.localizedDescription
        }

        isSyncing = false
    }

    // MARK: - Change-Triggered Sync (Debounced)

    /// Queues a sync after a task mutation (add, complete, delete, edit).
    ///
    /// Uses a 2-second debounce to coalesce rapid changes (e.g., checking
    /// off multiple tasks in sequence) into a single server round-trip.
    func syncAfterChange(modelContext: ModelContext) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(changeDebounceInterval))
            guard !Task.isCancelled else { return }
            logger.debug("Debounced sync triggered after change")
            await syncNow(modelContext: modelContext)
        }
    }

    // MARK: - Foreground Sync (Throttled)

    /// Syncs when the app returns to the foreground, if enough time has
    /// elapsed since the last sync.
    ///
    /// Enforces a 30-second minimum interval to avoid overwhelming the
    /// server during rapid app switching.
    func syncOnForeground(modelContext: ModelContext) {
        guard !isSyncing else { return }

        if let lastSync = lastSyncDate,
           Date().timeIntervalSince(lastSync) < foregroundMinInterval {
            logger.debug("Skipping foreground sync — last sync \(Int(Date().timeIntervalSince(lastSync)))s ago")
            return
        }
        logger.info("Foreground sync triggered")
        nonisolated(unsafe) let ctx = modelContext
        startTrackedTask {
            await self.syncNow(modelContext: ctx)
        }
    }

    // MARK: - Periodic Auto-Sync

    /// Starts a periodic auto-sync timer.
    func startAutoSync(modelContext: ModelContext) {
        stopAutoSync()

        nonisolated(unsafe) let ctx = modelContext
        syncTimer = Timer.scheduledTimer(
            withTimeInterval: autoSyncInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.syncNow(modelContext: ctx)
            }
        }
    }

    /// Stops the auto-sync timer.
    func stopAutoSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    // MARK: - Cancellation

    /// Cancels all inflight sync tasks to allow graceful termination.
    ///
    /// Call this when the app enters the background to prevent the watchdog
    /// from killing the process due to blocked main-thread work.
    func cancelInflightSync() {
        debounceTask?.cancel()
        debounceTask = nil
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
        stopAutoSync()
    }

    /// Starts a tracked async task that can be cancelled via `cancelInflightSync()`.
    func startTrackedTask(_ operation: @escaping @Sendable () async -> Void) {
        foregroundSyncTask?.cancel()
        foregroundSyncTask = Task { @MainActor in
            await operation()
        }
    }

    deinit {
        MainActor.assumeIsolated {
            syncTimer?.invalidate()
        }
    }
}
