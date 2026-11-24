import Foundation
import SwiftData

/// Before the first edit or move of a legacy import, retain attachments the older app never stored.
enum TaskPhotoLegacyCatchUp {
    struct RequestInfo: Sendable, Equatable {
        let href: String
        let sourceAccountID: String
        let sourceListID: String?
        let photoScope: TaskPhotoOwnership.Scope?
        var sourceBaseline: SyncResourceState? = nil
        var captureKind: SyncResourceState.CaptureKind { sourceListID == nil ? .currentResource : .moveSource }
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
              task.taskList?.id == listID,
              task.taskList?.account?.id == accountID else { return nil }
        guard let request = try request(for: task, in: context), let scope = request.photoScope else { return nil }
        let record = try SyncResourceState.read(scope: scope, href: request.href, in: context)
        if record?.shape == .unsupported { return nil }
        let state = try VTODOOpaqueState.load(taskID: task.id, in: context)
        let shapeKnown: Bool
        if request.sourceListID != nil || request.sourceBaseline != nil {
            shapeKnown = request.sourceBaseline?.shape == .singleTask && request.sourceBaseline?.etag.isEmpty == false
                && request.sourceBaseline?.uid == task.uid && record?.shape == .singleTask
                && record?.uid == task.uid && record?.etag.isEmpty == false
        } else {
            shapeKnown = (try? SyncResourceState.proof(list: task.taskList, href: request.href,
                etag: task.etag, taskID: task.id, uid: task.uid, in: context)) != nil
        }
        guard task.attachmentStateKnown != true || state == nil || !shapeKnown else { return nil }
        return request
    }

    /// Compatibility for existing callers; the engine needs source credentials as well as the href.
    @MainActor
    static func requiredHref(taskID: String, listID: String, accountID: String,
                             container: ModelContainer) throws -> String? {
        try requestInfo(taskID: taskID, listID: listID, accountID: accountID, container: container)?.href
    }

    @MainActor
    private static func request(for task: TaskItem, in context: ModelContext) throws -> RequestInfo? {
        // An older app may already have rewritten the destination without unknown
        // fields. Until source cleanup finishes, its original copy is authoritative.
        if let href = task.pendingMoveFromHref, !href.isEmpty {
            guard let sourceID = task.pendingMoveFromListID,
                  let source = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == sourceID })).first,
                  let accountID = source.account?.id else { throw CalDAVError.invalidResponse }
            return RequestInfo(href: href, sourceAccountID: accountID, sourceListID: sourceID,
                photoScope: TaskPhotoOwnership.Scope(list: source),
                sourceBaseline: try TaskPhotoOwnership.Scope(list: source).flatMap {
                    try SyncResourceState.capture(taskID: task.id, scope: $0, href: href, in: context)
                })
        }
        if let href = task.remoteHref, !href.isEmpty, let accountID = task.taskList?.account?.id {
            return RequestInfo(href: href, sourceAccountID: accountID, sourceListID: nil,
                photoScope: TaskPhotoOwnership.Scope(list: task.taskList),
                sourceBaseline: task.isDeletedLocally ? try TaskPhotoOwnership.Scope(list: task.taskList).flatMap {
                    try SyncResourceState.capture(taskID: task.id, scope: $0, href: href, kind: .currentResource, in: context)
                } : nil)
        }
        return nil

    }

    @MainActor
    static func accept(_ resource: ParsedRemoteTask, taskID: String, listID: String,
                       accountID: String, expectedRequest: RequestInfo,
                       responseScope: TaskPhotoOwnership.Scope, container: ModelContainer) throws -> SyncChange? {
        let main = container.mainContext
        let context = ModelContext(container); context.autosaveEnabled = false
        let id = taskID
        guard let stored = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first,
              stored.taskList?.id == listID, stored.taskList?.account?.id == accountID,
              try request(for: stored, in: context) == expectedRequest,
              expectedRequest.photoScope == responseScope else { throw SyncResourceState.Hold.needsRevalidation }
        let sourceID = responseScope.listID
        guard let source = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == sourceID })).first,
              responseScope.matches(source),
              let currentSource = try main.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == sourceID })).first,
              responseScope.matches(currentSource) else { throw SyncResourceState.Hold.needsRevalidation }
        let key = try SyncResourceState.key(scope: responseScope, href: resource.href)
        guard !(main.insertedModelsArray + main.changedModelsArray + main.deletedModelsArray).contains(where: { ($0 as? SyncMetadata)?.id == key }) else { throw SyncResourceState.Hold.needsRevalidation }
        guard try SyncResourceState.canonical(resource.href, scope: responseScope)
            == SyncResourceState.canonical(expectedRequest.href, scope: responseScope) else { throw CalDAVError.invalidResponse }
        try SyncResourceState.observe(resource, scope: responseScope, in: context)
        try context.save()
        guard resource.shape == .singleTask, let todo = resource.todo, todo.uid == stored.uid else {
            throw SyncResourceState.Hold.unsupported
        }
        guard let current = try main.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first,
              !SyncPushAcknowledgement.hasPendingChange(current, in: main) else { return nil }
        if stored.pendingMoveFromHref != nil || expectedRequest.sourceBaseline != nil,
           let proof = try SyncResourceState.read(scope: responseScope, href: resource.href, in: context), !proof.etag.isEmpty {
            let baseline = try SyncResourceState.capture(taskID: stored.id, scope: responseScope,
                href: expectedRequest.href, kind: expectedRequest.captureKind, in: context)
            guard baseline == expectedRequest.sourceBaseline,
                  baseline == nil || baseline?.uid == stored.uid else { throw SyncResourceState.Hold.needsRevalidation }
            if let baseline, baseline.etag.isEmpty {
                guard let expected = baseline.expectedBodyDigest, let body = resource.originalBody,
                      SyncResourceState.fingerprint(body) == expected else { throw SyncResourceState.Hold.needsRevalidation }
                try proof.store(in: context, key: SyncResourceState.captureKey(taskID: stored.id, kind: expectedRequest.captureKind))
                if stored.pendingMoveFromHref == nil { stored.etag = proof.etag }
            } else if baseline == nil {
                try proof.store(in: context, key: SyncResourceState.captureKey(taskID: stored.id, kind: expectedRequest.captureKind))
            }
        }
        if stored.isDeletedLocally {
            // Recover retention obligations only. Never import task fields, remove
            // photos, clear pending operations, or upload a tombstone's originals.
            if try VTODOOpaqueState.load(taskID: stored.id, in: context) == nil {
                try VTODOOpaqueState(todo).store(taskID: stored.id, in: context)
            }
            for attachment in todo.photos {
                let photo = stored.photos.first { $0.photoID == attachment.id }
                    ?? TaskPhoto(photoID: attachment.id, previewData: attachment.previewData)
                if photo.modelContext == nil { context.insert(photo); photo.task = stored }
                let update = try TaskPhotoOwnership.accepted(photo, fileID: attachment.originalFileID,
                    folderID: attachment.folderFileID, list: source, in: context)
                update.apply(in: context, normalize: true)
            }
            stored.opaqueAttachments = Array(Set(stored.opaqueAttachments + todo.opaqueAttachments)).sorted()
            stored.attachmentStateKnown = true
            // A legacy source tombstone can have no baseline; bind only this accepted GET.
            if stored.pendingMoveFromHref == nil, stored.etag?.isEmpty != false, !resource.etag.isEmpty { stored.etag = resource.etag }
            try context.save()
            return nil
        }
        try context.save()
        let change = try apply(todo, taskID: taskID, listID: listID, accountID: accountID,
            href: expectedRequest.href, container: container,
            expectedRequest: try request(for: stored, in: context), responseScope: responseScope)
        if expectedRequest.sourceListID == nil, stored.etag != resource.etag {
            guard !resource.etag.isEmpty else { throw SyncResourceState.Hold.needsRevalidation }
            // Legacy E1 has no shape proof. E2 is never relabelled as E1 authority:
            // use the same guarded supported-resource rebase as a 412 refetch.
            let fresh = ModelContext(container)
            guard let task = try fresh.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first,
                  task.isDirty else { return change }
            let captured = try SyncPushSnapshot(task: task, calendarPath: responseScope.collectionPath, requiringProof: false)
            return try SyncPushAcknowledgement.applyConflict(captured, resource: resource,
                container: container, responseScope: responseScope)
        }
        return change
    }

    /// An exact scoped GET 404 is an absence receipt, never permission for DELETE.
    @MainActor
    static func acceptAbsence(taskID: String, listID: String, accountID: String,
                              expectedRequest: RequestInfo, responseScope: TaskPhotoOwnership.Scope,
                              container: ModelContainer) throws -> SyncChange? {
        let main = container.mainContext
        let id = taskID
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let current = try main.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first,
              !SyncPushAcknowledgement.hasPendingChange(current, in: main),
              let stored = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first,
              stored.taskList?.id == listID, stored.taskList?.account?.id == accountID,
              try request(for: stored, in: context) == expectedRequest,
              expectedRequest.photoScope == responseScope else { return nil }
        let sourceID = responseScope.listID
        guard responseScope.matches(try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == sourceID })).first),
              responseScope.matches(try main.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == sourceID })).first),
              stored.attachmentStateKnown == true,
              try VTODOOpaqueState.load(taskID: stored.id, in: context) != nil,
              !TaskPhotoCleanupQueue.hasAmbiguousPendingRemoval(in: stored) else { throw SyncResourceState.Hold.needsRevalidation }
        var deleted = false
        if stored.pendingMoveFromHref != nil {
            guard PendingMoveSweep.isReady(stored),
                  try !SyncMoveAcknowledgement.hasRemainingSourceDescendant(of: stored, sourceListID: sourceID, in: context, main: main) else { return nil }
            if stored.isDeletedLocally {
                guard try !SyncPushAcknowledgement.hasRemainingDescendant(of: stored, in: context, main: main, sourceListID: sourceID) else { return nil }
                if stored.remoteHref?.isEmpty != false {
                    try SyncPushAcknowledgement.finalizeDeletion(stored, in: context); deleted = true
                }
            } else { try TaskPhotoSyncStore.completeMove(stored, in: context) }
            if !deleted {
                stored.pendingMoveFromHref = nil; stored.pendingMoveFromListID = nil
                try SyncResourceState.removeCapture(taskID: stored.id, in: context)
            }
        } else {
            guard stored.isDeletedLocally, current.isDeletedLocally,
                  try !SyncPushAcknowledgement.hasRemainingDescendant(of: stored, in: context, main: main) else { return nil }
            try SyncPushAcknowledgement.finalizeDeletion(stored, in: context); deleted = true
        }
        try context.save()
        return SyncChange(revision: 0, accountIDs: [accountID, responseScope.accountID], listIDs: [listID, sourceID],
            changedIDs: deleted ? [] : [id], deletedIDs: deleted ? [id] : [], kind: .tasks)
    }

    @MainActor
    static func apply(_ data: ICalendarParser.VTODOData, taskID: String, listID: String,
                      accountID: String, href: String, container: ModelContainer,
                      expectedRequest: RequestInfo? = nil,
                      responseScope: TaskPhotoOwnership.Scope? = nil) throws -> SyncChange? {
        let main = container.mainContext
        let predicate = #Predicate<TaskItem> { $0.id == taskID }
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first,
              !SyncPushAcknowledgement.hasPendingChange(current, in: main) else { return nil }
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              stored.taskList?.id == listID,
              stored.taskList?.account?.id == accountID, !stored.isDeletedLocally,
              let request = try request(for: stored, in: context), request.href == href,
              expectedRequest == nil || expectedRequest == request else { return nil }
        guard data.uid == stored.uid else { throw CalDAVError.invalidResponse }
        if data.photos.contains(where: { $0.originalFileID != nil }) {
            guard let captured = request.photoScope,
                  responseScope == nil || responseScope == captured else { throw TaskPhotoOwnership.Failure.missingOwner }
        }
        let source: TaskList?
        if let sourceID = request.sourceListID {
            guard let sourceList = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == sourceID })).first,
                  sourceList.account?.id == request.sourceAccountID else { return nil }
            source = sourceList
        } else { source = nil }
        let state = try VTODOOpaqueState.load(taskID: stored.id, in: context)
        if state == nil {
            var recovered = try VTODOOpaqueState(data)
            if source != nil, stored.remoteHref?.isEmpty == false,
               let account = stored.taskList?.account, account.mode != .vault {
                recovered.destinationRepairPending = true
                stored.isDirty = true
            }
            try recovered.store(taskID: stored.id, in: context)
        }
        if stored.attachmentStateKnown != true {
            try TaskPhotoSyncStore.apply(data.photos, opaque: data.opaqueAttachments, to: stored, in: context, scope: source ?? stored.taskList)
            if let source { try TaskPhotoSyncStore.prepareMove(stored, source: source) }
        }
        try context.save()
        return SyncChange(revision: 0, accountIDs: [accountID], listIDs: [listID],
            changedIDs: [taskID], deletedIDs: [], kind: .tasks)
    }
}
