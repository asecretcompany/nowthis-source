import SwiftData
import Testing
@testable import NowThis

@Suite("Iterative task hierarchy traversal")
@MainActor
struct TaskHierarchyTraversalTests {
    @Test("Cycles terminate, deleted branches stay hidden and stable depth/order survives")
    func cyclesAndDeletedBranches() throws {
        let container = try DAVSyncScenario.container(); let context = container.mainContext
        let root = TaskItem(id: "root", title: "Root")
        let child = TaskItem(id: "child", title: "Child", status: .completed)
        let hidden = TaskItem(id: "hidden", title: "Hidden")
        let hiddenChild = TaskItem(id: "hiddenChild", title: "Hidden child")
        [root, child, hidden, hiddenChild].forEach { context.insert($0) }
        child.parentTask = root; root.parentTask = child
        hidden.parentTask = root; hidden.isDeletedLocally = true; hiddenChild.parentTask = hidden
        let entries = TaskHierarchyTraversal.entries(from: root)
        #expect(entries.map(\.id) == ["root", "child"])
        #expect(entries.map(\.depth) == [0, 1])
        withExtendedLifetime(container) {}
    }

    @Test("A deep chain does not consume the Swift call stack")
    func deepChain() throws {
        let container = try DAVSyncScenario.container(); let context = container.mainContext
        let root = TaskItem(id: "0", title: "Root"); context.insert(root)
        var parent = root
        for index in 1..<2000 {
            let child = TaskItem(id: String(index), title: "Child")
            context.insert(child); child.parentTask = parent; parent = child
        }
        let entries = TaskHierarchyTraversal.entries(from: root)
        #expect(entries.count == 2000)
        #expect(entries.last?.depth == 1999)
        withExtendedLifetime(container) {}
    }
}
