import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Scoped task liveness")
@MainActor
struct TaskListScopedLivenessTests {
    @Test("Pending inserts, moves and parent changes obey the same list/root scope")
    func pendingEditsStayInScope() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let first = TaskList(id: "a", serverURL: "", name: "A", colorHex: "#007AFF")
        let other = TaskList(id: "b", serverURL: "", name: "B", colorHex: "#007AFF")
        context.insert(first); context.insert(other)
        let root = TaskItem(id: "root", title: "Root"); root.taskList = first
        let moved = TaskItem(id: "moved", title: "Moved"); moved.taskList = other
        context.insert(root); context.insert(moved); try context.save()
        let pending = TaskItem(id: "pending", title: "Pending"); pending.taskList = first
        context.insert(pending)
        moved.taskList = first
        let descriptor = FetchDescriptor(predicate: TaskListView.taskQueryPredicate(for: .taskList("a")))
        #expect(TaskListHelpers.liveTasks([root, moved, pending], in: context, matching: descriptor).map(\.id)
            == ["root", "moved", "pending"])
        moved.parentTask = root
        #expect(TaskListHelpers.liveTasks([root, moved, pending], in: context, matching: descriptor).map(\.id)
            == ["root", "pending"])
        pending.taskList = other
        #expect(TaskListHelpers.liveTasks([root, moved, pending], in: context, matching: descriptor).map(\.id)
            == ["root"])
        withExtendedLifetime(container) {}
    }

    @Test("Unrelated lists are excluded from the identifier result")
    func unrelatedRowsAreExcluded() throws {
        let fixture = try PerformanceFixture.seedDistributedTasks()
        let all = try fixture.context.fetch(FetchDescriptor<TaskItem>())
        let listID = "performance-distributed-list-0"
        let descriptor = FetchDescriptor(predicate: TaskListView.taskQueryPredicate(for: .taskList(listID)))
        let live = TaskListHelpers.liveTasks(all, in: fixture.context, matching: descriptor)
        #expect(live.count == 100)
        #expect(live.allSatisfy { $0.taskList?.id == listID })
        withExtendedLifetime(fixture) {}
    }

    @Test("Matrix reads roots before making display snapshots")
    func matrixQueryExcludesSubtasks() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let parent = TaskItem(id: "parent", title: "Parent")
        let child = TaskItem(id: "child", title: "Child"); child.parentTask = parent
        context.insert(parent); context.insert(child); try context.save()
        let descriptor = FetchDescriptor(predicate: EisenhowerMatrixView.activeTasksPredicate)
        #expect(try context.fetch(descriptor).map(\.id) == ["parent"])
        withExtendedLifetime(container) {}
    }
    @Test("Calendar scope keeps dated subtasks while excluding other lists")
    func calendarScopeKeepsSubtasks() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let first = TaskList(id: "a", serverURL: "", name: "A", colorHex: "#007AFF")
        let other = TaskList(id: "b", serverURL: "", name: "B", colorHex: "#007AFF")
        context.insert(first); context.insert(other)
        let parent = TaskItem(id: "parent", title: "Parent"); parent.taskList = first
        let child = TaskItem(id: "child", title: "Child"); child.taskList = first; child.parentTask = parent
        let unrelated = TaskItem(id: "other", title: "Other"); unrelated.taskList = other
        context.insert(parent); context.insert(child); context.insert(unrelated); try context.save()
        let descriptor = FetchDescriptor(predicate: CalendarContainerView.taskQueryPredicate(listID: "a"))
        #expect(try context.fetch(descriptor).map(\.id).sorted() == ["child", "parent"])
        withExtendedLifetime(container) {}
    }

}
