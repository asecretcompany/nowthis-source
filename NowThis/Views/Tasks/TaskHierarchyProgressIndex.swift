import Foundation

/// Descendant completion totals shared by rows in one active root hierarchy.
struct TaskHierarchyProgress {
    let completed: Int
    let total: Int
}

/// Builds descendant totals for a hierarchy revision so expanded rows do not
/// repeatedly walk overlapping subtrees.
struct TaskHierarchyProgressIndex<Node: AnyObject> {
    private let progressByNode: [ObjectIdentifier: TaskHierarchyProgress]

    init(
        roots: [Node],
        isVisible: (Node) -> Bool,
        children: (Node) -> [Node],
        isCompleted: (Node) -> Bool
    ) {
        var childrenByID: [ObjectIdentifier: [ObjectIdentifier]] = [:]
        var completionByID: [ObjectIdentifier: Bool] = [:]
        var traversalOrder: [ObjectIdentifier] = []
        var seen = Set<ObjectIdentifier>()
        var hasRepeatedNode = false
        var stack = roots.reversed().map { $0 }

        while let node = stack.popLast() {
            guard isVisible(node) else { continue }
            let nodeID = ObjectIdentifier(node)
            guard seen.insert(nodeID).inserted else {
                hasRepeatedNode = true
                continue
            }

            traversalOrder.append(nodeID)
            completionByID[nodeID] = isCompleted(node)

            let visibleChildren = children(node).filter(isVisible)
            let childIDs = visibleChildren.map(ObjectIdentifier.init)
            childrenByID[nodeID] = childIDs
            for childID in childIDs where seen.contains(childID) {
                hasRepeatedNode = true
            }
            stack.append(contentsOf: visibleChildren.reversed())
        }

        if hasRepeatedNode {
            // A valid task hierarchy is a tree. Keep the former per-row unique
            // descendant semantics for malformed cycles or shared children.
            var aggregates: [ObjectIdentifier: TaskHierarchyProgress] = [:]
            for nodeID in traversalOrder {
                var visited: Set<ObjectIdentifier> = [nodeID]
                var pending = childrenByID[nodeID] ?? []
                var completed = 0
                var total = 0
                while let descendantID = pending.popLast() {
                    guard visited.insert(descendantID).inserted else { continue }
                    total += 1
                    if completionByID[descendantID] == true { completed += 1 }
                    pending.append(contentsOf: childrenByID[descendantID] ?? [])
                }
                aggregates[nodeID] = TaskHierarchyProgress(completed: completed, total: total)
            }
            progressByNode = aggregates
            return
        }

        var aggregates: [ObjectIdentifier: TaskHierarchyProgress] = [:]
        for nodeID in traversalOrder.reversed() {
            var completed = 0
            var total = 0
            for childID in childrenByID[nodeID] ?? [] {
                let childProgress = aggregates[childID] ?? TaskHierarchyProgress(completed: 0, total: 0)
                completed += (completionByID[childID] == true ? 1 : 0) + childProgress.completed
                total += 1 + childProgress.total
            }
            aggregates[nodeID] = TaskHierarchyProgress(completed: completed, total: total)
        }
        progressByNode = aggregates
    }

    func progress(for node: Node) -> TaskHierarchyProgress {
        progressByNode[ObjectIdentifier(node)] ?? TaskHierarchyProgress(completed: 0, total: 0)
    }
}
