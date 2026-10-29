import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Cross-context deletion liveness

/// Covers the liveness guard `displayedTasks` applies before it reads a single
/// attribute of a `@Query` result.
///
/// `modelContext != nil` — the guard the row snapshot (`TaskRowData`) uses — only
/// catches a delete made on the **main** context, which detaches the model. The
/// `SyncEngine` hard-deletes on its own **background** context instead
/// (`SyncEngine.reconcileDeletions`, `pushDeletion`), and the main context is
/// never told: its `@Query` array still holds the task, still with a context, so
/// the guard passes and the first attribute read faults against a row that is no
/// longer in the store.
///
/// Every assertion here compares `persistentModelID`s, never attributes. Reading
/// an attribute of the deleted task is the very thing that traps, and a trap
/// inside the test process takes the whole run down with it rather than
/// reporting one red test.
@Suite("TaskListHelpers cross-context liveness")
@MainActor
struct TaskListLivenessTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(SchemaV2.models)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test("A task deleted on another context is dropped from the display list")
    func taskDeletedOnBackgroundContextIsFiltered() throws {
        // The container must outlive every context taken from it.
        let container = try makeContainer()
        let main = container.mainContext

        let keep = TaskItem(title: "keep")
        let doomed = TaskItem(title: "doomed")
        main.insert(keep)
        main.insert(doomed)
        try main.save()

        // What `@Query` handed the view, captured before the deletion lands.
        let stale = [keep, doomed]
        let keepID = keep.persistentModelID
        let doomedID = doomed.persistentModelID

        // The SyncEngine's background context, hard-deleting a task the server
        // no longer has. The main context is not notified.
        let background = ModelContext(container)
        let target = try #require(background.model(for: doomedID) as? TaskItem)
        background.delete(target)
        try background.save()

        let live = TaskListHelpers.liveTasks(stale, in: main)

        #expect(live.count == 1)
        #expect(live.map(\.persistentModelID) == [keepID])
        #expect(!live.map(\.persistentModelID).contains(doomedID))
    }

    @Test("Tasks whose rows are all present are returned untouched, in order")
    func liveTasksArePreservedInOrder() throws {
        let container = try makeContainer()
        let main = container.mainContext

        let tasks = (0..<3).map { TaskItem(title: "t\($0)") }
        for task in tasks { main.insert(task) }
        try main.save()

        let live = TaskListHelpers.liveTasks(tasks, in: main)

        #expect(live.count == 3)
        #expect(live.map(\.persistentModelID) == tasks.map(\.persistentModelID))
    }
}
