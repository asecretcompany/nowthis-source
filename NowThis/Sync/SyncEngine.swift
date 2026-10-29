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

    private let calDAVClient: CalDAVClient
    private let taskPhotoSync: TaskPhotoSync
    private let taskPhotoCleanup: TaskPhotoCleanupRunner
    private let taskPhotoVaultMoves: TaskPhotoVaultMoves
    private let taskPhotoCache: TaskPhotoCache
    private let logger = Logger(subsystem: "com.nowthis", category: "sync-engine")

    init(calDAVClient: CalDAVClient = CalDAVClient(),
         taskPhotoSync: TaskPhotoSync = TaskPhotoSync(),
         taskPhotoCleanup: TaskPhotoCleanupRunner = TaskPhotoCleanupRunner(),
         taskPhotoVaultMoves: TaskPhotoVaultMoves = TaskPhotoVaultMoves(),
         taskPhotoCache: TaskPhotoCache = TaskPhotoOriginals.cache) {
        self.calDAVClient = calDAVClient
        self.taskPhotoSync = taskPhotoSync
        self.taskPhotoCleanup = taskPhotoCleanup
        self.taskPhotoVaultMoves = taskPhotoVaultMoves
        self.taskPhotoCache = taskPhotoCache
    }

    private(set) var lastOutcome = SyncOutcome()
    private var revision: UInt64 = 0
    private var progressObservers: [UUID: AsyncStream<SyncProgress?>.Continuation] = [:]
    private var changeObservers: [UUID: AsyncStream<SyncChange>.Continuation] = [:]
    private var importedIDs: Set<String> = []
    private var updatedIDs: Set<String> = []
    private var deletedIDs: Set<String> = []
    private var visiblyChangedLists: Set<String> = []
    private var pendingScopeListIDs: Set<String> = []
    private var pendingScopeAccountIDs: Set<String> = []
    private var credentialGate = AuthFailureGate()
    private var deferredUntil: [String: Date] = [:]
    private var pendingSweepFailure: (any Error)?

    private func authenticationKey(accountID: String, baseURL: String, username: String) -> String {
        [accountID, baseURL, username].map { "\($0.utf8.count):\($0)" }.joined()
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
        visiblyChangedLists.removeAll()
        pendingScopeListIDs.removeAll(); pendingScopeAccountIDs.removeAll()
    }

    /// Capture IDs before saving; publish only after the store accepts the transaction.
    private func saveAndPublish(_ context: ModelContext, publish: Bool = true) throws {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        guard context.hasChanges else { return }
        let inserts = context.insertedModelsArray.compactMap { $0 as? TaskItem }
        let updates = context.changedModelsArray.compactMap { $0 as? TaskItem }
        let deletions = context.deletedModelsArray.compactMap { $0 as? TaskItem }
        let lists = (context.insertedModelsArray + context.deletedModelsArray)
            .compactMap { $0 as? TaskList }
            + context.changedModelsArray.compactMap { $0 as? TaskList }
                .filter { visiblyChangedLists.contains($0.id) }
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
        ReminderSchedulingJournal.enqueueTaskChanges(in: context)
        try context.save()
        guard publish else { return }
        visiblyChangedLists.subtract(lists.map(\.id))
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
        if let failure = SyncFailure.from(error) { lastOutcome.failures.append(failure) }
        lastOutcome.status = .partial
        if let dav = error as? CalDAVError {
            switch dav {
            case .unauthorized, .rateLimited: throw error
            default: break
            }
        }
    }

    /// A run's registered models can outlive account deletion during an await.
    /// Check the saved store before reading or saving those retained models.
    private func requireLiveAccount(_ accountID: String, container: ModelContainer) throws {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        let context = ModelContext(container)
        let predicate = #Predicate<ServerAccount> { $0.id == accountID }
        guard try context.fetchCount(FetchDescriptor(predicate: predicate)) == 1 else {
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
        lastMovePermissionDenied = false

        setState(.syncing)
        reportProgress(.init(accountID: accountID, listID: nil, stage: .discovering, completed: 0, total: nil))

        // Create a dedicated background context for all SwiftData work.
        // This is the fix for the 0x8BADF00D watchdog crash: heavy task
        // iteration no longer blocks the main thread.
        let bgContext = ModelContext(modelContainer)

        defer {
            // Keep SQL to direct fields; older runtimes cannot lower two optional joins.
            if let count = try? BackgroundRunBudget.protectingCurrent({
                let pending = #Predicate<TaskItem> { $0.isDirty || $0.isDeletedLocally }
                return try bgContext.fetch(FetchDescriptor(predicate: pending))
                    .filter { $0.taskList?.account?.id == accountID }.count
            }) { lastOutcome.pendingOutboundCount = count }
        }
        let targetID = accountID
        let accountPredicate = #Predicate<ServerAccount> { $0.id == targetID }
        var accountDescriptor = FetchDescriptor<ServerAccount>(
            predicate: accountPredicate
        )
        accountDescriptor.fetchLimit = 1
        guard let account = try bgContext.fetch(accountDescriptor).first else {
            setState(.idle)
            return false
        }

        var didImportInbound = false

        let authKey = authenticationKey(accountID: accountID, baseURL: serverBaseURL, username: credentials.username)
        await calDAVClient.setRunDeadline(Date().addingTimeInterval(900))
        do {
            if let deadline = deferredUntil[authKey], deadline > Date() { throw RetryDeferredError(deadline: deadline) }
            deferredUntil.removeValue(forKey: authKey)
            if credentialGate.shouldSkip(accountID: authKey, currentPassword: credentials.password) {
                throw CalDAVError.unauthorized
            }
            // Step 1: Discover calendars
            let principalPath = try await calDAVClient.discoverPrincipal(
                baseURL: serverBaseURL,
                credentials: credentials
            )
            try requireLiveAccount(accountID, container: modelContainer)

            let calendarHomePath = try await calDAVClient.discoverCalendarHome(
                baseURL: serverBaseURL,
                principalPath: principalPath,
                credentials: credentials
            )
            try requireLiveAccount(accountID, container: modelContainer)

            // Step 1.5: Push local-only lists to the server
            try await pushLocalLists(
                account: account,
                baseURL: serverBaseURL,
                calendarHomePath: calendarHomePath,
                credentials: credentials,
                modelContext: bgContext
            )

            try Task.checkCancellation()

            // Step 2: Re-discover to include freshly pushed calendars
            let discovered = try await calDAVClient.discoverTaskCalendars(
                baseURL: serverBaseURL,
                calendarHomePath: calendarHomePath,
                credentials: credentials
            )
            try requireLiveAccount(accountID, container: modelContainer)
            lastTrashedLists = discovered.trashed.map(TrashedList.init)

            // Step 3: Sync each calendar. `.live` only — a collection the server has thrown
            // away must not become a TaskList, or deleting and recreating a calendar leaves the
            // user with one row per corpse, all bearing the same name.
            for remoteCal in discovered.live {
                try requireLiveAccount(accountID, container: modelContainer)
                do {
                    if try await syncCalendar(remoteCal: remoteCal, account: account,
                        baseURL: serverBaseURL, credentials: credentials, modelContext: bgContext,
                        syncWindowMonths: syncWindowMonths) { didImportInbound = true }
                } catch {
                    guard Self.isDefinitiveCollectionDenial(error) else { throw error }
                    try recordOperationFailure(error)
                }
            }
            try await probeMissingPhotoLists(accountID: accountID,
                livePaths: Set(discovered.live.map(\.href)), baseURL: serverBaseURL,
                credentials: credentials, container: modelContainer)
            try requireLiveAccount(accountID, container: modelContainer)

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
                    removed += TaskListHelpers.cleanupDuplicateUIDs(
                        in: bgContext,
                        listID: list.id
                    )
                }
                if removed > 0 {
                    logger.warning("cleanupDuplicateUIDs removed \(removed) duplicate(s) — sync gate may have a gap")
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
            PendingMoveSweep.clearOrphans(in: bgContext)
            let movedOut = PendingMoveSweep.candidates(
                sourceListIDs: Set(account.taskLists.map(\.id)),
                in: bgContext
            )
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
                    onCommit: { self.publishExternalChange($0) },
                    onFailure: { error in
                        do { try self.recordOperationFailure(error) }
                        catch { self.pendingSweepFailure = error; throw error }
                    }) { href in
                    try await client.deleteTask(
                        baseURL: serverBaseURL,
                        taskPath: href,
                        etag: nil,
                        credentials: credentials
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
            if lastOutcome.failures.isEmpty { account.lastSyncDate = Date() }
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
                credentialGate.recordFailure(accountID: authKey, password: credentials.password)
            }
            if let deferred = error as? RetryDeferredError { deferredUntil[authKey] = deferred.deadline }
            if case CalDAVError.rateLimited(let wait) = error, let wait {
                deferredUntil[authKey] = Date().addingTimeInterval(wait)
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
                    try await performBackgroundSyncRun(accountID: accountID, serverBaseURL: serverBaseURL,
                        credentials: credentials, modelContainer: modelContainer,
                        syncWindowMonths: syncWindowMonths, reconcileNotifications: reconcileNotifications,
                        runBudget: budget)
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
        let bgContext = ModelContext(modelContainer)
        bgContext.autosaveEnabled = false

        defer {
            // Keep SQL to direct fields; older runtimes cannot lower two optional joins.
            if let count = try? BackgroundRunBudget.protectingCurrent({
                let pending = #Predicate<TaskItem> { $0.isDirty || $0.isDeletedLocally }
                return try bgContext.fetch(FetchDescriptor(predicate: pending))
                    .filter { $0.taskList?.account?.id == accountID }.count
            }) { lastOutcome.pendingOutboundCount = count }
        }
        let targetID = accountID
        let accountPredicate2 = #Predicate<ServerAccount> { $0.id == targetID }
        var accountDescriptor = FetchDescriptor<ServerAccount>(
            predicate: accountPredicate2
        )
        accountDescriptor.fetchLimit = 1
        guard let account = try BackgroundRunBudget.protectingCurrent({ try bgContext.fetch(accountDescriptor).first }) else {
            throw CancellationError()
        }

        let baseURL = serverBaseURL

        setState(.syncing)
        reportProgress(.init(accountID: accountID, listID: nil, stage: .discovering, completed: 0, total: nil))

        let authKey = authenticationKey(accountID: accountID, baseURL: serverBaseURL, username: credentials.username)
        do {
            if let deadline = deferredUntil[authKey], deadline > Date() { throw RetryDeferredError(deadline: deadline) }
            deferredUntil.removeValue(forKey: authKey)
            if credentialGate.shouldSkip(accountID: authKey, currentPassword: credentials.password) {
                throw CalDAVError.unauthorized
            }
            // Step 1: Discover calendars
            let principalPath = try await calDAVClient.discoverPrincipal(
                baseURL: baseURL,
                credentials: credentials
            )

            try requireLiveAccount(accountID, container: modelContainer)

            let calendarHomePath = try await calDAVClient.discoverCalendarHome(
                baseURL: baseURL,
                principalPath: principalPath,
                credentials: credentials
            )

            try requireLiveAccount(accountID, container: modelContainer)

            let discovered = try await calDAVClient.discoverTaskCalendars(
                baseURL: baseURL,
                calendarHomePath: calendarHomePath,
                credentials: credentials
            )
            try requireLiveAccount(accountID, container: modelContainer)
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
                guard let remoteCal = calendarsByPath[path] else { continue }
                try requireLiveAccount(accountID, container: modelContainer)
                try BackgroundSyncCursor.recordAttempt(id: path, scope: cursorScope, in: bgContext)

                let listID = try BackgroundRunBudget.protectingCurrent {
                    // Find or create local TaskList
                    let href = remoteCal.href
                    let lists = account.taskLists
                    let taskList: TaskList
                    if let existing = lists.first(where: { $0.serverURL == href }) {
                        let before = (existing.name, existing.colorHex, existing.isReadOnly)
                        existing.applyRemoteMetadata(
                            name: remoteCal.displayName,
                            colorHex: remoteCal.color
                        )
                        // Not behind `isMetadataDirty`: privileges are the server's, never a local edit.
                        if existing.isReadOnly != remoteCal.isReadOnly { existing.isReadOnly = remoteCal.isReadOnly }
                        if before != (existing.name, existing.colorHex, existing.isReadOnly) {
                            visiblyChangedLists.insert(existing.id)
                        }
                        taskList = existing
                    } else {
                        let newList = TaskList(
                            serverURL: href,
                            name: remoteCal.displayName.isEmpty
                                ? String(localized: "Tasks")
                                : remoteCal.displayName,
                            colorHex: remoteCal.color.isEmpty ? "#007AFF" : remoteCal.color
                        )
                        newList.account = account
                        newList.isReadOnly = remoteCal.isReadOnly
                        bgContext.insert(newList)
                        taskList = newList
                    }

                    try saveAndPublish(bgContext)
                    return taskList.id
                }
                if try await restorePhotoAccess(listID: listID, container: modelContainer) {
                    inboundChanged = true
                }
                try requireLiveAccount(accountID, container: modelContainer)
                let repair = Self.categoriesCatchUpPending(listID: listID)
                do {
                    if try await pullCalendarCheckingPhotoAccess(remoteCal: remoteCal, listID: listID,
                        accountID: accountID, baseURL: baseURL, credentials: credentials,
                        container: modelContainer, months: syncWindowMonths, repairCategories: repair) {
                        inboundChanged = true
                    }
                } catch {
                    guard Self.isDefinitiveCollectionDenial(error) else { throw error }
                    try recordOperationFailure(error)
                    continue
                }
                try requireLiveAccount(accountID, container: modelContainer)
                if repair { Self.markCategoriesCaughtUp(listID: listID) }

            }

            // Broad Files provisioning/status work, missing-list probes and global
            // cache pruning belong to foreground maintenance. Actual task pulls still
            // import photo metadata and confirm definitive access denial above.

            // Update last sync time
            try requireLiveAccount(accountID, container: modelContainer)
            try BackgroundRunBudget.protectingCurrent {
                if lastOutcome.failures.isEmpty { account.lastSyncDate = Date() }
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
                credentialGate.recordFailure(accountID: authKey, password: credentials.password)
            }
            if let deferred = error as? RetryDeferredError { deferredUntil[authKey] = deferred.deadline }
            if case CalDAVError.rateLimited(let wait) = error, let wait {
                deferredUntil[authKey] = Date().addingTimeInterval(wait)
            }
            lastOutcome.status = .partial
            if let failure = SyncFailure.from(error), !lastOutcome.failures.contains(failure) {
                lastOutcome.failures.append(failure)
            }
            setState(.error(error.localizedDescription))
            throw error
        }
    }

    /// Applies a single remote task to the local store. Not `@MainActor`-isolated.
    ///
    /// This is the background-safe equivalent of `processRemoteTask`.
    @discardableResult
    /// Every task in the list, by UID, for the pull to match the server against.
    ///
    /// **Deliberately includes tasks awaiting deletion.** They used to be
    /// filtered out, which made a task the user had just deleted invisible to
    /// this map — the server's copy then matched nothing, was inserted as a new
    /// row, and the pending DELETE removed the *original*. The task stayed in
    /// the list forever and was gone from the server.
    ///
    /// Being in the map is not permission to apply anything: both appliers
    /// refuse an `isDeletedLocally` task outright. Recognising it is what lets
    /// them refuse it.
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
        return importer.apply(try importer.parse(remoteTask), list: taskList, uidMap: &uidMap, movedAway: movedAway)
    }

    /// Applies parsed VTODO data onto a TaskItem. `nonisolated` so it can be
    /// called from `applyRemoteTask` without actor hops (it touches no actor state).
    nonisolated private func applyTodoDataBackground(
        _ data: ICalendarParser.VTODOData,
        to task: TaskItem,
        modelContext: ModelContext
    ) {
        applyTodoData(data, to: task, modelContext: modelContext)
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
        baseURL: String,
        credentials: CalDAVClient.Credentials,
        modelContext: ModelContext,
        syncWindowMonths: Int = 0
    ) async throws -> Bool {
        // Find or create local TaskList
        let taskList = findOrCreateTaskList(
            for: remoteCal,
            account: account,
            modelContext: modelContext
        )

        let expectedListID = taskList.id
        let expectedAccountID = account.id
        try saveAndPublish(modelContext)
        let restoredPhotoAccess = try await restorePhotoAccess(listID: expectedListID,
            container: modelContext.container)
        try requireLiveAccount(expectedAccountID, container: modelContext.container)

        // Owed once per list, and it has nothing to read without a pull — so it
        // overrides the CTag skip below. See `catchUpCategories`.
        let owesCategoriesCatchUp = Self.categoriesCatchUpPending(listID: taskList.id)
        let hierarchyKey = SyncImportCheckpoint.identity(accountID: account.id, listID: taskList.id,
            baseURL: baseURL, username: credentials.username, months: syncWindowMonths)
        let owesHierarchyResolution = try SyncImportCheckpoint.hierarchyPending(id: hierarchyKey, in: modelContext)

        // CTag delta check: skip the expensive full pull when nothing changed
        // on the server AND a full pull happened recently. The recency bound
        // (see `shouldSkipPull`) ensures a stale/cached `getctag` can never
        // silently suppress server changes. Still push local dirty/deleted tasks.
        if !restoredPhotoAccess, !remoteCal.supportsSyncCollection, !owesCategoriesCatchUp, !owesHierarchyResolution, Self.shouldSkipPull(
            localCTag: taskList.syncCTag,
            remoteCTag: remoteCal.ctag,
            lastFullPull: taskList.lastFullPullDate,
            now: Date(),
            maxSkipInterval: Self.maxPullSkipInterval
        ) {
            logger.debug("CTag unchanged for \(remoteCal.displayName), skipping pull")
            let photosChanged = try await synchronizePhotos(listID: expectedListID,
                accountID: expectedAccountID, baseURL: baseURL, credentials: credentials,
                container: modelContext.container)
            try requireLiveAccount(expectedAccountID, container: modelContext.container)

            // Push local dirty tasks even when server hasn't changed (with per-task error isolation)
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
                        deletedTask,
                        calendarPath: remoteCal.href,
                        baseURL: baseURL,
                        credentials: credentials,
                        modelContext: modelContext
                    )
                } catch {
                    try requireLiveAccount(expectedAccountID, container: modelContext.container)
                    try recordOperationFailure(error)
                    logger.error("Failed to push deletion '\(deletedTask.title)': \(error.localizedDescription)")
                }
                try requireLiveAccount(expectedAccountID, container: modelContext.container)
            }

            try saveAndPublish(modelContext)
            return photosChanged
        }

        // Tracks whether the inbound pull actually changed local data, so the
        // UI is only forced to re-query when the server delivered something new.
        var inboundChanged = false

        inboundChanged = try await pullCalendarCheckingPhotoAccess(remoteCal: remoteCal, listID: taskList.id,
            accountID: account.id, baseURL: baseURL, credentials: credentials,
            container: modelContext.container, months: syncWindowMonths,
            repairCategories: owesCategoriesCatchUp)
        try requireLiveAccount(expectedAccountID, container: modelContext.container)

        let photosChanged = try await synchronizePhotos(listID: expectedListID,
            accountID: expectedAccountID, baseURL: baseURL, credentials: credentials,
            container: modelContext.container)
        try requireLiveAccount(expectedAccountID, container: modelContext.container)
        inboundChanged = inboundChanged || photosChanged || restoredPhotoAccess

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
                    deletedTask,
                    calendarPath: remoteCal.href,
                    baseURL: baseURL,
                    credentials: credentials,
                    modelContext: modelContext
                )
            } catch {
                try requireLiveAccount(expectedAccountID, container: modelContext.container)
                try recordOperationFailure(error)
                logger.error("Failed to push deletion '\(deletedTask.title)': \(error.localizedDescription)")
            }
            try requireLiveAccount(expectedAccountID, container: modelContext.container)
        }

        let listID = taskList.id
        let metadataContext = ModelContext(modelContext.container)
        metadataContext.autosaveEnabled = false
        let listPredicate = #Predicate<TaskList> { $0.id == listID }
        if let currentList = try metadataContext.fetch(FetchDescriptor(predicate: listPredicate)).first {
            currentList.lastFullPullDate = Date()
            currentList.syncCTag = (!dirtyTasks.isEmpty || !deletedTasks.isEmpty) ? nil : remoteCal.ctag
            try metadataContext.save()
        }
        // Recorded only once what it added is saved; a pass that threw is still owed.
        if owesCategoriesCatchUp {
            Self.markCategoriesCaughtUp(listID: taskList.id)
        }
        return inboundChanged
    }

    /// Shared bounded bootstrap/delta path. No full-body array survives between batches.
    private func pullCalendar(remoteCal: CalDAVClient.RemoteCalendar, listID: String, accountID: String,
        baseURL: String, credentials: CalDAVClient.Credentials, container: ModelContainer,
        months: Int, repairCategories: Bool) async throws -> Bool {
        let scope = SyncCollectionPuller.Scope(accountID: accountID, listID: listID, historyScope: String(months))
        let key = SyncImportCheckpoint.identity(accountID: accountID, listID: listID,
            baseURL: baseURL, username: credentials.username, months: months)
        let (checkpoint, knownETags, repair) = try BackgroundRunBudget.protectingCurrent {
            try SyncImportCheckpoint.pruneOtherScopes(accountID: accountID, listID: listID, keeping: key, container: container)
            let read = ModelContext(container)
            let checkpoint = try SyncImportCheckpoint.read(id: key, scope: scope, in: read)
            let id = listID
            let local = try read.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.taskList?.id == id }))
            var knownETags = try SyncImportCheckpoint.accountedETags(id: key, container: container)
            for task in local {
                if let href = task.remoteHref {
                    // A nil ETag is an explicit invalidation after a refused move rollback.
                    if task.etag == nil { knownETags.removeValue(forKey: href) }
                    else if let etag = task.etag, !task.isDirty || knownETags[href] == nil { knownETags[href] = etag }
                }
            }
            let repair = repairCategories && !local.isEmpty
            if repairCategories && local.isEmpty { Self.markCategoriesCaughtUp(listID: listID) }
            return (checkpoint, knownETags, repair)
        }
        let cache = ICalendarParser.FormatterCache()
        let accountedHrefs = Set(knownETags.keys)
        let writer = await SyncInboundBatchWriter(container: container, listID: listID, expectedAccountID: accountID,
            checkpointID: key, needsParentResolution: checkpoint?.hasCompletedBaseline != true)
        let puller = SyncCollectionPuller(client: calDAVClient)
        let before = lastOutcome.importedCount + lastOutcome.updatedCount + lastOutcome.deletedCount
        _ = try await puller.pull(baseURL: baseURL, calendar: remoteCal, credentials: credentials,
            scope: scope, checkpoint: checkpoint, knownETags: knownETags,
            forceIntegrity: repair, forceBodies: repair,
            callbacks: .init(
                progress: { [self] stage, completed, total in
                    await self.reportProgress(.init(accountID: accountID, listID: listID, stage: stage, completed: completed, total: total))
                },
                applyBodies: { [self] bodies in
                    try await self.applyPullBodies(bodies, writer: writer, months: months, repairCategories: repair, cache: cache)
                    try await self.markPullBodiesAccounted(bodies, id: key, scope: scope, container: container)
                },
                deleteExplicit: { [self] hrefs in
                    try await writer.deleteExplicit(hrefs, onCommit: { await self.publishBatch($0) })
                    try await self.removePullReceipts(hrefs, id: key, scope: scope, container: container)
                },
                reconcileCompleteManifest: { [self] manifest in
                    try await writer.resolveParents(onCommit: { await self.publishBatch($0) })
                    try await writer.reconcileManifest(manifest, onCommit: { await self.publishBatch($0) })
                    let present = Set(manifest.map(\.href))
                    try await self.removePullReceipts(Array(accountedHrefs.subtracting(present)), id: key, scope: scope, container: container)
                },
                commitCheckpoint: { [self] checkpoint in
                    // Delta pages need parent wiring as well, before their token is durable.
                    try await writer.resolveParents(onCommit: { await self.publishBatch($0) })
                    try await self.commitPullCheckpoint(checkpoint, id: key, path: remoteCal.href, container: container)
                }))
        // An unchanged CTag returns without a checkpoint callback. Durable
        // local parent work still needs to drain and announce its committed IDs.
        try await writer.resolveParents(onCommit: { await self.publishBatch($0) })
        return before != lastOutcome.importedCount + lastOutcome.updatedCount + lastOutcome.deletedCount
    }

    private func applyPullBodies(_ bodies: [CalDAVClient.RemoteTask], writer: SyncInboundBatchWriter,
                                 months: Int, repairCategories: Bool, cache: ICalendarParser.FormatterCache) async throws {
        try Task.checkCancellation()
        let parsed = try bodies.map { resource in
            try SyncBodyValidation.parse(resource, using: cache)
        }
        if let commit = try await writer.apply(parsed, months: months, repairCategories: repairCategories) {
            publishBatch(commit)
        }
    }

    private func markPullBodiesAccounted(_ resources: [CalDAVClient.RemoteTask], id: String,
        scope: SyncCollectionPuller.Scope, container: ModelContainer) async throws {
        try Task.checkCancellation()
        try await MainActor.run {
            try BackgroundRunBudget.protectingCurrent {
                try Self.requireLiveScope(scope, container: container)
                try SyncImportCheckpoint.markAccounted(resources, id: id, container: container)
            }
        }
    }
    private func removePullReceipts(_ hrefs: [String], id: String,
        scope: SyncCollectionPuller.Scope, container: ModelContainer) async throws {
        try Task.checkCancellation()
        for start in stride(from: 0, to: hrefs.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(hrefs[start..<min(start + 100, hrefs.count)])
            try await MainActor.run {
                try BackgroundRunBudget.protectingCurrent {
                    try Self.requireLiveScope(scope, container: container)
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
                                     path: String, container: ModelContainer) async throws {
        try Task.checkCancellation()
        try await MainActor.run {
            try BackgroundRunBudget.protectingCurrent {
                try Self.requireLiveScope(checkpoint.scope, container: container)
                try SyncImportCheckpoint.commit(checkpoint, id: id, collectionPath: path, container: container)
            }
        }
    }

    @MainActor private static func requireLiveScope(_ scope: SyncCollectionPuller.Scope, container: ModelContainer) throws {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        let context = ModelContext(container)
        let listID = scope.listID; let accountID = scope.accountID
        let predicate = #Predicate<TaskList> { $0.id == listID && $0.account?.id == accountID }
        guard try context.fetchCount(FetchDescriptor(predicate: predicate)) == 1 else { throw CancellationError() }
    }

    // MARK: - Pull (Remote → Local)

    /// Processes a single remote task: creates or updates the local TaskItem.
    ///
    /// Uses a pre-built UID map for O(1) lookups instead of per-task SwiftData queries.
    /// `nonisolated` to mirror its background twin `applyRemoteTask`, which
    /// always was. Neither touches actor state — both work entirely on the
    /// `ModelContext` handed to them, and `logger` is a `let`. Being isolated for
    /// no reason meant the foreground path could not be driven from a test,
    /// because an `inout` map cannot cross an actor boundary.
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

    /// Applies parsed VTODO data onto a TaskItem model.
    ///
    /// `nonisolated` for the same reason as `processRemoteTask`, its only caller
    /// besides the conflict-resolution path: pure field assignment on a context
    /// it is given.
    nonisolated private func applyTodoData(
        _ data: ICalendarParser.VTODOData,
        to task: TaskItem,
        modelContext: ModelContext
    ) {
        if let importer = try? SyncImportStore(context: modelContext) { importer.applyFields(data, to: task) }
    }

    /// Applies the server's `CATEGORIES` to a task's tags.
    ///
    /// Shared by both apply paths, and `nonisolated` because the background pull
    /// runs on its own `ModelContext`.
    ///
    /// **Absent is not empty.** `nil` means the VTODO carried no `CATEGORIES`
    /// property, which every client that has never heard of it also does — it is
    /// silence, not an instruction, and adopting it as "no tags" deletes the
    /// user's tags here and then pushes that deletion to the server. `[]` means
    /// the server said the task has none, which *is* an instruction. This is the
    /// same reasoning `applyTodoData` already applies to `X-APPLE-SORT-ORDER`.
    ///
    /// Tags are matched through ``Tag/matching(_:in:)`` rather than by string
    /// equality, so an inbound `work` finds the user's existing `Work` instead of
    /// minting a second tag that the next push would send back as a duplicate
    /// category.
    /// Removes local tasks the server no longer has. Returns whether it removed
    /// any, so the caller can tell the UI to refresh.
    ///
    /// Must run **after** `resolveParentRelationships`: the rule that spares a
    /// parent whose subtask the server still holds reads `subtasks`, and that
    /// relationship is only populated once the pass has resolved `parentUID`.
    /// Called before an unreadable fetch can matter — `remoteUIDSet` returning
    /// `nil` abandons the reconciliation rather than proceeding on a short set.
    @discardableResult
    nonisolated private func reconcileServerDeletions(
        remoteTasks: [CalDAVClient.RemoteTask],
        uidMap: [String: TaskItem],
        modelContext: ModelContext,
        parsedTasks: [ParsedRemoteTask]? = nil
    ) -> Bool {
        let accountedUIDs: Set<String>?
        if let parsedTasks {
            accountedUIDs = parsedTasks.allSatisfy { $0.todo != nil }
                ? Set(parsedTasks.compactMap { $0.todo?.uid }) : nil
        } else { accountedUIDs = Self.remoteUIDSet(remoteTasks) }
        guard let remoteUIDs = accountedUIDs else {
            logger.error("Skipping deletion reconciliation: a fetched resource had no readable UID")
            return false
        }
        let doomed = Self.tasksDeletedOnServer(local: Array(uidMap.values), remoteUIDs: remoteUIDs)
        guard !doomed.isEmpty else { return false }
        for task in doomed {
            modelContext.delete(task)
        }
        return true
    }

    /// The UID of every fetched VTODO, or `nil` if any one of them could not be
    /// read.
    ///
    /// All-or-nothing on purpose. `tasksDeletedOnServer` treats "not in this
    /// set" as "deleted on the server", so a set short by one entry deletes the
    /// task that entry named. A resource we cannot read a UID from is a reason
    /// to abandon the reconciliation, not to proceed without it.
    ///
    /// Unfolds first. RFC 5545 folds lines past 75 octets and Nextcloud emits
    /// folded UIDs for the long ones it generates, so reading raw lines would
    /// silently truncate exactly those and delete their local counterparts.
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

    /// The local tasks the server no longer has, deepest first.
    ///
    /// The pull could add and update but never delete, so a task removed in the
    /// Nextcloud web UI stayed here forever, holding an etag and an href for a
    /// resource that 404s.
    ///
    /// **This is the one reconciliation that destroys data**, and it acts on an
    /// absence — which is also what a short read, a filtered fetch and a
    /// half-finished request look like. So it is written as refusals, and
    /// `remoteUIDs` must be the **whole** fetched set. `fetchAllTasks` issues a
    /// `calendar-query` for every VTODO with no time-range, so that set is
    /// complete; `filterCompletedByWindow` narrows only what gets *applied*.
    /// Passing the filtered subset here would delete the user's older completed
    /// history on the first run.
    ///
    /// Kept, never deleted:
    ///
    /// - A task with no `remoteHref`, or `isLocalOnly` — absent because it has
    ///   not been pushed, not because it was deleted.
    /// - A dirty task. The push that follows re-creates it on the server;
    ///   deleting it would discard the user's edit to win a race against our
    ///   own upload.
    /// - A task already flagged `isDeletedLocally`, which the deletion push
    ///   still owes the server a DELETE for.
    /// - A parent while the server still has any of its subtasks, because the
    ///   local delete cascades and would take a live child with it.
    /// - Everything, when `remoteUIDs` is empty. An empty fetch and a list the
    ///   user emptied are indistinguishable and want opposite handling. This
    ///   refuses on purpose: a genuinely emptied list stays until the user
    ///   clears it here too, which is the recoverable failure.
    ///
    /// Deepest first so each delete removes a leaf and no delete lands on a row
    /// an earlier cascade already removed.
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

    nonisolated private func applyCategories(
        _ categories: [String]?,
        to task: TaskItem,
        modelContext: ModelContext
    ) {
        guard let categories else { return }

        var known = (try? modelContext.fetch(FetchDescriptor<Tag>())) ?? []
        var resolved: [Tag] = []
        for name in categories {
            let tag = resolveTag(named: name, known: &known, modelContext: modelContext)
            // A VTODO may legally repeat a category, and two spellings of one
            // name resolve to the same tag.
            if !resolved.contains(where: { $0.id == tag.id }) {
                resolved.append(tag)
            }
        }
        // Assign rather than merge: a tag the server no longer lists has been
        // taken off the task. It is removed from the task only — the tag itself
        // stays in the user's sidebar and on whatever else carries it.
        task.tags = resolved
    }

    /// The tag `name` means among `known`, or a new one — inserted, and added to
    /// `known` so a later name in the same pass finds it. Shared by both category
    /// passes because they must agree on it; see ``Tag/matching(_:in:)``.
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
    /// `applyCategories` runs only when a task's etag changes, and every task
    /// pulled before categories were applied still carries that pull's etag. The
    /// gate calls it unchanged, so its categories are never read — and the first
    /// upload of it writes the empty tag set over them. This pass reads them
    /// regardless of the etag.
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

    /// Whether ``catchUpCategories(remoteTasks:uidMap:modelContext:)`` is still
    /// owed to a list. Keyed by the local `TaskList.id` rather than the href,
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

    private func restorePhotoAccess(listID: String, container: ModelContainer) async throws -> Bool {
        guard let change = try await TaskPhotoAccessMaintenance.restore(listID: listID,
            container: container) else { return false }
        publishExternalChange(change)
        return true
    }

    /// Discovery omission is ambiguous. Only a full collection probe can revoke access.
    private func probeMissingPhotoLists(accountID: String, livePaths: Set<String>, baseURL: String,
        credentials: CalDAVClient.Credentials, container: ModelContainer) async throws {
        let candidates = try await MainActor.run { () throws -> [(String, String)] in
            let context = ModelContext(container)
            let lists = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate {
                $0.account?.id == accountID
            }))
            var candidates: [(String, String)] = []
            for list in lists where !livePaths.contains(list.serverURL) && !list.serverURL.isEmpty {
                let id = list.id
                var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.taskList?.id == id })
                descriptor.relationshipKeyPathsForPrefetching = [\.photos]
                let hasPhotos = try context.fetch(descriptor).contains { !$0.photos.isEmpty }
                if list.photoAccessRevoked == true || hasPhotos { candidates.append((id, list.serverURL)) }
            }
            return candidates
        }
        for (listID, path) in candidates {
            try Task.checkCancellation()
            do {
                _ = try await calDAVClient.fetchTaskManifest(baseURL: baseURL,
                    calendarPath: path, credentials: credentials)
                _ = try await restorePhotoAccess(listID: listID, container: container)
            } catch {
                if Self.isDefinitiveCollectionDenial(error),
                   let change = try await TaskPhotoAccessMaintenance.revoke(listID: listID, container: container) {
                    publishExternalChange(change)
                }
                try recordOperationFailure(error)
            }
        }
    }

    /// A failed multiget/resource read is not proof of collection denial. Confirm with
    /// a collection REPORT before removing previews or cached originals.
    private func pullCalendarCheckingPhotoAccess(remoteCal: CalDAVClient.RemoteCalendar,
        listID: String, accountID: String, baseURL: String, credentials: CalDAVClient.Credentials,
        container: ModelContainer, months: Int, repairCategories: Bool) async throws -> Bool {
        do {
            return try await pullCalendar(remoteCal: remoteCal, listID: listID, accountID: accountID,
                baseURL: baseURL, credentials: credentials, container: container, months: months,
                repairCategories: repairCategories)
        } catch {
            guard Self.isDefinitiveCollectionDenial(error) else { throw error }
            do {
                _ = try await calDAVClient.fetchTaskManifest(baseURL: baseURL,
                    calendarPath: remoteCal.href, credentials: credentials)
            } catch {
                if Self.isDefinitiveCollectionDenial(error),
                   let change = try await TaskPhotoAccessMaintenance.revoke(listID: listID, container: container) {
                    publishExternalChange(change)
                }
                throw error
            }
            throw error
        }
    }

    /// TaskPhotoSync owns its no-original snapshot gate; an ordinary list adds no HTTP.
    private func synchronizePhotos(listID: String, accountID: String, baseURL: String,
        credentials: CalDAVClient.Credentials, container: ModelContainer,
        uploadOriginals: Bool = true, deadline: Date? = nil) async throws -> Bool {
        do {
            let changed = try await taskPhotoSync.synchronize(listID: listID,
                access: PhotoServerAccess(baseURL: baseURL, username: credentials.username,
                    password: credentials.password), container: container,
                uploadOriginals: uploadOriginals, deadline: deadline)
            guard !changed.isEmpty else { return false }
            publishExternalChange(SyncChange(revision: 0, accountIDs: [accountID], listIDs: [listID],
                changedIDs: changed, deletedIDs: [], kind: .tasks))
            return true
        } catch {
            try recordOperationFailure(error)
            return false
        }
    }

    // MARK: - Push (Local → Remote)

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
        if let request = try await TaskPhotoLegacyCatchUp.requestInfo(taskID: taskID,
            listID: expectedListID, accountID: expectedAccountID, container: container) {
            let access = PhotoServerAccess(baseURL: baseURL, username: credentials.username,
                password: credentials.password)
            let sourceAccess = request.sourceListID == nil ? access :
                try await TaskPhotoSync.sourceAccess(accountID: request.sourceAccountID,
                    fallback: access, container: container)
            let resource = try await calDAVClient.fetchTask(baseURL: sourceAccess.baseURL,
                taskPath: request.href, credentials: .init(username: sourceAccess.username,
                    password: sourceAccess.password))
            guard let todo = try ICalendarParser.parseSingleVTODO(from: resource.icsData) else {
                throw CalDAVError.invalidResponse
            }
            if let change = try await TaskPhotoLegacyCatchUp.apply(todo, taskID: taskID,
                listID: expectedListID, accountID: expectedAccountID, href: request.href,
                container: container, expectedRequest: request) {
                publishExternalChange(change)
            }
        }
        guard let snapshot = try await MainActor.run(body: {
            try SyncPushAcknowledgement.snapshot(taskID: taskID, calendarPath: calendarPath, container: container, expectedListID: expectedListID, expectedAccountID: expectedAccountID)
        }) else { return }
        let icsData = snapshot.payload
        let taskPath = snapshot.path

        do {
            let newEtag = try await calDAVClient.putTask(
                baseURL: baseURL, taskPath: taskPath, icsData: icsData,
                etag: snapshot.etag, credentials: credentials)
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
                let parsed = ParsedRemoteTask(href: refreshed.href, etag: refreshed.etag,
                    todo: try ICalendarParser.parseSingleVTODO(from: refreshed.icsData))
                let change = try await MainActor.run {
                    try SyncPushAcknowledgement.applyConflict(snapshot, resource: parsed, container: container)
                }
                publishExternalChange(change)
                // Only pending photo operations leave the rebased task dirty. A fresh
                // guarded snapshot therefore preserves title-only server-wins behavior.
                if let retry = try await SyncPushAcknowledgement.snapshot(taskID: taskID,
                    calendarPath: calendarPath, container: container,
                    expectedListID: expectedListID, expectedAccountID: expectedAccountID) {
                    let etag = try await calDAVClient.putTask(baseURL: baseURL, taskPath: retry.path,
                        icsData: retry.payload, etag: retry.etag, credentials: credentials)
                    try await SyncPushAcknowledgement.acknowledge(retry, etag: etag, container: container)
                }
            case .localWins:
                // Retry PUT without If-Match (force overwrite)
                let newEtag = try await calDAVClient.putTask(
                    baseURL: baseURL,
                    taskPath: taskPath,
                    icsData: icsData,
                    etag: nil,
                    credentials: credentials
                )
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
        _ task: TaskItem,
        calendarPath: String,
        baseURL: String,
        credentials: CalDAVClient.Credentials,
        modelContext: ModelContext
    ) async throws {
        let taskID = task.id
        let container = modelContext.container
        guard let snapshot = try await SyncPushAcknowledgement.deletionSnapshot(taskID: taskID, container: container) else { return }
        if let href = snapshot.href, !href.isEmpty {
            try await calDAVClient.deleteTask(baseURL: baseURL, taskPath: href, etag: snapshot.etag, credentials: credentials)
        }
        try Task.checkCancellation()
        if let change = try await SyncPushAcknowledgement.acknowledgeDeletion(snapshot, container: container) {
            publishExternalChange(change)
        }
    }

    // MARK: - Serialization

    /// Serializes a TaskItem to an .ics string for PUT.
    private func serializeTask(_ task: TaskItem) -> String {
        return ICalendarSerializer.serialize(
            uid: task.uid,
            summary: task.title,
            description: task.notes.isEmpty ? nil : task.notes,
            status: task.status.rawValue,
            priority: task.priorityRaw,
            percentComplete: task.percentComplete,
            dueDate: task.dueDate,
            startDate: task.startDate,
            completedDate: task.completedDate,
            createdDate: task.createdDate,
            lastModifiedDate: task.lastModifiedDate ?? Date(),
            categories: task.tags.compactMap { $0.name },
            location: task.location,
            latitude: task.latitude,
            longitude: task.longitude,
            url: task.url,
            parentUID: task.parentUID,
            recurrenceRule: task.recurrenceRule,
            alarmTriggerSeconds: task.reminderOffset,
            isDueDateOnly: task.isDueDateOnly,
            isStartDateOnly: task.isStartDateOnly,
            manualSortOrder: task.effectiveSortOrder,
            photos: task.photoAttachments,
            opaqueAttachments: task.opaqueAttachments
        )
    }

    // MARK: - Queries

    /// Finds or creates a local TaskList matching a remote calendar.
    private func findOrCreateTaskList(
        for remoteCal: CalDAVClient.RemoteCalendar,
        account: ServerAccount,
        modelContext: ModelContext
    ) -> TaskList {
        let href = remoteCal.href
        let lists = account.taskLists

        if let existing = lists.first(where: { $0.serverURL == href }) {
            let before = (existing.name, existing.colorHex, existing.isReadOnly)
            existing.applyRemoteMetadata(name: remoteCal.displayName, colorHex: remoteCal.color)
            if existing.isReadOnly != remoteCal.isReadOnly { existing.isReadOnly = remoteCal.isReadOnly }
            if before != (existing.name, existing.colorHex, existing.isReadOnly) {
                visiblyChangedLists.insert(existing.id)
            }
            return existing
        }

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

    /// Pushes local-only task lists to the server via `MKCALENDAR`.
    ///
    /// Lists with an empty `serverURL` were created locally on the device
    /// and need to be created on the remote CalDAV server. After creation,
    /// their `serverURL` is updated to match the remote href so subsequent
    /// syncs correctly associate them.
    private func pushLocalLists(
        account: ServerAccount,
        baseURL: String,
        calendarHomePath: String,
        credentials: CalDAVClient.Credentials,
        modelContext: ModelContext
    ) async throws {
        let accountID = account.id
        let localOnlyLists = account.taskLists.filter { $0.serverURL.isEmpty }

        for list in localOnlyLists {
            do {
                let remoteHref = try await calDAVClient.createCalendar(
                    baseURL: baseURL,
                    calendarHomePath: calendarHomePath,
                    name: list.name,
                    color: list.colorHex,
                    credentials: credentials
                )
                try requireLiveAccount(accountID, container: modelContext.container)
                list.serverURL = remoteHref
                list.isMetadataDirty = false
                try saveAndPublish(modelContext, publish: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try requireLiveAccount(accountID, container: modelContext.container)
                // Log but don't fail the whole sync for one list
                logger.error("Failed to push list '\(list.name)': \(error.localizedDescription)")
            }
        }

        // Lists already on the server whose name or colour was edited on this device. This
        // has to run before Step 2 re-discovers them, or the PROPFIND that follows reads the
        // server's older copy back over the edit. A failure here leaves `isMetadataDirty`
        // set, which is also what stops discovery adopting over it until the push lands.
        let editedLists = account.taskLists.filter { !$0.serverURL.isEmpty && $0.isMetadataDirty }

        for list in editedLists {
            do {
                try await calDAVClient.updateCalendarProperties(
                    baseURL: baseURL,
                    calendarPath: list.serverURL,
                    name: list.name,
                    colorHex: list.colorHex,
                    credentials: credentials
                )
                try requireLiveAccount(accountID, container: modelContext.container)
                list.isMetadataDirty = false
                try saveAndPublish(modelContext, publish: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try requireLiveAccount(accountID, container: modelContext.container)
                logger.error(
                    "Failed to push list metadata '\(list.name)': \(error.localizedDescription)"
                )
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
    /// The order is part of the contract, not a detail. `pushDeletion` hard-
    /// deletes each task once its DELETE succeeds, and that hard delete cascades
    /// to the task's children — so pushing a parent first removes its children
    /// from the context before their own DELETEs are sent, leaving them on the
    /// server exactly as the original bug did. Deepest first means every DELETE
    /// that goes out belongs to a row with nothing left underneath it.
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

    // MARK: - Parent Resolution

    /// Resolves `parentUID` strings into actual SwiftData `parentTask` relationships.
    ///
    /// After all tasks are fetched from the server, each task's `parentUID` (the CalDAV
    /// `RELATED-TO;RELTYPE=PARENT` UID) is matched against other tasks in the same list
    /// to build the `parentTask`/`subtasks` hierarchy.
    private func resolveParentRelationships(
        for taskList: TaskList,
        modelContext: ModelContext
    ) throws {
        // Use explicit FetchDescriptor instead of taskList.tasks relationship,
        // which can be stale/unfaulted in background contexts.
        let listID = taskList.id
        let predicate = #Predicate<TaskItem> {
            $0.taskList?.id == listID && !$0.isDeletedLocally
        }
        let allTasks = (try? modelContext.fetch(FetchDescriptor<TaskItem>(predicate: predicate))) ?? []

        // Build a UID → TaskItem lookup for O(1) parent resolution
        var uidMap: [String: TaskItem] = [:]
        for task in allTasks {
            uidMap[task.uid] = task
        }

        let rawParents = Dictionary(allTasks.map { ($0.uid, $0.parentUID) }, uniquingKeysWith: { _, latest in latest })
        let validParents = HierarchyResolver.resolvedParents(rawParents)
        for task in allTasks {
            let parent = validParents[task.uid].flatMap { uidMap[$0] }
            if task.parentTask !== parent { task.parentTask = parent }
            // Keep parentUID unchanged so missing/cyclic source links remain recoverable.
        }
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

    // MARK: - Pull-Skip Decision

    /// The longest a matching CTag may suppress a full pull before one is forced
    /// regardless. Bounds the CTag optimization so a stale/cached `getctag` can
    /// never silently blind the device to server changes indefinitely.
    static let maxPullSkipInterval: TimeInterval = 600 // 10 minutes

    /// Decides whether the inbound pull may be skipped for a calendar.
    ///
    /// The CTag delta check is only a *bandwidth* optimization, so it must never
    /// be the reason server data goes missing. A pull is skipped **only** when
    /// the stored CTag is present, equals the freshly-fetched server CTag, AND a
    /// full pull completed within `maxSkipInterval`. Any other case (no/empty
    /// CTag, differing CTags, no prior full pull, or a stale one) forces a pull.
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

    static func shouldSkipPull(
        localCTag: String?,
        remoteCTag: String,
        lastFullPull: Date?,
        now: Date,
        maxSkipInterval: TimeInterval
    ) -> Bool {
        guard let localCTag, !localCTag.isEmpty, localCTag == remoteCTag else {
            return false // ctags differ / missing → pull
        }
        guard let lastFullPull else {
            return false // never completed a full pull → pull
        }
        // A backward clock jump (NTP correction, manual change) makes the elapsed
        // interval negative; treat that as "stale" and pull, so a clock change can
        // never wedge the skip optimization into suppressing server changes.
        let elapsed = now.timeIntervalSince(lastFullPull)
        return elapsed >= 0 && elapsed < maxSkipInterval
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

    /// Test-accessible wrapper for `processRemoteTask`, the foreground twin of
    /// `applyRemoteTask`. Actor-isolated, so unlike `testApplyRemoteTask` this
    /// one is `async`.
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

