import Foundation
import SwiftData

/// The values that define the local state a pending-move DELETE was sent for.
/// It contains no SwiftData models, so it can safely cross the network await.
struct SyncMoveSnapshot: Sendable {
    let taskID: String
    let uid: String
    let sourceHref: String
    let sourceListID: String
    let destinationListID: String
    let destinationHref: String?
    let etag: String?
    let isDirty: Bool
    let isLocalOnly: Bool
    let isDeletedLocally: Bool
    let stamp: Date
    let payload: String
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
    }

    private static func sources(_ task: TaskItem) -> [PhotoSource] {
        task.photos.filter { $0.previousOriginalFileID != nil }.sorted { $0.id < $1.id }.map {
            PhotoSource(localID: $0.id, previousFile: $0.previousOriginalFileID,
                previousFolder: $0.previousOriginalFolderID, previousAccount: $0.previousOriginalAccountID,
                previousList: $0.previousOriginalListID, destinationFile: $0.originalFileID,
                destinationFolder: $0.folderFileID, operation: $0.pendingOperation,
                requested: $0.originalRequested, cachedInVault: $0.originalStatus == "local")
        }
    }

    func hasSamePhotoSources(as task: TaskItem) -> Bool { photoSources == Self.sources(task) }

    init?(task: TaskItem) {
        guard let sourceHref = task.pendingMoveFromHref,
              let sourceListID = task.pendingMoveFromListID else { return nil }
        taskID = task.id
        uid = task.uid
        self.sourceHref = sourceHref
        self.sourceListID = sourceListID
        destinationListID = task.taskList?.id ?? ""
        destinationHref = task.remoteHref
        etag = task.etag
        isDirty = task.isDirty
        isLocalOnly = task.isLocalOnly
        isDeletedLocally = task.isDeletedLocally
        stamp = task.lastModifiedDate ?? Date()
        payload = SyncPushSnapshot.serialize(task, stamp: stamp)
        photoSources = Self.sources(task)
    }

    func hasSameMoveMarkers(as task: TaskItem) -> Bool {
        task.id == taskID
            && task.pendingMoveFromHref == sourceHref
            && task.pendingMoveFromListID == sourceListID
    }

    func isAtSentDestination(_ task: TaskItem) -> Bool {
        task.taskList?.id == destinationListID && task.remoteHref == destinationHref
    }

    func stillMatches(_ task: TaskItem) -> Bool {
        hasSameMoveMarkers(as: task)
            && task.uid == uid
            && task.taskList?.id == destinationListID
            && task.remoteHref == destinationHref
            && task.etag == etag
            && task.isDirty == isDirty
            && task.isLocalOnly == isLocalOnly
            && task.isDeletedLocally == isDeletedLocally
            && SyncPushSnapshot.serialize(task, stamp: stamp) == payload
    }
}

/// Applies move acknowledgements on the main actor, against current UI state,
/// while saving through an independent context so older registered models cannot
/// overwrite edits made during the DELETE request.
enum SyncMoveAcknowledgement {
    @MainActor
    static func deletionSnapshot(_ candidate: SyncMoveSnapshot, container: ModelContainer) throws -> SyncMoveSnapshot? {
        let id = candidate.taskID
        let predicate = #Predicate<TaskItem> { $0.id == id }
        let main = container.mainContext
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first,
              !SyncPushAcknowledgement.hasPendingChange(current, in: main) else { return nil }
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              candidate.hasSameMoveMarkers(as: stored), !stored.isDeletedLocally,
              PendingMoveSweep.isReady(stored) else { return nil }
        return SyncMoveSnapshot(task: stored)
    }

    @MainActor
    @discardableResult
    static func acknowledgeDelete(_ snapshot: SyncMoveSnapshot, container: ModelContainer) throws -> SyncChange? {
        let id = snapshot.taskID
        let predicate = #Predicate<TaskItem> { $0.id == id }
        let main = container.mainContext
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first,
              current.modelContext != nil, !current.isDeletedLocally else { return nil }
        let pending = main.insertedModelsArray + main.changedModelsArray + main.deletedModelsArray
        let photoIDs = Set(current.photos.map(\.persistentModelID))
        guard !pending.contains(where: { $0 is TaskPhoto && photoIDs.contains($0.persistentModelID) }) else { return nil }
        if pending.contains(where: { $0.persistentModelID == current.persistentModelID }) {
            // A pending title edit is independent from finishing the acknowledged move.
            guard snapshot.hasSameMoveMarkers(as: current), snapshot.isAtSentDestination(current) else { return nil }
        }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              snapshot.hasSameMoveMarkers(as: stored), snapshot.isAtSentDestination(stored),
              snapshot.hasSamePhotoSources(as: stored), PendingMoveSweep.isReady(stored) else { return nil }

        TaskPhotoSyncStore.completeMove(stored, in: context)
        stored.pendingMoveFromHref = nil
        stored.pendingMoveFromListID = nil
        try context.save()
        return change(for: stored, sourceListID: snapshot.sourceListID, context: context)
    }

    @MainActor
    @discardableResult
    static func rollBackRefusedDelete(_ snapshot: SyncMoveSnapshot, container: ModelContainer) throws -> SyncChange? {
        let id = snapshot.taskID
        let predicate = #Predicate<TaskItem> { $0.id == id }
        let main = container.mainContext
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first,
              !SyncPushAcknowledgement.hasPendingChange(current, in: main) else { return nil }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              snapshot.stillMatches(stored),
              TaskMover.rollBackRefusedDelete(stored, in: context) else { return nil }

        try context.save()
        return change(for: stored, sourceListID: snapshot.sourceListID, context: context)
    }

    private static func change(for task: TaskItem, sourceListID: String, context: ModelContext) -> SyncChange {
        let destinationListID = task.taskList?.id
        let listIDs = Set([sourceListID, destinationListID].compactMap { $0 })
        let accountIDs = Set(listIDs.compactMap { listID -> String? in
            let predicate = #Predicate<TaskList> { $0.id == listID }
            return (try? context.fetch(FetchDescriptor(predicate: predicate)).first)?.account?.id
        })
        return SyncChange(revision: 0, accountIDs: accountIDs, listIDs: listIDs,
                          changedIDs: [task.id], deletedIDs: [], kind: .tasks)
    }
}
