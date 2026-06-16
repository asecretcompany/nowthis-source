import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - CreateTaskIntent Expanded Parameter Tests

@Suite("CreateTaskIntent Expanded")
struct CreateTaskIntentExpandedTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    @Test("Sets due date on created task")
    @MainActor
    func setsDueDate() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)
        try context.save()

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!

        var intent = CreateTaskIntent()
        intent.taskTitle = "Task with due date"
        intent.dueDate = tomorrow
        _ = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == 1)
        #expect(tasks.first?.dueDate != nil)
        #expect(Calendar.current.isDate(tasks.first!.dueDate!, inSameDayAs: tomorrow))
    }

    @Test("Sets notes on created task")
    @MainActor
    func setsNotes() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)
        try context.save()

        var intent = CreateTaskIntent()
        intent.taskTitle = "Task with notes"
        intent.notes = "Remember to check the specs"
        _ = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.first?.descriptionText == "Remember to check the specs")
    }

    @Test("Creates and assigns tag")
    @MainActor
    func createsAndAssignsTag() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)
        try context.save()

        var intent = CreateTaskIntent()
        intent.taskTitle = "Tagged task"
        intent.tag = "urgent"
        _ = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.first?.tags.count == 1)
        #expect(tasks.first?.tags.first?.name == "urgent")
    }

    @Test("Reuses existing tag if it exists")
    @MainActor
    func reusesExistingTag() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let existingTag = NowThis.Tag(name: "urgent")
        context.insert(existingTag)
        try context.save()

        var intent = CreateTaskIntent()
        intent.taskTitle = "Another tagged task"
        intent.tag = "urgent"
        _ = try await intent.performWithContainer(container)

        // Should still have only 1 tag entity
        let tags = try context.fetch(FetchDescriptor<NowThis.Tag>())
        #expect(tags.count == 1)
    }
}
