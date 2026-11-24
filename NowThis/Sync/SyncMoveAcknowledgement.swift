import Foundation
import SwiftData

/// The values that define the local state a pending-move DELETE was sent for.
/// It contains no SwiftData models, so it can safely cross the network await.
struct SyncMoveSnapshot: Sendable {
    let taskID: String
    let uid: String
    let sourceHref: String
    let sourceListID: String
    let sourceAccountID: String?
    let sourceProof: SyncResourceState
    let destinationListID: String
    let destinationAccountID: String?
    let destinationScope: TaskPhotoOwnership.Scope?
    let destinationHref: String?
    let etag: String?
    let isDirty: Bool
    let isLocalOnly: Bool
    let isDeletedLocally: Bool
    let stamp: Date
    let payload: String
    let opaqueState: VTODOOpaqueState
    let photoSources: [PhotoSource]

    struct PhotoSource: Sendable, Equatable {
        let localID: String
        let previousFile: String?
        let previousFolder: String?
        let previousAccount: String?
        let previousList: String?
        let destinationFile: String?
        let destinationFolder: String?
        let operation: String?
        let requested: Bool
        let cachedInVault: Bool
        let ownership: TaskPhotoOwnership
    }

    private static func sources(_ task: TaskItem) throws -> [PhotoSource] {
        guard let context = task.modelContext else { throw TaskPhotoOwnership.Failure.missingOwner }
        return try task.photos.sorted { $0.id < $1.id }.map {
            PhotoSource(localID: $0.id, previousFile: $0.previousOriginalFileID,
                previousFolder: $0.previousOriginalFolderID, previousAccount: $0.previousOriginalAccountID,
                previousList: $0.previousOriginalListID, destinationFile: $0.originalFileID,
                destinationFolder: $0.folderFileID, operation: $0.pendingOperation,
                requested: $0.originalRequested, cachedInVault: $0.originalStatus == "local",
                ownership: try TaskPhotoOwnership.read($0, in: context).state)
        }
    }

    func hasSamePhotoSources(as task: TaskItem) throws -> Bool { photoSources == (try Self.sources(task)) }

    init?(task: TaskItem, sourceAccountID: String? = nil) throws {
        guard let sourceHref = task.pendingMoveFromHref,
              let sourceListID = task.pendingMoveFromListID else { return nil }
        taskID = task.id
        uid = task.uid
        self.sourceHref = sourceHref
        self.sourceListID = sourceListID
        guard let context = task.modelContext, let proof = try SyncResourceState.sourceProof(task, in: context) else { throw SyncResourceState.Hold.needsRevalidation }
        sourceProof = proof
        self.sourceAccountID = sourceAccountID ?? proof.scope.accountID
        destinationListID = task.taskList?.id ?? ""
        destinationAccountID = task.taskList?.account?.id
        destinationScope = TaskPhotoOwnership.Scope(list: task.taskList)
        destinationHref = task.remoteHref
        etag = task.etag
        isDirty = task.isDirty
        isLocalOnly = task.isLocalOnly
        isDeletedLocally = task.isDeletedLocally
        stamp = task.lastModifiedDate ?? Date()
        opaqueState = try SyncPushSnapshot.state(for: task)
        payload = try SyncPushSnapshot.serialize(task, stamp: stamp, opaqueState: opaqueState)
        photoSources = try Self.sources(task)
    }

    func hasSameMoveMarkers(as task: TaskItem) -> Bool {
        task.id == taskID
            && task.pendingMoveFromHref == sourceHref
            && task.pendingMoveFromListID == sourceListID
    }

    func isAtSentDestination(_ task: TaskItem) -> Bool {
        task.taskList?.id == destinationListID && task.taskList?.account?.id == destinationAccountID
            && task.remoteHref == destinationHref
    }

    func stillMatches(_ task: TaskItem) throws -> Bool {
        try hasSameMoveMarkers(as: task)
            && task.uid == uid
            && isAtSentDestination(task)
            && task.etag == etag
            && task.isDirty == isDirty
            && task.isLocalOnly == isLocalOnly
            && task.isDeletedLocally == isDeletedLocally
            && SyncPushSnapshot.state(for: task) == opaqueState
            && SyncPushSnapshot.serialize(task, stamp: stamp, opaqueState: opaqueState) == payload
    }
}

/// Applies move acknowledgements on the main actor, against current UI state,
/// while saving through an independent context so older registered models cannot
/// overwrite edits made during the DELETE request.
enum SyncMoveAcknowledgement {
    @MainActor
    static func deletionSnapshot(_ candidate: SyncMoveSnapshot, container: ModelContainer,
                                 expectedSourceAccountID: String? = nil) throws -> SyncMoveSnapshot? {
        let id = candidate.taskID
        let predicate = #Predicate<TaskItem> { $0.id == id }
        let main = container.mainContext
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first,
              !SyncPushAcknowledgement.hasPendingChange(current, in: main) else { return nil }
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              candidate.hasSameMoveMarkers(as: stored), stored.isDeletedLocally == candidate.isDeletedLocally,
              PendingMoveSweep.isReady(stored) else { return nil }
        guard let freshProof = try SyncResourceState.sourceProof(stored, in: context),
              freshProof == candidate.sourceProof,
              freshProof.scope.matches(try sourceList(candidate.sourceListID, in: main)),
              expectedSourceAccountID == nil || freshProof.scope.accountID == expectedSourceAccountID else { return nil }
        guard try !hasRemainingSourceDescendant(of: stored, sourceListID: candidate.sourceListID,
            in: context, main: main) else { return nil }
        guard stored.isDeletedLocally else { return try SyncMoveSnapshot(task: stored, sourceAccountID: freshProof.scope.accountID) }

        guard !candidate.sourceHref.isEmpty,
              let sourceAccountID = try accountID(forList: candidate.sourceListID, in: context),
              expectedSourceAccountID == nil || expectedSourceAccountID == sourceAccountID,
              try candidate.hasSamePhotoSources(as: stored),
              try candidate.stillMatches(stored),
              try !SyncPushAcknowledgement.hasRemainingDescendant(of: stored, in: context, main: main,
                  sourceListID: candidate.sourceListID) else { return nil }
        guard !TaskPhotoCleanupQueue.hasAmbiguousPendingRemoval(in: stored) else {
            throw TaskPhotoCleanupQueue.OwnershipError.ambiguousPendingRemoval
        }
        return try SyncMoveSnapshot(task: stored, sourceAccountID: sourceAccountID)
    }

    @MainActor
    static func validateDeletion(_ snapshot: SyncMoveSnapshot, container: ModelContainer) throws {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        guard let sourceAccountID = snapshot.sourceAccountID,
              try deletionSnapshot(snapshot, container: container, expectedSourceAccountID: sourceAccountID) != nil else {
            throw SupersededTaskDeletion()
        }
    }

    @MainActor
    @discardableResult
    static func acknowledgeDelete(_ snapshot: SyncMoveSnapshot, container: ModelContainer,
                                  save: (ModelContext) throws -> Void = { try $0.save() }) throws -> SyncChange? {
        let id = snapshot.taskID
        let predicate = #Predicate<TaskItem> { $0.id == id }
        let main = container.mainContext
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first,
              current.modelContext != nil else { return nil }
        let pending = main.insertedModelsArray + main.changedModelsArray + main.deletedModelsArray
        let photoIDs = Set(current.photos.map(\.persistentModelID))
        let ownershipKeys = Set(current.photos.map { TaskPhotoOwnership.prefix + $0.id }).union(SyncResourceState.pendingKeys(current, in: main))
        guard !pending.contains(where: {
            ($0 is TaskPhoto && photoIDs.contains($0.persistentModelID))
                || ($0 as? SyncMetadata).map { ownershipKeys.contains($0.id) } == true
        }) else { return nil }
        if pending.contains(where: { $0.persistentModelID == current.persistentModelID }) {
            // A pending title edit is independent from finishing the acknowledged move.
            guard !snapshot.isDeletedLocally, !current.isDeletedLocally,
                  snapshot.hasSameMoveMarkers(as: current), snapshot.isAtSentDestination(current) else { return nil }
        }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              snapshot.hasSameMoveMarkers(as: stored), snapshot.isAtSentDestination(stored),
              snapshot.isDeletedLocally == stored.isDeletedLocally,
              try snapshot.hasSamePhotoSources(as: stored), PendingMoveSweep.isReady(stored),
              try SyncResourceState.sourceProof(stored, in: context) == snapshot.sourceProof,
              snapshot.sourceProof.scope.matches(try sourceList(snapshot.sourceListID, in: main)),
              try !hasRemainingSourceDescendant(of: stored, sourceListID: snapshot.sourceListID, in: context, main: main) else { return nil }
        if snapshot.isDeletedLocally {
            guard let sourceAccountID = snapshot.sourceAccountID,
                  try accountID(forList: snapshot.sourceListID, in: context) == sourceAccountID,
                  try snapshot.stillMatches(stored),
                  try !SyncPushAcknowledgement.hasRemainingDescendant(of: stored, in: context, main: main,
                      sourceListID: snapshot.sourceListID) else { return nil }
            guard !TaskPhotoCleanupQueue.hasAmbiguousPendingRemoval(in: stored) else {
                throw TaskPhotoCleanupQueue.OwnershipError.ambiguousPendingRemoval
            }
            if stored.remoteHref?.isEmpty != false {
                let deletion = change(for: stored, sourceListID: snapshot.sourceListID, context: context, deleting: true)
                try SyncPushAcknowledgement.finalizeDeletion(stored, in: context)
                try save(context)
                return deletion
            }
        } else {
            try TaskPhotoSyncStore.completeMove(stored, in: context)
        }
        // A tombstone keeps both sets of photo originals until its final
        // deletion queues cleanup with their original collection ownership.
        stored.pendingMoveFromHref = nil
        stored.pendingMoveFromListID = nil
        try SyncResourceState.removeCapture(taskID: stored.id, in: context)
        try save(context)
        return change(for: stored, sourceListID: snapshot.sourceListID, context: context)
    }

    @MainActor
    @discardableResult
    static func rollBackRefusedDelete(_ snapshot: SyncMoveSnapshot, container: ModelContainer) throws -> SyncChange? {
        guard !snapshot.isDeletedLocally else { return nil }
        let id = snapshot.taskID
        let predicate = #Predicate<TaskItem> { $0.id == id }
        let main = container.mainContext
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first,
              !SyncPushAcknowledgement.hasPendingChange(current, in: main) else { return nil }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              try snapshot.stillMatches(stored),
              try SyncResourceState.sourceProof(stored, in: context) == snapshot.sourceProof,
              snapshot.sourceProof.scope.matches(try sourceList(snapshot.sourceListID, in: main)),
              TaskPhotoOwnership.Scope(list: stored.taskList) == snapshot.destinationScope,
              TaskPhotoOwnership.Scope(list: current.taskList) == snapshot.destinationScope,
              TaskMover.rollBackRefusedDelete(stored, in: context) else { return nil }

        try context.save()
        return change(for: stored, sourceListID: snapshot.sourceListID, context: context)
    }

    /// Live children remain at the destination after their source cleanup. Only
    /// descendants still owing this source can make a cascading DELETE unsafe.
    @MainActor
    static func hasRemainingSourceDescendant(of task: TaskItem, sourceListID: String,
                                                     in context: ModelContext, main: ModelContext,
                                                     didFetch: (Int) -> Void = { _ in }) throws -> Bool {
        // Pending UI links are checked on every admission/retry/ACK. A saved
        // query cannot see a newly inserted child or an unsaved relationship.
        let pending = (main.insertedModelsArray + main.changedModelsArray + main.deletedModelsArray).compactMap { $0 as? TaskItem }
        for child in pending where child.id != task.id {
            var cursor: TaskItem? = child
            var seen: Set<String> = []
            while let node = cursor, seen.insert(node.id).inserted {
                if node.parentTask?.id == task.id { return true }
                if node.parentUID == task.uid,
                   node.pendingMoveFromListID == sourceListID || node.taskList?.id == sourceListID
                    || node.taskList?.id == task.taskList?.id { return true }
                cursor = node.parentTask
            }
        }
        // Walk only this subtree. Resolved links may cross lists after a move;
        // server UID links must belong to the source or current destination.
        // Delivered intermediate children are traversed to find held descendants.
        let destinationListID = task.taskList?.id
        var frontier: [(id: String, uid: String)] = [(task.id, task.uid)]
        var visited: Set<String> = [task.id]
        while !frontier.isEmpty {
            let batch = Array(frontier.prefix(100)); frontier.removeFirst(batch.count)
            let parentIDs = batch.map { $0.id }
            let parentUIDs: [String?] = batch.map { $0.uid }
            if pending.contains(where: { child in
                child.id != task.id && (child.parentTask.map { parentIDs.contains($0.id) } == true
                    || (parentUIDs.contains(child.parentUID)
                        && (child.pendingMoveFromListID == sourceListID || child.taskList?.id == sourceListID
                            || child.taskList?.id == destinationListID)))
            }) { return true }
            let resolved = #Predicate<TaskItem> {
                $0.parentTask.flatMap { parentIDs.contains($0.id) } ?? false
            }
            let byServerParent = #Predicate<TaskItem> {
                parentUIDs.contains($0.parentUID)
                    && ($0.pendingMoveFromListID == sourceListID || $0.taskList?.id == sourceListID
                        || $0.taskList?.id == destinationListID)
            }
            // A stale local parent relationship cannot override the server's
            // RELATED-TO link, so both queries remain independently protective.
            for predicate in [resolved, byServerParent] {
                var descriptor = FetchDescriptor<TaskItem>(predicate: predicate, sortBy: [SortDescriptor(\.id)])
                descriptor.fetchLimit = 100
                var offset = 0
                while true {
                    descriptor.fetchOffset = offset
                    let children = try context.fetch(descriptor)
                    didFetch(children.count)
                    for child in children where visited.insert(child.id).inserted {
                        if child.pendingMoveFromListID == sourceListID
                            || (child.taskList?.id == sourceListID && child.remoteHref != nil) { return true }
                        frontier.append((child.id, child.uid))
                    }
                    if children.count < 100 { break }
                    offset += children.count
                }
            }
        }
        return false
    }

    private static func sourceList(_ id: String, in context: ModelContext) throws -> TaskList? {
        try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == id })).first
    }

    private static func accountID(forList listID: String, in context: ModelContext) throws -> String? {
        let predicate = #Predicate<TaskList> { $0.id == listID }
        return try context.fetch(FetchDescriptor(predicate: predicate)).first?.account?.id
    }

    private static func change(for task: TaskItem, sourceListID: String, context: ModelContext,
                               deleting: Bool = false) -> SyncChange {
        let destinationListID = task.taskList?.id
        let listIDs = Set([sourceListID, destinationListID].compactMap { $0 })
        let accountIDs = Set(listIDs.compactMap { try? accountID(forList: $0, in: context) })
        return SyncChange(revision: 0, accountIDs: accountIDs, listIDs: listIDs,
                          changedIDs: deleting ? [] : [task.id], deletedIDs: deleting ? [task.id] : [], kind: .tasks)
    }
}
