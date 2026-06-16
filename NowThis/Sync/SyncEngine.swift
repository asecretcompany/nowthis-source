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
/// All SwiftData operations happen on the `@MainActor` to satisfy
/// `ModelContext` requirements. Network operations are dispatched
/// to the `CalDAVClient` actor.
actor SyncEngine {

    // MARK: - State

    enum SyncState: Sendable {
        case idle
        case syncing
        case error(String)
    }

    private(set) var state: SyncState = .idle

    /// True while either `performFullSync` or `performBackgroundSync` is executing.
    /// Used as a process-wide sync gate to prevent concurrent syncs from
    /// creating duplicate tasks.
    private var isRunning = false

    /// Public read accessor for the sync gate. Used by tests and
    /// `BackgroundSyncManager` to check if a sync is in progress.
    var isSyncInProgress: Bool { isRunning }

    private let calDAVClient: CalDAVClient
    private let logger = Logger(subsystem: "com.nowthis", category: "sync-engine")

    init(calDAVClient: CalDAVClient = CalDAVClient()) {
        self.calDAVClient = calDAVClient
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
    func performFullSync(
        accountID: String,
        serverBaseURL: String,
        credentials: CalDAVClient.Credentials,
        modelContainer: ModelContainer,
        syncWindowMonths: Int = 0
    ) async throws {
        guard !isRunning else {
            logger.info("Sync already in progress, skipping full sync")
            return
        }
        isRunning = true
        defer { isRunning = false }

        setState(.syncing)

        // Create a dedicated background context for all SwiftData work.
        // This is the fix for the 0x8BADF00D watchdog crash: heavy task
        // iteration no longer blocks the main thread.
        let bgContext = ModelContext(modelContainer)

        let targetID = accountID
        let accountPredicate = #Predicate<ServerAccount> { $0.id == targetID }
        var accountDescriptor = FetchDescriptor<ServerAccount>(
            predicate: accountPredicate
        )
        accountDescriptor.fetchLimit = 1
        guard let account = try bgContext.fetch(accountDescriptor).first else {
            setState(.idle)
            return
        }

        do {
            // Step 1: Discover calendars
            let principalPath = try await calDAVClient.discoverPrincipal(
                baseURL: serverBaseURL,
                credentials: credentials
            )

            let calendarHomePath = try await calDAVClient.discoverCalendarHome(
                baseURL: serverBaseURL,
                principalPath: principalPath,
                credentials: credentials
            )

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
            let updatedCalendars = try await calDAVClient.discoverTaskCalendars(
                baseURL: serverBaseURL,
                calendarHomePath: calendarHomePath,
                credentials: credentials
            )

            // Step 3: Sync each calendar
            for remoteCal in updatedCalendars {
                try Task.checkCancellation()
                try await syncCalendar(
                    remoteCal: remoteCal,
                    account: account,
                    baseURL: serverBaseURL,
                    credentials: credentials,
                    modelContext: bgContext,
                    syncWindowMonths: syncWindowMonths
                )
            }

            // Clean up any duplicate TaskItems that accumulated from prior syncs
            let removed = TaskListHelpers.cleanupDuplicateUIDs(in: bgContext)
            if removed > 0 {
                logger.warning("cleanupDuplicateUIDs removed \(removed) duplicate(s) — sync gate may have a gap")
            }

            // Update last sync time
            account.lastSyncDate = Date()
            try bgContext.save()

            // Refresh local notifications and badge on the main thread
            await MainActor.run {
                let mainContext = modelContainer.mainContext
                Task { @MainActor in
                    await ReminderScheduler.refreshAllReminders(modelContext: mainContext)
                    await ReminderScheduler.updateBadgeCount(modelContext: mainContext)
                }
            }

            setState(.idle)

        } catch is CancellationError {
            setState(.idle)
        } catch {
            let message = error.localizedDescription
            setState(.error(message))
            await MainActor.run { ErrorState.shared.show("Sync failed: \(message)") }
            throw error
        }
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
        syncWindowMonths: Int = 0
    ) async throws {
        guard !isRunning else {
            logger.info("Sync already in progress, skipping background sync")
            return
        }
        isRunning = true
        defer { isRunning = false }

        let bgContext = ModelContext(modelContainer)

        let targetID = accountID
        let accountPredicate2 = #Predicate<ServerAccount> { $0.id == targetID }
        var accountDescriptor = FetchDescriptor<ServerAccount>(
            predicate: accountPredicate2
        )
        accountDescriptor.fetchLimit = 1
        guard let account = try bgContext.fetch(accountDescriptor).first else {
            return
        }

        let baseURL = serverBaseURL

        setState(.syncing)

        do {
            // Step 1: Discover calendars
            let principalPath = try await calDAVClient.discoverPrincipal(
                baseURL: baseURL,
                credentials: credentials
            )

            try Task.checkCancellation()

            let calendarHomePath = try await calDAVClient.discoverCalendarHome(
                baseURL: baseURL,
                principalPath: principalPath,
                credentials: credentials
            )

            try Task.checkCancellation()

            let remoteCalendars = try await calDAVClient.discoverTaskCalendars(
                baseURL: baseURL,
                calendarHomePath: calendarHomePath,
                credentials: credentials
            )

            // Step 2: Pull each calendar
            for remoteCal in remoteCalendars {
                try Task.checkCancellation()

                // Find or create local TaskList
                let href = remoteCal.href
                let lists = account.taskLists
                let taskList: TaskList
                if let existing = lists.first(where: { $0.serverURL == href }) {
                    existing.name = remoteCal.displayName
                    if !remoteCal.color.isEmpty {
                        existing.colorHex = remoteCal.color
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
                    bgContext.insert(newList)
                    taskList = newList
                }

                // Fetch remote tasks
                let remoteTasks = try await calDAVClient.fetchAllTasks(
                    baseURL: baseURL,
                    calendarPath: remoteCal.href,
                    credentials: credentials
                )

                try Task.checkCancellation()

                // Build UID lookup via explicit fetch (relationship can be stale in background contexts)
                let listID = taskList.id
                let existingTasks = (try? bgContext.fetch(
                    FetchDescriptor<TaskItem>(
                        predicate: { let p = #Predicate<TaskItem> { $0.taskList?.id == listID && !$0.isDeletedLocally }; return p }()
                    )
                )) ?? []
                var uidMap: [String: TaskItem] = [:]
                for task in existingTasks {
                    uidMap[task.uid] = task
                }

                // Process remote tasks (active first)
                let (activeTasks, allCompleted) = Self.partitionByStatus(remoteTasks)
                let completedTasks = Self.filterCompletedByWindow(allCompleted, months: syncWindowMonths)

                for (index, remoteTask) in activeTasks.enumerated() {
                    try Task.checkCancellation()
                    try applyRemoteTask(remoteTask, taskList: taskList, uidMap: &uidMap, modelContext: bgContext)
                    if (index + 1) % 100 == 0 {
                        try bgContext.save()
                    }
                }

                try bgContext.save()

                for (index, remoteTask) in completedTasks.enumerated() {
                    try Task.checkCancellation()
                    try applyRemoteTask(remoteTask, taskList: taskList, uidMap: &uidMap, modelContext: bgContext)
                    if (index + 1) % 100 == 0 {
                        try bgContext.save()
                    }
                }

                // Update sync metadata
                taskList.syncCTag = remoteCal.ctag
                try bgContext.save()
            }

            // Update last sync time
            account.lastSyncDate = Date()
            try bgContext.save()

            // Reschedule reminders and refresh the badge for freshly-pulled
            // tasks. Without this, reminders/overdue badges for tasks synced in
            // the background are never scheduled until the app is foregrounded.
            await MainActor.run {
                let mainContext = modelContainer.mainContext
                Task { @MainActor in
                    await ReminderScheduler.refreshAllReminders(modelContext: mainContext)
                    await ReminderScheduler.updateBadgeCount(modelContext: mainContext)
                }
            }

            setState(.idle)

        } catch is CancellationError {
            setState(.idle)
        } catch {
            setState(.error(error.localizedDescription))
            throw error
        }
    }

    /// Applies a single remote task to the local store. Not `@MainActor`-isolated.
    ///
    /// This is the background-safe equivalent of `processRemoteTask`.
    private func applyRemoteTask(
        _ remoteTask: CalDAVClient.RemoteTask,
        taskList: TaskList,
        uidMap: inout [String: TaskItem],
        modelContext: ModelContext
    ) throws {
        guard let todoData = try ICalendarParser.parseSingleVTODO(
            from: remoteTask.icsData
        ) else { return }

        let uid = todoData.uid

        if let existingTask = uidMap[uid] {
            // Never overwrite a task with unsynced local edits — local wins
            guard !existingTask.isDirty else { return }

            let remoteModified = todoData.lastModifiedDate ?? Date.distantPast
            let localModified = existingTask.lastModifiedDate ?? Date.distantPast

            if remoteModified >= localModified {
                applyTodoDataBackground(todoData, to: existingTask)
                existingTask.etag = remoteTask.etag
                existingTask.remoteHref = remoteTask.href
                existingTask.isDirty = false
            }
        } else {
            let newTask = TaskItem(
                uid: todoData.uid,
                title: todoData.summary
            )
            applyTodoDataBackground(todoData, to: newTask)
            newTask.etag = remoteTask.etag
            newTask.remoteHref = remoteTask.href
            newTask.isDirty = false
            newTask.taskList = taskList
            modelContext.insert(newTask)
            uidMap[uid] = newTask
        }
    }

    /// Applies parsed VTODO data onto a TaskItem. Not `@MainActor`-isolated.
    private func applyTodoDataBackground(
        _ data: ICalendarParser.VTODOData,
        to task: TaskItem
    ) {
        task.title = data.summary
        task.notes = data.description ?? ""

        if let statusString = data.status {
            task.status = TaskStatus(rawValue: statusString) ?? .needsAction
        }

        task.priorityRaw = data.priority
        task.percentComplete = data.percentComplete
        task.dueDate = data.dueDate
        task.isDueDateOnly = data.isDueDateOnly
        task.startDate = data.startDate
        task.isStartDateOnly = data.isStartDateOnly
        task.completedDate = data.completedDate
        task.createdDate = data.createdDate ?? task.createdDate
        task.lastModifiedDate = data.lastModifiedDate
        task.location = data.location
        task.latitude = data.latitude
        task.longitude = data.longitude
        task.url = data.url
        task.parentUID = data.parentUID
        task.reminderOffset = data.alarmTriggerSeconds
        task.recurrenceRule = data.recurrenceRule
    }

    // MARK: - Calendar Sync

    /// Syncs a single remote calendar with its local TaskList counterpart.
    private func syncCalendar(
        remoteCal: CalDAVClient.RemoteCalendar,
        account: ServerAccount,
        baseURL: String,
        credentials: CalDAVClient.Credentials,
        modelContext: ModelContext,
        syncWindowMonths: Int = 0
    ) async throws {
        // Find or create local TaskList
        let taskList = findOrCreateTaskList(
            for: remoteCal,
            account: account,
            modelContext: modelContext
        )

        // CTag delta check: skip the expensive full pull when nothing
        // changed on the server. Still push local dirty/deleted tasks.
        if let localCTag = taskList.syncCTag,
           !localCTag.isEmpty,
           localCTag == remoteCal.ctag {

            logger.debug("CTag unchanged for \(remoteCal.displayName), skipping pull")

            // Push local dirty tasks even when server hasn't changed (with per-task error isolation)
            let dirtyTasks = findDirtyTasks(for: taskList, modelContext: modelContext)
            for localTask in dirtyTasks {
                try Task.checkCancellation()
                do {
                    try await pushLocalTask(
                        localTask,
                        calendarPath: remoteCal.href,
                        baseURL: baseURL,
                        credentials: credentials,
                        modelContext: modelContext
                    )
                } catch {
                    logger.error("Failed to push task '\(localTask.title)': \(error.localizedDescription)")
                }
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
                    logger.error("Failed to push deletion '\(deletedTask.title)': \(error.localizedDescription)")
                }
            }

            try modelContext.save()
            return
        }

        // Pull remote tasks
        let remoteTasks = try await calDAVClient.fetchAllTasks(
            baseURL: baseURL,
            calendarPath: remoteCal.href,
            credentials: credentials
        )

        try Task.checkCancellation()

        // Batch pre-fetch: build UID → TaskItem lookup via explicit fetch
        // (taskList.tasks relationship can be stale/unfaulted in background contexts)
        let listID = taskList.id
        let existingTasks = (try? modelContext.fetch(
            FetchDescriptor<TaskItem>(
                predicate: { let p = #Predicate<TaskItem> { $0.taskList?.id == listID && !$0.isDeletedLocally }; return p }()
            )
        )) ?? []
        var uidMap: [String: TaskItem] = [:]
        for task in existingTasks {
            uidMap[task.uid] = task
        }

        // Partition: process active tasks first so the user sees their
        // current work before years of completed history.
        let (activeTasks, allCompleted) = Self.partitionByStatus(remoteTasks)
        let completedTasks = Self.filterCompletedByWindow(allCompleted, months: syncWindowMonths)

        // Process active tasks
        for (index, remoteTask) in activeTasks.enumerated() {
            try Task.checkCancellation()
            try processRemoteTask(
                remoteTask,
                taskList: taskList,
                uidMap: &uidMap,
                modelContext: modelContext
            )
            if (index + 1) % 100 == 0 {
                try modelContext.save()
            }
        }

        // Save after all active tasks so UI updates immediately
        try modelContext.save()

        // Process completed tasks with periodic saves
        for (index, remoteTask) in completedTasks.enumerated() {
            try Task.checkCancellation()
            try processRemoteTask(
                remoteTask,
                taskList: taskList,
                uidMap: &uidMap,
                modelContext: modelContext
            )
            if (index + 1) % 100 == 0 {
                try modelContext.save()
            }
        }

        // Resolve parent-child relationships from parentUID → parentTask
        try resolveParentRelationships(
            for: taskList,
            modelContext: modelContext
        )

        // Push local dirty tasks (with per-task error isolation)
        let dirtyTasks = findDirtyTasks(for: taskList, modelContext: modelContext)
        for localTask in dirtyTasks {
            try Task.checkCancellation()
            do {
                try await pushLocalTask(
                    localTask,
                    calendarPath: remoteCal.href,
                    baseURL: baseURL,
                    credentials: credentials,
                    modelContext: modelContext
                )
            } catch {
                logger.error("Failed to push task '\(localTask.title)': \(error.localizedDescription)")
            }
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
                logger.error("Failed to push deletion '\(deletedTask.title)': \(error.localizedDescription)")
            }
        }

        // Update sync metadata
        // If we pushed anything, clear CTag to force a re-pull next time.
        // PUTs change the server's CTag, so the pre-push value is stale.
        if !dirtyTasks.isEmpty || !deletedTasks.isEmpty {
            taskList.syncCTag = nil
        } else {
            taskList.syncCTag = remoteCal.ctag
        }

        try modelContext.save()
    }

    // MARK: - Pull (Remote → Local)

    /// Processes a single remote task: creates or updates the local TaskItem.
    ///
    /// Uses a pre-built UID map for O(1) lookups instead of per-task SwiftData queries.
    private func processRemoteTask(
        _ remoteTask: CalDAVClient.RemoteTask,
        taskList: TaskList,
        uidMap: inout [String: TaskItem],
        modelContext: ModelContext
    ) throws {
        guard let todoData = try ICalendarParser.parseSingleVTODO(
            from: remoteTask.icsData
        ) else { return }

        let uid = todoData.uid

        if let existingTask = uidMap[uid] {
            // Never overwrite a task with unsynced local edits — local wins
            guard !existingTask.isDirty else { return }

            // Update existing task if remote is newer
            let remoteModified = todoData.lastModifiedDate ?? Date.distantPast
            let localModified = existingTask.lastModifiedDate ?? Date.distantPast

            if remoteModified >= localModified {
                applyTodoData(todoData, to: existingTask)
                existingTask.etag = remoteTask.etag
                existingTask.remoteHref = remoteTask.href
                existingTask.isDirty = false
            }
        } else {
            // Create new local task
            let newTask = TaskItem(
                uid: todoData.uid,
                title: todoData.summary
            )
            applyTodoData(todoData, to: newTask)
            newTask.etag = remoteTask.etag
            newTask.remoteHref = remoteTask.href
            newTask.isDirty = false
            newTask.taskList = taskList
            modelContext.insert(newTask)
            uidMap[uid] = newTask
        }
    }

    /// Applies parsed VTODO data onto a TaskItem model.
    private func applyTodoData(
        _ data: ICalendarParser.VTODOData,
        to task: TaskItem
    ) {
        task.title = data.summary
        task.notes = data.description ?? ""

        if let statusString = data.status {
            task.status = TaskStatus(rawValue: statusString) ?? .needsAction
        }

        task.priorityRaw = data.priority
        task.percentComplete = data.percentComplete
        task.dueDate = data.dueDate
        task.isDueDateOnly = data.isDueDateOnly
        task.startDate = data.startDate
        task.isStartDateOnly = data.isStartDateOnly
        task.completedDate = data.completedDate
        task.createdDate = data.createdDate ?? task.createdDate
        task.lastModifiedDate = data.lastModifiedDate
        task.location = data.location
        task.latitude = data.latitude
        task.longitude = data.longitude
        task.url = data.url
        task.parentUID = data.parentUID
        task.reminderOffset = data.alarmTriggerSeconds
        task.recurrenceRule = data.recurrenceRule
    }

    // MARK: - Push (Local → Remote)

    /// Pushes a locally modified task to the server.
    private func pushLocalTask(
        _ task: TaskItem,
        calendarPath: String,
        baseURL: String,
        credentials: CalDAVClient.Credentials,
        modelContext: ModelContext
    ) async throws {
        let icsData = serializeTask(task)

        // Build the task path
        let taskPath: String
        if let existingHref = task.remoteHref, !existingHref.isEmpty {
            taskPath = existingHref
        } else {
            taskPath = "\(calendarPath)\(task.uid).ics"
        }

        do {
            let newEtag = try await calDAVClient.putTask(
                baseURL: baseURL,
                taskPath: taskPath,
                icsData: icsData,
                etag: task.etag,
                credentials: credentials
            )

            task.etag = newEtag
            task.remoteHref = taskPath
            task.isDirty = false
            try modelContext.save()

        } catch CalDAVError.conflict {
            // Handle 412: server version wins for MVP
            let resolution = ConflictResolver.resolve(
                localModified: task.lastModifiedDate,
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
                if let todoData = try ICalendarParser.parseSingleVTODO(
                    from: refreshed.icsData
                ) {
                    applyTodoData(todoData, to: task)
                    task.etag = refreshed.etag
                    task.isDirty = false
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
                task.etag = newEtag
                task.isDirty = false
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
        guard let href = task.remoteHref, !href.isEmpty else {
            // Never synced — just delete locally
            modelContext.delete(task)
            return
        }

        try await calDAVClient.deleteTask(
            baseURL: baseURL,
            taskPath: href,
            etag: task.etag,
            credentials: credentials
        )

        modelContext.delete(task)
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
            isStartDateOnly: task.isStartDateOnly
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
            existing.name = remoteCal.displayName
            if !remoteCal.color.isEmpty {
                existing.colorHex = remoteCal.color
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
                list.serverURL = remoteHref
                try modelContext.save()
            } catch {
                // Log but don't fail the whole sync for one list
                logger.error("Failed to push list '\(list.name)': \(error.localizedDescription)")
            }
        }
    }

    /// Finds tasks that have been modified locally and need to be pushed.
    ///
    /// Uses an explicit `FetchDescriptor` instead of `taskList.tasks` relationship,
    /// which can be stale/unfaulted in background contexts.
    func findDirtyTasks(
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
    func findDeletedTasks(
        for taskList: TaskList,
        modelContext: ModelContext
    ) -> [TaskItem] {
        let listID = taskList.id
        let predicate = #Predicate<TaskItem> {
            $0.taskList?.id == listID && $0.isDeletedLocally
        }
        return (try? modelContext.fetch(FetchDescriptor<TaskItem>(predicate: predicate))) ?? []
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

        // Wire up parent-child relationships
        for task in allTasks {
            guard let parentUID = task.parentUID, !parentUID.isEmpty else {
                // No parent UID — this is a root task
                if task.parentTask != nil {
                    task.parentTask = nil
                }
                continue
            }

            if let parentTask = uidMap[parentUID] {
                if task.parentTask !== parentTask {
                    task.parentTask = parentTask
                }
            }
            // If parent not found in this list, leave parentTask nil
            // (parent may be in a different calendar)
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

        // Reusable date formatters for the two common COMPLETED timestamp formats
        let utcFormatter = DateFormatter()
        utcFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        utcFormatter.timeZone = TimeZone(identifier: "UTC")

        let localFormatter = DateFormatter()
        localFormatter.dateFormat = "yyyyMMdd'T'HHmmss"
        localFormatter.timeZone = TimeZone.current

        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.dateFormat = "yyyyMMdd"
        dateOnlyFormatter.timeZone = TimeZone.current

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

    /// Test-accessible wrapper for `applyRemoteTask`.
    func testApplyRemoteTask(
        _ remoteTask: CalDAVClient.RemoteTask,
        taskList: TaskList,
        uidMap: inout [String: TaskItem],
        modelContext: ModelContext
    ) throws {
        try applyRemoteTask(remoteTask, taskList: taskList, uidMap: &uidMap, modelContext: modelContext)
    }

    /// Test-accessible alias for `findDirtyTasks` — returns UIDs for Sendable safety.
    func testFindDirtyTasks(
        for taskList: TaskList,
        modelContext: ModelContext
    ) -> [String] {
        findDirtyTasks(for: taskList, modelContext: modelContext).map(\.uid)
    }

    /// Test-accessible alias for `findDeletedTasks` — returns UIDs for Sendable safety.
    func testFindDeletedTasks(
        for taskList: TaskList,
        modelContext: ModelContext
    ) -> [String] {
        findDeletedTasks(for: taskList, modelContext: modelContext).map(\.uid)
    }
}

