import Foundation
import SwiftData

struct SyncBatchCommit: Sendable {
    let change: SyncChange
    let insertedIDs: Set<String>
}

/// Parsing/network work stays off main. Only a bounded save transaction is serialized
/// with UI mutations, using a fresh context rather than a previous batch's registered models.
@MainActor
final class SyncInboundBatchWriter {
    let container: ModelContainer
    let listID: String
    private let expectedAccountID: String?
    private let planner: SyncInboundPlanner
    private var hierarchyNeedsResolution: Bool
    private var checkedDurableHierarchyWork = false
    private let checkpointID: String?
    private let mainSaveRevision: SyncMainSaveRevision
    init(container: ModelContainer, listID: String, expectedAccountID: String? = nil,
         checkpointID: String? = nil, needsParentResolution: Bool = false) {
        self.container = container; self.listID = listID
        self.expectedAccountID = expectedAccountID
        self.planner = SyncInboundPlanner(container: container, listID: listID)
        self.checkpointID = checkpointID
        self.hierarchyNeedsResolution = needsParentResolution
        self.mainSaveRevision = SyncMainSaveRevision(context: container.mainContext)
    }

    func apply(_ resources: [ParsedRemoteTask], months: Int = 0, repairCategories: Bool = false) throws -> SyncBatchCommit? {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        precondition(resources.count <= 100)
        let context = freshContext()
        guard let list = try list(in: context) else { throw CalDAVError.invalidResponse }
        let uids = resources.compactMap { $0.todo?.uid }
        let id = listID
        let predicate = #Predicate<TaskItem> { $0.taskList?.id == id && uids.contains($0.uid) }
        let saved = try context.fetch(FetchDescriptor(predicate: predicate))
        var map = Dictionary(saved.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let protected = try protectedUIDs(uids: uids)
        let sourceID = listID
        let moved = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.pendingMoveFromListID == sourceID }))
        let blocked = Set(moved.map(\.uid)).union(protected)
        let importer = try SyncImportStore(context: context)
        let (active, completed) = SyncEngine.partitionParsedTasks(resources, months: months)
        for resource in active + completed where !blocked.contains(resource.todo?.uid ?? "") {
            let previous = resource.todo.flatMap { map[$0.uid] }
            let previousParentUID = previous?.parentUID
            if importer.apply(resource, list: list, uidMap: &map, movedAway: blocked),
               previous == nil || previousParentUID != resource.todo?.parentUID {
                hierarchyNeedsResolution = true
            }
        }
        if repairCategories {
            _ = importer.catchUpCategories(resources.filter { !blocked.contains($0.todo?.uid ?? "") }, uidMap: map)
        }
        if hierarchyNeedsResolution, let checkpointID {
            try SyncImportCheckpoint.markHierarchyPending(id: checkpointID, in: context)
        }
        return try commit(context)
    }

    /// Planning scans committed values off main. Each transaction rechecks live state,
    /// yields between at most 100 actions, and announces its save before continuing.
    @discardableResult
    func reconcileManifest(_ resources: [CalDAVClient.RemoteResource],
        onCommit: (@Sendable (SyncBatchCommit) async -> Void)? = nil) async throws -> SyncBatchCommit? {
        guard !resources.isEmpty else { return nil }
        let candidates = try await planner.deletionCandidates(manifest: resources, explicitHrefs: nil,
            protectedUIDs: try pendingProtection().uids)
        return try await delete(candidates, onCommit: onCommit)
    }

    @discardableResult
    func deleteExplicit(_ hrefs: [String],
        onCommit: (@Sendable (SyncBatchCommit) async -> Void)? = nil) async throws -> SyncBatchCommit? {
        guard !hrefs.isEmpty else { return nil }
        let candidates = try await planner.deletionCandidates(manifest: nil, explicitHrefs: hrefs,
            protectedUIDs: try pendingProtection().uids)
        return try await delete(candidates, onCommit: onCommit)
    }

    @discardableResult
    func resolveParents(onCommit: (@Sendable (SyncBatchCommit) async -> Void)? = nil) async throws -> SyncBatchCommit? {
        try BackgroundRunBudget.protectingCurrent {
            if !checkedDurableHierarchyWork {
                checkedDurableHierarchyWork = true
                if let checkpointID, try SyncImportCheckpoint.hierarchyPending(id: checkpointID, in: freshContext()) {
                    hierarchyNeedsResolution = true
                }
            }
        }
        guard hierarchyNeedsResolution else { return nil }
        var lastCommit: SyncBatchCommit?
        while true {
            try Task.checkCancellation()
            let revision = mainSaveRevision.value
            let edits = try await planner.parentEdits(includeDirty: true)
            guard revision == mainSaveRevision.value else { continue }
            var replan = false
            var deferred = false
            for start in stride(from: 0, to: edits.count, by: 100) {
                try Task.checkCancellation()
                // A UI save can change any ancestor while the planner or publisher
                // suspends. Replan off main rather than walking deep chains on main.
                guard revision == mainSaveRevision.value else { replan = true; break }
                let result = try applyParents(Array(edits[start..<min(start + 100, edits.count)]))
                deferred = deferred || result.deferred
                if let saved = result.commit {
                    lastCommit = saved
                    await onCommit?(saved)
                }
                await Task.yield()
            }
            if replan || revision != mainSaveRevision.value { continue }
            if !deferred {
                if let checkpointID {
                    try BackgroundRunBudget.protectingCurrent {
                        let context = freshContext()
                        guard try list(in: context) != nil else { throw CancellationError() }
                        try SyncImportCheckpoint.clearHierarchyPending(id: checkpointID, in: context)
                        if context.hasChanges { try context.save() }
                    }
                }
                hierarchyNeedsResolution = false
            }
            return lastCommit
        }
    }

    private func delete(_ candidates: [SyncInboundPlanner.DeleteCandidate],
        onCommit: (@Sendable (SyncBatchCommit) async -> Void)?) async throws -> SyncBatchCommit? {
        var lastCommit: SyncBatchCommit?
        for start in stride(from: 0, to: candidates.count, by: 100) {
            try Task.checkCancellation()
            if let saved = try deleteBatch(Array(candidates[start..<min(start + 100, candidates.count)])) {
                lastCommit = saved
                await onCommit?(saved)
            }
            await Task.yield()
        }
        return lastCommit
    }

    private func deleteBatch(_ candidates: [SyncInboundPlanner.DeleteCandidate]) throws -> SyncBatchCommit? {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        let context = freshContext()
        guard try list(in: context) != nil else { throw CancellationError() }
        let ids = candidates.map(\.taskID)
        let stored = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { ids.contains($0.id) }))
        let byID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let protected = try pendingProtection().ids
        var deletedIDs = Set<String>()
        for candidate in candidates {
            guard let task = byID[candidate.taskID], !protected.contains(task.id),
                  task.taskList?.id == candidate.expectedListID, task.remoteHref == candidate.expectedHref,
                  !task.isDirty, !task.isDeletedLocally,
                  !(task.isLocalOnly && task.etag == nil),
                  // A newly inserted or edited descendant after planning must never cascade.
                  task.subtasks.allSatisfy({ deletedIDs.contains($0.id) }) else { continue }
            context.delete(task)
            deletedIDs.insert(task.id)
        }
        return try commit(context)
    }

    private func applyParents(_ edits: [SyncInboundPlanner.ParentEdit]) throws -> (commit: SyncBatchCommit?, deferred: Bool) {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        let context = freshContext()
        guard try list(in: context) != nil else { throw CancellationError() }
        let ids = edits.map(\.taskID) + edits.compactMap(\.parentID)
        let stored = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { ids.contains($0.id) }))
        let byID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let protected = try pendingProtection().ids
        var deferred = false
        for edit in edits {
            guard let task = byID[edit.taskID], task.taskList?.id == listID,
                  !task.isDirty, !task.isDeletedLocally, !protected.contains(task.id),
                  task.parentUID == edit.expectedRawParentUID,
                  task.parentTask?.id == edit.expectedParentID else { deferred = true; continue }
            let parent = edit.parentID.flatMap { byID[$0] }
            if let parentID = edit.parentID {
                guard let parent, parent.taskList?.id == listID, !parent.isDeletedLocally,
                      !protected.contains(parentID) else { deferred = true; continue }
            }
            task.parentTask = parent
        }
        return (try commit(context), deferred)
    }

    /// Only pending UI mutations are inspected here; whole-list work belongs to the planner.
    /// Walk every pending descendant's ancestors iteratively to guard cascade relationships.
    private func pendingProtection() throws -> (ids: Set<String>, uids: Set<String>) {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        let main = container.mainContext
        var ids = Set<String>(); var uids = Set<String>()
        for model in main.insertedModelsArray + main.changedModelsArray + main.deletedModelsArray {
            guard var task = model as? TaskItem else { continue }
            while ids.insert(task.id).inserted {
                uids.insert(task.uid)
                guard let parent = task.parentTask else { break }
                task = parent
            }
        }
        return (ids, uids)
    }

    private func protectedUIDs(uids: [String]) throws -> Set<String> {
        let main = container.mainContext
        let id = listID
        let live = try main.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.taskList?.id == id && uids.contains($0.uid) }))
        // Saved dirty fields are protected by the canonical importer. They still
        // need additive category repair and accepted resource-location metadata.
        var protected = Set(live.filter { $0.isDeletedLocally }.map(\.uid))
        for model in main.insertedModelsArray + main.changedModelsArray + main.deletedModelsArray {
            guard let task = model as? TaskItem, task.modelContext != nil else { continue }
            // Include pending moves before their destination/source markers have been saved.
            if uids.contains(task.uid) { protected.insert(task.uid) }
            if let parent = task.parentTask { protected.insert(parent.uid) }
        }
        return protected
    }

    private func freshContext() -> ModelContext {
        let context = ModelContext(container); context.autosaveEnabled = false
        return context
    }
    private func list(in context: ModelContext) throws -> TaskList? {
        let id = listID
        if container.mainContext.deletedModelsArray.contains(where: { ($0 as? TaskList)?.id == id }) { return nil }
        let list = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == id })).first
        if let expectedAccountID, list?.account?.id != expectedAccountID { return nil }
        return list
    }
    private func commit(_ context: ModelContext) throws -> SyncBatchCommit? {
        guard context.hasChanges else { return nil }
        let inserted = context.insertedModelsArray.compactMap { $0 as? TaskItem }
        let changed = context.changedModelsArray.compactMap { $0 as? TaskItem }
        let removed = context.deletedModelsArray.compactMap { $0 as? TaskItem }
        let insertedIDs = Set(inserted.map(\.id))
        let change = SyncChange(revision: 0,
            accountIDs: Set((inserted + changed + removed).compactMap { $0.taskList?.account?.id }),
            listIDs: [listID], changedIDs: insertedIDs.union(changed.map(\.id)), deletedIDs: Set(removed.map(\.id)), kind: .tasks)
        let interval = PerformanceTrace.begin("ImportSave", count: resourcesCount(context))
        defer { PerformanceTrace.end("ImportSave", interval) }
        ReminderSchedulingJournal.enqueueTaskChanges(in: context)
        try context.save()
        guard !change.changedIDs.isEmpty || !change.deletedIDs.isEmpty else { return nil }
        return SyncBatchCommit(change: change, insertedIDs: insertedIDs)
    }
    private func resourcesCount(_ context: ModelContext) -> Int {
        context.insertedModelsArray.count + context.changedModelsArray.count + context.deletedModelsArray.count
    }
}

/// Observe only UI-context saves. Fresh worker-context commits cannot invalidate their
/// own plan. Delivery is synchronous on main before the next bounded transaction.
@MainActor
private final class SyncMainSaveRevision {
    var value: UInt64 = 0
    private var token: SyncSaveObservationToken?

    init(context: ModelContext) {
        token = SyncSaveObservationToken(NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: context, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { self.value &+= 1 }
            }
        })
    }
}

private final class SyncSaveObservationToken: @unchecked Sendable {
    let value: NSObjectProtocol
    init(_ value: NSObjectProtocol) { self.value = value }
    deinit { NotificationCenter.default.removeObserver(value) }
}
