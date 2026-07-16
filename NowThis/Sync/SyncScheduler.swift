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

    /// The most recent sync failure, classified into a user-facing category
    /// with actionable guidance. Drives the in-app `SyncFailureBanner` and the
    /// Settings status line. `nil` when the last sync succeeded (or was
    /// cancelled — cancellation is not a failure).
    @Published var lastSyncFailure: SyncFailure?

    /// Bumped (to a fresh value) only when a sync's inbound pull actually created
    /// or updated local tasks. Task-list views key their content `.id` off this
    /// (see `refreshOnInboundSync()`) to force a fresh `@Query` fetch, because a
    /// `@Query` bound to the main context does not re-emit when the sync engine's
    /// background context commits new rows to the shared store. Gating on real
    /// inbound changes keeps routine/push-only syncs from needlessly rebuilding
    /// the list (which would reset scroll, expansion, and selection).
    @Published private(set) var dataRefreshToken = UUID()

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
        lastSyncFailure = nil

        do {
            let accounts = try modelContext.fetch(FetchDescriptor<ServerAccount>())
            let nextcloudAccounts = accounts.filter { $0.mode == .nextcloud }

            var inboundChanged = false

            for account in nextcloudAccounts {
                try Task.checkCancellation()

                guard let password = try await keychainManager.retrieve(for: account.id) else {
                    recordAuthFailure(
                        message: String(localized: "Can't sign in to \(account.displayName) — sign in again in Settings."))
                    continue
                }

                // Circuit breaker: never re-send a password the server already
                // rejected. Repeated failed Basic-Auth trips Nextcloud's
                // brute-force protection and locks the user out. The gate
                // auto-clears once the stored password changes (re-auth).
                if authGate.shouldSkip(accountID: account.id, currentPassword: password) {
                    recordAuthFailure(
                        message: String(localized: "\(account.displayName) needs re-authentication. Sync is paused until you update your account in Settings."))
                    continue
                }

                try Task.checkCancellation()

                let credentials = CalDAVClient.Credentials(
                    username: account.username,
                    password: password
                )

                let syncWindowMonths = SyncPreferences.windowMonths()

                do {
                    if try await syncEngine.performFullSync(
                        accountID: account.id,
                        serverBaseURL: account.serverBaseURL,
                        credentials: credentials,
                        modelContainer: modelContext.container,
                        syncWindowMonths: syncWindowMonths
                    ) {
                        inboundChanged = true
                    }
                } catch CalDAVError.unauthorized {
                    // Pause this account so we don't keep hammering the server with
                    // a credential it has already rejected.
                    authGate.recordFailure(accountID: account.id, password: password)
                    recordAuthFailure(
                        message: String(localized: "\(account.displayName) needs re-authentication. Sync is paused until you update your account in Settings."))
                    logger.error("Auth rejected (401) — pausing sync for account until re-auth")
                }
            }

            lastSyncDate = Date()

            // Only force the task-list views to re-query when the pull actually
            // brought in new/changed tasks — otherwise the visible list would
            // rebuild (and lose scroll/expansion/selection) on every routine sync.
            if inboundChanged {
                dataRefreshToken = UUID()
            }

            // Sync succeeded — refresh widgets so server-side changes appear.
            onWidgetReload()

        } catch is CancellationError {
            logger.info("Sync cancelled")
        } catch {
            if let failure = SyncFailure.from(error) {
                lastSyncFailure = failure
                lastError = failure.message
            }
        }

        isSyncing = false
    }

    /// Records an authentication failure for an account so it surfaces in the
    /// banner (tappable → Settings) and the Settings status line with the same
    /// account-specific, actionable wording.
    private func recordAuthFailure(message: String) {
        lastSyncFailure = SyncFailure(category: .authentication, message: message)
        lastError = message
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
