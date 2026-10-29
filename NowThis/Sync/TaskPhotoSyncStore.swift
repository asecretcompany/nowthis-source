import Foundation
import SwiftData

/// Context-confined photo reconciliation. Pending operations rebase by wire UUID.
enum TaskPhotoSyncStore {
    static func apply(_ attachments: [TaskPhotoAttachment], opaque: [String], to task: TaskItem, in context: ModelContext) {
        let existing = Dictionary(task.photos.map { ($0.photoID, $0) }, uniquingKeysWith: { first, _ in first })
        let incoming = Set(attachments.map(\.id))
        for (order, attachment) in attachments.enumerated() {
            let photo = existing[attachment.id] ?? TaskPhoto(photoID: attachment.id, previewData: attachment.previewData)
            if photo.modelContext == nil { context.insert(photo); photo.task = task }
            // A local addition or removal is an operation, not a stale remote value.
            guard photo.pendingOperation == nil else { continue }
            photo.previewData = attachment.previewData
            photo.sortOrder = order
            photo.originalRequested = attachment.originalRequested
            if photo.originalFileID != attachment.originalFileID { photo.originalStatus = nil }
            photo.originalFileID = attachment.originalFileID
            photo.folderFileID = attachment.folderFileID
        }
        for photo in task.photos where !incoming.contains(photo.photoID) && photo.pendingOperation == nil {
            context.delete(photo)
        }
        task.opaqueAttachments = opaque
        task.attachmentStateKnown = true
    }

    static func acknowledge(_ task: TaskItem, in context: ModelContext) {
        for photo in task.photos {
            if photo.pendingOperation == "remove" {
                TaskPhotoCleanupQueue.enqueue(photo.originalFileID, folderID: photo.folderFileID, account: task.taskList?.account,
                    list: task.taskList, in: context)
                TaskPhotoCleanupQueue.enqueuePrevious(photo, in: context)
                context.delete(photo)
            } else {
                photo.pendingOperation = nil
                if photo.originalFileID != nil {
                    photo.originalStatus = "available"
                    if task.pendingMoveFromHref == nil {
                        finishPrevious(photo, in: context)
                    }
                }
            }
        }
    }

    static func completeMove(_ task: TaskItem, in context: ModelContext) {
        for photo in task.photos {
            finishPrevious(photo, in: context)
            if task.taskList?.account?.mode == .vault, photo.pendingOperation == TaskPhotoOperation.remove.rawValue {
                context.delete(photo)
            }
        }
    }

    private static func finishPrevious(_ photo: TaskPhoto, in context: ModelContext) {
        TaskPhotoCleanupQueue.enqueuePrevious(photo, in: context)
        photo.previousOriginalFolderID = nil
        photo.previousOriginalFileID = nil
        photo.previousOriginalAccountID = nil
        photo.previousOriginalListID = nil
    }

    static func restoreMove(_ task: TaskItem, source: TaskList, in context: ModelContext) {
        for photo in task.photos {
            if task.remoteHref == nil, photo.originalFileID != photo.previousOriginalFileID {
                TaskPhotoCleanupQueue.enqueue(photo.originalFileID, folderID: photo.folderFileID,
                    account: task.taskList?.account, list: task.taskList, in: context)
            }
            guard photo.previousOriginalListID == source.id else { continue }
            photo.originalFileID = photo.previousOriginalFileID
            photo.folderFileID = photo.previousOriginalFolderID
            photo.originalStatus = photo.originalFileID == nil ? "pending" : "available"
            photo.previousOriginalFolderID = nil
            photo.previousOriginalFileID = nil
            photo.previousOriginalAccountID = nil
            photo.previousOriginalListID = nil
            if photo.pendingOperation == "add" { photo.pendingOperation = nil }
        }
    }

    static func prepareMove(_ task: TaskItem, source: TaskList? = nil) {
        let source = source ?? task.taskList
        for photo in task.photos where photo.pendingOperation != "remove" {
            if photo.previousOriginalFileID == nil, let original = photo.originalFileID {
                photo.previousOriginalFolderID = photo.folderFileID
                photo.previousOriginalFileID = original
                photo.previousOriginalAccountID = source?.account?.id
                photo.previousOriginalListID = source?.id
            }
            photo.originalFileID = nil; photo.folderFileID = nil
            if photo.originalRequested { photo.originalStatus = "pending" }
            photo.pendingOperation = "add"
        }
    }
}

/// Reuses the existing metadata model for durable, account-scoped cleanup work.
/// A complete authenticated remote scan must prove no VTODO still refers to the file.
enum TaskPhotoCleanupQueue {
    static let prefix = "taskPhotoCleanup:"

    static func enqueue(_ fileID: String?, folderID: String? = nil, account: ServerAccount?, list: TaskList?, in context: ModelContext) {
        guard let fileID, let account, let list else { return }
        let key = prefix + account.id + ":" + list.id + ":" + fileID
        let descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })
        guard (try? context.fetchCount(descriptor)) == 0 else { return }
        let work = SyncMetadata(id: key, collectionPath: list.serverURL)
        work.photoFolderID = folderID
        work.syncToken = fileID; work.lastCTag = account.id
        work.lastFullSync = Date().addingTimeInterval(24 * 60 * 60)
        context.insert(work)
    }

    static func enqueuePrevious(_ photo: TaskPhoto, in context: ModelContext) {
        guard let listID = photo.previousOriginalListID else { return }
        let list = try? context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first
        enqueue(photo.previousOriginalFileID, folderID: photo.previousOriginalFolderID, account: list?.account, list: list, in: context)
    }

    static func enqueueDeletion(_ task: TaskItem, in context: ModelContext) {
        var stack = [task]; var seen = Set<String>()
        while let node = stack.popLast() {
            guard seen.insert(node.id).inserted else { continue }
            for photo in node.photos {
                enqueue(photo.originalFileID, folderID: photo.folderFileID, account: node.taskList?.account, list: node.taskList, in: context)
                enqueuePrevious(photo, in: context)
            }
            stack.append(contentsOf: node.subtasks)
        }
    }
}
