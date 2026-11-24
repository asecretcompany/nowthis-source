import Foundation
import os
import SwiftData

/// Orchestrates bidirectional sync between SwiftData and a CalDAV server.
///
/// The engine follows this sequence:
/// 1. **Discover** calendars on the remote server
/// 2. **Pull** remote changes → update SwiftData
/// 3. **Push** local dirty records → PUT/DELETE to server
/// 4. **Reconcile** ETags and sync tokens
///
/// The engine owns a background ModelContext for each run. Only immutable
/// change values cross to UI and service consumers.
actor SyncEngine {

    // MARK: - State

    enum SyncState: Sendable {
        case idle
        case syncing
        case error(String)
    }

    private(set) var state: SyncState = .idle

    /// Collections the server reported as sitting in its trash on the most recent discovery.
    /// Read by `SyncScheduler` after a sync so the UI can tell the user why lists it can see on
    /// the server did not arrive. Not persisted and never turned into `TaskList`s.
    private(set) var lastTrashedLists: [TrashedList] = []

    /// Whether the last full sync undid a move because the server refused it
    /// (403) — a list shared read-only, or a share revoked since the move. Read by
    /// `SyncScheduler` after the sync returns, like `lastTrashedLists`, rather than
    /// thrown: a throw would abort the remaining accounts and the UI refresh, and
    /// the rollback itself is a local change the UI has to show.
    private(set) var lastMovePermissionDenied = false

    /// Whether a background pull applied inbound changes that no view has been told about.
    ///
    /// `performFullSync` returns its inbound-change signal and `SyncScheduler` turns that into
    /// `dataRefreshToken`. `performBackgroundSync` runs in the BGTask, returns `Void`, and has no
    /// `@Published` to bump — so it leaves the fact here instead, on the engine instance both
    /// paths share (`BackgroundSyncManager` is handed the scheduler's own actor). The next
    /// foreground sync consumes it.
    ///
    /// In memory on purpose. It matters only while the views that went stale are still alive; a
    /// relaunch rebuilds them and `@Query` fetches the rows from the store anyway.
    private(set) var pendingInboundRefresh = false

    /// Reads the flag and clears it, so one background pull produces one refresh.
    func consumePendingInboundRefresh() -> Bool {
        defer { pendingInboundRefresh = false }
        return pendingInboundRefresh
    }

    /// True while either `performFullSync` or `performBackgroundSync` is executing.
    /// Used as a process-wide sync gate to prevent concurrent syncs from
    /// creating duplicate tasks.
    private var isRunning = false

    /// Public read accessor for the sync gate. Used by tests and
    /// `BackgroundSyncManager` to check if a sync is in progress.
    var isSyncInProgress: Bool { isRunning }

    private let inboundSave: @MainActor @Sendable (ModelContext) throws -> Void
    private let calDAVClient: CalDAVClient
    private let taskPhotoSync: TaskPhotoSync
    private let taskPhotoCleanup: TaskPhotoCleanupRunner
    private let taskPhotoVaultMoves: TaskPhotoVaultMoves
    private let taskPhotoCache: TaskPhotoCache
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.nowthis", category: "sync-engine")

    init(calDAVClient: CalDAVClient = CalDAVClient(),
         taskPhotoSync: TaskPhotoSync = TaskPhotoSync(),
         taskPhotoCleanup: TaskPhotoCleanupRunner = TaskPhotoCleanupRunner(),
         taskPhotoVaultMoves: TaskPhotoVaultMoves = TaskPhotoVaultMoves(),
         taskPhotoCache: TaskPhotoCache = TaskPhotoOriginals.cache,
         now: @escaping @Sendable () -> Date = { Date() },
         inboundSave: @escaping @MainActor @Sendable (ModelContext) throws -> Void = { try $0.save() }) {
        self.inboundSave = inboundSave
        self.calDAVClient = calDAVClient
        self.taskPhotoSync = taskPhotoSync
        self.taskPhotoCleanup = taskPhotoCleanup
        self.taskPhotoVaultMoves = taskPhotoVaultMoves
        self.taskPhotoCache = taskPhotoCache
        self.now = now
    }

    private(set) var lastOutcome = SyncOutcome()
    private var revision: UInt64 = 0
    private var progressObservers: [UUID: AsyncStream<SyncProgress?>.Continuation] = [:]
    private var changeObservers: [UUID: AsyncStream<SyncChange>.Continuation] = [:]
    private var importedIDs: Set<String> = []
    private var updatedIDs: Set<String> = []
    private var deletedIDs: Set<String> = []
    private var pendingScopeListIDs: Set<String> = []
    private var pendingScopeAccountIDs: Set<String> = []
    private var credentialGate = AuthFailureGate()
    private let serverDeferrals = ServerDeferrals()
    private var pendingSweepFailure: (any Error)?

    private struct OtherAccountSyncFailure: Error {
        let underlying: any Error
    }

    /// URLSession records a wait on its delegate queue before body handling can fail.
    private final class ServerDeferrals: @unchecked Sendable {
        private let lock = NSLock()
        private var waits: [String: RetryDeferredError] = [:]

        func retain(_ deferral: RetryDeferredError, for accountID: String) {
            lock.withLock {
                if let existing = waits[accountID], existing.deadline > deferral.deadline { return }
                waits[accountID] = deferral
            }
        }

        func check(accountID: String, now: Date) throws {
            try lock.withLock {
                guard let deferral = waits[accountID] else { return }
                if deferral.deadline > now { throw deferral }
                waits.removeValue(forKey: accountID)
            }
        }
    }

    private func captureServerDeferrals<Value>(accountID: String,
        _ operation: () async throws -> Value) async rethrows -> Value {
        let admission = ServerRetryAdmission(accountID: accountID,
            checkDeadline: { [serverDeferrals, now] in try serverDeferrals.check(accountID: $0, now: now()) },
            recordDeadline: { [serverDeferrals] in serverDeferrals.retain($1, for: $0) })
        return try await ServerRetryAdmission.$current.withValue(admission) {
            try await operation()
        }
    }

    private func checkServerAdmission(accountID: String) throws {
        try serverDeferrals.check(accountID: accountID, now: now())
    }

    func changes() -> AsyncStream<SyncChange> {
        let id = UUID()
        return AsyncStream { continuation in
            changeObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    func progressUpdates() -> AsyncStream<SyncProgress?> {
        let id = UUID()
        return AsyncStream { continuation in
            progressObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeProgressObserver(id) } }
        }
    }
    private func removeProgressObserver(_ id: UUID) { progressObservers.removeValue(forKey: id) }
    private func reportProgress(_ value: SyncProgress) {
        for observer in progressObservers.values { observer.yield(value) }
    }

    private func removeObserver(_ id: UUID) { changeObservers.removeValue(forKey: id) }

    private func beginOutcome() {
        lastOutcome = SyncOutcome()
        importedIDs.removeAll(); updatedIDs.removeAll(); deletedIDs.removeAll()
        pendingScopeListIDs.removeAll(); pendingScopeAccountIDs.removeAll()
    }

    /// Capture IDs before saving; publish only after the store accepts the transaction.
    private func saveAndPublish(_ context: ModelContext) throws {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        guard context.hasChanges else { return }
        let inserts = context.insertedModelsArray.compactMap { $0 as? TaskItem }
        let updates = context.changedModelsArray.compactMap { $0 as? TaskItem }
        let deletions = context.deletedModelsArray.compactMap { $0 as? TaskItem }
        let lists = (context.insertedModelsArray + context.deletedModelsArray)
            .compactMap { $0 as? TaskList }
        let insertedIDs = Set(inserts.map(\.id))
        let changedIDs = Set(updates.map(\.id))
        let changed = insertedIDs.union(changedIDs)
        let removed = Set(deletions.map(\.id))
        let tasks = inserts + updates + deletions
        var listIDs = Set(tasks.compactMap { $0.taskList?.id })
        listIDs.formUnion(tasks.compactMap(\.pendingMoveFromListID))
        listIDs.formUnion(lists.map(\.id))
        listIDs.formUnion(pendingScopeListIDs)
        var accountIDs = Set(tasks.compactMap { $0.taskList?.account?.id })
        accountIDs.formUnion(lists.compactMap { $0.account?.id })
        accountIDs.formUnion(pendingScopeAccountIDs)
        for sourceID in tasks.compactMap(\.pendingMoveFromListID) {
            let predicate = #Predicate<TaskList> { $0.id == sourceID }
            if let source = try context.fetch(FetchDescriptor(predicate: predicate)).first,
               let accountID = source.account?.id { accountIDs.insert(accountID) }
        }
        let interval = PerformanceTrace.begin("ImportSave", count: tasks.count)
        defer { PerformanceTrace.end("ImportSave", interval) }
        try CalendarMirrorState.enqueueTaskChanges(in: context)
        ReminderSchedulingJournal.enqueueTaskChanges(in: context)
        try context.save()
        CalendarMirrorState.publishCommit(in: context.container,
                                          includesTaskChanges: !changed.isEmpty || !removed.isEmpty || !lists.isEmpty)
        guard !changed.isEmpty || !removed.isEmpty || !lists.isEmpty else { return }
        pendingScopeListIDs.removeAll(); pendingScopeAccountIDs.removeAll()
        importedIDs.formUnion(insertedIDs)
        updatedIDs.formUnion(changedIDs); updatedIDs.subtract(importedIDs)
        deletedIDs.formUnion(removed)
        lastOutcome.importedCount = importedIDs.count
        lastOutcome.updatedCount = updatedIDs.count
        lastOutcome.deletedCount = deletedIDs.count
        lastOutcome.changedListIDs.formUnion(listIDs)
        pendingInboundRefresh = true
        revision &+= 1
        let event = SyncChange(revision: revision, accountIDs: accountIDs, listIDs: listIDs,
            changedIDs: changed, deletedIDs: removed, kind: tasks.isEmpty ? .lists : .tasks)
        for observer in changeObservers.values { observer.yield(event) }
    }

    /// A bounded main-actor acknowledgement transaction returns only committed values.
    private func publishExternalChange(_ change: SyncChange, inserted: Set<String> = []) {
        importedIDs.formUnion(inserted)
        lastOutcome.importedCount = importedIDs.count
        updatedIDs.formUnion(change.changedIDs); updatedIDs.subtract(importedIDs)
        deletedIDs.formUnion(change.deletedIDs)
        lastOutcome.updatedCount = updatedIDs.count; lastOutcome.deletedCount = deletedIDs.count
        lastOutcome.changedListIDs.formUnion(change.listIDs)
        pendingInboundRefresh = true
        revision &+= 1
        let event = SyncChange(revision: revision, accountIDs: change.accountIDs, listIDs: change.listIDs,
            changedIDs: change.changedIDs, deletedIDs: change.deletedIDs, kind: change.kind)
        for observer in changeObservers.values { observer.yield(event) }
    }

    private func recordOperationFailure(_ error: Error) throws {
        if Task.isCancelled || error is CancellationError { throw CancellationError() }
        if error is RetryDeferredError || error is BackgroundBudgetExhausted { throw error }
        if error is AccountCredentialDeferral {
            lastOutcome.status = .partial
            return
        }
        let underlying = (error as? OtherAccountSyncFailure)?.underlying ?? error
        if let failure = SyncFailure.from(underlying) { lastOutcome.failures.append(failure) }
        lastOutcome.status = .partial
        if let dav = error as? CalDAVError {
            switch dav {
            case .unauthorized, .rateLimited: throw error
            default: break
            }
        }
    }

    /// A run's registered models can outlive account deletion during an await.
    /// List operations also pin the account settings used when discovery began.
    private func requireLiveAccount(_ accountID: String, container: ModelContainer,
                                    matching scope: ListAccountScope? = nil) throws {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        let context = ModelContext(container)
        let predicate = #Predicate<ServerAccount> { $0.id == accountID }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let scope {
            guard let account = try context.fetch(descriptor).first, scope.matches(account) else {
                throw CancellationError()
            }
        } else if try context.fetchCount(descriptor) != 1 {
            throw CancellationError()
        }
    }

    func performFullSyncOutcome(accountID: String, serverBaseURL: String,
        credentials: CalDAVClient.Credentials, modelContainer: ModelContainer,
        syncWindowMonths: Int = 0, reconcileNotifications: Bool = true) async -> SyncOutcome {
        guard !isRunning else { return SyncOutcome(status: .alreadyRunning) }
        do {
            try await performFullSync(accountID: accountID, serverBaseURL: serverBaseURL,
                credentials: credentials, modelContainer: modelContainer, syncWindowMonths: syncWindowMonths, reconcileNotifications: reconcileNotifications)
        } catch { /* The run records its explicit outcome before throwing. */ }
        return lastOutcome
    }

    func performBackgroundSyncOutcome(accountID: String, serverBaseURL: String,
        credentials: CalDAVClient.Credentials, modelContainer: ModelContainer,
        syncWindowMonths: Int = 0, reconcileNotifications: Bool = true, runBudget: BackgroundRunBudget? = nil) async -> SyncOutcome {
        guard !isRunning else { return SyncOutcome(status: .alreadyRunning) }
        do {
            try await performBackgroundSync(accountID: accountID, serverBaseURL: serverBaseURL,
                credentials: credentials, modelContainer: modelContainer, syncWindowMonths: syncWindowMonths, reconcileNotifications: reconcileNotifications, runBudget: runBudget)
        } catch { }
        return lastOutcome
    }

    // MARK: - Full Sync

    /// Performs a full bidirectional sync for the given account.
    ///
    /// Creates a **background** `ModelContext` so that heavy SwiftData work
    /// (fetching, iterating, saving tasks) does NOT block the main thread.
    /// This prevents 0x8BADF00D watchdog kills when the user backgrounds
    /// the app during an active sync.
    ///
    /// - Parameters:
    ///   - accountID: The `ServerAccount.id` to sync.
    ///   - serverBaseURL: The server's base URL.
    ///   - credentials: The CalDAV credentials.
    ///   - modelContainer: The shared `ModelContainer` (a background context is created internally).
    /// Returns `true` if the inbound pull created or updated any local task, so
    /// the caller can refresh the UI's `@Query`-backed lists (which do not
    /// observe the background context's writes).
    @discardableResult
    func performFullSync(
        accountID: String,
        serverBaseURL: String,
        credentials: CalDAVClient.Credentials,
        modelContainer: ModelContainer,
        syncWindowMonths: Int = 0,
        reconcileNotifications: Bool = true
    ) async throws -> Bool {
        guard !isRunning else {
            logger.info("Sync already in progress, skipping full sync")
            return false
        }
        isRunning = true
        beginOutcome()
        defer { isRunning = false; for observer in progressObservers.values { observer.yield(nil) } }
        return try await captureServerDeferrals(accountID: accountID) {
            try await performFullSyncRun(accountID: accountID, serverBaseURL: serverBaseURL,
                credentials: credentials, modelContainer: modelContainer,
                syncWindowMonths: syncWindowMonths, reconcileNotifications: reconcileNotifications)
        }
    }

    private func performFullSyncRun(accountID: String, serverBaseURL: String,
        credentials: CalDAVClient.Credentials, modelContainer: ModelContainer,
        syncWindowMonths: Int, reconcileNotifications: Bool) async throws -> Bool {
        lastMovePermissionDenied = false

        setState(.syncing)
        reportProgress(.init(accountID: accountID, listID: nil, stage: .discovering, completed: 0, total: nil))

        // Create a dedicated background context for all SwiftData work.
        // This is the fix for the 0x8BADF00D watchdog crash: heavy task
        // iteration no longer blocks the main thread.
        var bgContext = ModelContext(modelContainer)

        defer {
            // Keep SQL to direct fields; older runtimes cannot lower two optional joins.
            if let count = try? BackgroundRunBudget.protectingCurrent({
                let pending = #Predicate<TaskItem> { $0.isDirty || $0.isDeletedLocally }
                let rows = try bgContext.fetch(FetchDescriptor(predicate: pending))
                PerformanceTrace.record(.pendingOutbound, rows: rows.count)
                return rows.filter { $0.taskList?.account?.id == accountID }.count
            }) { lastOutcome.pendingOutboundCount = count }
        }
        let targetID = accountID
        let accountPredicate = #Predicate<ServerAccount> { $0.id == targetID }
        var accountDescriptor = FetchDescriptor<ServerAccount>(
            predicate: accountPredicate
        )
        accountDescriptor.fetchLimit = 1
        guard var account = try bgContext.fetch(accountDescriptor).first else {
            setState(.idle)
            return false
        }

        var didImportInbound = false
        let accountScope = ListAccountScope(account)

        let authScope = AuthFailureGate.Scope(accountID: accountID, baseURL: serverBaseURL,
            username: credentials.username, password: credentials.password)
        await calDAVClient.setRunDeadline(now().addingTimeInterval(900))
        do {
            guard accountScope.matchesRequest(baseURL: serverBaseURL, username: credentials.username) else {
                throw CancellationError()
            }
            try checkServerAdmission(accountID: accountID)
            if credentialGate.shouldSkip(authScope) {
                throw CalDAVError.unauthorized
            }
            // Discover first, then push local lists and rediscover so newly created lists
            // participate in this run. Validate identities before any reconciliation.
            let address = try NextcloudDiscoverySeed.address(accountID: accountID, serverURL: serverBaseURL, in: bgContext)
            let discovery = CalDAVDiscovery(client: calDAVClient, validateAccount: {
                try await self.requireLiveAccount(accountID, container: modelContainer, matching: accountScope)
            })
            let initial = try await discovery.discover(address: address, credentials: credentials)
            try requireLiveAccount(accountID, container: modelContainer, matching: accountScope)
            let beforeWrites = ModelContext(modelContainer)
            guard let writeAccount = try beforeWrites.fetch(accountDescriptor).first,
                  accountScope.matches(writeAccount) else { throw CancellationError() }
            _ = try CalDAVDiscovery.preservingStorageIdentities(initial.calendars,
                existingHrefs: writeAccount.taskLists.map(\.serverURL), baseURL: serverBaseURL)
            let pendingCreationIDs = writeAccount.taskLists.filter { $0.serverURL.isEmpty }.map(\.id)
            let deferredMetadata = try await pushNewLists(pendingCreationIDs, accountScope: accountScope,
                baseURL: serverBaseURL, discovery: initial, credentials: credentials, container: modelContainer)
            let metadataContext = ModelContext(modelContainer)
            guard let metadataAccount = try metadataContext.fetch(accountDescriptor).first,
                  accountScope.matches(metadataAccount) else { throw CancellationError() }
            let editedListIDs = metadataAccount.taskLists.filter {
                !$0.serverURL.isEmpty && $0.isMetadataDirty && !deferredMetadata.contains($0.id)
            }.map(\.id)
            try await pushListMetadata(editedListIDs, accountScope: accountScope, baseURL: serverBaseURL,
                credentials: credentials, container: modelContainer)
            try requireLiveAccount(accountID, container: modelContainer, matching: accountScope)
            let refreshed: CalDAVDiscoveryResult
            if !pendingCreationIDs.isEmpty || !editedListIDs.isEmpty {
                refreshed = try await discovery.refreshCalendars(homeURL: initial.calendarHomeURL,
                    allowedOrigin: address.baseURL, credentials: credentials, principalURL: initial.principalURL)
            } else {
                refreshed = initial
            }
            try requireLiveAccount(accountID, container: modelContainer, matching: accountScope)
            bgContext = ModelContext(modelContainer)
            guard let refreshedAccount = try bgContext.fetch(accountDescriptor).first,
                  accountScope.matches(refreshedAccount) else { throw CancellationError() }
            account = refreshedAccount
            let discovered = try CalDAVDiscovery.preservingStorageIdentities(refreshed.calendars,
                existingHrefs: account.taskLists.map(\.serverURL), baseURL: serverBaseURL)
            let held = try heldCreationHrefs(in: discovered.live, homeURL: refreshed.calendarHomeURL, account: account)
            try requireLiveAccount(accountID, container: modelContainer, matching: accountScope)
            lastTrashedLists = discovered.trashed.map(TrashedList.init)

            // Step 3: Sync each calendar. `.live` only — a collection the server has thrown
            // away must not become a TaskList, or deleting and recreating a calendar leaves the
            // user with one row per corpse, all bearing the same name.
            for remoteCal in discovered.live where !held.contains(remoteCal.href) {
                do {
                    if try await syncCalendar(remoteCal: remoteCal, account: account, accountScope: accountScope,
                        baseURL: serverBaseURL, credentials: credentials, modelContext: bgContext,
                        syncWindowMonths: syncWindowMonths) { didImportInbound = true }
                } catch {
                    guard Self.isDefinitiveCollectionDenial(error) else { throw error }
                    try recordOperationFailure(error)
                }
            }
            try requireLiveAccount(accountID, container: modelContainer, matching: accountScope)
            try await probeMissingPhotoLists(accountID: accountID,
                livePaths: Set(discovered.live.map(\.href)), baseURL: serverBaseURL,
                credentials: credentials, container: modelContainer)
            try requireLiveAccount(accountID, container: modelContainer, matching: accountScope)

            // Clean up any duplicate TaskItems that accumulated from prior syncs.
            //
            // Only after an inbound pull, and only over this account's own collections. A
            // duplicate arrives with a pull and carries the UID of the collection it came
            // from, so a sync that imported nothing has nothing to sweep — and syncing one
            // account never had cause to walk every other account's tasks. Unscoped, this
            // fetched every non-deleted task on the device on every sync, including the
            // no-op ones a foreground return or the periodic timer produces.
            if didImportInbound {
                var removed = 0
                for list in account.taskLists {
                    removed += try TaskListHelpers.cleanupDuplicateUIDs(
                        in: bgContext,
                        listID: list.id
                    )
                }
                if removed > 0 {
                    logger.warning("cleanupDuplicateUIDs removed \(removed) duplicate(s) — sync gate may have a gap")
                }
            }

            // Vault moves have no destination PUT to trigger catch-up. Capture their
            // source data before any source DELETE can make that data unrecoverable.
            let legacyMoves = PendingMoveSweep.candidates(
                sourceListIDs: Set(account.taskLists.map(\.id)), in: bgContext, requiringReady: false)
                .compactMap { task -> (String, String, String)? in
                    guard let list = task.taskList, let accountID = list.account?.id else { return nil }
                    return (task.id, list.id, accountID)
                }
            var failedLegacyMoves = Set<String>()
            for (taskID, listID, destinationAccountID) in legacyMoves {
                do {
                    try await catchUpLegacyTask(taskID: taskID, expectedListID: listID,
                        expectedAccountID: destinationAccountID, runAccountID: accountID, baseURL: serverBaseURL,
                        credentials: credentials, container: modelContainer)
                } catch {
                    failedLegacyMoves.insert(taskID)
                    try recordOperationFailure(error)
                }
            }

            // Step 4: Remove the copies moved tasks left in this account's lists. After
            // every push, so a moved task is never absent from the server. Runs on every
            // sync, not only after an inbound pull: a move is an outbound change.
            do {
                let changed = try await taskPhotoVaultMoves.prepare(accountID: accountID,
                    access: PhotoServerAccess(baseURL: serverBaseURL, username: credentials.username,
                        password: credentials.password), container: modelContainer)
                if !changed.isEmpty {
                    let scopes = try await MainActor.run { () throws -> (Set<String>, Set<String>) in
                        let context = ModelContext(modelContainer)
                        var listIDs = Set<String>()
                        var accountIDs: Set<String> = [accountID]
                        for id in changed {
                            guard let task = try context.fetch(FetchDescriptor<TaskItem>(
                                predicate: #Predicate { $0.id == id })).first else { continue }
                            if let list = task.taskList {
                                listIDs.insert(list.id)
                                if let account = list.account { accountIDs.insert(account.id) }
                            }
                            if let source = task.pendingMoveFromListID { listIDs.insert(source) }
                        }
                        return (listIDs, accountIDs)
                    }
                    publishExternalChange(SyncChange(revision: 0, accountIDs: scopes.1,
                        listIDs: scopes.0, changedIDs: changed, deletedIDs: [], kind: .tasks))
                }
            } catch { try recordOperationFailure(error) }

            try requireLiveAccount(accountID, container: modelContainer)
            do { try PendingMoveSweep.clearOrphans(in: bgContext) }
            catch { try recordOperationFailure(error) }
            let movedOut = PendingMoveSweep.candidates(
                sourceListIDs: Set(account.taskLists.map(\.id)),
                in: bgContext
            ).filter { !failedLegacyMoves.contains($0.id) }
            if !movedOut.isEmpty {
                // Save source scopes before the sweep clears the move markers.
                pendingScopeListIDs.formUnion(movedOut.compactMap(\.pendingMoveFromListID))
                for sourceID in pendingScopeListIDs {
                    let predicate = #Predicate<TaskList> { $0.id == sourceID }
                    if let source = try bgContext.fetch(FetchDescriptor(predicate: predicate)).first,
                       let sourceAccount = source.account?.id { pendingScopeAccountIDs.insert(sourceAccount) }
                }
                let client = calDAVClient
                pendingSweepFailure = nil
                let denied = await PendingMoveSweep.run(movedOut, in: bgContext,
                    expectedSourceAccountID: accountID, onCommit: { self.publishExternalChange($0) },
                    onFailure: { error in
                        do { try self.recordOperationFailure(error) }
                        catch { self.pendingSweepFailure = error; throw error }
                    }) { snapshot in
                    guard snapshot.sourceProof.scope.serverBaseURL == serverBaseURL,
                          snapshot.sourceProof.scope.username == credentials.username,
                          snapshot.sourceProof.scope.accountID == accountID else { throw SyncResourceState.Hold.needsRevalidation }
                    let validateAttempt: @Sendable () async throws -> Void = {
                        try await SyncMoveAcknowledgement.validateDeletion(snapshot, container: modelContainer)
                    }
                    try await client.deleteTask(
                        baseURL: serverBaseURL,
                        taskPath: snapshot.sourceProof.href,
                        etag: snapshot.sourceProof.etag,
                        credentials: credentials,
                        validateAttempt: validateAttempt
                    )
                }
                if denied { lastMovePermissionDenied = true }
                if let pendingSweepFailure { throw pendingSweepFailure }
                try Task.checkCancellation()
            }

            // Cleanup scans are deferred until the runner finds mature queued originals.
            // Include every live collection, even collections outside the local sync window,
            // and the queued source collection before deciding an original is unreferenced.
            let client = calDAVClient
            let livePaths = Set(discovered.live.map(\.href))
            do {
                _ = try await taskPhotoCleanup.run(accountID: accountID,
                    access: PhotoServerAccess(baseURL: serverBaseURL, username: credentials.username,
                        password: credentials.password), container: modelContainer) { sourcePath in
                    var references = Set<String>()
                    for path in livePaths.union([sourcePath]).sorted() {
                        try Task.checkCancellation()
                        references.formUnion(try await TaskPhotoReferenceScanner.scan(client: client,
                            baseURL: serverBaseURL, calendarPath: path, credentials: credentials))
                    }
                    return references
                }
            } catch { try recordOperationFailure(error) }

            try await TaskPhotoAccessMaintenance.prune(container: modelContainer, cache: taskPhotoCache)

            // Update last sync time
            try requireLiveAccount(accountID, container: modelContainer)
            if lastOutcome.status == .completed { account.lastSyncDate = Date() }
            try saveAndPublish(bgContext)

            // Awaited, not fired and forgotten: the background caller reports its BGTask
            // complete as soon as this returns and iOS suspends the process immediately after,
            // so an unstructured Task here was a race against suspension.
            if reconcileNotifications { await ReminderScheduler.reconcileNow(modelContainer: modelContainer) }

            setState(.idle)

        } catch is CancellationError {
            lastOutcome.status = .cancelled
            setState(.idle)
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                lastOutcome.status = .cancelled
                setState(.idle)
                throw CancellationError()
            }
            if let dav = error as? CalDAVError, case .unauthorized = dav {
                credentialGate.recordFailure(authScope)
            }
            lastOutcome.status = .partial
            if let failure = SyncFailure.from(error), !lastOutcome.failures.contains(failure) {
                lastOutcome.failures.append(failure)
            }
            // Record internal error state and re-throw. The foreground caller
            // (`SyncScheduler`) translates this into a categorized, user-facing
            // `SyncFailure` banner — so we no longer raise a raw technical alert
            // here (that double-surfaced and showed unhelpful wording).
            setState(.error(error.localizedDescription))
            throw error
        }

        return didImportInbound
    }

    // MARK: - Background Sync

    /// Performs a pull-only sync suitable for background execution.
    ///
    /// Creates its own background `ModelContext` from the provided container
    /// for thread-safe SwiftData access. Does not touch UI state.
    ///
    /// Background sync is pull-only: it fetches remote changes and updates
    /// the local store, but does not push local dirty tasks to the server.
    /// This keeps execution fast and safe within the BGTask time budget.
    func performBackgroundSync(
        accountID: String,
        serverBaseURL: String,
        credentials: CalDAVClient.Credentials,
        modelContainer: ModelContainer,
        syncWindowMonths: Int = 0,
        reconcileNotifications: Bool = true,
        runBudget: BackgroundRunBudget? = nil
    ) async throws {
        guard !isRunning else {
            logger.info("Sync already in progress, skipping background sync")
            return
        }
        // Claim the engine before the first await, retaining ownership through cleanup.
        isRunning = true
        beginOutcome()
        defer { isRunning = false; for observer in progressObservers.values { observer.yield(nil) } }
        let budget = runBudget ?? BackgroundRunBudget.current ?? BackgroundRunBudget()
        await calDAVClient.setRunBudget(budget)
        do {
            try await BackgroundRunBudget.$current.withValue(budget) {
                try await BackgroundRunBudget.$phase.withValue(.remote) {
                    try BackgroundBudgetExhausted.checkAdmission(budget)
                    try await captureServerDeferrals(accountID: accountID) {
                        try await performBackgroundSyncRun(accountID: accountID, serverBaseURL: serverBaseURL,
                            credentials: credentials, modelContainer: modelContainer,
                            syncWindowMonths: syncWindowMonths, reconcileNotifications: reconcileNotifications,
                            runBudget: budget)
                    }
                }
            }
        } catch {
            await calDAVClient.clearRunBudget(runID: budget.runID)
            if error is BackgroundBudgetExhausted {
                lastOutcome.status = .partial
                setState(.idle)
            } else if error is CancellationError || Task.isCancelled {
                lastOutcome.status = .cancelled
                setState(.idle)
            }
            throw error
        }
        await calDAVClient.clearRunBudget(runID: budget.runID)
    }

    private func performBackgroundSyncRun(
        accountID: String,
        serverBaseURL: String,
        credentials: CalDAVClient.Credentials,
        modelContainer: ModelContainer,
        syncWindowMonths: Int,
        reconcileNotifications: Bool,
        runBudget: BackgroundRunBudget
    ) async throws {
        var bgContext = ModelContext(modelContainer)
        bgContext.autosaveEnabled = false

        defer {
            // Keep SQL to direct fields; older runtimes cannot lower two optional joins.
            if let count = try? BackgroundRunBudget.protectingCurrent({
                let pending = #Predicate<TaskItem> { $0.isDirty || $0.isDeletedLocally }
                let rows = try bgContext.fetch(FetchDescriptor(predicate: pending))
                PerformanceTrace.record(.pendingOutbound, rows: rows.count)
                return rows.filter { $0.taskList?.account?.id == accountID }.count
            }) { lastOutcome.pendingOutboundCount = count }
        }
        let targetID = accountID
        let accountPredicate2 = #Predicate<ServerAccount> { $0.id == targetID }
        var accountDescriptor = FetchDescriptor<ServerAccount>(
            predicate: accountPredicate2
        )
        accountDescriptor.fetchLimit = 1
        let accountScope = try BackgroundRunBudget.protectingCurrent {
            guard let account = try bgContext.fetch(accountDescriptor).first else { throw CancellationError() }
            return ListAccountScope(account)
        }

        let baseURL = serverBaseURL

        setState(.syncing)
        reportProgress(.init(accountID: accountID, listID: nil, stage: .discovering, completed: 0, total: nil))

        let authScope = AuthFailureGate.Scope(accountID: accountID, baseURL: serverBaseURL,
            username: credentials.username, password: credentials.password)
        do {
            guard accountScope.matchesRequest(baseURL: baseURL, username: credentials.username) else {
                throw CancellationError()
            }
            try checkServerAdmission(accountID: accountID)
            if credentialGate.shouldSkip(authScope) {
                throw CalDAVError.unauthorized
            }
            let address = try NextcloudDiscoverySeed.address(accountID: accountID, serverURL: baseURL, in: bgContext)
            let discovery = CalDAVDiscovery(client: calDAVClient, validateAccount: {
                try await self.requireLiveAccount(accountID, container: modelContainer, matching: accountScope)
            })
            let result = try await discovery.discover(address: address, credentials: credentials)
            try requireLiveAccount(accountID, container: modelContainer, matching: accountScope)
            bgContext = ModelContext(modelContainer)
            bgContext.autosaveEnabled = false
            guard let account = try BackgroundRunBudget.protectingCurrent({ try bgContext.fetch(accountDescriptor).first }),
                  accountScope.matches(account) else {
                throw CancellationError()
            }
            let discovered = try CalDAVDiscovery.preservingStorageIdentities(result.calendars,
                existingHrefs: account.taskLists.map(\.serverURL), baseURL: baseURL)
            let held = try heldCreationHrefs(in: discovered.live, homeURL: result.calendarHomeURL, account: account)
            try requireLiveAccount(accountID, container: modelContainer, matching: accountScope)
            lastTrashedLists = discovered.trashed.map(TrashedList.init)

            // Accumulated across every calendar, then left on `pendingInboundRefresh` for the
            // next foreground sync to turn into a `dataRefreshToken` bump. `syncCalendar` keeps
            // the same tally and returns it; this path has no caller that could read one.
            var inboundChanged = false

            // Collection hrefs are stable discovery IDs within this account. Advisory
            // attempts never replace the saved import receipts or committed page token.
            let cursorScope = "lists:" + accountID
            let calendarsByPath = Dictionary(discovered.live.map { ($0.href, $0) },
                uniquingKeysWith: { first, _ in first })
            let orderedPaths = try BackgroundRunBudget.protectingCurrent {
                let cursor = try BackgroundSyncCursor.load(scope: cursorScope, in: bgContext)
                return BackgroundSyncCursor.rotated(discovered.live.map(\.href), after: cursor)
            }
            // Step 2: Pull each calendar. `.live` only — see the note in `performFullSync`.
            for path in orderedPaths {
                guard !held.contains(path), let remoteCal = calendarsByPath[path] else { continue }
                try requireLiveAccount(accountID, container: modelContainer, matching: accountScope)
                try BackgroundSyncCursor.recordAttempt(id: path, scope: cursorScope, in: bgContext)

                let taskList = try await findOrCreateTaskList(for: remoteCal, account: account,
                    accountScope: accountScope, modelContext: bgContext)
                let listID = taskList.id
                let photoScope = TaskPhotoOwnership.Scope(accountID: accountID, listID: listID,
                    collectionPath: remoteCal.href, serverBaseURL: baseURL, username: credentials.username)
                try saveAndPublish(bgContext)
                if try await restorePhotoAccess(scope: photoScope, container: modelContainer) {
                    inboundChanged = true
                }
                try requireLiveAccount(accountID, container: modelContainer, matching: accountScope)
                let repair = Self.categoriesCatchUpPending(listID: listID)
                do {
                    let pull = try await pullCalendarCheckingPhotoAccess(remoteCal: remoteCal,
                        scope: photoScope, credentials: credentials,
                        container: modelContainer, months: syncWindowMonths, repairCategories: repair)
                    inboundChanged = inboundChanged || pull.changed
                } catch {
                    guard Self.isDefinitiveCollectionDenial(error) else { throw error }
                    try recordOperationFailure(error)
                    continue
                }
                try requireLiveAccount(accountID, container: modelContainer, matching: accountScope)
                if repair { Self.markCategoriesCaughtUp(listID: listID) }

            }

            // Broad Files provisioning/status work, missing-list probes and global
            // cache pruning belong to foreground maintenance. Actual task pulls still
            // import photo metadata and confirm definitive access denial above.

            // Update last sync time
            try requireLiveAccount(accountID, container: modelContainer, matching: accountScope)
            try BackgroundRunBudget.protectingCurrent {
                if lastOutcome.status == .completed { account.lastSyncDate = Date() }
                try saveAndPublish(bgContext)
            }

            // Hand the signal to the foreground. Never cleared here on a `false`: a second
            // background pull that happens to find nothing must not wipe out an earlier
            // one's unconsumed refresh.
            if inboundChanged { pendingInboundRefresh = true }

            // Reschedule reminders and refresh the badge for freshly-pulled tasks. Without
            // this, reminders and overdue badges for tasks synced in the background are never
            // scheduled until the app is foregrounded. Awaited — see the full-sync path.
            if reconcileNotifications { await ReminderScheduler.reconcileNow(modelContainer: modelContainer) }

            setState(.idle)

        } catch let error as BackgroundBudgetExhausted {
            lastOutcome.status = .partial
            setState(.idle)
            throw error
        } catch is CancellationError {
            lastOutcome.status = .cancelled
            setState(.idle)
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                lastOutcome.status = .cancelled
                setState(.idle)
                throw CancellationError()
            }
            if let dav = error as? CalDAVError, case .unauthorized = dav {
                credentialGate.recordFailure(authScope)
            }
            lastOutcome.status = .partial
            if let failure = SyncFailure.from(error), !lastOutcome.failures.contains(failure) {
                lastOutcome.failures.append(failure)
            }
            setState(.error(error.localizedDescription))
            throw error
        }
    }

    /// Builds the list-scoped UID lookup for direct importer tests.
    /// Every task in the list is included for matching against the server.
    ///
    /// **Deliberately includes tasks awaiting deletion.** They used to be
    /// filtered out, which made a task the user had just deleted invisible to
    /// this map — the server's copy then matched nothing, was inserted as a new
    /// row, and the pending DELETE removed the *original*. The task stayed in
    /// the list forever and was gone from the server.
    ///
    /// Being in the map is not permission to apply anything: the importer
    /// refuses an `isDeletedLocally` task outright. Recognising it lets the
    /// importer refuse it.
    ///
    /// Fetched explicitly rather than through `taskList.tasks`, because the
    /// relationship can be stale or unfaulted on a background context.
    nonisolated private func existingTaskMap(
        for taskList: TaskList,
        modelContext: ModelContext
    ) -> [String: TaskItem] {
        let listID = taskList.id
        let tasks = (try? modelContext.fetch(
            FetchDescriptor<TaskItem>(
                predicate: #Predicate<TaskItem> { $0.taskList?.id == listID }
            )
        )) ?? []
        var map: [String: TaskItem] = [:]
        for task in tasks {
            map[task.uid] = task
        }
        return map
    }

    /// UIDs of tasks moved *out of* `taskList` whose copy there has not been
    /// DELETEd yet (see `TaskMover`).
    ///
    /// The pull must not insert those copies: the row now belongs to another
    /// list, so `existingTaskMap` misses it and the stale copy would arrive as a
    /// second task. Deliberately not merged into that map — matching the moved
    /// task there sends it down the update path, which overwrites its fresh
    /// destination href with the stale one. And keyed on the pending move, never
    /// `isDirty`, which the destination push clears while the old copy is still up.
    nonisolated private func pendingMoveUIDs(
        from taskList: TaskList,
        modelContext: ModelContext
    ) -> Set<String> {
        let listID = taskList.id
        let tasks = (try? modelContext.fetch(
            FetchDescriptor<TaskItem>(
                predicate: #Predicate<TaskItem> { $0.pendingMoveFromListID == listID }
            )
        )) ?? []
        return Set(tasks.map(\.uid))
    }

    nonisolated private func applyRemoteTask(
        _ remoteTask: CalDAVClient.RemoteTask,
        taskList: TaskList,
        uidMap: inout [String: TaskItem],
        movedAway: Set<String>,
        modelContext: ModelContext
    ) throws -> Bool {
        let importer = try SyncImportStore(context: modelContext)
        return try importer.apply(try importer.parse(remoteTask), list: taskList, uidMap: &uidMap, movedAway: movedAway)
    }

    // MARK: - Calendar Sync

    /// Syncs a single remote calendar with its local TaskList counterpart.
    ///
    /// Returns `true` if the inbound pull created or updated any local task —
    /// the signal the UI uses to refresh its `@Query`-backed lists (which do not
    /// observe the background context's writes). Push-only work, skipped pulls,
    /// and no-op re-applies return `false`.
    @discardableResult
    private func syncCalendar(
        remoteCal: CalDAVClient.RemoteCalendar,
        account: ServerAccount,
        accountScope: ListAccountScope,
        baseURL: String,
        credentials: CalDAVClient.Credentials,
        modelContext: ModelContext,
        syncWindowMonths: Int = 0
    ) async throws -> Bool {
        // Find or create local TaskList
        let taskList = try await findOrCreateTaskList(
            for: remoteCal,
            account: account,
            accountScope: accountScope,
            modelContext: modelContext
        )

        let expectedListID = taskList.id
        let expectedAccountID = account.id
        let photoScope = TaskPhotoOwnership.Scope(accountID: expectedAccountID, listID: expectedListID,
            collectionPath: remoteCal.href, serverBaseURL: baseURL, username: credentials.username)
        try saveAndPublish(modelContext)
        let restoredPhotoAccess = try await restorePhotoAccess(scope: photoScope,
            container: modelContext.container)
        try requireLiveAccount(expectedAccountID, container: modelContext.container, matching: accountScope)

        let owesCategoriesCatchUp = Self.categoriesCatchUpPending(listID: expectedListID)
        let pull = try await pullCalendarCheckingPhotoAccess(remoteCal: remoteCal,
            scope: photoScope, credentials: credentials,
            container: modelContext.container, months: syncWindowMonths,
            repairCategories: owesCategoriesCatchUp)
        try requireLiveAccount(expectedAccountID, container: modelContext.container, matching: accountScope)

        let photosChanged = try await synchronizePhotos(listID: expectedListID,
            accountID: expectedAccountID, baseURL: baseURL, credentials: credentials,
            container: modelContext.container)
        try requireLiveAccount(expectedAccountID, container: modelContext.container)
        let inboundChanged = pull.changed || photosChanged || restoredPhotoAccess

        // Push local dirty tasks (with per-task error isolation)
        let dirtyTasks = findDirtyTasks(for: taskList, modelContext: modelContext)
        for localTask in dirtyTasks {
            try Task.checkCancellation()
            do {
                try await pushLocalTask(
                    localTask,
                    expectedListID: expectedListID, expectedAccountID: expectedAccountID,
                    calendarPath: remoteCal.href,
                    baseURL: baseURL,
                    credentials: credentials,
                    modelContext: modelContext
                )
            } catch {
                try requireLiveAccount(expectedAccountID, container: modelContext.container)
                try recordOperationFailure(error)
                logger.error("Failed to push task '\(localTask.title)': \(error.localizedDescription)")
            }
            try requireLiveAccount(expectedAccountID, container: modelContext.container)
        }

        // Push local deletions (with per-task error isolation)
        let deletedTasks = findDeletedTasks(for: taskList, modelContext: modelContext)
        for deletedTask in deletedTasks {
            try Task.checkCancellation()
            do {
                try await pushDeletion(
                    deletedTask.id,
                    expectedListID: expectedListID, expectedAccountID: expectedAccountID,
                    baseURL: baseURL,
                    credentials: credentials,
                    container: modelContext.container
                )
            } catch {
                try requireLiveAccount(expectedAccountID, container: modelContext.container)
                try recordOperationFailure(error)
                logger.error("Failed to push deletion '\(deletedTask.title)': \(error.localizedDescription)")
            }
            try requireLiveAccount(expectedAccountID, container: modelContext.container)
        }

        if pull.didPull {
            let metadataContext = ModelContext(modelContext.container)
            metadataContext.autosaveEnabled = false
            let listPredicate = #Predicate<TaskList> { $0.id == expectedListID }
            if let currentList = try metadataContext.fetch(FetchDescriptor(predicate: listPredicate)).first {
                currentList.lastFullPullDate = Date()
                currentList.syncCTag = (!dirtyTasks.isEmpty || !deletedTasks.isEmpty) ? nil : remoteCal.ctag
                try metadataContext.save()
            }
        }
        // Recorded only once what it added is saved; a pass that threw is still owed.
        if owesCategoriesCatchUp {
            Self.markCategoriesCaughtUp(listID: taskList.id)
        }
        return inboundChanged
    }

    private struct CalendarPullResult {
        let changed: Bool
        let didPull: Bool
    }

    /// Shared bounded bootstrap/delta path. No full-body array survives between batches.
    private func pullCalendar(remoteCal: CalDAVClient.RemoteCalendar, resourceScope: TaskPhotoOwnership.Scope,
        credentials: CalDAVClient.Credentials, container: ModelContainer,
        months: Int, repairCategories: Bool) async throws -> CalendarPullResult {
        let accountID = resourceScope.accountID
        let listID = resourceScope.listID
        let baseURL = resourceScope.serverBaseURL
        let scope = SyncCollectionPuller.Scope(accountID: accountID, listID: listID, historyScope: String(months))
        let key = SyncImportCheckpoint.identity(accountID: accountID, listID: listID,
            baseURL: baseURL, username: resourceScope.username, months: months)
        let (checkpoint, repair, classification, aliases) = try BackgroundRunBudget.protectingCurrent {
            let read = ModelContext(container)
            let list = try resourceScope.requireList(in: read)
            try SyncImportCheckpoint.pruneOtherScopes(accountID: accountID, listID: listID, keeping: key, container: container)
            let checkpoint = try SyncImportCheckpoint.read(id: key, scope: scope, in: read)
            let scan = try SyncResourceState.scanForClassification(list: list, in: read)
            if repairCategories && !scan.hasLocalTasks { Self.markCategoriesCaughtUp(listID: listID) }
            let classification = try Set(scan.needsClassification.map { try SyncResourceState.canonical($0, scope: resourceScope) })
            return (checkpoint, repairCategories && scan.hasLocalTasks, classification, scan.aliases)
        }
        let cache = ICalendarParser.FormatterCache()
        let writer = await SyncInboundBatchWriter(container: container, listID: listID, expectedAccountID: accountID,
            checkpointID: key, needsParentResolution: checkpoint?.hasCompletedBaseline != true,
            photoScope: resourceScope, save: inboundSave)
        let puller = SyncCollectionPuller(client: calDAVClient, now: now)
        let before = lastOutcome.importedCount + lastOutcome.updatedCount + lastOutcome.deletedCount
        let result = try await puller.pull(baseURL: baseURL, calendar: remoteCal, credentials: credentials,
            scope: scope, checkpoint: checkpoint,
            forceIntegrity: repair || !classification.isEmpty, forceBodies: repair,
            callbacks: .init(
                progress: { [self] stage, completed, total in
                    await self.reportProgress(.init(accountID: accountID, listID: listID, stage: stage, completed: completed, total: total))
                },
                manifestInventory: {
                    try Self.manifestInventory(id: key, scope: resourceScope, classification: classification, container: container)
                },
                deltaInventory: { hrefs in
                    try Self.deltaInventory(id: key, scope: resourceScope, hrefs: hrefs, aliases: aliases, container: container)
                },
                applyBodies: { [self] bodies in
                    try await self.applyPullBodies(bodies, writer: writer, months: months, repairCategories: repair, cache: cache)
                    try await self.markPullBodiesAccounted(bodies, id: key, scope: resourceScope, container: container)
                },
                deleteExplicit: { [self] hrefs in
                    try await writer.deleteExplicit(hrefs, onCommit: { await self.publishBatch($0) })
                    try await self.removePullReceipts(hrefs, id: key, scope: resourceScope, container: container)
                },
                reconcileCompleteManifest: { [self] manifest, accountedHrefs in
                    try await writer.resolveParents(onCommit: { await self.publishBatch($0) })
                    try await writer.reconcileManifest(manifest, onCommit: { await self.publishBatch($0) })
                    let present = Set(manifest.map(\.href))
                    try await self.removePullReceipts(Array(accountedHrefs.subtracting(present)), id: key, scope: resourceScope, container: container)
                },
                commitCheckpoint: { [self] checkpoint in
                    // Delta pages need parent wiring as well, before their token is durable.
                    try await writer.resolveParents(onCommit: { await self.publishBatch($0) })
                    try await self.commitPullCheckpoint(checkpoint, id: key, scope: resourceScope, container: container)
                }))
        // An unchanged CTag returns without a checkpoint callback. Durable
        // local parent work still needs to drain and announce its committed IDs.
        try await writer.resolveParents(onCommit: { await self.publishBatch($0) })
        return CalendarPullResult(
            changed: before != lastOutcome.importedCount + lastOutcome.updatedCount + lastOutcome.deletedCount,
            didPull: result.didPull)
    }

    private nonisolated static func manifestInventory(id: String, scope: TaskPhotoOwnership.Scope,
        classification: Set<String>, container: ModelContainer) throws -> SyncCollectionPuller.Inventory {
        try BackgroundRunBudget.protectingCurrent {
            let context = ModelContext(container)
            _ = try scope.requireList(in: context)
            let listID = scope.listID
            let tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.taskList?.id == listID }))
            PerformanceTrace.record(.matchingTaskInventory, rows: tasks.count)
            let accounted = try SyncImportCheckpoint.accountedETags(id: id, container: container)
            return try matchInventory(tasks: tasks, accounted: accounted, scope: scope, invalidated: classification)
        }
    }

    private nonisolated static func deltaInventory(id: String, scope: TaskPhotoOwnership.Scope,
        hrefs: [String], aliases: [String: Set<String>], container: ModelContainer) throws -> SyncCollectionPuller.Inventory {
        try BackgroundRunBudget.protectingCurrent {
            let context = ModelContext(container)
            _ = try scope.requireList(in: context)
            let listID = scope.listID
            let spellings = Array(Set(hrefs).union(hrefs.flatMap { aliases[$0] ?? [] }))
            var tasks: [TaskItem] = []
            for start in stride(from: 0, to: spellings.count, by: 100) {
                try Task.checkCancellation()
                let batch = spellings[start..<min(start + 100, spellings.count)].map(Optional.some)
                let rows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate {
                    $0.taskList?.id == listID && batch.contains($0.calendarURL)
                }))
                PerformanceTrace.record(.matchingTaskLookup, rows: rows.count, keys: batch.count)
                tasks.append(contentsOf: rows)
            }
            let accounted = try SyncImportCheckpoint.accountedETags(id: id, hrefs: hrefs, in: context)
            return try matchInventory(tasks: tasks, accounted: accounted, scope: scope, invalidated: [])
        }
    }

    private nonisolated static func matchInventory(tasks: [TaskItem], accounted: [String: String],
        scope: TaskPhotoOwnership.Scope, invalidated: Set<String>) throws -> SyncCollectionPuller.Inventory {
        var known = accounted
        var invalidated = invalidated
        for task in tasks {
            guard let href = task.remoteHref, !href.isEmpty else { continue }
            if let etag = task.etag {
                // Preserve raw positive baselines. A fetched body can normalize an alias
                // before the conservative manifest-absence reconciliation reads it.
                if !task.isDirty || known[href] == nil { known[href] = etag }
            } else {
                invalidated.insert(href)
                invalidated.insert(try SyncResourceState.canonical(href, scope: scope))
            }
        }
        for href in invalidated { known.removeValue(forKey: href) }
        return .init(knownETags: known, accountedETags: accounted, invalidatedHrefs: invalidated)
    }

    nonisolated static func inboundApplyChunks(_ resources: [ParsedRemoteTask]) -> [[ParsedRemoteTask]] {
        var result: [[ParsedRemoteTask]] = []
        var chunk: [ParsedRemoteTask] = []
        var categories = 0
        for resource in resources {
            let count = resource.todo?.categories?.count ?? 0
            if !chunk.isEmpty && (chunk.count == 100 || categories + count > 512) {
                result.append(chunk)
                chunk = []
                categories = 0
            }
            chunk.append(resource)
            categories += count
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }

    private func applyPullBodies(_ bodies: [CalDAVClient.RemoteTask], writer: SyncInboundBatchWriter,
                                 months: Int, repairCategories: Bool, cache: ICalendarParser.FormatterCache) async throws {
        try Task.checkCancellation()
        let parsed = try bodies.map { resource in
            try SyncBodyValidation.parse(resource, using: cache)
        }
        for chunk in Self.inboundApplyChunks(parsed) {
            try Task.checkCancellation()
            if let commit = try await writer.apply(chunk, months: months, repairCategories: repairCategories) {
                publishBatch(commit)
            }
            await Task.yield()
        }
    }

    private func markPullBodiesAccounted(_ resources: [CalDAVClient.RemoteTask], id: String,
        scope: TaskPhotoOwnership.Scope, container: ModelContainer) async throws {
        try Task.checkCancellation()
        try await MainActor.run {
            try BackgroundRunBudget.protectingCurrent {
                _ = try scope.requireList(in: ModelContext(container))
                try SyncImportCheckpoint.markAccounted(resources, id: id, container: container)
            }
        }
    }
    private func removePullReceipts(_ hrefs: [String], id: String,
        scope: TaskPhotoOwnership.Scope, container: ModelContainer) async throws {
        try Task.checkCancellation()
        for start in stride(from: 0, to: hrefs.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(hrefs[start..<min(start + 100, hrefs.count)])
            try await MainActor.run {
                try BackgroundRunBudget.protectingCurrent {
                    _ = try scope.requireList(in: ModelContext(container))
                    try SyncImportCheckpoint.removeAccounted(batch, id: id, container: container)
                }
            }
            await Task.yield()
        }
    }

    private func publishBatch(_ commit: SyncBatchCommit) {
        publishExternalChange(commit.change, inserted: commit.insertedIDs)
    }

    private func commitPullCheckpoint(_ checkpoint: SyncCollectionPuller.Checkpoint, id: String,
                                     scope: TaskPhotoOwnership.Scope, container: ModelContainer) async throws {
        try Task.checkCancellation()
        try await MainActor.run {
            try BackgroundRunBudget.protectingCurrent {
                _ = try scope.requireList(in: ModelContext(container))
                try SyncImportCheckpoint.commit(checkpoint, id: id, collectionPath: scope.collectionPath, container: container)
            }
        }
    }

    // MARK: - Pull (Remote → Local)

    /// Legacy per-resource test seam retained for importer behavior tests.
    /// Shipping pulls use the shared bounded writer and do not call this facade.
    /// It stays nonisolated so tests can synchronously pass their context-owned UID map.
    @discardableResult
    nonisolated private func processRemoteTask(
        _ remoteTask: CalDAVClient.RemoteTask,
        taskList: TaskList,
        uidMap: inout [String: TaskItem],
        movedAway: Set<String>,
        modelContext: ModelContext
    ) throws -> Bool {
        try applyRemoteTask(remoteTask, taskList: taskList, uidMap: &uidMap,
            movedAway: movedAway, modelContext: modelContext)
    }

    /// The UID of every fetched VTODO, or nil if any one of them could not be
    /// read. Retained for direct completeness tests of the legacy UID-set helper;
    /// shipping pulls use the complete manifest writer.
    ///
    /// All-or-nothing on purpose. tasksDeletedOnServer treats absence from this
    /// set as a server deletion, so an unreadable resource abandons reconciliation.
    /// Unfold first: RFC 5545 folds lines past 75 octets and Nextcloud emits folded
    /// UIDs for long values, so reading raw lines would silently truncate them.
    nonisolated static func remoteUIDSet(_ tasks: [CalDAVClient.RemoteTask]) -> Set<String>? {
        var uids: Set<String> = []
        for task in tasks {
            let lines = ICalendarParser.unfoldLines(task.icsData)
                .components(separatedBy: .newlines)
            guard let line = lines.first(where: { $0.hasPrefix("UID:") || $0.hasPrefix("UID;") }),
                  let separator = line.firstIndex(of: ":")
            else { return nil }
            let uid = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty else { return nil }
            uids.insert(uid)
        }
        return uids
    }

    /// The local tasks absent from a complete UID set, deepest first.
    ///
    /// This legacy helper is kept for focused behavior tests. Production pulls
    /// reconcile complete manifests through SyncInboundBatchWriter.
    nonisolated static func tasksDeletedOnServer(local: [TaskItem],
                                                 remoteUIDs: Set<String>, protectedUIDs: Set<String> = [], allowEmpty: Bool = false) -> [TaskItem] {
        guard allowEmpty || !remoteUIDs.isEmpty else { return [] }

        let survivingUIDs = Set(local.lazy
            .filter { remoteUIDs.contains($0.uid) || protectedUIDs.contains($0.uid)
                || $0.isDirty || $0.isDeletedLocally || ($0.isLocalOnly && $0.etag == nil) }
            .map(\.uid))

        func hasLiveDescendant(_ task: TaskItem) -> Bool {
            var frontier = task.subtasks
            var seen: Set<String> = [task.uid]
            while let next = frontier.popLast() {
                guard seen.insert(next.uid).inserted else { continue }
                if survivingUIDs.contains(next.uid) { return true }
                frontier.append(contentsOf: next.subtasks)
            }
            return false
        }

        return local
            .filter { task in
                guard !remoteUIDs.contains(task.uid) else { return false }
                guard let href = task.remoteHref, !href.isEmpty else { return false }
                guard !(task.isLocalOnly && task.etag == nil), !task.isDirty, !task.isDeletedLocally, !protectedUIDs.contains(task.uid) else { return false }
                return !hasLiveDescendant(task)
            }
            .sorted { TaskListHelpers.depth(of: $0) > TaskListHelpers.depth(of: $1) }
    }

    /// Whether this task's start date is one the app deliberately withheld from
    /// the server.
    ///
    /// `ICalendarSerializer` omits `DTSTART` when it is not before `DUE`,
    /// because Sabre rejects the pair. A VTODO coming back without a `DTSTART`
    /// therefore has two possible meanings, and they are opposites: the user
    /// cleared the start date, or the app never sent it. Read as a deletion,
    /// the second one erases a field the user set, in the app that chose not to
    /// upload it.
    ///
    /// Must be asked **before** the inbound due date is applied — the question
    /// is what the last push would have done, and that used the values the task
    /// holds now.
    nonisolated static func startWasWithheldFromServer(_ task: TaskItem) -> Bool {
        ICalendarSerializer.omitsStart(startDate: task.startDate,
                                       dueDate: task.dueDate,
                                       isDueDateOnly: task.isDueDateOnly,
                                       isStartDateOnly: task.isStartDateOnly)
    }

    /// The tag `name` means among `known`, or a new one — inserted, and added to
    /// `known` so a later name in the same pass finds it; see ``Tag/matching(_:in:)``.
    nonisolated private func resolveTag(
        named name: String,
        known: inout [Tag],
        modelContext: ModelContext
    ) -> Tag {
        if let existing = Tag.matching(name, in: known) {
            return existing
        }
        let created = Tag(name: name)
        modelContext.insert(created)
        known.append(created)
        return created
    }

    /// Adds the server's `CATEGORIES` to the tasks a device already holds.
    /// Returns whether it added any, so the caller can refresh the UI.
    ///
    /// An existing task can already have its current ETag from a pull made before
    /// categories were imported. The additive pass reads categories even then,
    /// so the next upload does not overwrite them with the older local set.
    ///
    /// - **Adds, never removes.** A tag added here before tag edits marked a task
    ///   dirty never reached the server; adopting the server's set would delete it.
    /// - **Reaches dirty tasks.** The gate refuses them, and their upload is the
    ///   very write that would erase the categories. They stay dirty, so the edit
    ///   still goes out, now carrying them.
    /// - **Marks nothing dirty.** The server already has everything it adds.
    /// - **Owed once per list** (``categoriesCatchUpPending(listID:defaults:)``).
    ///   Repeated, it would restore every tag deleted from the sidebar, a deletion
    ///   that is never uploaded.
    ///
    /// Takes the whole fetched set, not the sync-window subset, so a completed
    /// task outside the window cannot be reopened later and uploaded without them.
    /// Retained as a direct compatibility test seam; production category repair
    /// runs through SyncImportStore in the bounded inbound writer.
    nonisolated private func catchUpCategories(
        remoteTasks: [CalDAVClient.RemoteTask],
        uidMap: [String: TaskItem],
        modelContext: ModelContext
    ) -> Bool {
        var known = (try? modelContext.fetch(FetchDescriptor<Tag>())) ?? []
        var added = false
        for remoteTask in remoteTasks {
            guard let data = try? ICalendarParser.parseSingleVTODO(from: remoteTask.icsData),
                  let categories = data.categories,
                  let task = uidMap[data.uid],
                  !task.isDeletedLocally
            else { continue }

            // Re-checked per name, so a category the VTODO repeats is added once.
            for name in categories where Tag.matching(name, in: task.tags) == nil {
                task.tags.append(resolveTag(named: name, known: &known, modelContext: modelContext))
                added = true
            }
        }
        return added
    }

    /// Whether ``SyncImportStore/catchUpCategories(_:uidMap:)`` is still owed to a
    /// list. The bounded inbound writer performs this repair. Keyed by the
    /// local `TaskList.id` rather than the href,
    /// which two accounts can share. App-local and never synced, like the
    /// trashed-list notice: on a fresh install it runs once and finds nothing.
    static func categoriesCatchUpPending(listID: String, defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: categoriesCatchUpKeyPrefix + listID)
    }

    static func markCategoriesCaughtUp(listID: String, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: categoriesCatchUpKeyPrefix + listID)
    }

    private static let categoriesCatchUpKeyPrefix = "categoriesCaughtUp."

    private static func isDefinitiveCollectionDenial(_ error: Error) -> Bool {
        guard let error = error as? CalDAVError else { return false }
        switch error {
        case .forbidden, .notFound: return true
        default: return false
        }
    }

    private func restorePhotoAccess(scope: TaskPhotoOwnership.Scope, container: ModelContainer) async throws -> Bool {
        guard let change = try await TaskPhotoAccessMaintenance.restore(scope: scope,
            container: container) else { return false }
        publishExternalChange(change)
        return true
    }

    /// Discovery omission is ambiguous. Only a full collection probe can revoke access.
    private func probeMissingPhotoLists(accountID: String, livePaths: Set<String>, baseURL: String,
        credentials: CalDAVClient.Credentials, container: ModelContainer) async throws {
        let candidates = try await MainActor.run { () throws -> [TaskPhotoOwnership.Scope] in
            let context = ModelContext(container)
            let lists = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate {
                $0.account?.id == accountID
            }))
            var candidates: [TaskPhotoOwnership.Scope] = []
            for list in lists where !livePaths.contains(list.serverURL) && !list.serverURL.isEmpty {
                let id = list.id
                var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.taskList?.id == id })
                descriptor.relationshipKeyPathsForPrefetching = [\.photos]
                let hasPhotos = try context.fetch(descriptor).contains { !$0.photos.isEmpty }
                if list.photoAccessRevoked == true || hasPhotos {
                    candidates.append(.init(accountID: accountID, listID: id, collectionPath: list.serverURL,
                        serverBaseURL: baseURL, username: credentials.username))
                }
            }
            return candidates
        }
        for scope in candidates {
            try requirePhotoProbeScope(scope, container: container)
            do {
                _ = try await calDAVClient.fetchTaskManifest(baseURL: scope.serverBaseURL,
                    calendarPath: scope.collectionPath, credentials: credentials)
            } catch {
                if Self.isDefinitiveCollectionDenial(error) {
                    let change = try await TaskPhotoAccessMaintenance.revoke(scope: scope,
                        container: container, cache: taskPhotoCache)
                    publishExternalChange(change)
                } else {
                    try requirePhotoProbeScope(scope, container: container)
                }
                try recordOperationFailure(error)
                continue
            }
            _ = try await restorePhotoAccess(scope: scope, container: container)
        }
    }

    private func requirePhotoProbeScope(_ scope: TaskPhotoOwnership.Scope, container: ModelContainer) throws {
        try BackgroundRunBudget.protectingCurrent {
            _ = try scope.requireList(in: ModelContext(container))
        }
    }

    /// A failed multiget/resource read is not proof of collection denial. Confirm with
    /// a collection REPORT before removing previews or cached originals.
    private func pullCalendarCheckingPhotoAccess(remoteCal: CalDAVClient.RemoteCalendar,
        scope: TaskPhotoOwnership.Scope, credentials: CalDAVClient.Credentials,
        container: ModelContainer, months: Int, repairCategories: Bool) async throws -> CalendarPullResult {
        do {
            return try await pullCalendar(remoteCal: remoteCal, resourceScope: scope,
                credentials: credentials, container: container, months: months,
                repairCategories: repairCategories)
        } catch {
            guard Self.isDefinitiveCollectionDenial(error) else { throw error }
            try requirePhotoProbeScope(scope, container: container)
            do {
                _ = try await calDAVClient.fetchTaskManifest(baseURL: scope.serverBaseURL,
                    calendarPath: scope.collectionPath, credentials: credentials)
            } catch {
                if Self.isDefinitiveCollectionDenial(error) {
                    let change = try await TaskPhotoAccessMaintenance.revoke(scope: scope,
                        container: container, cache: taskPhotoCache)
                    publishExternalChange(change)
                } else {
                    try requirePhotoProbeScope(scope, container: container)
                }
                throw error
            }
            try requirePhotoProbeScope(scope, container: container)
            throw error
        }
    }

    /// TaskPhotoSync owns its no-original snapshot gate; an ordinary list adds no HTTP.
    private func synchronizePhotos(listID: String, accountID: String, baseURL: String,
        credentials: CalDAVClient.Credentials, container: ModelContainer,
        uploadOriginals: Bool = true, deadline: Date? = nil) async throws -> Bool {
        do {
            let outcome = try await taskPhotoSync.synchronize(listID: listID,
                access: PhotoServerAccess(baseURL: baseURL, username: credentials.username,
                    password: credentials.password), container: container,
                uploadOriginals: uploadOriginals, deadline: deadline)
            if outcome.credentialsDeferred { lastOutcome.status = .partial }
            guard !outcome.changedTaskIDs.isEmpty else { return false }
            publishExternalChange(SyncChange(revision: 0, accountIDs: [accountID], listIDs: [listID],
                changedIDs: outcome.changedTaskIDs, deletedIDs: [], kind: .tasks))
            return true
        } catch {
            try recordOperationFailure(error)
            return false
        }
    }

    // MARK: - Push (Local → Remote)

    private func catchUpLegacyTask(taskID: String, expectedListID: String, expectedAccountID: String,
                                   runAccountID: String, baseURL: String, credentials: CalDAVClient.Credentials,
                                   container: ModelContainer) async throws {
        if let request = try await TaskPhotoLegacyCatchUp.requestInfo(taskID: taskID,
            listID: expectedListID, accountID: expectedAccountID, container: container) {
            guard let captured = request.photoScope else { throw SyncResourceState.Hold.needsRevalidation }
            let access = PhotoServerAccess(baseURL: baseURL, username: credentials.username,
                password: credentials.password)
            let expectedSource = AccountCredentialScope(id: captured.accountID, serverBaseURL: captured.serverBaseURL,
                                                        username: captured.username)
            let runScope = AccountCredentialScope(id: runAccountID, serverBaseURL: baseURL,
                                                  username: credentials.username)
            let sourceAccess: PhotoServerAccess
            if request.sourceAccountID == runAccountID && expectedSource == runScope {
                sourceAccess = access
            } else if request.sourceListID != nil {
                sourceAccess = try await taskPhotoSync.sourceAccess(accountID: request.sourceAccountID,
                    expected: expectedSource, container: container)
            } else {
                throw AccountCredentialDeferral.staleAccount
            }
            let responseScope = TaskPhotoOwnership.Scope(accountID: captured.accountID, listID: captured.listID,
                collectionPath: captured.collectionPath, serverBaseURL: sourceAccess.baseURL, username: sourceAccess.username)
            let sourceAuthScope = AuthFailureGate.Scope(accountID: request.sourceAccountID,
                baseURL: sourceAccess.baseURL, username: sourceAccess.username, password: sourceAccess.password)
            do {
                if credentialGate.shouldSkip(sourceAuthScope) { throw CalDAVError.unauthorized }
                let resource = try await captureServerDeferrals(accountID: request.sourceAccountID) {
                    try await calDAVClient.fetchTask(baseURL: sourceAccess.baseURL,
                        taskPath: try SyncResourceState.canonical(request.href, scope: captured),
                        credentials: .init(username: sourceAccess.username, password: sourceAccess.password))
                }
                let parsed = try SyncBodyValidation.parse(resource, using: .init())
                if let change = try await TaskPhotoLegacyCatchUp.accept(parsed, taskID: taskID,
                    listID: expectedListID, accountID: expectedAccountID, expectedRequest: request,
                    responseScope: responseScope, container: container) { publishExternalChange(change) }
            } catch CalDAVError.notFound {
                if let change = try await TaskPhotoLegacyCatchUp.acceptAbsence(taskID: taskID,
                    listID: expectedListID, accountID: expectedAccountID, expectedRequest: request,
                    responseScope: responseScope, container: container) { publishExternalChange(change) }
            } catch let error as RetryDeferredError where error.httpStatusCode != nil && request.sourceAccountID != runAccountID {
                throw OtherAccountSyncFailure(underlying: error)
            } catch CalDAVError.unauthorized {
                let runAuthScope = AuthFailureGate.Scope(accountID: runAccountID, baseURL: baseURL,
                    username: credentials.username, password: credentials.password)
                guard sourceAuthScope != runAuthScope else { throw CalDAVError.unauthorized }
                credentialGate.recordFailure(sourceAuthScope)
                throw OtherAccountSyncFailure(underlying: CalDAVError.unauthorized)
            }
        }
    }

    /// Pushes a locally modified task to the server.
    private func pushLocalTask(
        _ task: TaskItem,
        expectedListID: String, expectedAccountID: String,
        calendarPath: String,
        baseURL: String,
        credentials: CalDAVClient.Credentials,
        modelContext: ModelContext
    ) async throws {
        let taskID = task.id
        let container = modelContext.container
        try await catchUpLegacyTask(taskID: taskID, expectedListID: expectedListID,
            expectedAccountID: expectedAccountID, runAccountID: expectedAccountID, baseURL: baseURL, credentials: credentials,
            container: container)
        guard let snapshot = try await MainActor.run(body: {
            try SyncPushAcknowledgement.snapshot(taskID: taskID, calendarPath: calendarPath, container: container, expectedListID: expectedListID, expectedAccountID: expectedAccountID)
        }) else { return }
        let icsData = snapshot.payload
        let taskPath = snapshot.path
        let responseScope = TaskPhotoOwnership.Scope(accountID: expectedAccountID, listID: expectedListID,
            collectionPath: calendarPath, serverBaseURL: baseURL, username: credentials.username)

        do {
            let newEtag = try await calDAVClient.putTask(
                baseURL: baseURL, taskPath: taskPath, icsData: icsData,
                etag: snapshot.etag, credentials: credentials) {
                try await SyncPushAcknowledgement.validateWrite(snapshot, container: container, responseScope: responseScope)
            }
            try await MainActor.run {
                try SyncPushAcknowledgement.acknowledge(snapshot, etag: newEtag, container: container)
            }

        } catch CalDAVError.forbidden {
            let change = try await MainActor.run {
                try SyncPushAcknowledgement.rollBackRefusedMove(snapshot, container: container)
            }
            lastMovePermissionDenied = true
            publishExternalChange(change)

        } catch CalDAVError.conflict {
            // Rebase photo operations while retaining server-wins behavior for other fields
            let resolution = ConflictResolver.resolve(
                localModified: snapshot.modifiedAt,
                remoteModified: nil
            )

            switch resolution {
            case .serverWins:
                // Re-fetch from server
                let refreshed = try await calDAVClient.fetchTask(
                    baseURL: baseURL,
                    taskPath: taskPath,
                    credentials: credentials
                )
                let parsed = try SyncBodyValidation.parse(refreshed, using: .init())
                let change = try await MainActor.run {
                    try SyncPushAcknowledgement.applyConflict(snapshot, resource: parsed, container: container,
                        responseScope: .init(accountID: expectedAccountID, listID: expectedListID,
                            collectionPath: calendarPath, serverBaseURL: baseURL, username: credentials.username))
                }
                publishExternalChange(change)
                // Only pending photo operations leave the rebased task dirty. A fresh
                // guarded snapshot therefore preserves title-only server-wins behavior.
                if let retry = try await SyncPushAcknowledgement.snapshot(taskID: taskID,
                    calendarPath: calendarPath, container: container,
                    expectedListID: expectedListID, expectedAccountID: expectedAccountID) {
                    let etag = try await calDAVClient.putTask(baseURL: baseURL, taskPath: retry.path,
                        icsData: retry.payload, etag: retry.etag, credentials: credentials) {
                        try await SyncPushAcknowledgement.validateWrite(retry, container: container, responseScope: responseScope)
                    }
                    try await SyncPushAcknowledgement.acknowledge(retry, etag: etag, container: container)
                }
            case .localWins:
                // Retry PUT without If-Match (force overwrite)
                let newEtag = try await calDAVClient.putTask(
                    baseURL: baseURL,
                    taskPath: taskPath,
                    icsData: icsData,
                    etag: snapshot.etag,
                    credentials: credentials
                ) {
                    try await SyncPushAcknowledgement.validateWrite(snapshot, container: container, responseScope: responseScope)
                }
                try await MainActor.run {
                    try SyncPushAcknowledgement.acknowledge(snapshot, etag: newEtag, container: container)
                }
            case .manualMerge:
                break // Future: present merge UI
            }
        }
    }

    /// Pushes a deletion to the server.
    private func pushDeletion(
        _ taskID: String,
        expectedListID: String, expectedAccountID: String,
        baseURL: String,
        credentials: CalDAVClient.Credentials,
        container: ModelContainer
    ) async throws {
        try await catchUpLegacyTask(taskID: taskID, expectedListID: expectedListID,
            expectedAccountID: expectedAccountID, runAccountID: expectedAccountID, baseURL: baseURL,
            credentials: credentials, container: container)
        guard let snapshot = try await SyncPushAcknowledgement.deletionSnapshot(taskID: taskID, container: container,
            expectedListID: expectedListID, expectedAccountID: expectedAccountID) else { return }
        if let href = snapshot.href, !href.isEmpty {
            guard snapshot.resourceProof?.scope.serverBaseURL == baseURL,
                  snapshot.resourceProof?.scope.username == credentials.username else { throw SyncResourceState.Hold.needsRevalidation }
            do {
                guard let target = snapshot.resourceProof?.href else { throw SyncResourceState.Hold.needsRevalidation }
                try await calDAVClient.deleteTask(baseURL: baseURL, taskPath: target, etag: snapshot.etag,
                    credentials: credentials) {
                    try await SyncPushAcknowledgement.validateDeletion(snapshot, container: container)
                }
            } catch is SupersededTaskDeletion {
                return
            }
        }
        try Task.checkCancellation()
        if let change = try await SyncPushAcknowledgement.acknowledgeDeletion(snapshot, container: container) {
            publishExternalChange(change)
        }
    }

    // MARK: - Queries

    /// Finds or creates a local TaskList matching a remote calendar.
    private func findOrCreateTaskList(
        for remoteCal: CalDAVClient.RemoteCalendar,
        account: ServerAccount,
        accountScope: ListAccountScope,
        modelContext: ModelContext
    ) async throws -> TaskList {
        let container = modelContext.container
        try requireLiveAccount(accountScope.id, container: container, matching: accountScope)
        let href = remoteCal.href
        let lists = try BackgroundRunBudget.protectingCurrent { account.taskLists }
        if let existing = lists.first(where: { $0.serverURL == href }) {
            let listID = existing.id
            let metadataDiffers = existing.name != remoteCal.displayName
                || (!remoteCal.color.isEmpty && existing.colorHex != remoteCal.color)
            if metadataDiffers || existing.isReadOnly != remoteCal.isReadOnly {
                if try await Self.applyDiscoveredListMetadata(remoteCal, listID: listID,
                    accountScope: accountScope, container: container) {
                    publishExternalChange(.init(revision: 0, accountIDs: [accountScope.id], listIDs: [listID],
                        changedIDs: [], deletedIDs: [], kind: .lists))
                }
                try requireLiveAccount(accountScope.id, container: container, matching: accountScope)
            }
            return existing
        }

        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        // Create new list
        let newList = TaskList(
            serverURL: href,
            name: remoteCal.displayName.isEmpty
                ? String(localized: "Tasks")
                : remoteCal.displayName,
            colorHex: remoteCal.color.isEmpty ? "#007AFF" : remoteCal.color
        )
        newList.account = account
        newList.isReadOnly = remoteCal.isReadOnly
        modelContext.insert(newList)
        return newList
    }

    // MARK: - Push Local Lists

    private struct ListAccountScope: Sendable {
        let id: String
        let serverBaseURL: String
        let username: String

        init(_ account: ServerAccount) {
            id = account.id
            serverBaseURL = account.serverBaseURL
            username = account.username
        }

        func matches(_ account: ServerAccount) -> Bool {
            id == account.id && matchesRequest(baseURL: account.serverBaseURL, username: account.username)
        }

        func matchesRequest(baseURL: String, username: String) -> Bool {
            serverBaseURL.utf8.elementsEqual(baseURL.utf8) && self.username.utf8.elementsEqual(username.utf8)
        }
    }

    private struct ListWriteSnapshot: Sendable {
        let listID: String
        let accountScope: ListAccountScope
        let path: String
        let name: String
        let color: String

        init(list: TaskList, accountScope: ListAccountScope) {
            listID = list.id
            self.accountScope = accountScope
            path = list.serverURL
            name = list.name
            color = list.colorHex
        }

        func samePayload(as other: Self) -> Bool {
            path.utf8.elementsEqual(other.path.utf8)
                && name.utf8.elementsEqual(other.name.utf8)
                && color.utf8.elementsEqual(other.color.utf8)
        }

        func matchesMetadata(_ list: TaskList) -> Bool {
            name.utf8.elementsEqual(list.name.utf8) && color.utf8.elementsEqual(list.colorHex.utf8)
        }

        func matchesScope(_ list: TaskList) -> Bool {
            guard let account = list.account else { return false }
            return accountScope.matches(account) && list.serverURL.utf8.elementsEqual(path.utf8)
        }
    }

    private struct SupersededListWrite: Error {}

    @MainActor
    private static func hasPendingListChange(_ list: TaskList, container: ModelContainer) -> Bool {
        let main = container.mainContext
        return (main.insertedModelsArray + main.changedModelsArray + main.deletedModelsArray)
            .contains { $0.persistentModelID == list.persistentModelID }
            || list.account.map { hasPendingAccountScopeChange($0, in: main) } == true
    }

    @MainActor
    private static func hasPendingAccountScopeChange(_ account: ServerAccount, in main: ModelContext) -> Bool {
        main.deletedModelsArray.contains { $0.persistentModelID == account.persistentModelID }
            || main.changedModelsArray.contains { model in
                guard let pending = model as? ServerAccount,
                      pending.persistentModelID == account.persistentModelID else { return false }
                return !ListAccountScope(account).matches(pending)
            }
    }

    @MainActor
    private static func captureListCreation(listID: String, accountScope: ListAccountScope, target: URL,
        baseURL: String, container: ModelContainer) throws -> ListWriteSnapshot? {
        let context = ModelContext(container)
        let predicate = #Predicate<TaskList> { $0.id == listID }
        guard let list = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              let account = list.account, accountScope.matches(account), list.serverURL.isEmpty else { return nil }
        guard !hasPendingListChange(list, container: container) else { throw CalDAVDiscovery.ambiguousCollection }
        try requireUnclaimedCreationTarget(target, account: account, baseURL: baseURL, container: container)
        return ListWriteSnapshot(list: list, accountScope: accountScope)
    }

    @MainActor
    private static func requireUnclaimedCreationTarget(_ target: URL, account: ServerAccount,
        baseURL: String, container: ModelContainer) throws {
        guard let base = URL(string: baseURL) else { throw CalDAVError.invalidURL }
        let main = container.mainContext
        let pending = (main.insertedModelsArray + main.changedModelsArray).compactMap { $0 as? TaskList }
            .filter { $0.account?.id == account.id }
        if (account.taskLists + pending).contains(where: { list in
            guard !list.serverURL.isEmpty, let url = URL(string: list.serverURL, relativeTo: base)?.absoluteURL else { return false }
            return CalDAVDiscovery.sameCollection(url, target)
        }) {
            throw CalDAVDiscovery.ambiguousCollection
        }
    }

    @MainActor
    private static func bindCreatedList(_ creation: CalDAVClient.CalendarCreation,
        snapshot: ListWriteSnapshot, baseURL: String, container: ModelContainer) throws -> Bool {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let listID = snapshot.listID
        let predicate = #Predicate<TaskList> { $0.id == listID }
        guard let list = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              let account = list.account, snapshot.matchesScope(list),
              !hasPendingListChange(list, container: container),
              let target = URL(string: creation.href) else { throw CalDAVDiscovery.ambiguousCollection }
        try requireUnclaimedCreationTarget(target, account: account, baseURL: baseURL, container: container)
        let newerMetadata = !snapshot.matchesMetadata(list)
        list.serverURL = creation.href
        list.isMetadataDirty = creation.adopted || newerMetadata
        try context.save()
        return newerMetadata && !creation.adopted
    }

    private func pushNewLists(_ listIDs: [String], accountScope: ListAccountScope, baseURL: String,
        discovery: CalDAVDiscoveryResult, credentials: CalDAVClient.Credentials, container: ModelContainer
    ) async throws -> Set<String> {
        var deferredMetadata = Set<String>()
        for listID in listIDs {
            do {
                let target = try CalDAVDiscovery.creationTarget(listID: listID, homeURL: discovery.calendarHomeURL)
                guard let snapshot = try await Self.captureListCreation(listID: listID, accountScope: accountScope,
                    target: target, baseURL: baseURL, container: container) else { continue }
                let alreadyDiscovered = discovery.collectionAddresses.contains {
                    CalDAVDiscovery.sameCollection($0.requestURL, target)
                }
                let creation = try await calDAVClient.createCalendar(baseURL: baseURL,
                    calendarHomePath: discovery.calendarHomeURL.absoluteString, listID: listID,
                    name: snapshot.name, color: snapshot.color, credentials: credentials,
                    alreadyDiscovered: alreadyDiscovered, validateAccount: {
                        guard try await Self.captureListCreation(listID: listID, accountScope: accountScope,
                            target: target, baseURL: baseURL, container: container) != nil else {
                            throw SupersededListWrite()
                        }
                    })
                try requireLiveAccount(accountScope.id, container: container, matching: accountScope)
                if try await Self.bindCreatedList(creation, snapshot: snapshot, baseURL: baseURL, container: container) {
                    deferredMetadata.insert(listID)
                    try recordOperationFailure(SupersededListWrite())
                }
            } catch {
                if error is RetryDeferredError || error is BackgroundBudgetExhausted { throw error }
                try requireLiveAccount(accountScope.id, container: container, matching: accountScope)
                try recordOperationFailure(error)
            }
        }
        return deferredMetadata
    }

    private func heldCreationHrefs(in live: [CalDAVClient.RemoteCalendar], homeURL: URL,
                                   account: ServerAccount) throws -> Set<String> {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        let lists = account.taskLists
        let held = try CalDAVDiscovery.heldCreationHrefs(live,
            unboundIDs: lists.filter { $0.serverURL.isEmpty }.map(\.id),
            boundHrefs: Set(lists.map(\.serverURL)), homeURL: homeURL)
        if !held.isEmpty {
            let failure = CalDAVDiscovery.ambiguousCollection
            if let summary = SyncFailure.from(failure), !lastOutcome.failures.contains(summary) {
                try recordOperationFailure(failure)
            }
        }
        return held
    }

    @MainActor
    private static func applyDiscoveredListMetadata(_ remote: CalDAVClient.RemoteCalendar, listID: String,
        accountScope: ListAccountScope, container: ModelContainer) throws -> Bool {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let predicate = #Predicate<TaskList> { $0.id == listID }
        guard let list = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              let account = list.account, accountScope.matches(account),
              list.serverURL.utf8.elementsEqual(remote.href.utf8) else { return false }

        let main = container.mainContext
        let modelID = list.persistentModelID
        let insertedOrDeleted = (main.insertedModelsArray + main.deletedModelsArray)
            .contains { $0.persistentModelID == modelID }
        guard !insertedOrDeleted, !hasPendingAccountScopeChange(account, in: main) else { return false }
        let pending = main.changedModelsArray.first { $0.persistentModelID == modelID } as? TaskList
        if let pending {
            guard pending.id.utf8.elementsEqual(list.id.utf8),
                  pending.serverURL.utf8.elementsEqual(list.serverURL.utf8),
                  pending.calendarPath.map({ Array($0.utf8) }) == list.calendarPath.map({ Array($0.utf8) }),
                  let pendingAccount = pending.account, pendingAccount.persistentModelID == account.persistentModelID,
                  accountScope.matches(pendingAccount) else { return false }
        }

        let before = (list.name, list.colorHex, list.isReadOnly)
        if pending == nil { list.applyRemoteMetadata(name: remote.displayName, colorHex: remote.color) }
        if list.isReadOnly != remote.isReadOnly { list.isReadOnly = remote.isReadOnly }
        let changed = before != (list.name, list.colorHex, list.isReadOnly)
        if changed { try context.save() }
        // Saving a pending row can write its old privilege back to the store.
        if let pending, pending.isReadOnly != list.isReadOnly { pending.isReadOnly = list.isReadOnly }
        return changed
    }

    @MainActor
    private static func captureListMetadata(listID: String, accountScope: ListAccountScope,
        container: ModelContainer) throws -> ListWriteSnapshot? {
        let context = ModelContext(container)
        let predicate = #Predicate<TaskList> { $0.id == listID }
        guard let list = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              let account = list.account, accountScope.matches(account),
              !list.serverURL.isEmpty, list.isMetadataDirty else { return nil }
        guard !hasPendingListChange(list, container: container) else { throw SupersededListWrite() }
        return ListWriteSnapshot(list: list, accountScope: accountScope)
    }

    @MainActor
    private static func acknowledgeListMetadata(_ snapshot: ListWriteSnapshot, container: ModelContainer) throws {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let listID = snapshot.listID
        let predicate = #Predicate<TaskList> { $0.id == listID }
        guard let list = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              list.isMetadataDirty, snapshot.matchesScope(list), snapshot.matchesMetadata(list),
              !hasPendingListChange(list, container: container) else { throw SupersededListWrite() }
        list.isMetadataDirty = false
        try context.save()
    }

    private func pushListMetadata(_ listIDs: [String], accountScope: ListAccountScope, baseURL: String,
        credentials: CalDAVClient.Credentials, container: ModelContainer) async throws {
        for listID in listIDs {
            do {
                guard let snapshot = try await Self.captureListMetadata(listID: listID, accountScope: accountScope,
                    container: container) else { continue }
                try await calDAVClient.updateCalendarProperties(baseURL: baseURL,
                    calendarPath: snapshot.path, name: snapshot.name, colorHex: snapshot.color,
                    credentials: credentials, validateAttempt: {
                        guard let current = try await Self.captureListMetadata(listID: listID, accountScope: accountScope,
                            container: container), snapshot.samePayload(as: current) else {
                            throw SupersededListWrite()
                        }
                    })
                try requireLiveAccount(accountScope.id, container: container, matching: accountScope)
                try await Self.acknowledgeListMetadata(snapshot, container: container)
            } catch {
                if error is RetryDeferredError || error is BackgroundBudgetExhausted { throw error }
                try requireLiveAccount(accountScope.id, container: container, matching: accountScope)
                try recordOperationFailure(error)
            }
        }
    }

    /// Finds tasks that have been modified locally and need to be pushed.
    ///
    /// Uses an explicit `FetchDescriptor` instead of `taskList.tasks` relationship,
    /// which can be stale/unfaulted in background contexts.
    nonisolated func findDirtyTasks(
        for taskList: TaskList,
        modelContext: ModelContext
    ) -> [TaskItem] {
        let listID = taskList.id
        let predicate = #Predicate<TaskItem> {
            $0.taskList?.id == listID && $0.isDirty && !$0.isDeletedLocally
        }
        return (try? modelContext.fetch(FetchDescriptor<TaskItem>(predicate: predicate))) ?? []
    }

    /// Finds tasks that have been marked for deletion locally.
    ///
    /// Uses an explicit `FetchDescriptor` instead of `taskList.tasks` relationship,
    /// which can be stale/unfaulted in background contexts.
    /// Tasks awaiting a DELETE, **deepest first**.
    ///
    /// Try children first so their parent can be removed in the same sync.
    /// Deletion snapshots and acknowledgements separately verify that each row
    /// is a leaf, since a failed DELETE or a new child can change eligibility.
    nonisolated func findDeletedTasks(
        for taskList: TaskList,
        modelContext: ModelContext
    ) -> [TaskItem] {
        let listID = taskList.id
        let predicate = #Predicate<TaskItem> {
            $0.taskList?.id == listID && $0.isDeletedLocally
        }
        let tasks = (try? modelContext.fetch(FetchDescriptor<TaskItem>(predicate: predicate))) ?? []
        return tasks.sorted { TaskListHelpers.depth(of: $0) > TaskListHelpers.depth(of: $1) }
    }

    // MARK: - State Management

    private func setState(_ newState: SyncState) {
        state = newState
    }
    // MARK: - Task Partitioning

    /// Partitions remote tasks into active and completed/cancelled groups.
    ///
    /// Uses a lightweight string check on the raw ICS data to avoid
    /// full parsing. Tasks without STATUS or with NEEDS-ACTION/IN-PROCESS
    /// are considered active.
    static func partitionByStatus(
        _ tasks: [CalDAVClient.RemoteTask]
    ) -> (active: [CalDAVClient.RemoteTask], completed: [CalDAVClient.RemoteTask]) {
        var active: [CalDAVClient.RemoteTask] = []
        var completed: [CalDAVClient.RemoteTask] = []
        for task in tasks {
            if task.icsData.contains("STATUS:COMPLETED") || task.icsData.contains("STATUS:CANCELLED") {
                completed.append(task)
            } else {
                active.append(task)
            }
        }
        return (active, completed)
    }

    nonisolated static func partitionParsedTasks(_ tasks: [ParsedRemoteTask], months: Int,
                                                now: Date = Date()) -> ([ParsedRemoteTask], [ParsedRemoteTask]) {
        let cutoff = months > 0 ? Calendar.current.date(byAdding: .month, value: -months, to: now) : nil
        var active: [ParsedRemoteTask] = []
        var completed: [ParsedRemoteTask] = []
        for task in tasks {
            if task.todo?.status == TaskStatus.completed.rawValue {
                if let cutoff, let finished = task.todo?.completedDate, finished < cutoff { continue }
                completed.append(task)
            } else { active.append(task) }
        }
        return (active, completed)
    }

    // MARK: - Sync Window Filter

    /// Filters completed remote tasks to only include those completed within the given window.
    ///
    /// Uses a lightweight string scan on the raw ICS `COMPLETED:` timestamp to avoid
    /// full VTODO parsing (same pattern as `partitionByStatus`).
    ///
    /// - Parameters:
    ///   - tasks: Completed remote tasks to filter.
    ///   - months: Number of months to keep. 0 means keep all (no filtering).
    /// - Returns: Filtered array of tasks completed within the window.
    static func filterCompletedByWindow(
        _ tasks: [CalDAVClient.RemoteTask],
        months: Int,
        now: Date = Date()
    ) -> [CalDAVClient.RemoteTask] {
        guard months > 0 else { return tasks }

        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: now)!

        // Reusable date formatters for the two common COMPLETED timestamp formats.
        //
        // `en_US_POSIX` is required, not stylistic. These parse an iCalendar wire format, and
        // without it the formatter follows the user's *region calendar* — under Buddhist or
        // Japanese, `yyyy` is the era year, every COMPLETED: parse returns nil, and the sync
        // window silently stops filtering. Matches the nine other ICS formatters in the repo
        // (ICalendarParser, ICalendarSerializer, VEventSerializer).
        let posix = Locale(identifier: "en_US_POSIX")

        let utcFormatter = DateFormatter()
        utcFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        utcFormatter.timeZone = TimeZone(identifier: "UTC")
        utcFormatter.locale = posix

        let localFormatter = DateFormatter()
        localFormatter.dateFormat = "yyyyMMdd'T'HHmmss"
        localFormatter.timeZone = TimeZone.current
        localFormatter.locale = posix

        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.dateFormat = "yyyyMMdd"
        dateOnlyFormatter.timeZone = TimeZone.current
        dateOnlyFormatter.locale = posix

        return tasks.filter { task in
            // Scan for COMPLETED: line in raw ICS
            guard let range = task.icsData.range(of: "COMPLETED:") else {
                // No COMPLETED timestamp — keep it (can't determine age)
                return true
            }

            let afterPrefix = task.icsData[range.upperBound...]
            let line = afterPrefix.prefix(while: { $0 != "\r" && $0 != "\n" })
            let dateString = String(line).trimmingCharacters(in: .whitespaces)

            // Try parsing: UTC datetime, local datetime, or date-only
            let completedDate: Date?
            if dateString.hasSuffix("Z") {
                completedDate = utcFormatter.date(from: dateString)
            } else if dateString.contains("T") {
                completedDate = localFormatter.date(from: dateString)
            } else {
                completedDate = dateOnlyFormatter.date(from: dateString)
            }

            guard let date = completedDate else {
                // Unparseable date — keep it
                return true
            }

            return date >= cutoff
        }
    }

    // MARK: - Test Helpers

    /// Test-accessible wrapper for `applyRemoteTask`. `nonisolated` so tests can
    /// drive it synchronously with an `inout` map (an `inout` can't cross an
    /// actor boundary). Returns whether the apply changed local data.
    @discardableResult
    nonisolated func testApplyRemoteTask(
        _ remoteTask: CalDAVClient.RemoteTask,
        taskList: TaskList,
        uidMap: inout [String: TaskItem],
        movedAway: Set<String> = [],
        modelContext: ModelContext
    ) throws -> Bool {
        try applyRemoteTask(remoteTask, taskList: taskList, uidMap: &uidMap,
                            movedAway: movedAway, modelContext: modelContext)
    }

    /// Test-accessible wrapper for `existingTaskMap`.
    nonisolated func testExistingTaskMap(
        for taskList: TaskList,
        modelContext: ModelContext
    ) -> [String: TaskItem] {
        existingTaskMap(for: taskList, modelContext: modelContext)
    }

    /// Synchronous test wrapper for the legacy per-resource importer seam.
    /// Production pulls use the shared bounded writer instead.
    @discardableResult
    nonisolated func testProcessRemoteTask(
        _ remoteTask: CalDAVClient.RemoteTask,
        taskList: TaskList,
        uidMap: inout [String: TaskItem],
        movedAway: Set<String> = [],
        modelContext: ModelContext
    ) throws -> Bool {
        try processRemoteTask(remoteTask, taskList: taskList, uidMap: &uidMap,
                              movedAway: movedAway, modelContext: modelContext)
    }

    /// Test-accessible wrapper for `pendingMoveUIDs`.
    nonisolated func testPendingMoveUIDs(
        from taskList: TaskList,
        modelContext: ModelContext
    ) -> Set<String> {
        pendingMoveUIDs(from: taskList, modelContext: modelContext)
    }

    /// Test-accessible wrapper for `catchUpCategories`.
    @discardableResult
    nonisolated func testCatchUpCategories(
        remoteTasks: [CalDAVClient.RemoteTask],
        uidMap: [String: TaskItem],
        modelContext: ModelContext
    ) -> Bool {
        catchUpCategories(remoteTasks: remoteTasks, uidMap: uidMap, modelContext: modelContext)
    }

    /// Test-accessible alias for `findDirtyTasks` — returns UIDs for Sendable safety.
    nonisolated func testFindDirtyTasks(
        for taskList: TaskList,
        modelContext: ModelContext
    ) -> [String] {
        findDirtyTasks(for: taskList, modelContext: modelContext).map(\.uid)
    }

    /// Test-accessible alias for `findDeletedTasks` — returns UIDs for Sendable safety.
    nonisolated func testFindDeletedTasks(
        for taskList: TaskList,
        modelContext: ModelContext
    ) -> [String] {
        findDeletedTasks(for: taskList, modelContext: modelContext).map(\.uid)
    }
}

