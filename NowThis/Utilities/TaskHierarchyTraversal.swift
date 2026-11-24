import Foundation
import SwiftData

struct TaskTreeEntry: Identifiable {
    let task: TaskItem
    let depth: Int
    var id: String { task.id }
}

enum TaskHierarchyTraversal {
    /// Resolves and reparents a dragged task by ID within the active model context.
    @MainActor
    static func reparent(
        taskID: String,
        under newParent: TaskItem?,
        in context: ModelContext,
        errorState: ErrorState? = nil
    ) -> Bool {
        let policy = TaskWriteEligibility(writingIn: context)
        do {
            let child = try policy.task(.id(taskID))
            if let newParent { _ = try policy.task(.retained(newParent)) }
            return reparent(child, under: newParent)
        } catch {
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState)
            return false
        }
    }

    /// Reparents a live task when the target preserves a valid single-list tree.
    static func reparent(_ child: TaskItem, under newParent: TaskItem?) -> Bool {
        guard isLive(child), child !== newParent,
              !hasAncestryCycle(startingAt: child) else { return false }

        if let newParent {
            guard isLive(newParent), child.taskList?.id == newParent.taskList?.id,
                  !isDescendant(newParent, of: child) else { return false }
        }

        child.parentTask = newParent
        child.parentUID = newParent?.uid
        child.lastModifiedDate = Date()
        child.isDirty = true
        return true
    }

    static func isDescendant(_ candidate: TaskItem, of ancestor: TaskItem) -> Bool {
        guard isLive(candidate), isLive(ancestor) else { return true }
        var current: TaskItem? = candidate
        var seen = Set<ObjectIdentifier>()

        while let task = current {
            guard isLive(task), seen.insert(ObjectIdentifier(task)).inserted else { return true }
            if task === ancestor { return true }
            current = task.parentTask
        }
        return false
    }

    private static func hasAncestryCycle(startingAt task: TaskItem) -> Bool {
        var current: TaskItem? = task
        var seen = Set<ObjectIdentifier>()

        while let node = current {
            guard isLive(node), seen.insert(ObjectIdentifier(node)).inserted else { return true }
            current = node.parentTask
        }
        return false
    }

    private static func isLive(_ task: TaskItem) -> Bool {
        task.modelContext != nil && !task.isDeletedLocally
    }

    /// Preorder traversal with a seen set. A deleted branch contributes no visible descendants.
    static func entries(from root: TaskItem, depth: Int = 0) -> [TaskTreeEntry] {
        guard root.modelContext != nil else { return [] }
        var stack: [(TaskItem, Int)] = [(root, depth)]
        var seen = Set<ObjectIdentifier>()
        var entries: [TaskTreeEntry] = []
        while let (task, level) = stack.popLast() {
            guard task.modelContext != nil, seen.insert(ObjectIdentifier(task)).inserted,
                  !task.isDeletedLocally else { continue }
            entries.append(TaskTreeEntry(task: task, depth: level))
            let children = task.subtasks.filter { $0.modelContext != nil && !$0.isDeletedLocally }
                .sorted { $0.createdDate < $1.createdDate }
            stack.append(contentsOf: children.reversed().map { ($0, level + 1) })
        }
        return entries
    }
}
