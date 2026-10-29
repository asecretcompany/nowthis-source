import Foundation
import SwiftData
import Testing
#if canImport(NowThis)
@testable import NowThis
#else
@testable import SpotlightHarness
#endif

@MainActor
private func spotlightContainer() throws -> ModelContainer {
#if canImport(NowThis)
    return try DAVSyncScenario.container()
#else
    return try ModelContainer(for: TaskItem.self, TaskList.self, Tag.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
#endif
}

private actor SuspendedSpotlightSource: SpotlightSnapshotSource {
    private var captured = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func read(container: ModelContainer, pending: SpotlightPendingChanges) async throws -> [SpotlightTaskSnapshot] {
        let values = try await SpotlightSnapshotReader().read(container: container, pending: pending)
        guard !captured else { return values }
        captured = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        await withCheckedContinuation { release = $0 }
        return values
    }

    func waitUntilCaptured() async {
        guard !captured else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resumeRead() { release?.resume(); release = nil }
}

@Suite("Spotlight saved-state overlay")
@MainActor
struct SpotlightSnapshotTests {
    @Test func pendingTaskAndRelatedNamesOverlaySavedReadWithoutSaving() async throws {
        let container = try spotlightContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let list = TaskList(id: "list", serverURL: "", name: "Saved list", colorHex: "#007AFF")
        let tag = Tag(name: "Saved tag")
        let edited = TaskItem(id: "edited", title: "Saved title")
        let untouched = TaskItem(id: "untouched", title: "Untouched")
        let doomed = TaskItem(id: "doomed", title: "Pending deletion")
        context.insert(list)
        context.insert(tag)
        for task in [edited, untouched, doomed] {
            task.taskList = list
            task.tags = [tag]
            context.insert(task)
        }
        try context.save()
        edited.title = "Pending title"
        edited.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        list.name = "Pending list"
        tag.name = "Pending tag"
        let inserted = TaskItem(id: "inserted", title: "Unsaved insertion")
        context.insert(inserted)
        context.delete(doomed)

        let pending = try SpotlightIndexer.pendingChanges(in: context)
        let snapshots = try await SpotlightSnapshotReader().read(container: container, pending: pending)
        let values = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        #expect(values["edited"]?.title == "Pending title")
        #expect(values["edited"]?.dueDate == edited.dueDate)
        #expect(values["inserted"]?.title == "Unsaved insertion")
        #expect(values["doomed"] == nil)
        #expect(values["untouched"]?.containerTitle == "Pending list")
        #expect(values["untouched"]?.keywords.contains("Pending tag") == true)
        #expect(values["untouched"]?.keywords.contains("Saved tag") == false)
        #expect(context.hasChanges)
        withExtendedLifetime(container) {}
    }

    @Test func localSaveBurstCoalescesAndIndexesLatestRelatedNames() async throws {
        let container = try spotlightContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(id: "task", title: "Before")
        let list = TaskList(id: "list", serverURL: "", name: "Before list", colorHex: "#007AFF")
        let tag = Tag(name: "Before tag")
        context.insert(list)
        context.insert(tag)
        task.taskList = list
        task.tags = [tag]
        context.insert(task)
        try context.save()
        let source = CountingSpotlightSource()
        let sink = SuspendedSpotlightSink()
        let indexer = SpotlightIndexer(worker: SpotlightIndexWorker(sink: sink, store: SpotlightTestStore()),
                                      source: source)
        indexer.startObserving(modelContext: context, coalescingWindow: .milliseconds(20))
        // Repeated setup must replace its observer, not install a second one.
        indexer.startObserving(modelContext: context, coalescingWindow: .milliseconds(20))
        task.title = "After"
        try context.save()
        list.name = "After list"
        try context.save()
        tag.name = "After tag"
        try context.save()
        try await waitForIndexedTask("task", in: sink)
        let values = await sink.values()
        #expect(await source.readCount == 1)
        #expect(values["task"]?.title == "After")
        #expect(values["task"]?.containerTitle == "After list")
        #expect(values["task"]?.keywords.contains("After tag") == true)
        withExtendedLifetime(container) {}
    }

    @Test func localObserverIgnoresOtherContextSaves() async throws {
        let container = try spotlightContainer()
        let context = container.mainContext
        let source = CountingSpotlightSource()
        let sink = SuspendedSpotlightSink()
        let indexer = SpotlightIndexer(worker: SpotlightIndexWorker(sink: sink, store: SpotlightTestStore()),
                                      source: source)
        indexer.startObserving(modelContext: context, coalescingWindow: .milliseconds(20))
        let background = ModelContext(container)
        background.insert(TaskItem(id: "remote", title: "Committed by sync"))
        try background.save()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await source.readCount == 0)
        // The sync change consumer requests the refresh through this same coalescing API.
        indexer.requestReindex(modelContext: context)
        indexer.requestReindex(modelContext: context)
        try await waitForIndexedTask("remote", in: sink)
        #expect(await source.readCount == 1)
        #expect(await sink.values()["remote"]?.title == "Committed by sync")
        withExtendedLifetime(container) {}
    }

    /// Wait for the observable side effect, rather than assuming the background
    /// projection completes within a fixed sleep on a busy simulator.
    private func waitForIndexedTask(_ id: String, in sink: SuspendedSpotlightSink) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while await sink.values()[id] == nil, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await sink.values()[id] != nil, "The coalesced refresh must reach Spotlight")
    }

    @Test func newerRefreshRejectsPausedOlderGeneration() async throws {
        let container = try spotlightContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(id: "task", title: "Old")
        context.insert(task)
        try context.save()
        let source = SuspendedSpotlightSource()
        let sink = SuspendedSpotlightSink()
        let indexer = SpotlightIndexer(worker: SpotlightIndexWorker(sink: sink, store: SpotlightTestStore()),
                                      source: source)
        let old = Task { await indexer.reindexAll(modelContext: context) }
        await source.waitUntilCaptured()
        task.title = "Latest pending value"
        // Only the first source read is paused; a newer generation may complete first.
        await indexer.reindexAll(modelContext: context)
        await source.resumeRead()
        await old.value
        #expect(await sink.values()["task"]?.title == "Latest pending value")
        #expect(context.hasChanges)
        withExtendedLifetime(container) {}
    }

    @Test func detachedModelIsRejectedBeforeAttributesAreRead() {
        let detached = TaskItem(title: "Never inserted")
        #expect(SpotlightIndexer.snapshot(from: detached) == nil)
    }

    @Test func newerEditWinsWhileSavedProjectionIsSuspended() async throws {
        let container = try spotlightContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(id: "task", title: "Old")
        let other = TaskItem(id: "other", title: "Other saved task")
        context.insert(task)
        context.insert(other)
        try context.save()
        let source = SuspendedSpotlightSource()
        let sink = SuspendedSpotlightSink()
        let indexer = SpotlightIndexer(worker: SpotlightIndexWorker(sink: sink, store: SpotlightTestStore()),
                                      source: source)
        let refresh = Task { await indexer.reindexAll(modelContext: context) }
        await source.waitUntilCaptured()
        task.title = "New unsaved edit"
        await indexer.index(task: task)
        await source.resumeRead()
        await refresh.value
        let values = await sink.values()
        #expect(values["task"]?.title == "New unsaved edit")
        #expect(values["other"]?.title == "Other saved task")
        #expect(context.hasChanges)
        withExtendedLifetime(container) {}
    }

    @Test func newerRemovalWinsWhileSavedProjectionIsSuspended() async throws {
        let container = try spotlightContainer()
        let context = container.mainContext
        let removed = TaskItem(id: "removed", title: "Old task")
        let other = TaskItem(id: "other", title: "Other saved task")
        context.insert(removed)
        context.insert(other)
        try context.save()
        let source = SuspendedSpotlightSource()
        let sink = SuspendedSpotlightSink()
        let indexer = SpotlightIndexer(worker: SpotlightIndexWorker(sink: sink, store: SpotlightTestStore()),
                                      source: source)
        let refresh = Task { await indexer.reindexAll(modelContext: context) }
        await source.waitUntilCaptured()
        await indexer.remove(taskID: "removed")
        await source.resumeRead()
        await refresh.value
        let values = await sink.values()
        #expect(values["removed"] == nil)
        #expect(values["other"]?.title == "Other saved task")
        withExtendedLifetime(container) {}
    }

    @Test func freshOwnerExcludesCrossContextDeletion() async throws {
        let container = try spotlightContainer()
        let context = container.mainContext
        let task = TaskItem(id: "removed", title: "Removed elsewhere")
        context.insert(task)
        try context.save()
        let other = ModelContext(container)
        let doomed = try #require(other.fetch(FetchDescriptor<TaskItem>()).first)
        other.delete(doomed)
        try other.save()
        let pending = try SpotlightIndexer.pendingChanges(in: context)
        let snapshots = try await SpotlightSnapshotReader().read(container: container, pending: pending)
        #expect(snapshots.isEmpty)
        withExtendedLifetime(container) {}
    }
}

private actor CountingSpotlightSource: SpotlightSnapshotSource {
    private(set) var readCount = 0
    func read(container: ModelContainer, pending: SpotlightPendingChanges) async throws -> [SpotlightTaskSnapshot] {
        readCount += 1
        return try await SpotlightSnapshotReader().read(container: container, pending: pending)
    }
}
