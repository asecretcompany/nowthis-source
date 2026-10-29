import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Watch snapshot pipeline")
@MainActor
struct WatchSnapshotPipelineTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(SchemaV2.models)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test func pendingEditsMovesAndDeletesOverlaySavedRows() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let source = TaskList(serverURL: "https://example.com/dav", name: "Source", colorHex: "#111111")
        let destination = TaskList(serverURL: "https://example.com/dav", name: "Destination", colorHex: "#222222")
        let edited = TaskItem(title: "Saved title")
        edited.taskList = source
        let removed = TaskItem(title: "Delete me")
        removed.taskList = source
        for model in [source, destination] { context.insert(model) }
        for model in [edited, removed] { context.insert(model) }
        try context.save()

        let savedTasks = [WatchTaskInput(edited, isLive: true), WatchTaskInput(removed, isLive: true)]
        let savedLists = [WatchListInput(source), WatchListInput(destination)]
        edited.title = "Pending title"
        edited.taskList = destination
        context.delete(removed)
        let overlay = WatchSnapshotPendingOverlay.capture(from: context)

        let merged = WatchSnapshotProjection.applying(overlay, toTasks: savedTasks, lists: savedLists)
        let snapshot = WatchSnapshotValueBuilder.build(
            tasks: merged.tasks,
            lists: merged.lists,
            isProUnlocked: false,
            defaultListID: nil,
            now: Date(timeIntervalSince1970: 1_800_000_000),
            calendar: Calendar(identifier: .gregorian)
        )

        #expect(snapshot.tasks.map(\.title) == ["Pending title"])
        #expect(snapshot.tasks.first?.listID == destination.id)
        #expect(snapshot.lists.first { $0.id == source.id }?.activeTaskCount == 0)
        #expect(snapshot.lists.first { $0.id == destination.id }?.activeTaskCount == 1)
    }

    @Test func workerMergesPendingValuesWithoutSavingOwnerContext() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let list = TaskList(serverURL: "", name: "Inbox", colorHex: "#007AFF")
        let edited = TaskItem(title: "Saved title")
        edited.id = "edited"
        edited.taskList = list
        let removed = TaskItem(title: "Removed")
        removed.id = "removed"
        removed.taskList = list
        context.insert(list)
        context.insert(edited)
        context.insert(removed)
        try context.save()
        edited.title = "Pending title"
        context.delete(removed)
        let inserted = TaskItem(title: "Pending insertion")
        inserted.id = "inserted"
        inserted.taskList = list
        context.insert(inserted)
        let request = WatchSnapshotBuildRequest(
            isProUnlocked: false, savedDefaultListID: list.id,
            now: Date(timeIntervalSince1970: 1_800_000_000), calendar: .current,
            proAccessValidUntil: nil, testerProOverride: nil,
            overlay: WatchSnapshotPendingOverlay.capture(from: context))

        let encoded = try #require(await WatchSnapshotWorker(modelContainer: container).makeSnapshot(for: request))
        let snapshot = try #require(WatchSnapshot(contextDictionary: encoded.contextDictionary))
        #expect(Set(snapshot.tasks.map(\.id)) == ["edited", "inserted"])
        #expect(snapshot.tasks.first { $0.id == "edited" }?.title == "Pending title")
        #expect(context.hasChanges)
        withExtendedLifetime(container) {}
    }

    @Test func modelArrayBuilderMatchesValueBuilder() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let list = TaskList(serverURL: "https://example.com/dav", name: "Inbox", colorHex: "#007AFF")
        let due = TaskItem(title: "Due tomorrow")
        due.taskList = list
        due.dueDate = Date(timeIntervalSince1970: 1_800_086_400)
        let backlog = TaskItem(title: "Backlog")
        backlog.taskList = list
        backlog.manualSortOrder = 12
        let done = TaskItem(title: "Done", status: .completed)
        done.taskList = list
        for model in [list] { context.insert(model) }
        for model in [due, backlog, done] { context.insert(model) }
        try context.save()

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let legacy = WatchSnapshotBuilder.build(
            tasks: [due, backlog, done], lists: [list], isProUnlocked: true,
            defaultListID: list.id, now: now, calendar: calendar,
            proAccessValidUntil: now.addingTimeInterval(3_600), testerProOverride: true
        )
        let values = WatchSnapshotValueBuilder.build(
            tasks: [due, backlog, done].map { WatchTaskInput($0) },
            lists: [WatchListInput(list)], isProUnlocked: true,
            defaultListID: list.id, now: now, calendar: calendar,
            proAccessValidUntil: now.addingTimeInterval(3_600), testerProOverride: true
        )

        #expect(values == legacy)
    }
}

@Suite("Watch snapshot job coalescing")
@MainActor
struct WatchSnapshotJobCoalescingTests {
    @Test func coalescesBurstAndAppliesOnlyLatestGeneration() async {
        let gate = WatchSnapshotBuildGate()
        var applied: [(generation: UInt64, value: Int)] = []
        let queue = WatchSnapshotJobQueue<Int, Int>(
            build: { value in await gate.build(value) },
            apply: { generation, value in applied.append((generation, value)) }
        )

        queue.submit(1)
        await gate.waitUntilStarted(1)
        queue.submit(2)
        queue.submit(3)
        await gate.release(1)
        await gate.waitUntilStarted(2)
        await gate.release(3)
        while !queue.isIdle { await Task.yield() }

        #expect(await gate.startedValues == [1, 3])
        #expect(applied.count == 1)
        #expect(applied.first?.value == 3)
        #expect(applied.first?.generation == queue.latestGeneration)
    }
}

private actor WatchSnapshotBuildGate {
    private(set) var startedValues: [Int] = []
    private var buildContinuations: [Int: CheckedContinuation<Int, Never>] = [:]
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func build(_ value: Int) async -> Int {
        startedValues.append(value)
        let ready = startWaiters.filter { startedValues.count >= $0.0 }
        startWaiters.removeAll { startedValues.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        return await withCheckedContinuation { buildContinuations[value] = $0 }
    }

    func waitUntilStarted(_ count: Int) async {
        guard startedValues.count < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func release(_ value: Int) {
        buildContinuations.removeValue(forKey: value)?.resume(returning: value)
    }
}
