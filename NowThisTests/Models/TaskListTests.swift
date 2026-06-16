import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - TaskList CRUD Tests

@Suite("TaskList CRUD")
struct TaskListCRUDTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self,
            configurations: config
        )
    }

    @Test("Insert and fetch a TaskList")
    func insertAndFetch() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let list = TaskList(
            serverURL: "https://cloud.example.com/remote.php/dav/calendars/user/tasks/",
            name: "Work Tasks",
            colorHex: "#007AFF"
        )
        context.insert(list)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<TaskList>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.name == "Work Tasks")
        #expect(fetched.first?.colorHex == "#007AFF")
        #expect(fetched.first?.isReadOnly == false)
    }

    @Test("Update TaskList properties")
    func updateTaskList() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let list = TaskList(serverURL: "", name: "Old Name", colorHex: "#000000")
        context.insert(list)
        try context.save()

        list.name = "New Name"
        list.colorHex = "#FF0000"
        list.ctag = "ctag-123"
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<TaskList>())
        #expect(fetched.first?.name == "New Name")
        #expect(fetched.first?.colorHex == "#FF0000")
        #expect(fetched.first?.ctag == "ctag-123")
    }

    @Test("Delete a TaskList")
    func deleteTaskList() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let list = TaskList(serverURL: "", name: "Delete me", colorHex: "#333")
        context.insert(list)
        try context.save()

        context.delete(list)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<TaskList>())
        #expect(fetched.isEmpty)
    }
}

// MARK: - TaskList + ServerAccount Relationship Tests

@Suite("TaskList-Account Relationship")
struct TaskListAccountTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self,
            configurations: config
        )
    }

    @Test("TaskList belongs to a ServerAccount")
    func listBelongsToAccount() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let account = ServerAccount(
            displayName: "My Cloud",
            serverBaseURL: "https://cloud.example.com",
            username: "user"
        )
        let list = TaskList(serverURL: "https://cloud.example.com/tasks/", name: "Personal", colorHex: "#00FF00")
        list.account = account

        context.insert(account)
        context.insert(list)
        try context.save()

        #expect(account.taskLists.count == 1)
        #expect(account.taskLists.first?.name == "Personal")
        #expect(list.account?.displayName == "My Cloud")
    }

    @Test("Deleting an account cascade-deletes its task lists")
    func cascadeDeleteAccount() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let account = ServerAccount(
            displayName: "Test",
            serverBaseURL: "https://test.com",
            username: "test"
        )
        let list1 = TaskList(serverURL: "", name: "List 1", colorHex: "#111")
        let list2 = TaskList(serverURL: "", name: "List 2", colorHex: "#222")
        list1.account = account
        list2.account = account

        context.insert(account)
        context.insert(list1)
        context.insert(list2)
        try context.save()

        context.delete(account)
        try context.save()

        let remainingAccounts = try context.fetch(FetchDescriptor<ServerAccount>())
        let remainingLists = try context.fetch(FetchDescriptor<TaskList>())
        #expect(remainingAccounts.isEmpty)
        #expect(remainingLists.isEmpty)
    }
}
