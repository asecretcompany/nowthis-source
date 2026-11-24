import Foundation
import SwiftData

/// Moves a task, with its subtree, to a different list.
///
/// CalDAV has no portable cross-collection move, so a move is create-then-delete:
/// the row keeps its `id` and `uid`, its `remoteHref` is cleared so the next push
/// creates it in the destination, and the href it used to occupy is recorded in
/// `pendingMoveFromHref` for the sync engine to DELETE once that push has landed.
/// The server therefore holds at least one copy at every instant, and the pull
/// guard hides the stale one until it is reaped.
///
/// Identity is preserved deliberately: deep links, notification identifiers,
/// Spotlight entries, geofences and journal associations all key off `id`, and a
/// kept `uid` lets other CalDAV clients read the change as a move rather than a
/// delete plus an unrelated add.
enum TaskMover {

    /// Moves `task` and every live descendant to `destination`.
    ///
    /// A task moved without its parent is promoted to top level: both
    /// `parentTask` and `parentUID` are cleared so later server pulls cannot
    /// restore the moved task's old parent relationship.
    ///
    /// - Returns: The nodes moved, deepest first — the order a DELETE of the old
    ///   copies must follow, since a server-side delete of a parent can cascade.
    ///   Empty when `task` is already in `destination`.
    @discardableResult
    static func move(
        _ task: TaskItem,
        to destination: TaskList,
        in context: ModelContext,
        now: Date = Date(),
        ownershipReads: TaskPhotoOwnership.Reads = .init(),
        onShapeHold: ((SyncResourceState.Hold) -> Void)? = nil
    ) -> [TaskItem] {
        guard task.taskList?.id != destination.id else { return [] }

        let nodes = subtree(of: task)
            .sorted { TaskListHelpers.depth(of: $0) > TaskListHelpers.depth(of: $1) }
        do {
            for node in nodes { try SyncResourceState.requireWritable(node, allowRetainedRevision: false, in: context) }
        } catch let hold as SyncResourceState.Hold { onShapeHold?(hold); return [] }
        catch { onShapeHold?(.needsRevalidation); return [] }
        let plans: [(TaskPhotoSyncStore.MovePlan, (() -> Void)?)]
        do {
            plans = try nodes.map { node in
                let returning = node.pendingMoveFromHref != nil && node.pendingMoveFromListID == destination.id
                let photos = try TaskPhotoSyncStore.movePlan(node, restoring: returning ? destination : nil,
                    in: context, reads: ownershipReads)
                let tombstone: (() -> Void)?
                if node.pendingMoveFromHref != nil, let href = node.remoteHref, !href.isEmpty, let list = node.taskList {
                    tombstone = try tombstonePlan(for: node, href: href, etag: node.etag, in: list, context: context)
                } else { tombstone = nil }
                return (photos, tombstone)
            }
        } catch { return [] }
        let sourceCaptures: [() -> Void]
        let finishedCaptures: [() -> Void]
        do {
            finishedCaptures = try nodes.filter { $0.pendingMoveFromListID == destination.id }.map {
                try SyncResourceState.prepareRemoveCapture(taskID: $0.id, in: context)
            }
            sourceCaptures = try nodes.filter { $0.pendingMoveFromHref == nil }.compactMap { node in
                if let href = node.remoteHref, !href.isEmpty {
                    let proof = try SyncResourceState.proof(list: node.taskList, href: href, etag: node.etag, taskID: node.id, uid: node.uid, allowRetainedRevision: false, in: context)
                    return try proof.prepareStore(in: context, key: SyncResourceState.movePrefix + node.id)
                }
                return nil
            }
        } catch { onShapeHold?(.needsRevalidation); return [] }
        sourceCaptures.forEach { $0() }
        finishedCaptures.forEach { $0() }
        if let parent = task.parentTask, parent.taskList?.id != destination.id {
            task.parentTask = nil
            task.parentUID = nil
        }
        for (index, node) in nodes.enumerated() {
            plans[index].1?()
            moveNode(node, to: destination, in: context, photos: plans[index].0)
            node.lastModifiedDate = now
            node.isDirty = true
        }
        return nodes
    }

    /// The task and its live descendants. A descendant already awaiting its
    /// DELETE stays where it is: that DELETE targets its current href, which a
    /// move would clear.
    static func subtree(of root: TaskItem) -> [TaskItem] {
        var result: [TaskItem] = []
        var seen: Set<String> = []
        var frontier = [root]
        while let node = frontier.popLast() {
            guard node.modelContext != nil, seen.insert(node.id).inserted, !node.isDeletedLocally else { continue }
            result.append(node)
            frontier.append(contentsOf: node.subtasks)
        }
        return result
    }

    private static func moveNode(_ node: TaskItem, to destination: TaskList, in context: ModelContext,
                                 photos: TaskPhotoSyncStore.MovePlan) {
        let currentHref = node.remoteHref.flatMap { $0.isEmpty ? nil : $0 }
        if let pendingHref = node.pendingMoveFromHref {
            if node.pendingMoveFromListID == destination.id {
                // Back where the original copy lives: cancel instead of deleting it.
                node.remoteHref = pendingHref
                node.pendingMoveFromHref = nil
                node.pendingMoveFromListID = nil
            } else {
                node.remoteHref = nil
            }
            node.etag = nil
        } else if let currentHref {
            node.pendingMoveFromHref = currentHref
            node.pendingMoveFromListID = node.taskList?.id
            node.remoteHref = nil
            node.etag = nil
        }
        // A task never pushed owes no server anything; it is a plain reassignment.

        photos.apply(in: context)
        node.taskList = destination
    }

    // MARK: - Rollback

    /// Undoes a move whose PUT into the destination the server refused (403).
    ///
    /// Nothing was created there, so the task goes back to its source list and
    /// its original href. The etag is cleared and `isDirty` dropped: the next pull
    /// of the source list sees a changed etag and re-applies the server's copy,
    /// which is the only one that exists.
    ///
    /// - Returns: `false` when the task carries no move to undo, or its source
    ///   list is gone — the refusal is then an ordinary one and is left as it was.
    @discardableResult
    static func rollBackRefusedPut(_ task: TaskItem, in context: ModelContext) -> Bool {
        guard let source = pendingSource(of: task, in: context) else { return false }
        guard let plan = try? TaskPhotoSyncStore.movePlan(task, restoring: source, in: context),
              let finishCapture = try? SyncResourceState.prepareRemoveCapture(taskID: task.id, in: context) else { return false }
        finishCapture()
        restore(task, to: source, in: context, photos: plan)
        return true
    }

    /// Undoes a move whose DELETE from the source list the server refused (403).
    ///
    /// The source copy stays, so the task returns to it. The copy the move created
    /// in the destination, if its PUT had landed, is left behind as a tombstone for
    /// that list's own deletion push — which also covers a destination in another
    /// account, whose credentials this sync does not have.
    @discardableResult
    static func rollBackRefusedDelete(_ task: TaskItem, in context: ModelContext) -> Bool {
        guard let source = pendingSource(of: task, in: context) else { return false }
        let plan: TaskPhotoSyncStore.MovePlan
        let tombstone: (() -> Void)?
        let finishCapture: () -> Void
        do {
            finishCapture = try SyncResourceState.prepareRemoveCapture(taskID: task.id, in: context)
            plan = try TaskPhotoSyncStore.movePlan(task, restoring: source, in: context)
            if let href = task.remoteHref, !href.isEmpty, let destination = task.taskList {
                tombstone = try tombstonePlan(for: task, href: href, etag: task.etag, in: destination, context: context)
            } else { tombstone = nil }
        } catch { return false }
        tombstone?()
        finishCapture()
        restore(task, to: source, in: context, photos: plan)
        return true
    }

    private static func pendingSource(of task: TaskItem, in context: ModelContext) -> TaskList? {
        guard task.pendingMoveFromHref != nil, let sourceID = task.pendingMoveFromListID else { return nil }
        var descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == sourceID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func restore(_ task: TaskItem, to source: TaskList, in context: ModelContext,
                                photos: TaskPhotoSyncStore.MovePlan) {
        photos.apply(in: context)
        task.taskList = source
        task.remoteHref = task.pendingMoveFromHref
        task.etag = nil
        task.isDirty = false
        task.pendingMoveFromHref = nil
        task.pendingMoveFromListID = nil
    }

    /// Inserts a row whose only job is to carry a DELETE for `href` through the
    /// existing deletion push, which sends it and then removes the row.
    static func insertTombstone(for node: TaskItem, href: String, etag: String?, in list: TaskList,
                                context: ModelContext) throws {
        try tombstonePlan(for: node, href: href, etag: etag, in: list, context: context)()
    }

    static func tombstonePlan(
        for node: TaskItem,
        href: String,
        etag: String?,
        in list: TaskList,
        context: ModelContext
    ) throws -> () -> Void {
        let records = try TaskPhotoOwnership.records(node, in: context)
        let tombstone = TaskItem(uid: node.uid, title: node.title)
        tombstone.remoteHref = href
        let sourceCapture: SyncResourceState?
        if node.pendingMoveFromListID == list.id, node.pendingMoveFromHref == href,
           let scope = TaskPhotoOwnership.Scope(list: list) {
            sourceCapture = try SyncResourceState.capture(taskID: node.id, scope: scope, href: href, in: context)
        } else if etag?.isEmpty == false {
            sourceCapture = try SyncResourceState.proof(list: list, href: href, etag: etag,
                taskID: node.id, uid: node.uid, in: context)
        } else { sourceCapture = nil }
        tombstone.etag = sourceCapture?.etag ?? etag
        let storeCapture = try sourceCapture?.prepareStore(in: context, key: SyncResourceState.cleanupPrefix + tombstone.id)
        tombstone.isLocalOnly = false
        tombstone.isDeletedLocally = true
        var updates: [TaskPhotoOwnership.Update] = []
        for record in records {
            let bindings = ([record.state.current].compactMap { $0 } + record.state.retained).filter { $0.matches(list) }
            guard !bindings.isEmpty else { continue }
            let source = record.photo
            let photo = TaskPhoto(photoID: source.photoID, previewData: source.previewData)
            photo.task = tombstone
            let state = TaskPhotoOwnership(taskID: tombstone.id, photoID: photo.id,
                current: bindings.first, retained: Array(bindings.dropFirst()))
            updates.append(try TaskPhotoOwnership.Record(photo: photo, row: nil, state: state).update(state))
        }
        return {
            context.insert(tombstone)
            tombstone.taskList = list
            storeCapture?()
            for update in updates {
                context.insert(update.photo)
                update.apply(in: context, normalize: true)
            }
        }
    }
}
