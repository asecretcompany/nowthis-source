import Testing
import Foundation
import SwiftData

@testable import NowThis

@Suite("Entity query scoping")
@MainActor
struct EntityQueryScopingTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(SchemaV2.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @Test("Task resolution predicate fetches only the requested visible row among 500 tasks")
    func taskDescriptorScopesAtTheStore() throws {
        let container = try makeContainer()
        let context = container.mainContext
        for index in 0..<500 {
            let task = TaskItem(id: "task-\(index)", title: "Task \(index)")
            task.isDeletedLocally = index == 498
            context.insert(task)
        }
        try context.save()

        let descriptor = EntityQueryLookup.taskDescriptor(for: ["task-499", "task-498", "missing"])
        #expect(descriptor.predicate != nil)
        #expect(descriptor.fetchLimit == nil)
        #expect(try context.fetchCount(descriptor) == 1)
        #expect(try context.fetch(descriptor).map(\.id) == ["task-499"])
        #expect(try TaskEntityQuery().entities(for: ["task-499"], in: context).map(\.id) == ["task-499"])
        #expect(try TaskEntityQuery().entities(for: ["task-498"], in: context).isEmpty)
    }

    @Test("Task resolution keeps requested order and omits duplicate missing and deleted IDs")
    func taskResolutionPreservesIdentityAndOrder() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let list = TaskList(id: "work", serverURL: "", name: "Work", colorHex: "#007AFF")
        context.insert(list)
        let first = TaskItem(id: "first", title: "First")
        let completed = TaskItem(id: "completed", title: "Finished", status: .completed)
        completed.taskList = list
        let deleted = TaskItem(id: "deleted", title: "Deleted")
        deleted.isDeletedLocally = true
        for task in [first, completed, deleted] { context.insert(task) }
        try context.save()

        let result = try TaskEntityQuery().entities(
            for: ["completed", "missing", "first", "completed", "deleted"], in: context)
        #expect(result.map(\.id) == ["completed", "first"])
        #expect(result.first?.title == "Finished")
        #expect(result.first?.isCompleted == true)
        #expect(result.first?.listName == "Work")
        #expect(result.last?.listName == TaskEntity.noListName)
        #expect(try TaskEntityQuery().entities(for: [], in: context).isEmpty)
        #expect(try TaskEntityQuery().entities(for: ["missing"], in: context).isEmpty)
        #expect(try context.fetchCount(EntityQueryLookup.taskDescriptor(for: [])) == 0)
    }

    @Test("List resolution scopes at the store and never clips more than 50 requested lists")
    func listResolutionIsScopedAndUnboundedBySuggestionLimit() throws {
        let container = try makeContainer()
        let context = container.mainContext
        for index in 0..<75 {
            context.insert(TaskList(id: "list-\(index)", serverURL: "",
                                    name: String(format: "List %02d", index), colorHex: "#007AFF"))
        }
        try context.save()
        let requested = (10..<75).reversed().map { "list-\($0)" }
        let identifiers = requested + ["missing", "list-74"]
        let descriptor = EntityQueryLookup.listDescriptor(for: identifiers)
        #expect(descriptor.predicate != nil)
        #expect(descriptor.fetchLimit == nil)
        #expect(try context.fetchCount(descriptor) == 65)
        #expect(try TaskListEntityQuery().entities(for: identifiers, in: context).map(\.id) == requested)
        #expect(try WidgetListEntityQuery().entities(for: identifiers, in: context).map(\.id) == requested)
    }

    @Test("Empty and missing list IDs resolve to nothing in both entity queries")
    func emptyAndMissingListResolution() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(TaskList(id: "existing", serverURL: "", name: "Work", colorHex: "#007AFF"))
        try context.save()
        #expect(try context.fetchCount(EntityQueryLookup.listDescriptor(for: [])) == 0)
        for identifiers in [[], ["missing"]] {
            #expect(try TaskListEntityQuery().entities(for: identifiers, in: context).isEmpty)
            #expect(try WidgetListEntityQuery().entities(for: identifiers, in: context).isEmpty)
        }
        #expect(try TaskListEntityQuery().entities(for: ["existing", "existing"], in: context).map(\.id) == ["existing"])
        #expect(try WidgetListEntityQuery().entities(for: ["existing", "existing"], in: context).map(\.id) == ["existing"])
    }

    @Test("Both list pickers offer the same first 50 lists in name order")
    func listSuggestionsAreBounded() throws {
        let container = try makeContainer()
        let context = container.mainContext
        for index in (0..<75).reversed() {
            context.insert(TaskList(id: "list-\(index)", serverURL: "",
                                    name: String(format: "List %02d", index), colorHex: "#007AFF"))
        }
        try context.save()
        let expected = (0..<50).map { "list-\($0)" }
        #expect(try TaskListEntityQuery().suggestedEntities(in: context).map(\.id) == expected)
        #expect(try WidgetListEntityQuery().suggestedEntities(in: context).map(\.id) == expected)
    }

    @Test("Equal list names have a stable identity order in both suggestion pickers")
    func equalListNamesHaveStableOrder() throws {
        let container = try makeContainer()
        let context = container.mainContext
        for id in ["c", "a", "b"] {
            context.insert(TaskList(id: id, serverURL: "", name: "Work", colorHex: "#007AFF"))
        }
        try context.save()
        #expect(try TaskListEntityQuery().suggestedEntities(in: context).map(\.id) == ["a", "b", "c"])
        #expect(try WidgetListEntityQuery().suggestedEntities(in: context).map(\.id) == ["a", "b", "c"])
    }

    @Test("Task suggestions remain the 20 newest visible tasks")
    func taskSuggestionsKeepExistingLimitAndVisibility() throws {
        let container = try makeContainer()
        let context = container.mainContext
        for index in 0..<30 {
            let task = TaskItem(id: "task-\(index)", title: "Task \(index)")
            task.createdDate = Date(timeIntervalSince1970: Double(index))
            task.isDeletedLocally = index == 29
            context.insert(task)
        }
        try context.save()
        let result = try TaskEntityQuery().suggestedEntities(in: context)
        #expect(result.map(\.id) == (9...28).reversed().map { "task-\($0)" })
    }

    @Test("Selected widget list names omit missing and unrelated lists and remain alphabetized")
    func selectedWidgetNamesUseScopedLookup() throws {
        let container = try makeContainer()
        let context = container.mainContext
        for (id, name) in [("work", "Work"), ("home", "Home"), ("unrelated", "Secret")] {
            context.insert(TaskList(id: id, serverURL: "", name: name, colorHex: "#007AFF"))
        }
        try context.save()
        let identifiers = ["work", "home", "missing", "work"]
        let descriptor = EntityQueryLookup.listDescriptor(for: identifiers)
        #expect(descriptor.predicate != nil)
        #expect(try context.fetchCount(descriptor) == 2)
        let result = try SelectListsIntent.fetchFilteredTasks(listIDs: identifiers, maxTasks: 5, container: container)
        #expect(result.tasks.isEmpty)
        #expect(result.displayName == "Home, Work")
    }
}
