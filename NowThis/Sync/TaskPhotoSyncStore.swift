import Foundation
import SwiftData

/// Context-confined photo reconciliation. Pending operations rebase by wire UUID.
enum TaskPhotoSyncStore {
    static func apply(_ attachments: [TaskPhotoAttachment], opaque: [String], to task: TaskItem,
                      in context: ModelContext, scope: TaskList? = nil) throws {
        let existing = Dictionary(task.photos.map { ($0.photoID, $0) }, uniquingKeysWith: { first, _ in first })
        let incoming = Set(attachments.map(\.id))
        for (order, attachment) in attachments.enumerated() {
            let photo = existing[attachment.id] ?? TaskPhoto(photoID: attachment.id, previewData: attachment.previewData)
            if photo.modelContext == nil { context.insert(photo); photo.task = task }
            guard photo.pendingOperation == nil else { continue }
            let previousFile = photo.originalFileID
            if let list = scope ?? task.taskList {
                let update = try TaskPhotoOwnership.accepted(photo, fileID: attachment.originalFileID,
                    folderID: attachment.folderFileID, list: list, in: context)
                update.apply(in: context, normalize: true)
            } else if attachment.originalFileID != nil { throw TaskPhotoOwnership.Failure.missingOwner }
            photo.previewData = attachment.previewData
            photo.sortOrder = order
            photo.originalRequested = attachment.originalRequested
            if previousFile != attachment.originalFileID { photo.originalStatus = nil }
            photo.originalFileID = attachment.originalFileID
            photo.folderFileID = attachment.folderFileID
        }
        for photo in task.photos where !incoming.contains(photo.photoID) && photo.pendingOperation == nil {
            // Retain originals until their exact cleanup obligation is durable.
            if task.pendingMoveFromHref != nil { photo.pendingOperation = "remove"; continue }
            try TaskPhotoCleanupQueue.enqueuePhoto(photo, in: context)
            context.delete(photo)
        }
        task.opaqueAttachments = opaque
        task.attachmentStateKnown = true
    }

    static func acknowledge(_ task: TaskItem, in context: ModelContext) throws {
        for photo in task.photos {
            if photo.pendingOperation == "remove" {
                guard task.pendingMoveFromHref == nil else { continue }
                try TaskPhotoCleanupQueue.enqueuePhoto(photo, in: context)
                context.delete(photo)
            } else {
                photo.pendingOperation = nil
                if photo.originalFileID != nil {
                    photo.originalStatus = "available"
                    if task.pendingMoveFromHref == nil { try finishPrevious(photo, in: context) }
                }
            }
        }
    }

    static func completeMove(_ task: TaskItem, in context: ModelContext) throws {
        for photo in task.photos {
            if photo.pendingOperation == "remove" {
                try TaskPhotoCleanupQueue.enqueuePhoto(photo, in: context)
                context.delete(photo)
            } else { try finishPrevious(photo, in: context) }
        }
    }

    private static func finishPrevious(_ photo: TaskPhoto, in context: ModelContext) throws {
        let record = try TaskPhotoOwnership.read(photo, in: context)
        for binding in record.state.retained { try TaskPhotoCleanupQueue.enqueue(binding, in: context) }
        var next = record.state; next.retained = []
        try record.update(next).apply(in: context, normalize: true)
    }

    struct MovePlan {
        let updates: [TaskPhotoOwnership.Update]
        let restoring: Bool
        func apply(in context: ModelContext) {
            for update in updates {
                update.apply(in: context, normalize: true)
                let photo = update.photo
                if restoring {
                    photo.originalStatus = photo.originalFileID == nil ? "pending" : "available"
                    if update.state.current != nil, photo.pendingOperation == "add" { photo.pendingOperation = nil }
                } else {
                    if photo.originalRequested { photo.originalStatus = "pending" }
                    if photo.pendingOperation != "remove" { photo.pendingOperation = "add" }
                }
            }
        }
    }

    static func movePlan(_ task: TaskItem, restoring source: TaskList? = nil,
                         in context: ModelContext, reads: TaskPhotoOwnership.Reads = .init()) throws -> MovePlan {
        let records = try TaskPhotoOwnership.records(task, in: context, reads: reads)
        let updates = try records.map { record in
            var next = record.state
            let current = next.current; next.current = nil
            try next.retain(current)
            if let source, let binding = next.retained.first(where: { $0.matches(source) }) {
                next.current = binding; next.retained.removeAll { $0 == binding }
            }
            return try record.update(next)
        }
        return MovePlan(updates: updates, restoring: source != nil)
    }

    static func prepareMove(_ task: TaskItem, source: TaskList? = nil) throws {
        guard let context = task.modelContext else { throw TaskPhotoOwnership.Failure.missingOwner }
        try movePlan(task, in: context).apply(in: context)
    }
}

/// Reuses the existing metadata model for durable, account-scoped cleanup work.
/// A complete authenticated remote scan must prove no VTODO still refers to the file.
enum TaskPhotoCleanupQueue {
    static let prefix = "taskPhotoCleanup:"

    struct DeletionReads {
        var ownershipRow: (ModelContext, FetchDescriptor<SyncMetadata>) throws -> SyncMetadata? = { try $0.fetch($1).first }
        var queuedWork: (ModelContext, FetchDescriptor<SyncMetadata>) throws -> SyncMetadata? = { try $0.fetch($1).first }
        var previousList: (ModelContext, String) throws -> TaskList? = { context, listID in
            try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first
        }
    }

    enum OwnershipError: Error {
        case missingOwner
        case conflictingWork
        case ambiguousPendingRemoval
    }

    static func hasAmbiguousPendingRemoval(in task: TaskItem) -> Bool {
        guard task.pendingMoveFromHref != nil, let context = task.modelContext else { return false }
        do { _ = try TaskPhotoOwnership.records(task, in: context); return false }
        catch { return true }
    }

    static func enqueue(_ fileID: String?, folderID: String? = nil, account: ServerAccount?, list: TaskList?,
                        in context: ModelContext) {
        guard let fileID, let account, let list else { return }
        try? enqueue(fileID, folderID: folderID, accountID: account.id, list: list, in: context, reads: .init())
    }

    private static func enqueue(_ fileID: String, folderID: String?, accountID: String, list: TaskList,
                                in context: ModelContext, reads: DeletionReads) throws {
        let key = prefix + accountID + ":" + list.id + ":" + fileID
        let descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })
        if let existing = try reads.queuedWork(context, descriptor) {
            guard existing.syncToken == fileID, existing.lastCTag == accountID,
                  existing.collectionPath == list.serverURL, existing.photoFolderID == folderID else {
                throw OwnershipError.conflictingWork
            }
            return
        }
        let work = SyncMetadata(id: key, collectionPath: list.serverURL)
        work.photoFolderID = folderID
        work.syncToken = fileID; work.lastCTag = accountID
        work.lastFullSync = Date().addingTimeInterval(24 * 60 * 60)
        context.insert(work)
    }

    static func enqueuePrevious(_ photo: TaskPhoto, in context: ModelContext) {
        guard let listID = photo.previousOriginalListID else { return }
        let list = try? DeletionReads().previousList(context, listID)
        enqueue(photo.previousOriginalFileID, folderID: photo.previousOriginalFolderID, account: list?.account,
                list: list, in: context)
    }

    /// The caller has revalidated that this task is a leaf. The cleanup rows
    /// and deletion are saved together by its private acknowledgement context.
    static func enqueueDeletion(_ task: TaskItem, in context: ModelContext, reads: DeletionReads = .init()) throws {
        let ownershipReads = TaskPhotoOwnership.Reads(row: reads.ownershipRow, list: reads.previousList)
        let records = try TaskPhotoOwnership.records(task, in: context, reads: ownershipReads)
        for record in records {
            for binding in [record.state.current].compactMap({ $0 }) + record.state.retained {
                try enqueue(binding, in: context, reads: reads)
            }
        }
        for record in records { if let row = record.row { context.delete(row) } }
    }

    static func enqueuePhoto(_ photo: TaskPhoto, in context: ModelContext) throws {
        let record = try TaskPhotoOwnership.read(photo, in: context)
        for binding in [record.state.current].compactMap({ $0 }) + record.state.retained {
            try enqueue(binding, in: context)
        }
        if let row = record.row { context.delete(row) }
    }

    static func enqueue(_ binding: TaskPhotoOwnership.Binding, in context: ModelContext,
                        reads: DeletionReads = .init()) throws {
        guard let list = try reads.previousList(context, binding.listID), binding.matches(list) else {
            throw OwnershipError.missingOwner
        }
        try enqueue(binding.fileID, folderID: binding.folderID, accountID: binding.accountID,
                    list: list, in: context, reads: reads)
    }
}
