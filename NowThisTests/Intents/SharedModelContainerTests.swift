import Foundation
import SwiftData
import Testing

@testable import NowThis

@Suite("Shared intent model container", .serialized)
@MainActor
struct SharedModelContainerTests {
    @Test("Repeated read-write factory calls reuse the process container")
    func processContainerIsCached() throws {
        let first = try SharedModelContainer.create()
        let second = try SharedModelContainer.create()
        #expect(first === second)
    }

    private func temporaryStore() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-13-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("tasks.store")
    }

    @Test("Read-only and read-write roles coexist, cache separately, and enforce saves")
    func rolesShareDurableStoreWithoutSharingWriteAccess() throws {
        let url = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let factory = SharedModelContainer.Factory(storeURL: url)
        let writer = try factory.create()
        let seedContext = ModelContext(writer)
        seedContext.insert(TaskItem(id: "seed", title: "Saved by writer"))
        try seedContext.save()

        let reader = try factory.createReadOnly()
        #expect(try factory.create() === writer)
        #expect(try factory.createReadOnly() === reader)
        #expect(reader !== writer)
        let readContext = ModelContext(reader)
        #expect(try readContext.fetch(FetchDescriptor<TaskItem>()).map(\.title) == ["Saved by writer"])
        readContext.insert(TaskItem(id: "forbidden", title: "Must not persist"))
        #expect(throws: (any Error).self) { try readContext.save() }
        readContext.rollback()
        #expect(try ModelContext(writer).fetchCount(FetchDescriptor<TaskItem>()) == 1)
    }

    @Test("A failed store open is retried after the filesystem recovers")
    func failedOpenIsRetryable() throws {
        let url = try temporaryStore()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockedParent = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedParent)
        let factory = SharedModelContainer.Factory(storeURL: blockedParent.appendingPathComponent("tasks.store"))
        #expect(throws: (any Error).self) { try factory.create() }
        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: false)
        let recovered = try factory.create()
        let context = ModelContext(recovered)
        context.insert(TaskItem(title: "Recovered"))
        try context.save()
        #expect(try ModelContext(recovered).fetchCount(FetchDescriptor<TaskItem>()) == 1)
        #expect(try factory.create() === recovered)
    }

    @Test("Entity queries re-read durable changes instead of retaining managed tasks and lists")
    func productionQueriesSeeExternalSave() async throws {
        let writer = try SharedModelContainer.create()
        let context = ModelContext(writer)
        let id = "task-13-\(UUID().uuidString)"
        let listID = "task-13-list-\(UUID().uuidString)"
        let task = TaskItem(id: id, title: "Before")
        let list = TaskList(id: listID, serverURL: "", name: "Before list", colorHex: "#007AFF")
        context.insert(task)
        context.insert(list)
        task.taskList = list
        try context.save()
        defer {
            context.delete(task)
            context.delete(list)
            try? context.save()
        }
        #expect(try await TaskEntityQuery().entities(for: [id]).first?.title == "Before")
        #expect(try await TaskListEntityQuery().entities(for: [listID]).first?.name == "Before list")
        #expect(try await WidgetListEntityQuery().entities(for: [listID]).first?.name == "Before list")

        let external = try ModelContainer(for: Schema(SchemaV2.models), configurations: Array(writer.configurations))
        let externalContext = ModelContext(external)
        let externalTask = try #require(EntityQueryLookup.tasks(for: [id], in: externalContext).first)
        let externalList = try #require(EntityQueryLookup.lists(for: [listID], in: externalContext).first)
        externalTask.title = "After"
        externalList.name = "After list"
        try externalContext.save()
        // Cached contexts can also carry unsaved state from an earlier operation.
        // A query must read the durable save through its own context.
        let cachedReader = try SharedModelContainer.createReadOnly().mainContext
        let stale = try #require(EntityQueryLookup.tasks(for: [id], in: cachedReader).first)
        stale.title = "Unsaved cached title"
        defer { cachedReader.rollback() }

        #expect(try await TaskEntityQuery().entities(for: [id]).first?.title == "After")
        #expect(try await TaskListEntityQuery().entities(for: [listID]).first?.name == "After list")
        #expect(try await WidgetListEntityQuery().entities(for: [listID]).first?.name == "After list")
        #expect(try await TaskEntityQuery().suggestedEntities().contains { $0.id == id && $0.title == "After" })
        #expect(try await TaskListEntityQuery().suggestedEntities().contains { $0.id == listID && $0.name == "After list" })
        #expect(try await WidgetListEntityQuery().suggestedEntities().contains { $0.id == listID && $0.name == "After list" })
    }

    @Test("Interactive completion uses a fresh read-write context and persists its result")
    func interactiveCompletionSeesExternalSave() async throws {
        let container = try SharedModelContainer.create()
        // Prime the cached container's main context with the obsolete active model.
        let original = TaskItem(id: "task-13-\(UUID().uuidString)", title: "Interactive task")
        container.mainContext.insert(original)
        try container.mainContext.save()
        defer {
            container.mainContext.delete(original)
            try? container.mainContext.save()
        }
        let external = try ModelContainer(for: Schema(SchemaV2.models), configurations: Array(container.configurations))
        let externalContext = ModelContext(external)
        let changed = try #require(EntityQueryLookup.tasks(for: [original.id], in: externalContext).first)
        changed.status = .completed
        changed.percentComplete = 100
        changed.completedDate = Date()
        try externalContext.save()
        // An earlier operation's unsaved model must not override durable state.
        original.status = .needsAction

        let intent = CompleteTaskIntent(task: TaskEntity(id: original.id, title: original.title,
                                                        isCompleted: false, listName: ""))
        let result = try await intent.perform()
        #expect(result.value == false)
        let durable = try #require(EntityQueryLookup.tasks(for: [original.id], in: ModelContext(container)).first)
        #expect(durable.status == .needsAction)
        #expect(durable.percentComplete == 0)
        #expect(durable.completedDate == nil)
        #expect(durable.isDirty)
    }
}
