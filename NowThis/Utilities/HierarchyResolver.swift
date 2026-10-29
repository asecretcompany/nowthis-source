import Foundation

enum HierarchyResolver {
    /// Returns only parent links whose endpoints exist and which are not part of a cycle.
    ///
    /// Each child has at most one outgoing parent link, so walking and marking each node
    /// once takes O(n) expected time and O(n) space. The walk is iterative to support deep
    /// hierarchies without using the call stack.
    static func resolvedParents(_ rawParents: [String: String?]) -> [String: String] {
        var parents: [String: String] = [:]
        for (child, rawParent) in rawParents {
            guard let parent = rawParent,
                  parent != child,
                  rawParents.index(forKey: parent) != nil
            else {
                continue
            }
            parents[child] = parent
        }

        var completed = Set<String>()
        var pathPositions: [String: Int] = [:]

        for start in rawParents.keys where !completed.contains(start) {
            var path: [String] = []
            pathPositions.removeAll(keepingCapacity: true)

            var current: String? = start
            while let node = current, !completed.contains(node) {
                if let cycleStart = pathPositions[node] {
                    for cycleNode in path[cycleStart...] {
                        parents.removeValue(forKey: cycleNode)
                    }
                    break
                }

                pathPositions[node] = path.count
                path.append(node)
                current = parents[node]
            }

            completed.formUnion(path)
        }

        return parents
    }
}
