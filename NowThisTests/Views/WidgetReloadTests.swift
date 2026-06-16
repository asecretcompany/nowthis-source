import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Widget Reload on Completion Tests

@Suite("Widget Reload on Task Changes")
struct WidgetReloadTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    @Test("Widget reload is triggered when a task is completed")
    @MainActor
    func widgetReloadOnComplete() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = TaskItem(title: "Test task")
        context.insert(task)

        var widgetReloaded = false
        let coordinator = TaskCompletionCoordinator(
            animationDelay: 0.05,
            onWidgetReload: { widgetReloaded = true }
        )

        coordinator.toggle(task) { }
        try await Task.sleep(for: .milliseconds(150))

        #expect(task.status == .completed)
        #expect(widgetReloaded == true, "Widget timelines should be reloaded after completing a task")
    }

    @Test("Widget reload is triggered when a task is un-completed")
    @MainActor
    func widgetReloadOnUncomplete() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = TaskItem(title: "Test task", status: .completed)
        task.completedDate = Date()
        task.percentComplete = 100
        context.insert(task)

        var widgetReloaded = false
        let coordinator = TaskCompletionCoordinator(
            animationDelay: 0.8,
            onWidgetReload: { widgetReloaded = true }
        )

        coordinator.toggle(task) { }

        #expect(task.status == .needsAction)
        #expect(widgetReloaded == true, "Widget timelines should be reloaded after un-completing a task")
    }

    @Test("Completed task is excluded from widget fetch results")
    @MainActor
    func completedTaskExcludedFromWidgetFetch() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let task1 = TaskItem(title: "Active task")
        task1.taskList = list
        context.insert(task1)

        let task2 = TaskItem(title: "Will complete")
        task2.taskList = list
        context.insert(task2)

        try context.save()

        // Before completion: both tasks shown
        let beforeResult = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list.id],
            maxTasks: 10,
            container: container
        )
        #expect(beforeResult.tasks.count == 2)

        // Complete the task via coordinator (simulating main app interaction)
        let coordinator = TaskCompletionCoordinator(animationDelay: 0.05)
        coordinator.toggle(task2) {
            try? context.save()
        }

        try await Task.sleep(for: .milliseconds(150))

        // After completion: only 1 task shown in widget
        let afterResult = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list.id],
            maxTasks: 10,
            container: container
        )
        #expect(afterResult.tasks.count == 1)
        #expect(afterResult.tasks.first?.title == "Active task")
    }
}
