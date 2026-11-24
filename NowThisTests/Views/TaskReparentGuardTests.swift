import SwiftData
import Testing
@testable import NowThis

@Suite("Task reparent guard")
@MainActor
struct TaskReparentGuardTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    @Test("Rejecting a drop onto a descendant leaves the hierarchy unchanged")
    func rejectsDescendantDrop() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = TaskItem(id: "a", title: "A")
        let b = TaskItem(id: "b", title: "B")
        let c = TaskItem(id: "c", title: "C")
        [a, b, c].forEach { context.insert($0) }
        b.parentTask = a
        c.parentTask = b

        #expect(TaskHierarchyTraversal.reparent(a, under: c) == false)
        #expect(a.parentTask == nil)
        #expect(c.parentTask === b)
        withExtendedLifetime(container) {}
    }

    @Test("Rejecting a cross-list drop leaves the child at the root")
    func rejectsCrossListDrop() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let firstList = TaskList(serverURL: "/one/", name: "One", colorHex: "#000000")
        let secondList = TaskList(serverURL: "/two/", name: "Two", colorHex: "#000000")
        let child = TaskItem(id: "child", title: "Child")
        let parent = TaskItem(id: "parent", title: "Parent")
        [firstList, secondList].forEach { context.insert($0) }
        [child, parent].forEach { context.insert($0) }
        child.taskList = firstList
        parent.taskList = secondList

        #expect(TaskHierarchyTraversal.reparent(child, under: parent) == false)
        #expect(child.parentTask == nil)
        #expect(child.parentUID == nil)
        withExtendedLifetime(container) {}
    }

    @Test("A malformed parent ancestry cycle is unsafe and terminates")
    func rejectsExistingAncestryCycle() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = TaskItem(id: "a", title: "A")
        let b = TaskItem(id: "b", title: "B")
        let unrelated = TaskItem(id: "unrelated", title: "Unrelated")
        [a, b, unrelated].forEach { context.insert($0) }
        a.parentTask = b
        b.parentTask = a

        #expect(TaskHierarchyTraversal.isDescendant(a, of: unrelated))
        #expect(TaskHierarchyTraversal.reparent(unrelated, under: a) == false)
        withExtendedLifetime(container) {}
    }

    @Test("A valid same-list reparent and move to root succeed")
    func acceptsValidSameListAndRootReparent() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let list = TaskList(serverURL: "/one/", name: "One", colorHex: "#000000")
        let child = TaskItem(id: "child", title: "Child")
        let parent = TaskItem(id: "parent", title: "Parent")
        context.insert(list)
        context.insert(child)
        context.insert(parent)
        child.taskList = list
        parent.taskList = list

        #expect(TaskHierarchyTraversal.reparent(child, under: parent))
        #expect(child.parentTask === parent)
        #expect(child.parentUID == parent.uid)
        #expect(TaskHierarchyTraversal.reparent(child, under: nil))
        #expect(child.parentTask == nil)
        #expect(child.parentUID == nil)
        withExtendedLifetime(container) {}
    }

    @Test("Invalidated models and self drops are rejected")
    func rejectsInvalidatedAndSelfDrops() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let child = TaskItem(id: "child", title: "Child")
        context.insert(child)
        #expect(TaskHierarchyTraversal.reparent(child, under: child) == false)

        let detached = TaskItem(id: "detached", title: "Detached")
        #expect(TaskHierarchyTraversal.reparent(detached, under: nil) == false)
        withExtendedLifetime(container) {}
    }

    @Test("A drop resolves and accepts an unrelated same-list root")
    func dropAcceptsUnrelatedSameListRoot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let list = TaskList(serverURL: "/one/", name: "One", colorHex: "#000000")
        let dragged = TaskItem(id: "dragged", title: "Dragged")
        let target = TaskItem(id: "target", title: "Target")
        context.insert(list)
        context.insert(dragged)
        context.insert(target)
        dragged.taskList = list
        target.taskList = list
        try context.save()

        #expect(TaskHierarchyTraversal.reparent(taskID: dragged.id, under: target, in: context))
        #expect(dragged.parentTask === target)
        withExtendedLifetime(container) {}
    }

    @Test("A drop action rejects a parent on its grandchild and a cross-list target")
    func dropActionRejectsUnsafeTargets() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let firstList = TaskList(serverURL: "/one/", name: "One", colorHex: "#000000")
        let secondList = TaskList(serverURL: "/two/", name: "Two", colorHex: "#000000")
        let parent = TaskItem(id: "parent", title: "Parent")
        let child = TaskItem(id: "child", title: "Child")
        let grandchild = TaskItem(id: "grandchild", title: "Grandchild")
        let otherListTarget = TaskItem(id: "other-target", title: "Other target")
        [firstList, secondList].forEach { context.insert($0) }
        [parent, child, grandchild, otherListTarget].forEach { context.insert($0) }
        parent.taskList = firstList
        child.taskList = firstList
        grandchild.taskList = firstList
        otherListTarget.taskList = secondList
        child.parentTask = parent
        grandchild.parentTask = child
        try context.save()

        #expect(TaskHierarchyTraversal.reparent(taskID: parent.id, under: grandchild, in: context) == false)
        #expect(TaskHierarchyTraversal.reparent(taskID: child.id, under: otherListTarget, in: context) == false)
        withExtendedLifetime(container) {}
    }

    @Test("A drop action rejects missing and soft-deleted dragged IDs")
    func dropActionRejectsUnavailableIDs() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let target = TaskItem(id: "target", title: "Target")
        let deleted = TaskItem(id: "deleted", title: "Deleted")
        context.insert(target)
        context.insert(deleted)
        deleted.isDeletedLocally = true
        try context.save()

        #expect(TaskHierarchyTraversal.reparent(taskID: "missing", under: target, in: context) == false)
        #expect(TaskHierarchyTraversal.reparent(taskID: "detached", under: target, in: context) == false)
        #expect(TaskHierarchyTraversal.reparent(taskID: deleted.id, under: target, in: context) == false)
        withExtendedLifetime(container) {}
    }
}
