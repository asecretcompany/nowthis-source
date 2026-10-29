import Foundation
import SwiftData

/// Before the first edit or move of a legacy import, retain attachments the older app never stored.
enum TaskPhotoLegacyCatchUp {
    struct RequestInfo: Sendable, Equatable {
        let href: String
        let sourceAccountID: String
        let sourceListID: String?
    }

    @MainActor
    static func requestInfo(taskID: String, listID: String, accountID: String,
                            container: ModelContainer) throws -> RequestInfo? {
        let main = container.mainContext
        let predicate = #Predicate<TaskItem> { $0.id == taskID }
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first,
              !SyncPushAcknowledgement.hasPendingChange(current, in: main) else { return nil }
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let task = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              task.attachmentStateKnown != true, task.taskList?.id == listID,
              task.taskList?.account?.id == accountID, !task.isDeletedLocally else { return nil }
        return try request(for: task, in: context)
    }

    /// Compatibility for existing callers; the engine needs source credentials as well as the href.
    @MainActor
    static func requiredHref(taskID: String, listID: String, accountID: String,
                             container: ModelContainer) throws -> String? {
        try requestInfo(taskID: taskID, listID: listID, accountID: accountID, container: container)?.href
    }

    @MainActor
    private static func request(for task: TaskItem, in context: ModelContext) throws -> RequestInfo? {
        if let href = task.remoteHref, !href.isEmpty, let accountID = task.taskList?.account?.id {
            return RequestInfo(href: href, sourceAccountID: accountID, sourceListID: nil)
        }
        guard let href = task.pendingMoveFromHref, !href.isEmpty,
              let sourceID = task.pendingMoveFromListID,
              let source = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == sourceID })).first,
              let accountID = source.account?.id else { return nil }
        return RequestInfo(href: href, sourceAccountID: accountID, sourceListID: sourceID)
    }

    @MainActor
    static func apply(_ data: ICalendarParser.VTODOData, taskID: String, listID: String,
                      accountID: String, href: String, container: ModelContainer,
                      expectedRequest: RequestInfo? = nil) throws -> SyncChange? {
        let main = container.mainContext
        let predicate = #Predicate<TaskItem> { $0.id == taskID }
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first,
              !SyncPushAcknowledgement.hasPendingChange(current, in: main) else { return nil }
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              stored.attachmentStateKnown != true, stored.taskList?.id == listID,
              stored.taskList?.account?.id == accountID, !stored.isDeletedLocally,
              let request = try request(for: stored, in: context), request.href == href,
              expectedRequest == nil || expectedRequest == request else { return nil }
        guard data.uid == stored.uid else { throw CalDAVError.invalidResponse }
        let source: TaskList?
        if let sourceID = request.sourceListID {
            guard let sourceList = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == sourceID })).first,
                  sourceList.account?.id == request.sourceAccountID else { return nil }
            source = sourceList
        } else { source = nil }
        TaskPhotoSyncStore.apply(data.photos, opaque: data.opaqueAttachments, to: stored, in: context)
        if let source { TaskPhotoSyncStore.prepareMove(stored, source: source) }
        try context.save()
        return SyncChange(revision: 0, accountIDs: [accountID], listIDs: [listID],
            changedIDs: [taskID], deletedIDs: [], kind: .tasks)
    }
}
