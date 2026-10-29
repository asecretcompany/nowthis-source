import Foundation
import SwiftData

/// Pending owner-context values captured before suspension. Persistent IDs are
/// safe even when a main-context delete has detached the model.
struct SpotlightPendingChanges: Sendable {
    var tasks: [PersistentIdentifier: SpotlightTaskSnapshot] = [:]
    var deletedTaskIDs: Set<PersistentIdentifier> = []
    var listNames: [PersistentIdentifier: String] = [:]
    var deletedListIDs: Set<PersistentIdentifier> = []
    var tagNames: [PersistentIdentifier: String] = [:]
    var deletedTagIDs: Set<PersistentIdentifier> = []
}

protocol SpotlightSnapshotSource: Sendable {
    func read(container: ModelContainer, pending: SpotlightPendingChanges) async throws -> [SpotlightTaskSnapshot]
}

actor SpotlightSnapshotReader: SpotlightSnapshotSource {
    /// This context and every model fetched through it have one isolated owner.
    func read(container: ModelContainer, pending: SpotlightPendingChanges) throws -> [SpotlightTaskSnapshot] {
        let interval = PerformanceTrace.begin("SpotlightRead", count: pending.tasks.count)
        defer { PerformanceTrace.end("SpotlightRead", interval) }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isDeletedLocally })
        descriptor.includePendingChanges = false
        let tasks = try context.fetch(descriptor)
        let liveIDs = Set(try context.fetchIdentifiers(descriptor))
        let projectionInterval = PerformanceTrace.begin("SpotlightProjection", count: tasks.count)
        defer { PerformanceTrace.end("SpotlightProjection", projectionInterval) }
        var values: [String: SpotlightTaskSnapshot] = [:]
        for task in tasks {
            let id = task.persistentModelID
            guard liveIDs.contains(id), !pending.deletedTaskIDs.contains(id) else { continue }
            if let snapshot = SpotlightModelProjection.snapshot(from: task, pending: pending) {
                values[snapshot.id] = snapshot
            }
        }
        for snapshot in pending.tasks.values { values[snapshot.id] = snapshot }
        return values.values.sorted { $0.id < $1.id }
    }
}

enum SpotlightModelProjection {
    /// Call synchronously on the model's owner. No managed attribute is read
    /// until the attachment guard succeeds.
    static func snapshot(from task: TaskItem,
                         pending: SpotlightPendingChanges = SpotlightPendingChanges()) -> SpotlightTaskSnapshot? {
        guard task.modelContext != nil else { return nil }
        guard !task.isDeletedLocally else { return nil }
        var listName: String?
        if let list = task.taskList, list.modelContext != nil {
            let listID = list.persistentModelID
            guard !pending.deletedListIDs.contains(listID) else { return nil }
            listName = pending.listNames[listID] ?? list.name
        }
        var keywords = [task.title]
        if let listName { keywords.append(listName) }
        for tag in task.tags where tag.modelContext != nil {
            let tagID = tag.persistentModelID
            guard !pending.deletedTagIDs.contains(tagID) else { continue }
            keywords.append(pending.tagNames[tagID] ?? tag.name)
        }
        return SpotlightProjection.snapshot(from: SpotlightTaskInput(
            id: task.id,
            title: task.title,
            contentDescription: task.descriptionText,
            containerTitle: listName,
            keywords: keywords,
            priorityDescription: task.priority == .none ? nil : "\(task.priority) priority",
            dueDate: task.dueDate,
            completionDate: task.completedDate,
            isDeleted: false
        ))
    }
}
