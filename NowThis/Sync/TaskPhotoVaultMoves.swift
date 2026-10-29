import Foundation
import SwiftData

/// Preserves originals locally before a moved task's source VTODO may be deleted.
actor TaskPhotoVaultMoves {
    private let files: any TaskPhotoFilesTransport
    private let cache: TaskPhotoCache

    init(files: any TaskPhotoFilesTransport = NextcloudPhotoClient(), cache: TaskPhotoCache = TaskPhotoOriginals.cache) {
        self.files = files
        self.cache = cache
    }

    private struct Photo: Sendable, Equatable {
        let localID: String
        let taskID: String
        let vaultListID: String
        let vaultAccountID: String
        let sourceFileID: String
        let sourceFolderID: String?
        let sourceAccountID: String
        let sourceListID: String
        let sourceCalendarHref: String
        let sourceBaseURL: String
        let sourceUsername: String
        let moveFromHref: String
        let moveFromListID: String
        let originalFileID: String?
        let folderFileID: String?
        let pendingOperation: String?
        let status: String?
    }

    func prepare(accountID: String, access: PhotoServerAccess, container: ModelContainer) async throws -> Set<String> {
        try Task.checkCancellation()
        await files.setRunDeadline(Date().addingTimeInterval(300))
        try Task.checkCancellation()
        let photos = try await Self.snapshot(accountID: accountID, container: container)
        try Task.checkCancellation()
        var changed = Set<String>()

        for photo in photos {
            try Task.checkCancellation()
            guard try await Self.isCurrent(photo, container: container) else { continue }
            try Task.checkCancellation()
            do {
                let cached = try await cache.load(photoID: photo.localID)
                try Task.checkCancellation()
                guard try await Self.isCurrent(photo, container: container) else { continue }
                try Task.checkCancellation()
                if cached == nil {
                    guard let folderID = photo.sourceFolderID, !folderID.isEmpty,
                          !photo.sourceCalendarHref.isEmpty,
                          photo.moveFromListID == photo.sourceListID,
                          photo.sourceBaseURL == access.baseURL,
                          photo.sourceUsername == access.username else {
                        throw TaskPhotoOriginalError.unavailable
                    }
                    let bytes = try await files.download(fileID: photo.sourceFileID, folderFileID: folderID,
                        calendarHref: photo.sourceCalendarHref, access: access)
                    try Task.checkCancellation()
                    guard try await Self.isCurrent(photo, container: container) else { continue }
                    try Task.checkCancellation()
                    // Preserve the full original. A stale completion must never remove a
                    // cache entry that another context may have populated in the meantime.
                    try await cache.store(bytes, photoID: photo.localID)
                    try Task.checkCancellation()
                    guard try await Self.isCurrent(photo, container: container) else { continue }
                    try Task.checkCancellation()
                }
                if let taskID = try await Self.commit(photo, status: "local", container: container) {
                    changed.insert(taskID)
                }
                try Task.checkCancellation()
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let taskID = try await Self.commit(photo, status: "unavailable", container: container) {
                    changed.insert(taskID)
                }
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        return changed
    }

    @MainActor
    private static func snapshot(accountID: String, container: ModelContainer) throws -> [Photo] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return try context.fetch(FetchDescriptor<TaskPhoto>(predicate: #Predicate {
            $0.originalRequested && $0.previousOriginalAccountID == accountID
        })).compactMap { try value(for: $0, in: context) }
    }

    @MainActor
    private static func value(for photo: TaskPhoto, in context: ModelContext) throws -> Photo? {
        guard photo.modelContext != nil, photo.originalRequested, photo.pendingOperation != "remove",
              let task = photo.task, task.modelContext != nil, !task.isDeletedLocally,
              let vault = task.taskList, let vaultAccount = vault.account, vaultAccount.mode == .vault,
              let moveHref = task.pendingMoveFromHref, !moveHref.isEmpty,
              let moveListID = task.pendingMoveFromListID,
              let fileID = photo.previousOriginalFileID, !fileID.isEmpty,
              let accountID = photo.previousOriginalAccountID,
              let listID = photo.previousOriginalListID,
              let source = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first,
              let account = source.account, account.id == accountID, account.mode != .vault else { return nil }
        return Photo(localID: photo.id, taskID: task.id, vaultListID: vault.id, vaultAccountID: vaultAccount.id,
            sourceFileID: fileID, sourceFolderID: photo.previousOriginalFolderID,
            sourceAccountID: accountID, sourceListID: listID, sourceCalendarHref: source.serverURL,
            sourceBaseURL: account.serverBaseURL, sourceUsername: account.username,
            moveFromHref: moveHref, moveFromListID: moveListID,
            originalFileID: photo.originalFileID, folderFileID: photo.folderFileID,
            pendingOperation: photo.pendingOperation, status: photo.originalStatus)
    }

    @MainActor
    private static func isCurrent(_ photo: Photo, container: ModelContainer) throws -> Bool {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let current = try checkedPhoto(photo, in: context, main: container.mainContext) != nil
        try Task.checkCancellation()
        return current
    }

    /// UI contexts can retain older saved rows, so use them to detect pending edits
    /// and read the authoritative move and source bindings from a fresh context.
    @MainActor
    private static func checkedPhoto(_ photo: Photo, in context: ModelContext, main: ModelContext) throws -> TaskPhoto? {
        let photoID = photo.localID
        let taskID = photo.taskID
        let pending = main.insertedModelsArray + main.changedModelsArray + main.deletedModelsArray
        guard !pending.contains(where: { model in
            if let row = model as? TaskPhoto { return row.id == photoID }
            if let row = model as? TaskItem { return row.id == taskID }
            if let row = model as? TaskList { return row.id == photo.vaultListID || row.id == photo.sourceListID }
            if let row = model as? ServerAccount { return row.id == photo.vaultAccountID || row.id == photo.sourceAccountID }
            return false
        }), let currentTask = try main.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first,
            currentTask.modelContext != nil, !currentTask.isDeletedLocally,
            !SyncPushAcknowledgement.hasPendingChange(currentTask, in: main),
            let stored = try context.fetch(FetchDescriptor<TaskPhoto>(predicate: #Predicate { $0.id == photoID })).first,
            try value(for: stored, in: context) == photo else { return nil }
        return stored
    }

    @MainActor
    private static func commit(_ photo: Photo, status: String, container: ModelContainer) throws -> String? {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let stored = try checkedPhoto(photo, in: context, main: container.mainContext),
              stored.originalStatus != status else { return nil }
        // Source identity and pending operations belong to the later DELETE acknowledgement.
        stored.originalStatus = status
        try context.save()
        return photo.taskID
    }
}
