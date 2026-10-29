import Foundation

/// Preorder rows for a single lazy List, with offsets into the original sibling groups.
/// The closures let the view guard model liveness and supply its existing sort order.
struct TaskListHierarchyProjection<Node, ID: Hashable> {
    struct Row: Identifiable {
        let id: ID
        let node: Node
        let parent: Node?
        let parentID: ID?
        let depth: Int
        let siblingIndex: Int
        let hasChildren: Bool
    }

    struct Move {
        let parent: Node?
        let parentID: ID?
        let source: IndexSet
        let destination: Int
    }

    let rows: [Row]

    init(roots: [Node], collapsedIDs: Set<ID> = [],
         isVisible: (Node) -> Bool, id: (Node) -> ID,
         orderedChildren: (Node) -> [Node]) {
        var stack: [(node: Node, parent: Node?, parentID: ID?, depth: Int, siblingIndex: Int)] = []
        for (index, root) in roots.enumerated().reversed() {
            stack.append((root, nil, nil, 0, index))
        }
        var seen = Set<ID>()
        var result: [Row] = []
        while let entry = stack.popLast() {
            // Check before either identity or relationships can fault a detached model.
            guard isVisible(entry.node) else { continue }
            let nodeID = id(entry.node)
            guard seen.insert(nodeID).inserted else { continue }
            let children = orderedChildren(entry.node).enumerated().filter {
                isVisible($0.element) && !seen.contains(id($0.element))
            }
            result.append(Row(id: nodeID, node: entry.node, parent: entry.parent,
                parentID: entry.parentID, depth: entry.depth,
                siblingIndex: entry.siblingIndex, hasChildren: !children.isEmpty))
            guard !collapsedIDs.contains(nodeID) else { continue }
            for (index, child) in children.reversed() {
                stack.append((child, entry.node, nodeID, entry.depth + 1, index))
            }
        }
        rows = result
    }

    /// List offsets include descendants; mutation handlers require sibling offsets.
    /// A drop within another sibling's subtree snaps after that sibling. Drops
    /// outside the group clamp to its start/end and never implicitly reparent.
    func move(from source: IndexSet, to destination: Int) -> Move? {
        guard let firstIndex = source.first, rows.indices.contains(firstIndex),
              (0...rows.count).contains(destination) else { return nil }
        let first = rows[firstIndex]
        guard source.allSatisfy({
            rows.indices.contains($0) && rows[$0].parentID == first.parentID
        }) else { return nil }
        let siblings = rows.enumerated().filter { $0.element.parentID == first.parentID }
        let siblingDestination = siblings.first { $0.offset >= destination }?.element.siblingIndex
            ?? ((siblings.last?.element.siblingIndex ?? -1) + 1)
        return Move(parent: first.parent, parentID: first.parentID,
            source: IndexSet(source.map { rows[$0].siblingIndex }),
            destination: siblingDestination)
    }
}

/// A root starts with no relationship reads; its first visible row activates it.
struct TaskListRootHierarchyState<Node, ID: Hashable> {
    private(set) var projection: TaskListHierarchyProjection<Node, ID>?
    private(set) var needsRefresh = true

    mutating func activate(_ build: () -> TaskListHierarchyProjection<Node, ID>) {
        guard needsRefresh else { return }
        projection = build()
        needsRefresh = false
    }

    private var receivedRevision: UInt64?

    mutating func receiveRevision(_ revision: UInt64) {
        guard revision != receivedRevision else { return }
        receivedRevision = revision
        invalidate()
    }

    mutating func invalidate() {
        needsRefresh = true
    }
}

/// Keep extreme hierarchies usable without losing their actual projected depth.
enum TaskListHierarchyLayout {
    static func visualDepth(_ depth: Int) -> Int {
        min(depth, 4)
    }
}
