import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - TaskItem CRUD Tests

@Suite("TaskItem CRUD")
struct TaskItemCRUDTests {

    /// Creates an in-memory ModelContainer for isolated testing.
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self,
            configurations: config
        )
    }

    @Test("Insert and fetch a TaskItem")
    func insertAndFetch() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let task = TaskItem(title: "Buy groceries")
        context.insert(task)
        try context.save()

        let descriptor = FetchDescriptor<TaskItem>()
        let fetched = try context.fetch(descriptor)

        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Buy groceries")
        #expect(fetched.first?.status == .needsAction)
        #expect(fetched.first?.priority == TaskPriority.none)
        #expect(fetched.first?.percentComplete == 0)
        #expect(fetched.first?.isLocalOnly == true)
    }

    @Test("Update a TaskItem and verify isDirty")
    func updateAndDirtyFlag() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let task = TaskItem(title: "Original title")
        context.insert(task)
        try context.save()

        // Simulate a user edit
        task.title = "Updated title"
        task.isDirty = true
        task.lastModifiedDate = Date()
        try context.save()

        let descriptor = FetchDescriptor<TaskItem>()
        let fetched = try context.fetch(descriptor)

        #expect(fetched.first?.title == "Updated title")
        #expect(fetched.first?.isDirty == true)
    }

    @Test("Delete a TaskItem")
    func deleteTask() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let task = TaskItem(title: "To be deleted")
        context.insert(task)
        try context.save()

        context.delete(task)
        try context.save()

        let descriptor = FetchDescriptor<TaskItem>()
        let fetched = try context.fetch(descriptor)
        #expect(fetched.isEmpty)
    }

    @Test("Soft-delete sets isDeletedLocally flag")
    func softDelete() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let task = TaskItem(title: "Soft delete me")
        task.isLocalOnly = false  // Already synced
        context.insert(task)
        try context.save()

        // Soft-delete (for sync push)
        task.isDeletedLocally = true
        task.isDirty = true
        try context.save()

        // Item still exists in store
        let allDescriptor = FetchDescriptor<TaskItem>()
        let allFetched = try context.fetch(allDescriptor)
        #expect(allFetched.count == 1)
        #expect(allFetched.first?.isDeletedLocally == true)

        // But would be excluded from a "visible items" query
        let visibleDescriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { !$0.isDeletedLocally }
        )
        let visibleFetched = try context.fetch(visibleDescriptor)
        #expect(visibleFetched.isEmpty)
    }

    @Test("TaskItem initializer sets correct defaults")
    func initializerDefaults() throws {
        let task = TaskItem(title: "Test task")

        #expect(task.title == "Test task")
        #expect(task.status == .needsAction)
        #expect(task.priority == .none)
        #expect(task.percentComplete == 0)
        #expect(task.isLocalOnly == true)
        #expect(task.isDirty == false)
        #expect(task.isDeletedLocally == false)
        #expect(task.descriptionText == nil)
        #expect(task.dueDate == nil)
        #expect(task.startDate == nil)
        #expect(task.completedDate == nil)
        #expect(!task.id.isEmpty)
        #expect(!task.uid.isEmpty)
    }

    @Test("TaskItem completion sets status and date")
    func taskCompletion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let task = TaskItem(title: "Complete me")
        context.insert(task)

        // Complete the task
        task.status = .completed
        task.completedDate = Date()
        task.percentComplete = 100
        task.isDirty = true
        try context.save()

        let descriptor = FetchDescriptor<TaskItem>()
        let fetched = try context.fetch(descriptor)

        #expect(fetched.first?.status == .completed)
        #expect(fetched.first?.completedDate != nil)
        #expect(fetched.first?.percentComplete == 100)
    }
}

// MARK: - TaskItem Hierarchy Tests

@Suite("TaskItem Hierarchy")
struct TaskItemHierarchyTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self,
            configurations: config
        )
    }

    @Test("3-level deep hierarchy: parent → child → grandchild")
    func threeLevelHierarchy() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let parent = TaskItem(title: "Project")
        let child = TaskItem(title: "Feature")
        let grandchild = TaskItem(title: "Sub-task")

        child.parentTask = parent
        grandchild.parentTask = child

        context.insert(parent)
        context.insert(child)
        context.insert(grandchild)
        try context.save()

        // Verify parent has child
        #expect(parent.subtasks.count == 1)
        #expect(parent.subtasks.first?.title == "Feature")

        // Verify child has grandchild
        #expect(child.subtasks.count == 1)
        #expect(child.subtasks.first?.title == "Sub-task")

        // Verify grandchild has parent
        #expect(grandchild.parentTask?.title == "Feature")
        #expect(grandchild.parentTask?.parentTask?.title == "Project")
    }

    @Test("Cascade delete: removing parent deletes all descendants")
    func cascadeDelete() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let parent = TaskItem(title: "Parent")
        let child = TaskItem(title: "Child")
        let grandchild = TaskItem(title: "Grandchild")

        child.parentTask = parent
        grandchild.parentTask = child

        context.insert(parent)
        context.insert(child)
        context.insert(grandchild)
        try context.save()

        // Delete the parent
        context.delete(parent)
        try context.save()

        // All should be gone
        let descriptor = FetchDescriptor<TaskItem>()
        let remaining = try context.fetch(descriptor)
        #expect(remaining.isEmpty)
    }

    @Test("Root tasks have nil parentTask")
    func rootTasksHaveNilParent() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let root = TaskItem(title: "Root task")
        context.insert(root)
        try context.save()

        #expect(root.parentTask == nil)
        #expect(root.subtasks.isEmpty)
    }
}

// MARK: - TaskItem + TaskList Relationship Tests

@Suite("TaskItem-TaskList Relationship")
struct TaskItemTaskListTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self,
            configurations: config
        )
    }

    @Test("Task belongs to a TaskList")
    func taskBelongsToList() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let list = TaskList(serverURL: "https://example.com/tasks/", name: "Work", colorHex: "#FF5733")
        let task = TaskItem(title: "Finish report")
        task.taskList = list

        context.insert(list)
        context.insert(task)
        try context.save()

        #expect(list.tasks.count == 1)
        #expect(list.tasks.first?.title == "Finish report")
        #expect(task.taskList?.name == "Work")
    }

    @Test("Deleting a TaskList cascade-deletes its tasks")
    func cascadeDeleteList() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let list = TaskList(serverURL: "", name: "Temporary", colorHex: "#333333")
        let task1 = TaskItem(title: "Task 1")
        let task2 = TaskItem(title: "Task 2")
        task1.taskList = list
        task2.taskList = list

        context.insert(list)
        context.insert(task1)
        context.insert(task2)
        try context.save()

        #expect(list.tasks.count == 2)

        context.delete(list)
        try context.save()

        let remainingTasks = try context.fetch(FetchDescriptor<TaskItem>())
        let remainingLists = try context.fetch(FetchDescriptor<TaskList>())
        #expect(remainingTasks.isEmpty)
        #expect(remainingLists.isEmpty)
    }
}

// MARK: - TaskItem + Tag Relationship Tests

@Suite("TaskItem-Tag Relationship")
struct TaskItemTagTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self,
            configurations: config
        )
    }

    @Test("Many-to-many: Task has multiple tags")
    func taskHasMultipleTags() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let task = TaskItem(title: "Tagged task")
        let tag1 = Tag(name: "urgent")
        let tag2 = Tag(name: "backend")

        task.tags.append(tag1)
        task.tags.append(tag2)

        context.insert(task)
        context.insert(tag1)
        context.insert(tag2)
        try context.save()

        #expect(task.tags.count == 2)
        let tagNames = Set(task.tags.map(\.name))
        #expect(tagNames.contains("urgent"))
        #expect(tagNames.contains("backend"))
    }

    @Test("Many-to-many inverse: Tag.tasks resolves correctly")
    func tagInverseResolvesCorrectly() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let task1 = TaskItem(title: "Task A")
        let task2 = TaskItem(title: "Task B")
        let tag = Tag(name: "shared-tag")

        task1.tags.append(tag)
        task2.tags.append(tag)

        context.insert(task1)
        context.insert(task2)
        context.insert(tag)
        try context.save()

        // Verify inverse: tag.tasks should contain both tasks
        #expect(tag.tasks.count == 2)
        let titles = Set(tag.tasks.map(\.title))
        #expect(titles.contains("Task A"))
        #expect(titles.contains("Task B"))
    }

    @Test("Many-to-many survives re-fetch from fresh context")
    func tagRelationshipSurvivesRefetch() throws {
        let container = try makeContainer()
        let context1 = ModelContext(container)

        let task = TaskItem(title: "Persisted task")
        let tag = Tag(name: "persisted-tag")
        task.tags.append(tag)

        context1.insert(task)
        context1.insert(tag)
        try context1.save()

        // Re-fetch from a new context to trigger SwiftData fault resolution
        let context2 = ModelContext(container)
        let tasks = try context2.fetch(FetchDescriptor<TaskItem>())
        let tags = try context2.fetch(FetchDescriptor<NowThis.Tag>())

        #expect(tasks.count == 1)
        #expect(tags.count == 1)

        let fetchedTask = try #require(tasks.first)
        let fetchedTag = try #require(tags.first)

        // These accesses trigger relationship faulting — the crash site
        #expect(fetchedTask.tags.count == 1)
        #expect(fetchedTask.tags.first?.name == "persisted-tag")
        #expect(fetchedTag.tasks.count == 1)
        #expect(fetchedTag.tasks.first?.title == "Persisted task")
    }
}
