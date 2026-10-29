import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - TaskListView Query Predicate Tests
//
// `TaskListView` used to `@Query` every non-deleted task — subtasks and
// completed history included — then filter roots in Swift on every read of
// `displayedTasks`, at ~100 ms per pass at 1,650 tasks. `taskQueryPredicate`
// moves the root/list filter into the `@Query`'s `#Predicate` itself, so
// SwiftData does the filtering once at fetch time instead of the view redoing
// it two or three times per render and per add.

@Suite("TaskListView Query Predicate")
struct TaskListQueryTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(SchemaV2.models)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test("A smart list fetches live roots only")
    @MainActor
    func smartListFetchesLiveRootsOnly() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let rootA = TaskItem(title: "Root A")
        let subtaskB = TaskItem(title: "Subtask B")
        subtaskB.parentTask = rootA
        subtaskB.parentUID = rootA.uid
        let rootC = TaskItem(title: "Root C")
        rootC.isDeletedLocally = true

        context.insert(rootA)
        context.insert(subtaskB)
        context.insert(rootC)
        try context.save()

        let predicate = TaskListView.taskQueryPredicate(for: .smart(.all))
        let results = try context.fetch(FetchDescriptor<TaskItem>(predicate: predicate))

        #expect(Set(results.map(\.id)) == [rootA.id])
    }

    @Test("A list selection fetches only that list's roots")
    @MainActor
    func listSelectionFetchesOnlyThatListsRoots() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let listL1 = TaskList(serverURL: "https://x.test", name: "L1", colorHex: "#FF0000")
        let listL2 = TaskList(serverURL: "https://x.test", name: "L2", colorHex: "#00FF00")

        let rootR1 = TaskItem(title: "Root R1")
        rootR1.taskList = listL1
        let rootR2 = TaskItem(title: "Root R2")
        rootR2.taskList = listL2
        let subtaskS1 = TaskItem(title: "Subtask S1")
        subtaskS1.taskList = listL1
        subtaskS1.parentTask = rootR1
        subtaskS1.parentUID = rootR1.uid

        context.insert(listL1)
        context.insert(listL2)
        context.insert(rootR1)
        context.insert(rootR2)
        context.insert(subtaskS1)
        try context.save()

        let predicate = TaskListView.taskQueryPredicate(for: .taskList(listL1.id))
        let results = try context.fetch(FetchDescriptor<TaskItem>(predicate: predicate))

        #expect(Set(results.map(\.id)) == [rootR1.id])
    }

    @Test("Tag and saved-filter selections fetch all live roots")
    @MainActor
    func tagAndSavedFilterSelectionsFetchAllLiveRoots() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let listL1 = TaskList(serverURL: "https://x.test", name: "L1", colorHex: "#FF0000")
        let listL2 = TaskList(serverURL: "https://x.test", name: "L2", colorHex: "#00FF00")

        let rootR1 = TaskItem(title: "Root R1")
        rootR1.taskList = listL1
        let rootR2 = TaskItem(title: "Root R2")
        rootR2.taskList = listL2
        let subtaskS1 = TaskItem(title: "Subtask S1")
        subtaskS1.taskList = listL1
        subtaskS1.parentTask = rootR1
        subtaskS1.parentUID = rootR1.uid

        context.insert(listL1)
        context.insert(listL2)
        context.insert(rootR1)
        context.insert(rootR2)
        context.insert(subtaskS1)
        try context.save()

        let predicate = TaskListView.taskQueryPredicate(for: .tag("any"))
        let results = try context.fetch(FetchDescriptor<TaskItem>(predicate: predicate))

        #expect(Set(results.map(\.id)) == [rootR1.id, rootR2.id])
    }
}
