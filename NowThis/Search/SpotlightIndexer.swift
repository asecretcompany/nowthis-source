import CoreSpotlight
import Foundation
import os
import SwiftData
import UniformTypeIdentifiers

/// The main context contributes only pending values. Saved task reads, payload
/// construction and bounded Spotlight application run on isolated owners.
@MainActor
final class SpotlightIndexer {
    private let worker: SpotlightIndexWorker
    private let source: any SpotlightSnapshotSource
    private var projectionGeneration = 0
    private var activeReadGeneration: Int?
    private var readUpdates: [String: SpotlightTaskSnapshot] = [:]
    private var readRemovals: Set<String> = []
    private var readWasCleared = false

    private weak var observedModelContext: ModelContext?
    private var observationGeneration: UInt64 = 0
    private var saveObserver: NSObjectProtocol?
    private var pendingRefresh: Task<Void, Never>?
    private var coalescingWindow = Duration.milliseconds(300)

    init() {
        worker = SpotlightIndexWorker(sink: CoreSpotlightSink(),
            store: SpotlightJournalStore(
                baseline: SpotlightFileStateStore(legacy: SpotlightDefaultsStore()),
                journal: SpotlightFileJournal()),
            reportError: { message in
                Logger(subsystem: "com.nowthis", category: "spotlight").error("Index operation failed: \(message)")
            })
        source = SpotlightSnapshotReader()
    }

    init(worker: SpotlightIndexWorker, source: any SpotlightSnapshotSource) {
        self.worker = worker
        self.source = source
    }

    /// Observe only local owner-context saves. Sync commits arrive through the scheduler's
    /// change stream, avoiding a full refresh for every background import batch.
    func startObserving(modelContext: ModelContext,
                        coalescingWindow: Duration = .milliseconds(300)) {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        pendingRefresh?.cancel()
        projectionGeneration += 1
        self.coalescingWindow = coalescingWindow
        observedModelContext = modelContext
        observationGeneration &+= 1
        let observation = observationGeneration
        // NotificationCenter filters by identity without reading any model attributes on the
        // posting thread. The work is scheduled after save() returns, on the context's owner.
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: modelContext, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == observation,
                      let modelContext = self.observedModelContext else { return }
                self.requestReindex(modelContext: modelContext)
            }
        }
    }

    /// Replace the pending request, invalidating a saved read already in flight. Local saves
    /// and committed sync events share this slot, so a burst projects only its latest state.
    func requestReindex(modelContext: ModelContext) {
        projectionGeneration += 1
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor [weak self, weak modelContext] in
            guard let self, let modelContext else { return }
            do { try await Task.sleep(for: self.coalescingWindow) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self.reindexAll(modelContext: modelContext)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
            pendingRefresh?.cancel()
        }
    }

    func reindexAll(modelContext: ModelContext) async {
        projectionGeneration += 1
        let generation = projectionGeneration
        activeReadGeneration = generation
        readUpdates = [:]
        readRemovals = []
        readWasCleared = false
        defer {
            if activeReadGeneration == generation { activeReadGeneration = nil }
        }
        do {
            try Task.checkCancellation()
            let pending = try Self.pendingChanges(in: modelContext)
            let snapshots = try await source.read(container: modelContext.container, pending: pending)
            try Task.checkCancellation()
            guard generation == projectionGeneration else { return }
            // A CRUD event during the saved read supersedes that task's value,
            // while the remaining saved snapshot still needs to be indexed.
            var latest = readWasCleared ? [:] : Dictionary(
                snapshots.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
            for id in readRemovals { latest.removeValue(forKey: id) }
            for (id, snapshot) in readUpdates { latest[id] = snapshot }
            activeReadGeneration = nil
            readUpdates = [:]
            readRemovals = []
            await worker.submit(.refresh(latest.values.sorted { $0.id < $1.id }))
            await worker.flush()
        } catch is CancellationError {
            // A cancelled read does not enqueue an incomplete replacement.
        } catch {
            Logger(subsystem: "com.nowthis", category: "spotlight")
                .error("Snapshot failed: \(error.localizedDescription)")
        }
    }

    func index(task: TaskItem) async {
        guard let snapshot = Self.snapshot(from: task) else { return }
        if activeReadGeneration != nil {
            readUpdates[snapshot.id] = snapshot
            readRemovals.remove(snapshot.id)
        }
        await worker.submit(.index(snapshot))
        await worker.flush()
    }

    func remove(taskID: String) async {
        if activeReadGeneration != nil {
            readUpdates.removeValue(forKey: taskID)
            readRemovals.insert(taskID)
        }
        await worker.submit(.remove(taskID))
        await worker.flush()
    }

    func removeAll() async {
        if activeReadGeneration != nil {
            readWasCleared = true
            readUpdates = [:]
            readRemovals = []
        }
        await worker.submit(.clear)
        await worker.flush()
    }

    static func snapshot(from task: TaskItem) -> SpotlightTaskSnapshot? {
        guard task.modelContext != nil else { return nil }
        return SpotlightModelProjection.snapshot(from: task)
    }

    /// Identifier queries are bounded to pending saved models, never the full
    /// store. Pending inserts are known to this owner and may have temporary IDs.
    static func pendingChanges(in context: ModelContext) throws -> SpotlightPendingChanges {
        let inserts = context.insertedModelsArray
        let changes = context.changedModelsArray
        let deletions = context.deletedModelsArray
        var pending = SpotlightPendingChanges()
        pending.deletedTaskIDs = Set(deletions.compactMap { ($0 as? TaskItem)?.persistentModelID })
        pending.deletedListIDs = Set(deletions.compactMap { ($0 as? TaskList)?.persistentModelID })
        pending.deletedTagIDs = Set(deletions.compactMap { ($0 as? Tag)?.persistentModelID })

        let insertedIDs = Set(inserts.map(\.persistentModelID))
        let taskCandidates = (inserts + changes).compactMap { $0 as? TaskItem }
        let taskIDs = taskCandidates.map(\.persistentModelID).filter { !insertedIDs.contains($0) }
        var taskDescriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { taskIDs.contains($0.persistentModelID) })
        taskDescriptor.includePendingChanges = true
        let liveTaskIDs = taskIDs.isEmpty ? Set<PersistentIdentifier>() : Set(try context.fetchIdentifiers(taskDescriptor))

        let lists = (inserts + changes).compactMap { $0 as? TaskList }
        let listIDs = lists.map(\.persistentModelID).filter { !insertedIDs.contains($0) }
        var listDescriptor = FetchDescriptor<TaskList>(predicate: #Predicate { listIDs.contains($0.persistentModelID) })
        listDescriptor.includePendingChanges = true
        let liveListIDs = listIDs.isEmpty ? Set<PersistentIdentifier>() : Set(try context.fetchIdentifiers(listDescriptor))
        for list in lists {
            let id = list.persistentModelID
            guard list.modelContext != nil, !pending.deletedListIDs.contains(id),
                  insertedIDs.contains(id) || liveListIDs.contains(id) else { continue }
            pending.listNames[id] = list.name
        }

        let tags = (inserts + changes).compactMap { $0 as? Tag }
        let tagIDs = tags.map(\.persistentModelID).filter { !insertedIDs.contains($0) }
        var tagDescriptor = FetchDescriptor<Tag>(predicate: #Predicate { tagIDs.contains($0.persistentModelID) })
        tagDescriptor.includePendingChanges = true
        let liveTagIDs = tagIDs.isEmpty ? Set<PersistentIdentifier>() : Set(try context.fetchIdentifiers(tagDescriptor))
        for tag in tags {
            let id = tag.persistentModelID
            guard tag.modelContext != nil, !pending.deletedTagIDs.contains(id),
                  insertedIDs.contains(id) || liveTagIDs.contains(id) else { continue }
            pending.tagNames[id] = tag.name
        }

        for task in taskCandidates {
            let id = task.persistentModelID
            guard task.modelContext != nil, !pending.deletedTaskIDs.contains(id),
                  insertedIDs.contains(id) || liveTaskIDs.contains(id) else { continue }
            if let snapshot = SpotlightModelProjection.snapshot(from: task, pending: pending) {
                pending.tasks[id] = snapshot
            } else {
                pending.deletedTaskIDs.insert(id)
            }
        }
        return pending
    }
}

private actor SpotlightDefaultsStore: SpotlightIndexStateStore {
    private let defaults = UserDefaults.standard
    private let stateKey = "com.asecretcompany.nowthis.spotlightState"
    private let legacyKey = "com.asecretcompany.nowthis.spotlightFingerprints"

    func load() throws -> [String: SpotlightIndexRecord] {
        if let data = defaults.data(forKey: stateKey) {
            return try JSONDecoder().decode([String: SpotlightIndexRecord].self, from: data)
        }
        let old = defaults.dictionary(forKey: legacyKey) as? [String: String] ?? [:]
        // Retain legacy IDs for deletion; missing renewal dates force an upsert.
        return old.mapValues { SpotlightIndexRecord(fingerprint: $0, expiresAt: .distantPast) }
    }

    func save(_ records: [String: SpotlightIndexRecord]) throws {
        defaults.set(try JSONEncoder().encode(records), forKey: stateKey)
        defaults.removeObject(forKey: legacyKey)
    }
}

private actor CoreSpotlightSink: SpotlightIndexSink {
    private static let domainID = "com.asecretcompany.nowthis.task"
    private let index = CSSearchableIndex(name: "com.asecretcompany.nowthis.tasks")

    func index(_ snapshots: [SpotlightTaskSnapshot], expiresAt: Date) async throws {
        let interval = PerformanceTrace.begin("SpotlightIndex", count: snapshots.count)
        defer { PerformanceTrace.end("SpotlightIndex", interval) }
        var items: [CSSearchableItem] = []
        for snapshot in snapshots {
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = snapshot.title
            attributes.contentDescription = snapshot.contentDescription
            attributes.containerTitle = snapshot.containerTitle
            attributes.keywords = snapshot.keywords
            if let priority = snapshot.priorityDescription { attributes.alternateNames = [priority] }
            if let dueDate = snapshot.dueDate {
                attributes.dueDate = dueDate
                attributes.completionDate = snapshot.completionDate
            }
            attributes.relatedUniqueIdentifier = snapshot.id
            attributes.url = URL(string: "nowthis://task/\(snapshot.id)")
            let item = CSSearchableItem(uniqueIdentifier: snapshot.id,
                                       domainIdentifier: Self.domainID, attributeSet: attributes)
            item.expirationDate = expiresAt
            items.append(item)
        }
        try await index.indexSearchableItems(items)
    }

    func remove(_ identifiers: [String]) async throws {
        let interval = PerformanceTrace.begin("SpotlightRemove", count: identifiers.count)
        defer { PerformanceTrace.end("SpotlightRemove", interval) }
        try await index.deleteSearchableItems(withIdentifiers: identifiers)
    }

    func removeAll() async throws {
        let interval = PerformanceTrace.begin("SpotlightClear")
        defer { PerformanceTrace.end("SpotlightClear", interval) }
        try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domainID])
    }
}
