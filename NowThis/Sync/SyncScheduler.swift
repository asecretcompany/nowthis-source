import Foundation
import SwiftData
import WidgetKit
import os

/// The fields a sync pass needs from a `ServerAccount`, copied out of the model.
///
/// A sync loop awaits the keychain and then a multi-second network round trip per
/// account, and `AccountManager.removeAccount` deletes on the **main** context.
/// Holding the `ServerAccount` itself across those suspensions means a delete
/// that lands mid-sync invalidates it, and the next `account.displayName` read
/// traps in SwiftData. Values can't be invalidated.
struct SyncAccount: Equatable, Sendable {
    let id: String
    let displayName: String
    let serverBaseURL: String
    let username: String

    /// Reads every field up front, on the caller's actor, before any `await`.
    init(account: ServerAccount) {
        self.id = account.id
        self.displayName = account.displayName
        self.serverBaseURL = account.serverBaseURL
        self.username = account.username
    }
}

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

    /// Compatibility signal for consumers such as the Watch. Screens use scoped query revisions.
    @Published private(set) var dataRefreshToken = UUID()

    /// Collections the server holds in its trash, found during the last sync. Surfaced once by
    /// `TrashedListsNotice` so a user who can see a list on the server understands why it did
    /// not arrive here, instead of it silently going missing.
    @Published private(set) var trashedListsFound: [TrashedList] = []

    // MARK: - Dependencies

    /// The shared sync engine. Exposed so `BackgroundSyncManager` can share
    /// the same actor instance for the process-wide sync gate.
    let syncEngine: SyncEngine
    private let keychainManager: KeychainManager

    /// Called after a successful sync to refresh widget timelines so changes
    /// pulled from the server (e.g. a task completed on another device) appear
    /// in the widget without waiting for its own 15-minute timeline refresh.
    /// Injectable for testing.
    let progressState = SyncProgressState()
    private var progressListener: Task<Void, Never>?

    private let onWidgetReload: @MainActor () -> Void
    private let onNotificationFlush: @MainActor (ModelContext) async -> Void
    private weak var spotlightModelContext: ModelContext?
    private weak var spotlightIndexer: SpotlightIndexer?

    private var syncTimer: Timer?
    private var debounceTask: Task<Void, Never>?
    private var foregroundSyncTask: Task<Void, Never>?
    private var runnerTask: Task<Void, Never>?
    private var needsFollowup = false
    private var pendingAccountSync = false
    private var isForeground = true
    private var changeListener: Task<Void, Never>?
    private var changeFlush: Task<Void, Never>?
    private var pendingChange: SyncChange?
    @Published private(set) var unscopedRefreshRevision: UInt64 = 0
    @Published private(set) var latestCommittedChange: SyncChange?
    @Published private(set) var listRevisions: [String: UInt64] = [:]
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
        onWidgetReload: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
        onNotificationFlush: @escaping @MainActor (ModelContext) async -> Void = {
            await ReminderScheduler.reconcileNow(modelContext: $0)
        }
    ) {
        self.syncEngine = syncEngine
        self.keychainManager = keychainManager
        self.onWidgetReload = onWidgetReload
        self.onNotificationFlush = onNotificationFlush
        progressListener = Task { [weak self, syncEngine] in
            let stream = await syncEngine.progressUpdates()
            for await progress in stream {
                guard let self, !Task.isCancelled else { return }
                if let progress { self.progressState.apply(progress) }
                else { self.progressState.clear() }
            }
        }
        changeListener = Task { [weak self, syncEngine] in
            let stream = await syncEngine.changes()
            for await change in stream {
                guard let self, !Task.isCancelled else { return }
                self.queueCommittedChange(change)
            }
        }
    }

    /// Bind the app's existing indexer before store services start. The same instance observes
    /// local saves and receives committed background changes through this scheduler's stream.
    func configureSpotlight(modelContext: ModelContext, indexer: SpotlightIndexer) {
        spotlightModelContext = modelContext
        spotlightIndexer = indexer
    }

    private func queueCommittedChange(_ change: SyncChange) {
        if let pending = pendingChange {
            pendingChange = SyncChange(revision: max(pending.revision, change.revision),
                accountIDs: pending.accountIDs.union(change.accountIDs),
                listIDs: pending.listIDs.union(change.listIDs),
                changedIDs: pending.changedIDs.union(change.changedIDs),
                deletedIDs: pending.deletedIDs.union(change.deletedIDs), kind: change.kind)
        } else { pendingChange = change }
        guard changeFlush == nil else { return }
        changeFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.flushCommittedChanges()
        }
    }

    private func flushCommittedChanges() {
        changeFlush?.cancel(); changeFlush = nil
        guard let change = pendingChange else { return }
        pendingChange = nil
        guard change.revision > (latestCommittedChange?.revision ?? 0) else { return }
        for id in change.listIDs { listRevisions[id] = change.revision }
        latestCommittedChange = change
        dataRefreshToken = UUID()
        if let spotlightModelContext, let spotlightIndexer {
            spotlightIndexer.requestReindex(modelContext: spotlightModelContext)
        }
    }

    // MARK: - Public API

    /// Starts the first pull after account setup has saved metadata and credentials.
    /// Login is an explicit request: it must bypass the foreground throttle and
    /// must not get lost behind a run that already captured its account list.
    func syncAfterAccountAdded(modelContext: ModelContext) {
        pendingAccountSync = true
        guard isForeground else { return }
        if isSyncing { needsFollowup = true; return }
        debounceTask?.cancel()
        debounceTask = nil
        nonisolated(unsafe) let context = modelContext
        startTrackedTask {
            await self.syncNow(modelContext: context)
        }
    }

    /// Triggers a sync for all Nextcloud accounts.
    ///
    /// - Parameter modelContext: The SwiftData model context.
    func syncNow(modelContext: ModelContext) async {
        if let runnerTask { await runnerTask.value; return }
        // Reserve ownership synchronously before any actor hop.
        isSyncing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.needsFollowup = false
                await self.performSyncRun(modelContext: modelContext)
            } while self.needsFollowup && !Task.isCancelled
            self.runnerTask = nil
            self.isSyncing = false
            // Foreground return can arrive before a cancelled runner finishes
            // its cleanup. Start the saved login request once ownership is free.
            if self.pendingAccountSync && self.isForeground {
                self.syncAfterAccountAdded(modelContext: modelContext)
            }
        }
        runnerTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
    }

    private func performSyncRun(modelContext: ModelContext) async {
        let servicingAccountSync = pendingAccountSync
        pendingAccountSync = false
        defer {
            if servicingAccountSync && Task.isCancelled { pendingAccountSync = true }
        }

        // A background pull may have committed rows to the shared store while the app was away.
        // It runs in the BGTask with no `@Published` to bump, so it leaves its inbound-change
        // signal on the engine both paths share. Take it here, before the network work: those
        // rows are already stored, so showing them must not wait on this sync — or depend on it
        // succeeding. Nor can the sync below make up for it, since the background pull stored the
        // new etags and this one will therefore find nothing changed.
        if await syncEngine.consumePendingInboundRefresh() {
            dataRefreshToken = UUID()
            unscopedRefreshRevision &+= 1
        }

        lastError = nil
        lastSyncFailure = nil

        do {
            // Materialize the accounts before the first suspension point. The loop
            // below awaits the keychain and then a multi-second network sync, and
            // `AccountManager.removeAccount` deletes on the main context — so a
            // delete landing mid-sync would invalidate a `ServerAccount` this loop
            // still holds, and the next property read would trap in SwiftData.
            let accounts = try modelContext.fetch(FetchDescriptor<ServerAccount>())
            let nextcloudAccounts = accounts
                .filter { $0.mode == .nextcloud }
                .map(SyncAccount.init(account:))

            var inboundChanged = false
            var trashedFound: [TrashedList] = []

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
                        syncWindowMonths: syncWindowMonths,
                        reconcileNotifications: false
                    ) {
                        inboundChanged = true
                    }
                    trashedFound.append(contentsOf: await syncEngine.lastTrashedLists)
                    if await syncEngine.lastMovePermissionDenied {
                        // A move was undone locally; the lists have to show it.
                        inboundChanged = true
                        lastSyncFailure = SyncFailure(
                            category: .accessDenied,
                            message: SyncFailure.accessDeniedMessage
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch CalDAVError.unauthorized {
                    // Pause this account so we don't keep hammering the server with
                    // a credential it has already rejected.
                    authGate.recordFailure(accountID: account.id, password: password)
                    recordAuthFailure(
                        message: String(localized: "\(account.displayName) needs re-authentication. Sync is paused until you update your account in Settings."))
                    logger.error("Auth rejected (401) — pausing sync for account until re-auth")
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    if let failure = SyncFailure.from(error) {
                        lastSyncFailure = failure
                        lastError = failure.message
                    }
                    // Other accounts may be healthy; retain this account's failure and continue.
                }
                let outcome = await syncEngine.lastOutcome
                if outcome.status == .partial, let failure = outcome.failures.first {
                    lastSyncFailure = failure; lastError = failure.message
                }
            }

            if lastSyncFailure == nil { lastSyncDate = Date() }

            // De-duplicated by href: two accounts could in principle report the same collection
            // path, and the user should not be shown the same row twice.
            var seenHrefs: Set<String> = []
            trashedListsFound = trashedFound.filter { seenHrefs.insert($0.href).inserted }

            // Only force the task-list views to re-query when the pull actually
            // brought in new/changed tasks — otherwise the visible list would
            // rebuild (and lose scroll/expansion/selection) on every routine sync.
            if inboundChanged { flushCommittedChanges() }

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

        // Committed changes carry durable tickets. A canceled foreground run may no
        // longer own an assertion; the next local recovery pass services those tickets.
        progressState.clear()
        if !Task.isCancelled { await onNotificationFlush(modelContext) }

        let unconsumed = await syncEngine.consumePendingInboundRefresh()
        if pendingChange != nil { flushCommittedChanges() }
        else if unconsumed, latestCommittedChange == nil {
            dataRefreshToken = UUID()
            unscopedRefreshRevision &+= 1
        }
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
        if isSyncing { needsFollowup = true; return }
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
        isForeground = true
        guard !isSyncing else { return }

        if !pendingAccountSync, let lastSync = lastSyncDate,
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
                guard !self.isSyncing else { return }
                self.startTrackedTask { await self.syncNow(modelContext: ctx) }
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
        isForeground = false
        debounceTask?.cancel()
        debounceTask = nil
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
        runnerTask?.cancel()
        needsFollowup = false
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
            changeListener?.cancel()
            progressListener?.cancel(); changeFlush?.cancel(); runnerTask?.cancel()
            syncTimer?.invalidate()
        }
    }
}
