import SwiftData
import Testing
import Observation

@testable import NowThis

@Suite("Task Hierarchy Progress Index")
struct TaskHierarchyProgressIndexTests {
    @Observable
    final class Node {
        var children: [Node] = []
        var isCompleted = false
        var isDeleted = false
    }

    private func makeIndex(roots: [Node]) -> TaskHierarchyProgressIndex<Node> {
        TaskHierarchyProgressIndex(
            roots: roots,
            isVisible: { !$0.isDeleted },
            children: { $0.children },
            isCompleted: { $0.isCompleted }
        )
    }

    @Test("One acyclic hierarchy pass supplies progress for every row")
    func aggregatesBroadHierarchyInLinearWork() {
        let root = Node()
        let children = (0..<1_649).map { index in
            let node = Node()
            node.isCompleted = index.isMultiple(of: 2)
            return node
        }
        root.children = children

        var childrenReadCount = 0
        var completionReadCount = 0
        let index = TaskHierarchyProgressIndex(
            roots: [root],
            isVisible: { !$0.isDeleted },
            children: {
                childrenReadCount += 1
                return $0.children
            },
            isCompleted: {
                completionReadCount += 1
                return $0.isCompleted
            }
        )

        #expect(childrenReadCount == 1_650, "each visible node's children are read once")
        #expect(completionReadCount == 1_650, "each visible node's completion is read once")
        #expect(index.progress(for: root).total == 1_649)
        #expect(index.progress(for: root).completed == 825)
        #expect(index.progress(for: children[0]).total == 0)
        #expect(index.progress(for: children[0]).completed == 0)
    }

    @Test("Cycles retain per-row descendant semantics without counting the row itself")
    func handlesMalformedCycle() {
        let first = Node()
        let second = Node()
        first.children = [second]
        second.children = [first]
        second.isCompleted = true

        let index = makeIndex(roots: [first])

        #expect(index.progress(for: first).total == 1)
        #expect(index.progress(for: first).completed == 1)
        #expect(index.progress(for: second).total == 1)
        #expect(index.progress(for: second).completed == 0)
    }

    @Test("Deleted branches do not contribute to any row progress")
    func prunesDeletedBranches() {
        let root = Node()
        let visible = Node()
        let deleted = Node()
        let deletedChild = Node()
        deleted.isDeleted = true
        deleted.isCompleted = true
        deleted.children = [deletedChild]
        root.children = [visible, deleted]

        var childrenReadCount = 0
        let index = TaskHierarchyProgressIndex(
            roots: [root],
            isVisible: { !$0.isDeleted },
            children: {
                childrenReadCount += 1
                return $0.children
            },
            isCompleted: { $0.isCompleted }
        )

        #expect(index.progress(for: root).total == 1)
        #expect(index.progress(for: root).completed == 0)
        #expect(childrenReadCount == 2, "deleted nodes and their descendants are never traversed")
    }

    @Test("An unsaved grandchild completion invalidates the shared root aggregate")
    @MainActor
    func unsavedCompletionRebuildsObservedProgress() {
        let root = Node()
        let child = Node()
        let grandchild = Node()
        root.children = [child]
        child.children = [grandchild]
        let cache = ObservedProjectionCache<String, TaskHierarchyProgressIndex<Node>>()
        var buildCount = 0

        func progress() -> TaskHierarchyProgressIndex<Node> {
            cache.value(for: "root") {
                buildCount += 1
                return makeIndex(roots: [root])
            }
        }

        #expect(progress().progress(for: root).completed == 0)
        grandchild.isCompleted = true
        let updated = progress()

        #expect(updated.progress(for: root).total == 2)
        #expect(updated.progress(for: root).completed == 1)
        #expect(updated.progress(for: child).total == 1)
        #expect(updated.progress(for: child).completed == 1)
        #expect(buildCount == 2, "the unsaved property change rebuilds the active revision")
    }
    @Test("Shared progress observes unsaved SwiftData descendant edits and deleted branches")
    @MainActor
    func swiftDataDescendantChangesRefreshAggregates() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let root = TaskItem(title: "Root")
        let child = TaskItem(title: "Child")
        let grandchild = TaskItem(title: "Grandchild")
        context.insert(root); context.insert(child); context.insert(grandchild)
        child.parentTask = root; grandchild.parentTask = child
        try context.save()
        let cache = ObservedProjectionCache<Int, TaskHierarchyProgressIndex<TaskItem>>()
        func index() -> TaskHierarchyProgressIndex<TaskItem> {
            cache.value(for: 0) {
                TaskHierarchyProgressIndex(roots: [root],
                    isVisible: { $0.modelContext != nil && !$0.isDeletedLocally },
                    children: { $0.subtasks }, isCompleted: { $0.status == .completed })
            }
        }
        #expect(index().progress(for: root).total == 2)
        #expect(index().progress(for: root).completed == 0)
        grandchild.status = .completed
        #expect(index().progress(for: root).completed == 1)
        child.isDeletedLocally = true
        let progress = index().progress(for: root)
        #expect(progress.total == 0)
        #expect(progress.completed == 0)
        let row = try #require(TaskRowData(task: root, progress: progress))
        #expect(row.directSubtaskCount == 1)
        #expect(row.subtasksTotal == 0)
        #expect(context.hasChanges)
        withExtendedLifetime(container) {}
    }

}
