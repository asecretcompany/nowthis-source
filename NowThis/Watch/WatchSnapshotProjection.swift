import Foundation
import SwiftData

/// Immutable task data used by Watch snapshot projection. It never retains a SwiftData model.
struct WatchTaskInput: Sendable, Equatable, Identifiable {
    let id: String
    let uid: String
    let title: String
    let dueDate: Date?
    let isDueDateOnly: Bool
    let priorityRaw: Int
    let isCompleted: Bool
    let isDeletedLocally: Bool
    let listID: String?
    let parentUID: String?
    let effectiveSortOrder: Int
    let isLive: Bool

    init(_ task: TaskItem, isLive: Bool? = nil) {
        id = task.id
        uid = task.uid
        title = task.title
        dueDate = task.dueDate
        isDueDateOnly = task.isDueDateOnly
        priorityRaw = task.priority.rawValue
        isCompleted = task.status == .completed
        isDeletedLocally = task.isDeletedLocally
        listID = task.taskList?.id
        parentUID = task.parentUID
        effectiveSortOrder = task.effectiveSortOrder
        self.isLive = isLive ?? (task.modelContext != nil)
    }
}

/// Immutable list data used by Watch snapshot projection.
struct WatchListInput: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let colorHex: String
    let isLive: Bool

    init(_ list: TaskList, isLive: Bool? = nil) {
        id = list.id
        name = list.name
        colorHex = list.colorHex
        self.isLive = isLive ?? (list.modelContext != nil)
    }
}

/// The unsaved main-context changes captured before Watch work crosses an await.
struct WatchSnapshotPendingOverlay: Sendable, Equatable {
    let tasks: [WatchTaskInput]
    let lists: [WatchListInput]
    let deletedTaskIDs: Set<String>
    let deletedListIDs: Set<String>

    @MainActor
    static func capture(from context: ModelContext) -> WatchSnapshotPendingOverlay {
        var changedTasks: [String: WatchTaskInput] = [:]
        var changedLists: [String: WatchListInput] = [:]
        for model in context.insertedModelsArray + context.changedModelsArray {
            if let task = model as? TaskItem {
                changedTasks[task.id] = WatchTaskInput(task)
            } else if let list = model as? TaskList {
                changedLists[list.id] = WatchListInput(list)
            }
        }

        var deletedTaskIDs = Set<String>()
        var deletedListIDs = Set<String>()
        for model in context.deletedModelsArray {
            if let task = model as? TaskItem {
                deletedTaskIDs.insert(task.id)
            } else if let list = model as? TaskList {
                deletedListIDs.insert(list.id)
            }
        }

        return WatchSnapshotPendingOverlay(
            tasks: Array(changedTasks.values),
            lists: Array(changedLists.values),
            deletedTaskIDs: deletedTaskIDs,
            deletedListIDs: deletedListIDs
        )
    }
}

struct WatchSnapshotRows: Sendable, Equatable {
    let tasks: [WatchTaskInput]
    let lists: [WatchListInput]
}

enum WatchSnapshotProjection {
    static func applying(
        _ overlay: WatchSnapshotPendingOverlay,
        toTasks baseTasks: [WatchTaskInput],
        lists baseLists: [WatchListInput]
    ) -> WatchSnapshotRows {
        WatchSnapshotRows(
            tasks: merging(baseTasks, updates: overlay.tasks, removing: overlay.deletedTaskIDs),
            lists: merging(baseLists, updates: overlay.lists, removing: overlay.deletedListIDs)
        )
    }

    private static func merging<Value: Identifiable>(
        _ base: [Value],
        updates: [Value],
        removing removedIDs: Set<String>
    ) -> [Value] where Value.ID == String {
        var values = base.filter { !removedIDs.contains($0.id) }
        var indexByID = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($1.id, $0) })
        for update in updates where !removedIDs.contains(update.id) {
            if let index = indexByID[update.id] {
                values[index] = update
            } else {
                indexByID[update.id] = values.endIndex
                values.append(update)
            }
        }
        return values
    }
}

/// Request metadata is captured on the main actor with the pending overlay.
struct WatchSnapshotBuildRequest: Sendable {
    let isProUnlocked: Bool
    let savedDefaultListID: String?
    let now: Date
    let calendar: Calendar
    let proAccessValidUntil: Date?
    let testerProOverride: Bool?
    let overlay: WatchSnapshotPendingOverlay
}

/// `contextDictionary()` contains only immutable Foundation `Data`; WCSession requires
/// `[String: Any]`, so this small box is the sendability boundary for that API shape.
struct WatchEncodedSnapshot: @unchecked Sendable {
    let contextDictionary: [String: Any]
}

/// Main-actor queue that retains one active build and replaces any queued request with the
/// newest generation. A completed build is applied only while its generation is current.
@MainActor
final class WatchSnapshotJobQueue<Input: Sendable, Output: Sendable> {
    private struct Job {
        let generation: UInt64
        let input: Input
    }

    private let build: @Sendable (Input) async -> Output
    private let apply: @MainActor (UInt64, Output) -> Void
    private var pendingJob: Job?
    private var isDraining = false
    private(set) var latestGeneration: UInt64 = 0

    var isIdle: Bool { !isDraining && pendingJob == nil }

    init(
        build: @escaping @Sendable (Input) async -> Output,
        apply: @escaping @MainActor (UInt64, Output) -> Void
    ) {
        self.build = build
        self.apply = apply
    }

    func submit(_ input: Input) {
        latestGeneration &+= 1
        pendingJob = Job(generation: latestGeneration, input: input)
        guard !isDraining else { return }
        isDraining = true
        Task { await drain() }
    }

    private func drain() async {
        while let job = pendingJob {
            pendingJob = nil
            let output = await build(job.input)
            if job.generation == latestGeneration {
                apply(job.generation, output)
            }
        }
        isDraining = false
    }
}
