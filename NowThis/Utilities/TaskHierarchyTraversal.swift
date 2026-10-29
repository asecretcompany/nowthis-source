import Foundation

struct TaskTreeEntry: Identifiable {
    let task: TaskItem
    let depth: Int
    var id: String { task.id }
}

enum TaskHierarchyTraversal {
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
