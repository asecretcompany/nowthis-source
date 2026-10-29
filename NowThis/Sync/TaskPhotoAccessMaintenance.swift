import Foundation
import SwiftData

/// Revocation needs a definitive authenticated collection response, never discovery absence alone.
enum TaskPhotoAccessMaintenance {
    @MainActor
    static func canView(task: TaskItem, container: ModelContainer) throws -> Bool {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        guard task.modelContext != nil, !task.isDeletedLocally else { return false }
        guard let listID = task.taskList?.id else { return true }
        let context = ModelContext(container); context.autosaveEnabled = false
        if let stored = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first {
            return stored.photoAccessRevoked != true
        }
        // A new local list is editable before its first save; a deleted persisted list is not.
        guard let list = task.taskList, let owner = list.modelContext, owner.container === container else { return false }
        return owner.insertedModelsArray.contains { $0.persistentModelID == list.persistentModelID }
    }

    @MainActor
    static func canEdit(task: TaskItem, container: ModelContainer) throws -> Bool {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        guard try canView(task: task, container: container), task.taskList?.isReadOnly != true else { return false }
        guard let listID = task.taskList?.id else { return true }
        let context = ModelContext(container); context.autosaveEnabled = false
        return try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first?.isReadOnly != true
    }

    @MainActor
    static func revoke(listID: String, container: ModelContainer,
                       cache: TaskPhotoCache = TaskPhotoOriginals.cache) async throws -> SyncChange? {
        let (change, purged): (SyncChange?, [String]) = try BackgroundRunBudget.protectingCurrent {
            let context = ModelContext(container); context.autosaveEnabled = false
            guard let list = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first else { return (nil, []) }
            let accountID = list.account?.id
            // Nested optional relationship predicates trap on older SwiftData runtimes.
            var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.taskList?.id == listID })
            descriptor.relationshipKeyPathsForPrefetching = [\.photos]
            let tasks = try context.fetch(descriptor)
            let photos = tasks.flatMap(\.photos)
            // Durable previews and unsent operations remain recoverable; downloaded originals are dropped.
            let purged = photos.filter { !($0.pendingOperation == "add" && $0.originalFileID == nil) }.map(\.id)
            list.photoAccessRevoked = true; list.syncCTag = nil; list.lastFullPullDate = nil
            if let accountID { try SyncImportCheckpoint.removeList(accountID: accountID, listID: listID, in: context) }
            try context.save()
            return (SyncChange(revision: 0, accountIDs: Set([accountID].compactMap { $0 }), listIDs: [listID],
                changedIDs: Set(tasks.map(\.id)), deletedIDs: [], kind: .tasks), purged)
        }
        for id in purged {
            try Task.checkCancellation()
            try await cache.remove(photoID: id)
        }
        return change
    }

    @MainActor
    static func restore(listID: String, container: ModelContainer) throws -> SyncChange? {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let list = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first,
              list.photoAccessRevoked == true else { return nil }
        list.photoAccessRevoked = false; list.syncCTag = nil; list.lastFullPullDate = nil
        if let accountID = list.account?.id {
            try SyncImportCheckpoint.removeList(accountID: accountID, listID: listID, in: context)
        }
        try context.save()
        return SyncChange(revision: 0, accountIDs: Set([list.account?.id].compactMap { $0 }), listIDs: [listID],
            changedIDs: [], deletedIDs: [], kind: .lists)
    }

    @MainActor
    static func prune(container: ModelContainer, cache: TaskPhotoCache = TaskPhotoOriginals.cache) async throws {
        let retained = try BackgroundRunBudget.protectingCurrent {
            let context = ModelContext(container); context.autosaveEnabled = false
            return Set(try context.fetch(FetchDescriptor<TaskPhoto>()).map(\.id))
        }
        // A library import may have cached bytes just before its model save boundary.
        try await cache.retain(photoIDs: retained, olderThan: Date().addingTimeInterval(-3600))
    }
}
