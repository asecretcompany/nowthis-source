import Foundation
import SwiftData

/// Values actually sent. Acknowledgements never write through a model held across the HTTP await.
struct SyncPushSnapshot: Sendable {
    let taskID: String
    let uid: String
    let listID: String
    let accountID: String?
    let path: String
    let originalHref: String?
    let etag: String?
    let modifiedAt: Date?
    let stamp: Date
    let payload: String

    init(task: TaskItem, calendarPath: String, stamp: Date = Date()) {
        taskID = task.id; uid = task.uid; listID = task.taskList?.id ?? ""
        accountID = task.taskList?.account?.id
        originalHref = task.remoteHref
        path = task.remoteHref.flatMap { $0.isEmpty ? nil : $0 } ?? calendarPath + task.uid + ".ics"
        etag = task.etag; modifiedAt = task.lastModifiedDate
        self.stamp = stamp
        payload = Self.serialize(task, stamp: stamp)
    }

    func stillMatches(_ task: TaskItem) -> Bool {
        task.id == taskID && task.uid == uid && task.taskList?.id == listID
            && task.remoteHref == originalHref && !task.isDeletedLocally
            && task.lastModifiedDate == modifiedAt && Self.serialize(task, stamp: stamp) == payload
    }

    static func serialize(_ task: TaskItem, stamp: Date) -> String {
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
            lastModifiedDate: task.lastModifiedDate ?? stamp,
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
            dtStamp: stamp,
            photos: task.photoAttachments,
            opaqueAttachments: task.opaqueAttachments
        )
    }
}

/// The main actor serializes this tiny acknowledgement with UI mutations. Persistence uses a
/// fresh context so saving accepted metadata cannot write stale fields over a later saved edit.
enum SyncPushAcknowledgement {
    @MainActor
    static func snapshot(taskID: String, calendarPath: String, container: ModelContainer, expectedListID: String? = nil, expectedAccountID: String? = nil) throws -> SyncPushSnapshot? {
        let main = container.mainContext
        let predicate = #Predicate<TaskItem> { $0.id == taskID }
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first,
              !hasPendingChange(current, in: main) else { return nil }
        // Registered UI rows can lag a completed import/original upload. Read the durable payload.
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let task = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              !task.isDeletedLocally, task.isDirty, task.taskList?.photoAccessRevoked != true else { return nil }
        guard expectedListID == nil || task.taskList?.id == expectedListID,
              expectedAccountID == nil || task.taskList?.account?.id == expectedAccountID else { return nil }
        guard (task.remoteHref?.isEmpty != false && task.pendingMoveFromHref == nil) || task.attachmentStateKnown == true,
              task.photoAttachments.count <= 5,
              task.photoAttachments.allSatisfy({ $0.contentLine != nil }) else {
            throw TaskPhotoAttachmentError.invalid
        }
        return SyncPushSnapshot(task: task, calendarPath: calendarPath)
    }

    @MainActor
    static func acknowledge(_ snapshot: SyncPushSnapshot, etag: String?, container: ModelContainer) throws {
        let main = container.mainContext
        let id = snapshot.taskID
        let predicate = #Predicate<TaskItem> { $0.id == id }
        let current = try main.fetch(FetchDescriptor(predicate: predicate)).first
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first

        if let current, let stored, current.taskList?.id == snapshot.listID, stored.taskList?.id == snapshot.listID {
            // Retain the accepted ETag even when a newer edit must be uploaded next.
            let unchanged = snapshot.stillMatches(stored) && !hasPendingChange(current, in: main)
            stored.etag = etag
            stored.isLocalOnly = false
            stored.remoteHref = snapshot.path
            stored.isDirty = unchanged ? false : true
            if unchanged { TaskPhotoSyncStore.acknowledge(stored, in: context) }
            try context.save()
        } else {
            // A PUT into the former list can succeed after a move or local delete. Persist
            // its cleanup through the existing tombstone path, without acknowledging a new destination.
            if current?.pendingMoveFromHref == snapshot.path && current?.pendingMoveFromListID == snapshot.listID {
                return // The durable move already carries this source cleanup.
            }
            let listID = snapshot.listID
            let listPredicate = #Predicate<TaskList> { $0.id == listID }
            guard let list = try context.fetch(FetchDescriptor(predicate: listPredicate)).first else { return }
            let path = snapshot.path
            let cleanupPredicate = #Predicate<TaskItem> {
                $0.isDeletedLocally && $0.calendarURL == path && $0.taskList?.id == listID
            }
            if try context.fetchCount(FetchDescriptor(predicate: cleanupPredicate)) == 0 {
                let cleanup = TaskItem(uid: snapshot.uid, title: "")
                cleanup.taskList = list; cleanup.remoteHref = snapshot.path; cleanup.etag = etag
                cleanup.isDeletedLocally = true; cleanup.isLocalOnly = false
                context.insert(cleanup)
                try context.save()
            }
        }
    }

    @MainActor
    static func applyConflict(_ snapshot: SyncPushSnapshot, resource: ParsedRemoteTask,
                              container: ModelContainer) throws -> SyncChange {
        let id = snapshot.taskID
        let predicate = #Predicate<TaskItem> { $0.id == id }
        let main = container.mainContext
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first,
              !hasPendingChange(current, in: main),
              let todo = resource.todo, todo.uid == snapshot.uid else { throw CalDAVError.conflict(etag: nil) }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              snapshot.stillMatches(stored) else { throw CalDAVError.conflict(etag: nil) }
        let importer = try SyncImportStore(context: context)
        importer.applyFields(todo, to: stored)
        stored.etag = resource.etag; stored.remoteHref = resource.href
        stored.isDirty = stored.photos.contains { $0.pendingOperation != nil }
        let accounts = Set([stored.taskList?.account?.id].compactMap { $0 })
        try context.save()
        return SyncChange(revision: 0, accountIDs: accounts, listIDs: [snapshot.listID],
            changedIDs: [id], deletedIDs: [], kind: .tasks)
    }

    @MainActor
    static func rollBackRefusedMove(_ snapshot: SyncPushSnapshot, container: ModelContainer) throws -> SyncChange {
        let id = snapshot.taskID
        let predicate = #Predicate<TaskItem> { $0.id == id }
        let main = container.mainContext
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first,
              !hasPendingChange(current, in: main) else { throw CalDAVError.forbidden }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              snapshot.stillMatches(stored), TaskMover.rollBackRefusedPut(stored, in: context) else { throw CalDAVError.forbidden }
        let lists = Set([snapshot.listID, stored.taskList?.id].compactMap { $0 })
        let accounts = Set([snapshot.accountID, stored.taskList?.account?.id].compactMap { $0 })
        try context.save()
        return SyncChange(revision: 0, accountIDs: accounts, listIDs: lists,
            changedIDs: [id], deletedIDs: [], kind: .tasks)
    }

    @MainActor
    static func deletionSnapshot(taskID: String, container: ModelContainer) throws -> SyncDeleteSnapshot? {
        let id = taskID
        let main = container.mainContext
        guard let task = try main.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first,
              task.isDeletedLocally, !hasPendingChange(task, in: main) else { return nil }
        return SyncDeleteSnapshot(taskID: id, uid: task.uid, listID: task.taskList?.id ?? "",
            href: task.remoteHref, etag: task.etag)
    }

    @MainActor
    static func acknowledgeDeletion(_ snapshot: SyncDeleteSnapshot, container: ModelContainer) throws -> SyncChange? {
        let id = snapshot.taskID
        let predicate = #Predicate<TaskItem> { $0.id == id }
        let main = container.mainContext
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first else { return nil }
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first else { return nil }
        let accounts = Set([stored.taskList?.account?.id].compactMap { $0 })
        let lists = Set([snapshot.listID, stored.taskList?.id].compactMap { $0 })
        if current.isDeletedLocally && current.taskList?.id == snapshot.listID
            && current.remoteHref == snapshot.href && !hasPendingChange(current, in: main) {
            TaskPhotoCleanupQueue.enqueueDeletion(stored, in: context)
            context.delete(stored)
            try context.save()
            return SyncChange(revision: 0, accountIDs: accounts, listIDs: lists,
                changedIDs: [], deletedIDs: [id], kind: .tasks)
        }
        // The user restored/moved the task while the old DELETE was in flight. Its next
        // upload must create a new copy; an If-Match against the removed ETag cannot succeed.
        if stored.taskList?.id == snapshot.listID && stored.remoteHref == snapshot.href {
            stored.remoteHref = nil; stored.etag = nil; stored.isDirty = true
            try context.save()
        }
        return nil
    }

    @MainActor
    static func hasPendingChange(_ task: TaskItem, in context: ModelContext) -> Bool {
        let ids = Set([task.persistentModelID] + task.photos.map(\.persistentModelID))
        return (context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray)
            .contains { ids.contains($0.persistentModelID) }
    }
}

struct SyncDeleteSnapshot: Sendable {
    let taskID: String
    let uid: String
    let listID: String
    let href: String?
    let etag: String?
}
