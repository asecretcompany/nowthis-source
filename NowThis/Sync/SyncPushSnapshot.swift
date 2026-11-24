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
    let opaqueState: VTODOOpaqueState
    let acceptedOpaqueState: VTODOOpaqueState
    let photoScope: TaskPhotoOwnership.Scope?
    let resourceProof: SyncResourceState?
    let sourceProof: SyncResourceState?

    init(task: TaskItem, calendarPath: String, stamp: Date = Date(), requiringProof: Bool = true) throws {
        let scope = TaskPhotoOwnership.Scope(list: task.taskList)
        let rawTarget = task.remoteHref.flatMap { $0.isEmpty ? nil : $0 } ?? calendarPath + task.uid + ".ics"
        let target = try scope.map { try SyncResourceState.canonical(rawTarget, scope: $0) } ?? rawTarget
        let existingTarget = task.remoteHref?.isEmpty == false
        if let context = task.modelContext {
            if requiringProof { try SyncResourceState.requireWritable(task, allowRetainedRevision: existingTarget, in: context) }
            resourceProof = try TaskPhotoOwnership.Scope(list: task.taskList).flatMap {
                try SyncResourceState.read(scope: $0, href: target, in: context)
            }
            sourceProof = requiringProof ? try SyncResourceState.sourceProof(task, requireCurrent: !existingTarget, in: context) : nil
        } else { resourceProof = nil; sourceProof = nil }
        opaqueState = try Self.state(for: task)
        acceptedOpaqueState = ICalendarSerializer.emittedOpaqueState(opaqueState, alarmTriggerSeconds: task.reminderOffset)
        photoScope = scope
        taskID = task.id; uid = task.uid; listID = task.taskList?.id ?? ""
        accountID = task.taskList?.account?.id
        originalHref = task.remoteHref
        path = target
        etag = task.etag; modifiedAt = task.lastModifiedDate
        self.stamp = stamp
        payload = try Self.serialize(task, stamp: stamp, opaqueState: opaqueState)
    }

    func stillMatches(_ task: TaskItem) throws -> Bool {
        return try task.id == taskID && task.uid == uid && task.taskList?.id == listID
            && task.remoteHref == originalHref && !task.isDeletedLocally
            && task.lastModifiedDate == modifiedAt && Self.state(for: task) == opaqueState
            && Self.serialize(task, stamp: stamp, opaqueState: opaqueState) == payload
    }

    static func state(for task: TaskItem) throws -> VTODOOpaqueState {
        guard let context = task.modelContext else {
            guard task.isLocalOnly, task.remoteHref?.isEmpty != false && task.pendingMoveFromHref == nil else { throw VTODOOpaqueState.StateError.missingRemoteState }
            return .empty
        }
        return try VTODOOpaqueState.outbound(for: task, in: context)
    }

    static func serialize(_ task: TaskItem, stamp: Date, opaqueState: VTODOOpaqueState? = nil) throws -> String {
        let opaqueState = try opaqueState ?? state(for: task)
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
            opaqueAttachments: task.opaqueAttachments,
            opaqueState: opaqueState
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
        return try SyncPushSnapshot(task: task, calendarPath: calendarPath)
    }

    @MainActor
    static func validateWrite(_ snapshot: SyncPushSnapshot, container: ModelContainer,
                              responseScope: TaskPhotoOwnership.Scope) throws {
        let main = container.mainContext
        let id = snapshot.taskID
        guard let current = try main.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first,
              !hasPendingChange(current, in: main), responseScope == snapshot.photoScope,
              responseScope.matches(current.taskList) else { throw SyncResourceState.Hold.needsRevalidation }
        let context = ModelContext(container)
        guard let stored = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first,
              responseScope.matches(stored.taskList), try snapshot.stillMatches(stored) else {
            throw SyncResourceState.Hold.needsRevalidation
        }
        let existingTarget = snapshot.originalHref?.isEmpty == false
        try SyncResourceState.requireWritable(stored, allowRetainedRevision: existingTarget, in: context)
        guard try SyncResourceState.sourceProof(stored, requireCurrent: !existingTarget, in: context) == snapshot.sourceProof else { throw SyncResourceState.Hold.needsRevalidation }
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

        // Record only the exact request identity, even when its task moved during PUT.
        guard let scope = snapshot.photoScope else { throw SyncResourceState.Hold.needsRevalidation }
        let listID = snapshot.listID
        guard let sentList = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first,
              scope.matches(sentList) else { throw SyncResourceState.Hold.needsRevalidation }
        let proofKey = try SyncResourceState.key(scope: scope, href: snapshot.path)
        guard !(main.insertedModelsArray + main.changedModelsArray + main.deletedModelsArray).contains(where: { ($0 as? SyncMetadata)?.id == proofKey }) else { return }
        let currentProof = try SyncResourceState.read(scope: scope, href: snapshot.path, in: context)
        guard (currentProof == nil && snapshot.resourceProof == nil)
            || currentProof.flatMap({ current in snapshot.resourceProof.map { current.sameObservation(as: $0) } }) == true else { return }
        guard scope.matches(try main.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first) else { return }
        let unchangedPayload = try stored.map { try snapshot.stillMatches($0) } ?? false
        let acceptedProof = try SyncResourceState(scope: scope,
            href: SyncResourceState.canonical(snapshot.path, scope: scope),
            etag: etag ?? "", shape: .singleTask, originalBody: nil,
            expectedBodyDigest: etag?.isEmpty != false ? SyncResourceState.fingerprint(snapshot.payload) : nil, uid: snapshot.uid)
        // Empty acknowledgement ETags invalidate earlier authority for this path.
        try acceptedProof.store(in: context)
        if let current, let stored, current.taskList?.id == snapshot.listID, stored.taskList?.id == snapshot.listID {
            // Retain the accepted ETag even when a newer edit must be uploaded next.
            let unchanged = unchangedPayload && !hasPendingChange(current, in: main)
            let currentState = try VTODOOpaqueState.load(taskID: stored.id, in: context)
            if (currentState ?? .empty) == snapshot.opaqueState {
                var accepted = snapshot.acceptedOpaqueState
                accepted.destinationRepairPending = nil
                try accepted.store(taskID: stored.id, in: context)
            }
            if stored.isDeletedLocally {
                try acceptedProof.store(in: context, key: SyncResourceState.cleanupPrefix + stored.id)
            } else {
                try SyncResourceState.removeCapture(taskID: stored.id, kind: .currentResource, in: context)
            }
            stored.etag = etag
            stored.isLocalOnly = false
            stored.remoteHref = snapshot.path
            stored.isDirty = unchanged ? false : true
            if unchanged { try TaskPhotoSyncStore.acknowledge(stored, in: context) }
            try context.save()
        } else {
            // A PUT into the former list can succeed after a move or local delete. Persist
            // its cleanup through the existing tombstone path, without acknowledging a new destination.
            func carriesSentSource(_ task: TaskItem?) -> Bool {
                guard let task, task.pendingMoveFromListID == snapshot.listID,
                      let href = task.pendingMoveFromHref else { return false }
                return (try? SyncResourceState.canonical(href, scope: scope)) == snapshot.path
            }
            if carriesSentSource(current) || carriesSentSource(stored) {
                // Canonical identity finds the obligation; the raw local marker
                // still has to agree with both the stored row and the sent operation.
                guard let current, let stored, carriesSentSource(current), carriesSentSource(stored),
                      current.uid == snapshot.uid, stored.uid == snapshot.uid,
                      current.pendingMoveFromHref == stored.pendingMoveFromHref,
                      stored.pendingMoveFromHref == snapshot.originalHref else { return }
                let moveKey = SyncResourceState.movePrefix + stored.id
                guard !(main.insertedModelsArray + main.changedModelsArray + main.deletedModelsArray).contains(where: { ($0 as? SyncMetadata)?.id == moveKey }) else { return }
                let captured = try SyncResourceState.read(key: moveKey, in: context)
                if captured?.scope == scope, captured?.href == acceptedProof.href,
                   captured?.uid == snapshot.uid, captured?.etag == snapshot.etag {
                    try acceptedProof.store(in: context, key: moveKey)
                }
                try context.save()
                return // The durable move already carries this source cleanup.
            }
            let listID = snapshot.listID
            let listPredicate = #Predicate<TaskList> { $0.id == listID }
            guard let list = try context.fetch(FetchDescriptor(predicate: listPredicate)).first else { return }
            let uid = snapshot.uid
            let cleanupPredicate = #Predicate<TaskItem> {
                $0.isDeletedLocally && $0.uid == uid && $0.taskList?.id == listID
            }
            let matching = try context.fetch(FetchDescriptor(predicate: cleanupPredicate)).filter {
                $0.remoteHref.flatMap { try? SyncResourceState.canonical($0, scope: scope) } == snapshot.path
            }
            guard matching.count <= 1 else { return }
            if let cleanup = matching.first {
                let cleanupID = cleanup.id
                guard cleanup.uid == snapshot.uid, cleanup.pendingMoveFromHref == nil,
                      let captured = try SyncResourceState.capture(taskID: cleanupID, scope: scope, href: snapshot.path, kind: .currentResource, in: context),
                      captured.uid == snapshot.uid, captured.etag == snapshot.etag,
                      cleanup.etag == snapshot.etag,
                      let currentCleanup = try main.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == cleanupID })).first,
                      currentCleanup.remoteHref == cleanup.remoteHref,
                      !hasPendingChange(currentCleanup, in: main), scope.matches(currentCleanup.taskList),
                      let todo = try ICalendarParser.parseSingleVTODO(from: snapshot.payload) else { return }
                // This is the same still-current cleanup obligation. Retain every
                // earlier original while adding the actual accepted sent body.
                for attachment in todo.photos {
                    let photo = cleanup.photos.first { $0.photoID == attachment.id }
                        ?? TaskPhoto(photoID: attachment.id, previewData: attachment.previewData)
                    if photo.modelContext == nil { context.insert(photo); photo.task = cleanup }
                    let update = try TaskPhotoOwnership.accepted(photo, fileID: attachment.originalFileID,
                        folderID: attachment.folderFileID, list: list, in: context)
                    update.apply(in: context, normalize: true)
                }
                cleanup.opaqueAttachments = Array(Set(cleanup.opaqueAttachments + todo.opaqueAttachments)).sorted()
                cleanup.attachmentStateKnown = true
                if try VTODOOpaqueState.load(taskID: cleanupID, in: context) == nil {
                    try snapshot.acceptedOpaqueState.store(taskID: cleanupID, in: context)
                }
                cleanup.etag = etag
                try acceptedProof.store(in: context, key: SyncResourceState.cleanupPrefix + cleanupID)
                try context.save()
            } else {
                let cleanup = TaskItem(uid: snapshot.uid, title: "")
                cleanup.taskList = list; cleanup.remoteHref = snapshot.path; cleanup.etag = etag
                cleanup.isDeletedLocally = true; cleanup.isLocalOnly = false
                context.insert(cleanup)
                // The accepted bytes are a complete retention baseline for this
                // exact late-created resource, including its source originals.
                guard let todo = try ICalendarParser.parseSingleVTODO(from: snapshot.payload) else { throw CalDAVError.invalidResponse }
                try TaskPhotoSyncStore.apply(todo.photos, opaque: todo.opaqueAttachments, to: cleanup, in: context, scope: list)
                try snapshot.acceptedOpaqueState.store(taskID: cleanup.id, in: context)
                try acceptedProof.store(in: context, key: SyncResourceState.cleanupPrefix + cleanup.id)
                try context.save()
            }
        }
    }

    @MainActor
    static func applyConflict(_ snapshot: SyncPushSnapshot, resource: ParsedRemoteTask,
                              container: ModelContainer,
                              responseScope: TaskPhotoOwnership.Scope? = nil) throws -> SyncChange {
        let id = snapshot.taskID
        let predicate = #Predicate<TaskItem> { $0.id == id }
        let main = container.mainContext
        if resource.shape != nil {
            let observation = ModelContext(container); observation.autosaveEnabled = false
            let listID = snapshot.listID
            guard let scope = responseScope, scope == snapshot.photoScope,
                  let list = try observation.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first,
                  scope.matches(list),
                  let currentList = try main.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first,
                  scope.matches(currentList) else { throw SyncResourceState.Hold.needsRevalidation }
            let key = try SyncResourceState.key(scope: scope, href: resource.href)
            guard !(main.insertedModelsArray + main.changedModelsArray + main.deletedModelsArray).contains(where: { ($0 as? SyncMetadata)?.id == key }) else { throw SyncResourceState.Hold.needsRevalidation }
            try SyncResourceState.observe(resource, scope: scope, in: observation)
            try observation.save()
            guard resource.shape == .singleTask else { throw SyncResourceState.Hold.unsupported }
        }
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first,
              !hasPendingChange(current, in: main),
              let todo = resource.todo, todo.uid == snapshot.uid else { throw CalDAVError.conflict(etag: nil) }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              try snapshot.stillMatches(stored) else { throw CalDAVError.conflict(etag: nil) }
        let repairPending = snapshot.opaqueState.destinationRepairPending == true
        var mergedRepair: VTODOOpaqueState?
        let recoveredAttachments = repairPending ? stored.opaqueAttachments : []
        if repairPending {
            // A repair must remain conditional on the version just fetched.
            guard !resource.etag.isEmpty else { throw CalDAVError.conflict(etag: nil) }
            var merged = try VTODOOpaqueState(todo)
            let singletonNames: Set<String> = ["CLASS", "SEQUENCE", "ORGANIZER", "RECURRENCE-ID", "DURATION", "TRANSP", "DTEND"]
            let remoteNames = Set(merged.opaqueProperties.map { ICalendarParser.splitProperty($0).name })
            for line in snapshot.opaqueState.opaqueProperties {
                let name = ICalendarParser.splitProperty(line).name
                if !merged.opaqueProperties.contains(line) && !(singletonNames.contains(name) && remoteNames.contains(name)) {
                    merged.opaqueProperties.append(line)
                }
            }
            for alarm in snapshot.opaqueState.alarmBlocks where !merged.alarmBlocks.contains(alarm) {
                merged.alarmBlocks.append(alarm)
            }
            if todo.alarmBlocks.isEmpty {
                merged.baselineReminderOffset = snapshot.opaqueState.baselineReminderOffset
            }
            merged.destinationRepairPending = true
            mergedRepair = merged
            // The normal importer protects repair metadata. Permit this guarded rebase
            // in the unsaved context, then restore the combined state before saving.
            var temporary = snapshot.opaqueState
            temporary.destinationRepairPending = nil
            try temporary.store(taskID: stored.id, in: context)
        }
        if todo.photos.contains(where: { $0.originalFileID != nil }) {
            guard let captured = snapshot.photoScope, captured.matches(stored.taskList),
                  responseScope == nil || responseScope == captured else { throw TaskPhotoOwnership.Failure.missingOwner }
        }
        let importer = try SyncImportStore(context: context)
        try importer.applyFields(todo, to: stored)
        if let mergedRepair {
            try mergedRepair.store(taskID: stored.id, in: context)
            for attachment in recoveredAttachments where !stored.opaqueAttachments.contains(attachment) {
                stored.opaqueAttachments.append(attachment)
            }
            if todo.alarmBlocks.isEmpty { stored.reminderOffset = mergedRepair.baselineReminderOffset }
        }
        stored.etag = resource.etag; stored.remoteHref = resource.href
        stored.isDirty = repairPending || stored.photos.contains { $0.pendingOperation != nil }
        let accounts = Set([stored.taskList?.account?.id].compactMap { $0 })
        if let scope = snapshot.photoScope {
            try SyncResourceState.releaseBaseline(taskID: stored.id, scope: scope, href: resource.href, in: context)
        }
        try context.save()
        return SyncChange(revision: 0, accountIDs: accounts, listIDs: [snapshot.listID],
            changedIDs: [id], deletedIDs: [], kind: .tasks)
    }

    @MainActor
    static func rollBackRefusedMove(_ snapshot: SyncPushSnapshot, container: ModelContainer) throws -> SyncChange {
        // A repair targets an existing destination, not an uncreated initial move.
        // Keep its recovered data and retry markers when permission is refused.
        guard snapshot.opaqueState.destinationRepairPending != true else { throw CalDAVError.forbidden }
        let id = snapshot.taskID
        let predicate = #Predicate<TaskItem> { $0.id == id }
        let main = container.mainContext
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first,
              !hasPendingChange(current, in: main) else { throw CalDAVError.forbidden }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              snapshot.photoScope?.matches(current.taskList) == true,
              snapshot.photoScope?.matches(stored.taskList) == true,
              try SyncResourceState.sourceProof(stored, in: context) == snapshot.sourceProof,
              try snapshot.sourceProof.map({ proof in
                  let sourceID = proof.scope.listID
                  return proof.scope.matches(try main.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == sourceID })).first)
              }) != false,
              try snapshot.stillMatches(stored), TaskMover.rollBackRefusedPut(stored, in: context) else { throw CalDAVError.forbidden }
        let lists = Set([snapshot.listID, stored.taskList?.id].compactMap { $0 })
        let accounts = Set([snapshot.accountID, stored.taskList?.account?.id].compactMap { $0 })
        try context.save()
        return SyncChange(revision: 0, accountIDs: accounts, listIDs: lists,
            changedIDs: [id], deletedIDs: [], kind: .tasks)
    }

    @MainActor
    static func deletionSnapshot(taskID: String, container: ModelContainer,
                                 expectedListID: String? = nil, expectedAccountID: String? = nil) throws -> SyncDeleteSnapshot? {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        let main = container.mainContext
        let predicate = #Predicate<TaskItem> { $0.id == taskID }
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first,
              !hasPendingChange(current, in: main) else { return nil }
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              stored.isDeletedLocally, stored.pendingMoveFromHref == nil, let list = stored.taskList,
              expectedListID == nil || list.id == expectedListID,
              expectedAccountID == nil || list.account?.id == expectedAccountID,
              try !hasRemainingDescendant(of: stored, in: context, main: main) else { return nil }
        let proof: SyncResourceState?
        if let href = stored.remoteHref, !href.isEmpty {
            proof = try SyncResourceState.proof(list: list, href: href, etag: stored.etag, taskID: stored.id, uid: stored.uid, in: context)
        } else { proof = nil }
        if let proof { guard proof.scope.matches(current.taskList) else { throw SyncResourceState.Hold.needsRevalidation } }
        return SyncDeleteSnapshot(taskID: taskID, uid: stored.uid, listID: list.id, accountID: list.account?.id,
            href: stored.remoteHref, etag: stored.etag, resourceProof: proof)
    }

    @MainActor
    static func validateDeletion(_ snapshot: SyncDeleteSnapshot, container: ModelContainer) throws {
        guard try deletionSnapshot(taskID: snapshot.taskID, container: container,
            expectedListID: snapshot.listID, expectedAccountID: snapshot.accountID) == snapshot else {
            throw SupersededTaskDeletion()
        }
    }

    @MainActor
    static func acknowledgeDeletion(_ snapshot: SyncDeleteSnapshot, container: ModelContainer,
                                    cleanupReads: TaskPhotoCleanupQueue.DeletionReads = .init(),
                                    save: (ModelContext) throws -> Void = { try $0.save() }) throws -> SyncChange? {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        let id = snapshot.taskID
        let predicate = #Predicate<TaskItem> { $0.id == id }
        let main = container.mainContext
        guard let current = try main.fetch(FetchDescriptor(predicate: predicate)).first else { return nil }
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              snapshot.matchesResource(stored) else { return nil }
        if let proof = snapshot.resourceProof {
            guard proof.scope.matches(stored.taskList), proof.scope.matches(current.taskList),
                  try SyncResourceState.proof(list: stored.taskList, href: proof.href, etag: snapshot.etag, taskID: stored.id, uid: stored.uid, in: context) == proof else { return nil }
        }

        let pendingEdit = hasPendingChange(current, in: main)
        let pendingRestore = pendingEdit && !current.isDeletedLocally && snapshot.matchesResource(current)
        if !stored.isDeletedLocally || pendingRestore {
            // Restore the task as a new upload only when its exact server copy was removed.
            if snapshot.href?.isEmpty == false {
                stored.remoteHref = nil; stored.etag = nil; stored.isDirty = true
                try save(context)
            }
            return nil
        }

        // The move sweep owns this source DELETE even if the destination never landed.
        guard !pendingEdit, stored.pendingMoveFromHref == nil,
              try !hasRemainingDescendant(of: stored, in: context, main: main) else { return nil }
        try finalizeDeletion(stored, in: context, cleanupReads: cleanupReads)
        try save(context)
        let accounts = Set([snapshot.accountID].compactMap { $0 })
        return SyncChange(revision: 0, accountIDs: accounts, listIDs: [snapshot.listID],
            changedIDs: [], deletedIDs: [id], kind: .tasks)
    }

    @MainActor
    static func finalizeDeletion(_ task: TaskItem, in context: ModelContext,
                                 cleanupReads: TaskPhotoCleanupQueue.DeletionReads = .init()) throws {
        try CalendarMirrorState.stagePurge([task], in: context)
        try TaskPhotoCleanupQueue.enqueueDeletion(task, in: context, reads: cleanupReads)
        try SyncResourceState.removeCapture(taskID: task.id, in: context)
        try SyncResourceState.removeCapture(taskID: task.id, kind: .currentResource, in: context)
        if let scope = TaskPhotoOwnership.Scope(list: task.taskList), let href = task.remoteHref {
            try SyncResourceState.releaseBaseline(taskID: task.id, scope: scope, href: href, in: context)
        }
        try VTODOOpaqueState.remove(tasks: [task], in: context)
        context.delete(task)
    }

    @MainActor
    static func hasRemainingDescendant(of task: TaskItem, in context: ModelContext, main: ModelContext,
                                       sourceListID: String? = nil) throws -> Bool {
        // A remaining direct child means the branch is not empty, regardless of its deletion state.
        if !task.subtasks.isEmpty { return true }

        // A pulled task can name this parent before its SwiftData relationship is resolved.
        let id = task.id
        let uid = task.uid
        let listIDs = Set([task.taskList?.id, sourceListID].compactMap { $0 })
        for listID in listIDs {
            let unresolved = #Predicate<TaskItem> {
                $0.parentUID == uid && $0.parentTask == nil && $0.taskList?.id == listID && $0.id != id
            }
            var descriptor = FetchDescriptor(predicate: unresolved)
            descriptor.fetchLimit = 1
            if try !context.fetch(descriptor).isEmpty { return true }
        }

        // Pending UI mutations can attach a child that the fresh context cannot see yet.
        let pending = main.insertedModelsArray + main.changedModelsArray + main.deletedModelsArray
        var seen: Set<String> = [id]
        for case let row as TaskItem in pending {
            var node: TaskItem? = row
            while let child = node, seen.insert(child.id).inserted {
                let parent = child.parentTask
                if parent?.id == id { return true }
                if parent == nil, child.parentUID == uid, let listID = child.taskList?.id, listIDs.contains(listID) {
                    return true
                }
                node = parent
            }
        }
        return false
    }

    @MainActor
    static func hasPendingChange(_ task: TaskItem, in context: ModelContext) -> Bool {
        let ids = Set([task.persistentModelID] + task.photos.map(\.persistentModelID))
        let ownershipKeys = Set(task.photos.map { TaskPhotoOwnership.prefix + $0.id }).union(SyncResourceState.pendingKeys(task, in: context))
        return (context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray)
            .contains { model in
                ids.contains(model.persistentModelID)
                    || (model as? SyncMetadata).map { ownershipKeys.contains($0.id) } == true
            }
    }
}

/// The original resource or its eligibility changed before a wire attempt.
struct SupersededTaskDeletion: Error, Sendable {}

struct SyncDeleteSnapshot: Sendable, Equatable {
    let taskID: String
    let uid: String
    let listID: String
    let accountID: String?
    let href: String?
    let etag: String?
    var resourceProof: SyncResourceState? = nil

    func matchesResource(_ task: TaskItem) -> Bool {
        task.id == taskID && task.uid == uid && task.taskList?.id == listID
            && task.taskList?.account?.id == accountID && task.remoteHref == href && task.etag == etag
    }
}
