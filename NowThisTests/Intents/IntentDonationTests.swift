import Testing
import Foundation

@testable import NowThis

@Suite("IntentDonationManager")
struct IntentDonationTests {
    @Test("Create donation carries title and stable list identity")
    func createCarriesParameters() throws {
        let intent = try #require(IntentDonationManager.makeCreateTaskIntent(
            title: "Buy groceries", list: TaskListEntity(id: "list-work", name: "Work")))
        #expect(intent.taskTitle == "Buy groceries")
        #expect(intent.list?.id == "list-work")
        #expect(intent.list?.name == "Work")
    }

    @Test("Create donation preserves no list and distinguishes identically named lists")
    func createListIdentity() throws {
        let noList = try #require(IntentDonationManager.makeCreateTaskIntent(title: "Inbox task", list: nil))
        #expect(noList.taskTitle == "Inbox task")
        #expect(noList.list == nil)
        let first = try #require(IntentDonationManager.makeCreateTaskIntent(
            title: "Task", list: TaskListEntity(id: "first", name: "Work")))
        let second = try #require(IntentDonationManager.makeCreateTaskIntent(
            title: "Task", list: TaskListEntity(id: "second", name: "Work")))
        #expect(first.list?.id == "first")
        #expect(second.list?.id == "second")
    }

    @Test("Completion donation carries stable identity even for duplicate titles")
    func completeCarriesEntity() throws {
        let first = try #require(IntentDonationManager.makeCompleteTaskIntent(
            task: TaskEntity(id: "task-first", title: "Same title", isCompleted: true, listName: "Work")))
        let second = try #require(IntentDonationManager.makeCompleteTaskIntent(
            task: TaskEntity(id: "task-second", title: "Same title", isCompleted: false, listName: "Home")))
        #expect(first.task.id == "task-first")
        #expect(second.task.id == "task-second")
        #expect(first.task.title == "Same title")
        #expect(first.task.isCompleted)
        #expect(first.task.listName == "Work")
        #expect(!second.task.isCompleted)
        #expect(second.task.listName == "Home")
    }

    @Test("Donation factories reject empty required parameters")
    func emptyParametersAreNotDonated() {
        for title in ["", "  \n"] {
            #expect(IntentDonationManager.makeCreateTaskIntent(title: title, list: nil) == nil)
            #expect(IntentDonationManager.makeCompleteTaskIntent(task:
                TaskEntity(id: "task", title: title, isCompleted: true, listName: "Work")) == nil)
        }
        #expect(IntentDonationManager.makeCompleteTaskIntent(task:
            TaskEntity(id: "", title: "Task", isCompleted: true, listName: "Work")) == nil)
    }
}
