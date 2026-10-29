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
    /// `parentTask` and `parentUID` are cleared, because `resolveParentRelationships`
    /// re-reads `parentUID` on every sync and would otherwise re-link it.
    ///
    /// - Returns: The nodes moved, deepest first — the order a DELETE of the old
    ///   copies must follow, since a server-side delete of a parent can cascade.
    ///   Empty when `task` is already in `destination`.
    @discardableResult
    static func move(
        _ task: TaskItem,
        to destination: TaskList,
        in context: ModelContext,
        now: Date = Date()
    ) -> [TaskItem] {
        guard task.taskList?.id != destination.id else { return [] }

        if let parent = task.parentTask, parent.taskList?.id != destination.id {
            task.parentTask = nil
            task.parentUID = nil
        }

        let nodes = subtree(of: task)
            .sorted { TaskListHelpers.depth(of: $0) > TaskListHelpers.depth(of: $1) }

        for node in nodes {
            moveNode(node, to: destination, in: context)
            node.lastModifiedDate = now
            node.isDirty = true
        }
        return nodes
    }

    /// The task and its live descendants. A descendant already awaiting its
    /// DELETE stays where it is: that DELETE targets its current href, which a
    /// move would clear.
    private static func subtree(of root: TaskItem) -> [TaskItem] {
        var result: [TaskItem] = []
        var seen: Set<String> = []
        var frontier = [root]
        while let node = frontier.popLast() {
            guard seen.insert(node.id).inserted, !node.isDeletedLocally else { continue }
            result.append(node)
            frontier.append(contentsOf: node.subtasks)
        }
        return result
    }

    private static func moveNode(_ node: TaskItem, to destination: TaskList, in context: ModelContext) {
        let currentHref = node.remoteHref.flatMap { $0.isEmpty ? nil : $0 }
        let returnsToSource = node.pendingMoveFromHref != nil && node.pendingMoveFromListID == destination.id

        if let pendingHref = node.pendingMoveFromHref {
            // Already mid-move. The original copy is still owed its DELETE.
            if let currentHref, let currentList = node.taskList {
                // The PUT into the intermediate list landed, so that list holds a
                // second copy. The deletion push already knows how to remove a
                // copy it has a tombstone for.
                insertTombstone(for: node, href: currentHref, etag: node.etag, in: currentList, context: context)
            }
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

        if returnsToSource {
            TaskPhotoSyncStore.restoreMove(node, source: destination, in: context)
        } else {
            TaskPhotoSyncStore.prepareMove(node)
        }
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
        restore(task, to: source, in: context)
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
        if let destinationHref = task.remoteHref, !destinationHref.isEmpty,
           let destination = task.taskList {
            insertTombstone(for: task, href: destinationHref, etag: task.etag, in: destination, context: context)
        }
        restore(task, to: source, in: context)
        return true
    }

    private static func pendingSource(of task: TaskItem, in context: ModelContext) -> TaskList? {
        guard task.pendingMoveFromHref != nil, let sourceID = task.pendingMoveFromListID else { return nil }
        var descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == sourceID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func restore(_ task: TaskItem, to source: TaskList, in context: ModelContext) {
        TaskPhotoSyncStore.restoreMove(task, source: source, in: context)
        task.taskList = source
        task.remoteHref = task.pendingMoveFromHref
        task.etag = nil
        task.isDirty = false
        task.pendingMoveFromHref = nil
        task.pendingMoveFromListID = nil
    }

    /// Inserts a row whose only job is to carry a DELETE for `href` through the
    /// existing deletion push, which sends it and then removes the row.
    static func insertTombstone(
        for node: TaskItem,
        href: String,
        etag: String?,
        in list: TaskList,
        context: ModelContext
    ) {
        let tombstone = TaskItem(uid: node.uid, title: node.title)
        tombstone.taskList = list
        tombstone.remoteHref = href
        tombstone.etag = etag
        tombstone.isLocalOnly = false
        tombstone.isDeletedLocally = true
        context.insert(tombstone)
        // Cleanup of an intermediate destination follows its acknowledged task DELETE.
        for source in node.photos where source.originalFileID != nil {
            let photo = TaskPhoto(photoID: source.photoID, previewData: source.previewData)
            photo.originalFileID = source.originalFileID; photo.folderFileID = source.folderFileID
            context.insert(photo); photo.task = tombstone
        }
    }
}
