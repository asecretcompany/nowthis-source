import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Widget Configuration Tests

@Suite("WidgetConfiguration")
struct WidgetConfigurationTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    // MARK: - All Lists (no filter)

    @Test("Returns all tasks when no lists selected")
    @MainActor
    func allTasksWhenNoFilter() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list1 = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        let list2 = TaskList(serverURL: "", name: "Home", colorHex: "#00FF00")
        context.insert(list1)
        context.insert(list2)

        let task1 = TaskItem(title: "Work task")
        task1.taskList = list1
        context.insert(task1)

        let task2 = TaskItem(title: "Home task")
        task2.taskList = list2
        context.insert(task2)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [],
            maxTasks: 10,
            container: container
        )

        #expect(result.tasks.count == 2)
        #expect(result.displayName == "All Lists")
    }

    // MARK: - Single list filter

    @Test("Returns only tasks from selected list")
    @MainActor
    func singleListFilter() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let workList = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        let homeList = TaskList(serverURL: "", name: "Home", colorHex: "#00FF00")
        context.insert(workList)
        context.insert(homeList)

        let workTask = TaskItem(title: "Work task")
        workTask.taskList = workList
        context.insert(workTask)

        let homeTask = TaskItem(title: "Home task")
        homeTask.taskList = homeList
        context.insert(homeTask)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [workList.id],
            maxTasks: 10,
            container: container
        )

        #expect(result.tasks.count == 1)
        #expect(result.tasks.first?.title == "Work task")
        #expect(result.displayName == "Work")
    }

    // MARK: - Multi list filter

    @Test("Returns tasks from multiple selected lists")
    @MainActor
    func multiListFilter() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list1 = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        let list2 = TaskList(serverURL: "", name: "Home", colorHex: "#00FF00")
        let list3 = TaskList(serverURL: "", name: "Shopping", colorHex: "#0000FF")
        context.insert(list1)
        context.insert(list2)
        context.insert(list3)

        let t1 = TaskItem(title: "Work task")
        t1.taskList = list1
        context.insert(t1)

        let t2 = TaskItem(title: "Home task")
        t2.taskList = list2
        context.insert(t2)

        let t3 = TaskItem(title: "Shopping task")
        t3.taskList = list3
        context.insert(t3)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list1.id, list2.id],
            maxTasks: 10,
            container: container
        )

        #expect(result.tasks.count == 2)
        let titles = Set(result.tasks.map(\.title))
        #expect(titles.contains("Work task"))
        #expect(titles.contains("Home task"))
        #expect(!titles.contains("Shopping task"))
    }

    // MARK: - Excludes deleted tasks

    @Test("Excludes soft-deleted tasks from results")
    @MainActor
    func excludesDeletedTasks() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let active = TaskItem(title: "Active task")
        active.taskList = list
        context.insert(active)

        let deleted = TaskItem(title: "Deleted task")
        deleted.taskList = list
        deleted.isDeletedLocally = true
        context.insert(deleted)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list.id],
            maxTasks: 10,
            container: container
        )

        #expect(result.tasks.count == 1)
        #expect(result.tasks.first?.title == "Active task")
    }

    // MARK: - Respects maxTasks limit

    @Test("Respects maxTasks limit")
    @MainActor
    func respectsMaxTasks() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Big", colorHex: "#FF0000")
        context.insert(list)

        for i in 1...10 {
            let task = TaskItem(title: "Task \(i)")
            task.taskList = list
            context.insert(task)
        }

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list.id],
            maxTasks: 3,
            container: container
        )

        #expect(result.tasks.count == 3)
    }

    // MARK: - Display name for multiple lists

    @Test("Display name shows comma-separated list names for multi-select")
    @MainActor
    func displayNameMultiSelect() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list1 = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        let list2 = TaskList(serverURL: "", name: "Home", colorHex: "#00FF00")
        context.insert(list1)
        context.insert(list2)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list1.id, list2.id],
            maxTasks: 10,
            container: container
        )

        #expect(result.displayName.contains("Work"))
        #expect(result.displayName.contains("Home"))
    }

    // MARK: - Due date sorting

    @Test("Tasks with due dates appear before tasks without due dates")
    @MainActor
    func dueDateTasksSortFirst() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let noDue = TaskItem(title: "No due date")
        noDue.taskList = list
        context.insert(noDue)

        let hasDue = TaskItem(title: "Has due date")
        hasDue.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        hasDue.taskList = list
        context.insert(hasDue)

        let earlierDue = TaskItem(title: "Earlier due date")
        earlierDue.dueDate = Date()
        earlierDue.taskList = list
        context.insert(earlierDue)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list.id],
            maxTasks: 10,
            container: container
        )

        #expect(result.tasks.count == 3)
        // Tasks with due dates should come first, sorted by soonest
        #expect(result.tasks[0].title == "Earlier due date")
        #expect(result.tasks[1].title == "Has due date")
        #expect(result.tasks[2].title == "No due date")
    }

    @Test("Widget only shows due-date tasks when limit is reached")
    @MainActor
    func dueDateTasksFillLimitFirst() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        // Create 3 tasks without due dates
        for i in 1...3 {
            let task = TaskItem(title: "No due \(i)")
            task.taskList = list
            context.insert(task)
        }

        // Create 3 tasks WITH due dates
        for i in 1...3 {
            let task = TaskItem(title: "Due \(i)")
            task.dueDate = Calendar.current.date(byAdding: .day, value: i, to: Date())
            task.taskList = list
            context.insert(task)
        }

        try context.save()

        // Limit to 3 — should get ALL 3 due-date tasks, NONE of the no-due-date ones
        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list.id],
            maxTasks: 3,
            container: container
        )

        #expect(result.tasks.count == 3)
        for task in result.tasks {
            #expect(task.dueDate != nil, "All tasks in limited widget should have due dates, got: \(task.title)")
        }
    }

    // MARK: - Excludes completed tasks

    @Test("Excludes completed tasks from widget results")
    @MainActor
    func excludesCompletedTasks() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let active = TaskItem(title: "Active task")
        active.taskList = list
        context.insert(active)

        let completed = TaskItem(title: "Completed task", status: .completed)
        completed.taskList = list
        context.insert(completed)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list.id],
            maxTasks: 10,
            container: container
        )

        #expect(result.tasks.count == 1)
        #expect(result.tasks.first?.title == "Active task")
    }
}
