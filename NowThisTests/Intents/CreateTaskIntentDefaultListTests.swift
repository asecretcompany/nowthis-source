import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - CreateTaskIntent Default List Tests

@Suite("CreateTaskIntent Default List")
struct CreateTaskIntentDefaultListTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    @Test("Uses configured default list instead of first alphabetical list")
    @MainActor
    func usesConfiguredDefaultList() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        // Create three lists — alphabetically: Grocery, Personal, Work
        let grocery = TaskList(serverURL: "", name: "Grocery", colorHex: "#00FF00")
        let personal = TaskList(serverURL: "", name: "Personal", colorHex: "#0000FF")
        let work = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(grocery)
        context.insert(personal)
        context.insert(work)
        try context.save()

        // Configure "Work" as the default Siri list
        UserDefaults.standard.set(work.id, forKey: "defaultSiriListID")

        var intent = CreateTaskIntent()
        intent.taskTitle = "Buy coffee beans"
        // list is nil — should use the configured default, not alphabetical first
        let result = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == 1)
        #expect(tasks.first?.taskList?.id == work.id)
        #expect(result.dialog.contains("Work"))

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "defaultSiriListID")
    }

    @Test("Falls back to first list when configured default list is deleted")
    @MainActor
    func fallsBackWhenDefaultListDeleted() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let alpha = TaskList(serverURL: "", name: "Alpha", colorHex: "#FF0000")
        let beta = TaskList(serverURL: "", name: "Beta", colorHex: "#00FF00")
        context.insert(alpha)
        context.insert(beta)
        try context.save()

        // Point to a non-existent list ID
        UserDefaults.standard.set("deleted-list-id-that-does-not-exist", forKey: "defaultSiriListID")

        var intent = CreateTaskIntent()
        intent.taskTitle = "Fallback task"
        let result = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == 1)
        // Should fall back to first alphabetical list
        #expect(tasks.first?.taskList?.id == alpha.id)
        #expect(result.dialog.contains("Alpha"))

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "defaultSiriListID")
    }

    @Test("Falls back to first list when no default is configured")
    @MainActor
    func fallsBackWhenNoDefaultConfigured() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let alpha = TaskList(serverURL: "", name: "Alpha", colorHex: "#FF0000")
        let beta = TaskList(serverURL: "", name: "Beta", colorHex: "#00FF00")
        context.insert(alpha)
        context.insert(beta)
        try context.save()

        // Ensure no default is set
        UserDefaults.standard.removeObject(forKey: "defaultSiriListID")

        var intent = CreateTaskIntent()
        intent.taskTitle = "No default task"
        let result = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == 1)
        // Should use first alphabetical list (existing behavior)
        #expect(tasks.first?.taskList?.id == alpha.id)
        #expect(result.dialog.contains("Alpha"))
    }
}
