import Foundation
import SwiftData

/// Reads committed list state on its own executor and returns values for bounded commits.
/// The committer must recheck current state and pending edits before applying each action.
actor SyncInboundPlanner {
    struct ParentEdit: Sendable, Equatable {
        let taskID: String
        let uid: String
        let expectedRawParentUID: String?
        let expectedParentID: String?
        let parentID: String?
    }

    struct DeleteCandidate: Sendable, Equatable {
        let taskID: String
        let uid: String
        let expectedHref: String?
        let expectedListID: String
    }

    private struct TaskValue: Sendable {
        let id: String
        let uid: String
        let rawParentUID: String?
        let parentID: String?
        let href: String?
        let etag: String?
        let isDirty: Bool
        let isLocalOnly: Bool
        let isDeletedLocally: Bool
    }

    private let container: ModelContainer
    private let listID: String

    init(container: ModelContainer, listID: String) {
        self.container = container
        self.listID = listID
    }

    /// Resolve retained server UIDs without changing models or saving the list.
    func parentEdits(includeDirty: Bool = false) async throws -> [ParentEdit] {
        let tasks = try values().filter { !$0.isDeletedLocally }
        let byUID = Dictionary(tasks.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let rawParents = Dictionary(tasks.map { ($0.uid, $0.rawParentUID) },
            uniquingKeysWith: { first, _ in first })
        let resolved = HierarchyResolver.resolvedParents(rawParents)
        return tasks.compactMap { task in
            guard includeDirty || !task.isDirty else { return nil }
            let parentID = resolved[task.uid].flatMap { byUID[$0]?.id }
            guard parentID != task.parentID else { return nil }
            return ParentEdit(taskID: task.id, uid: task.uid, expectedRawParentUID: task.rawParentUID,
                expectedParentID: task.parentID, parentID: parentID)
        }.sorted { $0.taskID < $1.taskID }
    }

    /// Snapshot absence is conservative; authenticated explicit hrefs can remove the final leaf.
    /// Every retained descendant protects its complete ancestor chain from cascade deletion.
    func deletionCandidates(manifest: [CalDAVClient.RemoteResource]?, explicitHrefs: [String]?,
                            protectedUIDs: Set<String>) async throws -> [DeleteCandidate] {
        let explicit = Set(explicitHrefs ?? [])
        guard manifest?.isEmpty == false || !explicit.isEmpty else { return [] }
        let tasks = try values()
        let manifestHrefs = Set((manifest ?? []).map(\.href))
        // Resource filenames are not UIDs, and a manifest may also contain VEVENT/VJOURNAL.
        let manifestUIDs = Set(tasks.lazy.filter { task in
            task.href.map { manifestHrefs.contains($0) } ?? false
        }.map(\.uid))
        // Preserve the existing UID policy, including duplicate UIDs at different hrefs.
        let explicitSurvivors = Set(tasks.lazy.filter { task in
            !explicit.contains(task.href ?? "")
        }.map(\.uid))
        var candidateIDs = Set<String>()
        var parentIDs: [String: String] = [:]
        for task in tasks {
            if let parentID = task.parentID { parentIDs[task.id] = parentID }
            // Older imported rows can retain isLocalOnly despite a confirmed server ETag.
            guard let href = task.href, !href.isEmpty,
                  !task.isDirty, !(task.isLocalOnly && task.etag == nil), !task.isDeletedLocally,
                  !protectedUIDs.contains(task.uid) else { continue }
            // No matched task UIDs means no reliable evidence for snapshot absence.
            let absent = !manifestUIDs.isEmpty && !manifestUIDs.contains(task.uid)
            let tombstoned = explicit.contains(href) && !explicitSurvivors.contains(task.uid)
            if absent || tombstoned { candidateIDs.insert(task.id) }
        }

        // Seed every retained task, including server survivors, pending overlays and tasks
        // with no href. Each parent enters the frontier once, even for shared paths/cycles.
        var retainedIDs = Set(tasks.lazy.filter { !candidateIDs.contains($0.id) }.map(\.id))
        var frontier = Array(retainedIDs)
        while let id = frontier.popLast() {
            guard let parentID = parentIDs[id], retainedIDs.insert(parentID).inserted else { continue }
            frontier.append(parentID)
        }
        candidateIDs.subtract(retainedIDs)
        guard !candidateIDs.isEmpty else { return [] }

        let depths = Self.deletionDepths(parentIDs: parentIDs, taskIDs: tasks.map(\.id))
        return tasks.filter { candidateIDs.contains($0.id) }.sorted { first, second in
            let firstDepth = depths[first.id] ?? 0
            let secondDepth = depths[second.id] ?? 0
            return firstDepth == secondDepth ? first.id < second.id : firstDepth > secondDepth
        }.map { task in
            DeleteCandidate(taskID: task.id, uid: task.uid, expectedHref: task.href, expectedListID: listID)
        }
    }

    /// O(n) iterative depth calculation. Cycle members share depth zero; tails retain their
    /// relative depths. Sorting consumes these cached values rather than walking every chain.
    nonisolated static func deletionDepths(parentIDs: [String: String], taskIDs: [String]) -> [String: Int] {
        let ids = Set(taskIDs)
        var depths: [String: Int] = [:]
        // Completed nodes are checked in depths first, so their old positions need no reset.
        var positions: [String: Int] = [:]
        for start in taskIDs where depths[start] == nil {
            var path: [String] = []
            var current: String? = start
            var depth = -1
            while let id = current {
                if let known = depths[id] {
                    depth = known
                    break
                }
                if let cycleStart = positions[id] {
                    for member in path[cycleStart...] { depths[member] = 0 }
                    path.removeSubrange(cycleStart...)
                    depth = 0
                    break
                }
                positions[id] = path.count
                path.append(id)
                current = parentIDs[id].flatMap { ids.contains($0) ? $0 : nil }
            }
            for id in path.reversed() {
                depth += 1
                depths[id] = depth
            }
        }
        return depths
    }

    /// Context creation and model reads occur only on the planner's actor. A new context
    /// sees the latest committed state; no registered models survive into another call.
    private func values() throws -> [TaskValue] {
        let section = try BackgroundRunBudget.current?.beginCriticalSection()
        defer { section?.end() }
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let id = listID
        let predicate = #Predicate<TaskItem> { $0.taskList?.id == id }
        return try context.fetch(FetchDescriptor(predicate: predicate)).map { task in
            TaskValue(id: task.id, uid: task.uid, rawParentUID: task.parentUID,
                parentID: task.parentTask?.id, href: task.remoteHref, etag: task.etag, isDirty: task.isDirty,
                isLocalOnly: task.isLocalOnly, isDeletedLocally: task.isDeletedLocally)
        }
    }
}
