import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Widget Today Filter Tests

@Suite("WidgetTodayFilter")
struct WidgetTodayFilterTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    // MARK: - Only today's tasks shown by default

    @Test("Widget only returns tasks due today")
    @MainActor
    func onlyTasksDueToday() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        // Task due today
        let todayTask = TaskItem(title: "Due today")
        todayTask.dueDate = Date()
        todayTask.taskList = list
        context.insert(todayTask)

        // Task due tomorrow
        let tomorrowTask = TaskItem(title: "Due tomorrow")
        tomorrowTask.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        tomorrowTask.taskList = list
        context.insert(tomorrowTask)

        // Task due next week
        let nextWeekTask = TaskItem(title: "Due next week")
        nextWeekTask.dueDate = Calendar.current.date(byAdding: .day, value: 7, to: Date())
        nextWeekTask.taskList = list
        context.insert(nextWeekTask)

        // Task with no due date
        let noDueTask = TaskItem(title: "No due date")
        noDueTask.taskList = list
        context.insert(noDueTask)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [],
            maxTasks: 10,
            showOverdue: false,
            container: container
        )

        #expect(result.tasks.count == 1)
        #expect(result.tasks.first?.title == "Due today")
    }

    // MARK: - Overdue + today when toggle is on

    @Test("Widget returns overdue and today tasks when showOverdue is true")
    @MainActor
    func overdueAndTodayTasks() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        // Task due today
        let todayTask = TaskItem(title: "Due today")
        todayTask.dueDate = Date()
        todayTask.taskList = list
        context.insert(todayTask)

        // Task overdue (yesterday)
        let overdueTask = TaskItem(title: "Overdue yesterday")
        overdueTask.dueDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        overdueTask.taskList = list
        context.insert(overdueTask)

        // Task overdue (last week)
        let overdueOldTask = TaskItem(title: "Overdue last week")
        overdueOldTask.dueDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())
        overdueOldTask.taskList = list
        context.insert(overdueOldTask)

        // Task due tomorrow (should NOT appear)
        let tomorrowTask = TaskItem(title: "Due tomorrow")
        tomorrowTask.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        tomorrowTask.taskList = list
        context.insert(tomorrowTask)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [],
            maxTasks: 10,
            showOverdue: true,
            container: container
        )

        #expect(result.tasks.count == 3)
        let titles = Set(result.tasks.map(\.title))
        #expect(titles.contains("Due today"))
        #expect(titles.contains("Overdue yesterday"))
        #expect(titles.contains("Overdue last week"))
        #expect(!titles.contains("Due tomorrow"))
    }

    // MARK: - Overdue off excludes overdue tasks

    @Test("Widget excludes overdue tasks when showOverdue is false")
    @MainActor
    func overdueExcludedWhenToggleOff() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        // Task due today
        let todayTask = TaskItem(title: "Due today")
        todayTask.dueDate = Date()
        todayTask.taskList = list
        context.insert(todayTask)

        // Task overdue
        let overdueTask = TaskItem(title: "Overdue")
        overdueTask.dueDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())
        overdueTask.taskList = list
        context.insert(overdueTask)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [],
            maxTasks: 10,
            showOverdue: false,
            container: container
        )

        #expect(result.tasks.count == 1)
        #expect(result.tasks.first?.title == "Due today")
    }

    // MARK: - Date-only tasks due today are included

    @Test("Date-only task due today is included in widget")
    @MainActor
    func dateOnlyDueTodayIncluded() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        // Date-only task due today — stored as midnight UTC for today's date
        let todayTask = TaskItem(title: "Date-only today")
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let localComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        todayTask.dueDate = utcCal.date(from: localComponents)
        todayTask.isDueDateOnly = true
        todayTask.taskList = list
        context.insert(todayTask)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [],
            maxTasks: 10,
            showOverdue: false,
            container: container
        )

        #expect(result.tasks.count == 1)
        #expect(result.tasks.first?.title == "Date-only today")
    }

    // MARK: - Empty state when nothing due today

    @Test("Widget returns empty when no tasks are due today")
    @MainActor
    func emptyWhenNothingDueToday() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        // Only future tasks
        let futureTask = TaskItem(title: "Due next week")
        futureTask.dueDate = Calendar.current.date(byAdding: .day, value: 7, to: Date())
        futureTask.taskList = list
        context.insert(futureTask)

        // No due date
        let noDueTask = TaskItem(title: "No due date")
        noDueTask.taskList = list
        context.insert(noDueTask)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [],
            maxTasks: 10,
            showOverdue: false,
            container: container
        )

        #expect(result.tasks.isEmpty)
    }
}
