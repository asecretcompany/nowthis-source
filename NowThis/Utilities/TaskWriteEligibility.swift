import Foundation
import SwiftData

/// Checks committed write access immediately before a synchronous user mutation.
@MainActor
struct TaskWriteEligibility {
    nonisolated static var readOnlyEditMessage: LocalizedStringResource {
        LocalizedStringResource(
            "task.write.readOnly.edit",
            defaultValue: "This list is read-only. Ask the list owner for permission to edit it.",
            comment: "Shown when editing a task is refused because its list is read-only. The list owner can grant edit permission.")
    }

    nonisolated static var readOnlyCreationMessage: LocalizedStringResource {
        LocalizedStringResource(
            "task.write.readOnly.create",
            defaultValue: "This list is read-only. Choose another list or ask the list owner for permission to edit it.",
            comment: "Shown when a task cannot be added to a read-only list. The creation draft stays available.")
    }

    enum Refusal: Error, Equatable {
        case readOnly
        case taskUnavailable
        case listUnavailable
        case targetChanged
    }

    enum ExistingTask {
        case id(String)
        case retained(TaskItem)
    }

    enum CreationDestination {
        case list(id: String, expectedPersistentID: PersistentIdentifier?)
        case unbound
    }

    private let writer: ModelContext
    private let container: ModelContainer

    init(writingIn writer: ModelContext) {
        self.writer = writer
        container = writer.container
    }

    /// Returns the exact row owned by the context that will perform the mutation.
    func task(_ target: ExistingTask) throws -> TaskItem {
        switch target {
        case .retained(let row):
            try tasks([row])
            return row
        case .id(let id):
            let reader = makeReader()
            var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
            descriptor.includePendingChanges = false
            descriptor.fetchLimit = 1
            descriptor.relationshipKeyPathsForPrefetching = [\.taskList]
            guard let stored = try reader.fetch(descriptor).first, !stored.isDeletedLocally else {
                throw Refusal.taskUnavailable
            }
            let persistentID = stored.persistentModelID
            let pending = PendingChanges(in: writer)
            guard !pending.unavailable.contains(persistentID) else { throw Refusal.taskUnavailable }
            guard let row: TaskItem = try writerRow(with: persistentID) else {
                throw Refusal.taskUnavailable
            }
            try checkTasks([row], against: [persistentID: stored], pending: pending, reader: reader)
            return row
        }
    }

    /// Call with the rows an operation will actually change, after computing its write set.
    func tasks(_ rows: [TaskItem]) throws {
        guard !rows.isEmpty else { return }
        let pending = PendingChanges(in: writer)
        var ids = Set<PersistentIdentifier>()
        for row in rows {
            let id = row.persistentModelID
            guard row.modelContext === writer, !pending.unavailable.contains(id) else {
                throw Refusal.taskUnavailable
            }
            ids.insert(id)
        }

        let reader = makeReader()
        var storedByID: [PersistentIdentifier: TaskItem] = [:]
        for batch in Self.batches(ids) {
            var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { batch.contains($0.persistentModelID) })
            descriptor.includePendingChanges = false
            descriptor.relationshipKeyPathsForPrefetching = [\.taskList]
            for stored in try reader.fetch(descriptor) {
                storedByID[stored.persistentModelID] = stored
            }
        }
        try checkTasks(rows, against: storedByID, pending: pending, reader: reader)
    }

    /// Missing or replaced explicit lists fail. Only the caller can choose an unbound task.
    func destination(_ target: CreationDestination) throws -> TaskList? {
        guard case .list(let id, let expectedPersistentID) = target else { return nil }
        let reader = makeReader()
        var descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == id })
        descriptor.includePendingChanges = false
        descriptor.fetchLimit = 1
        descriptor.relationshipKeyPathsForPrefetching = [\.account]
        guard let stored = try reader.fetch(descriptor).first else { throw Refusal.listUnavailable }
        let persistentID = stored.persistentModelID
        if let expectedPersistentID, expectedPersistentID != persistentID { throw Refusal.targetChanged }

        let pending = PendingChanges(in: writer)
        try checkStoredList(stored, pending: pending)
        guard let row: TaskList = try writerRow(with: persistentID) else {
            throw Refusal.listUnavailable
        }
        try checkWriterList(row, against: stored, pending: pending)
        return row
    }

    private func checkTasks(_ rows: [TaskItem], against storedByID: [PersistentIdentifier: TaskItem],
                            pending: PendingChanges, reader: ModelContext) throws {
        var listIDs = Set<PersistentIdentifier>()
        for row in rows {
            guard let stored = storedByID[row.persistentModelID], !stored.isDeletedLocally else {
                throw Refusal.taskUnavailable
            }
            if let listID = stored.taskList?.persistentModelID { listIDs.insert(listID) }
        }

        var storedListsByID: [PersistentIdentifier: TaskList] = [:]
        for batch in Self.batches(listIDs) {
            var descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { batch.contains($0.persistentModelID) })
            descriptor.includePendingChanges = false
            descriptor.relationshipKeyPathsForPrefetching = [\.account]
            for stored in try reader.fetch(descriptor) {
                try checkStoredList(stored, pending: pending)
                storedListsByID[stored.persistentModelID] = stored
            }
        }
        guard storedListsByID.count == listIDs.count else { throw Refusal.listUnavailable }

        var checkedLists = Set<PersistentIdentifier>()
        for row in rows {
            let id = row.persistentModelID
            guard row.modelContext === writer, !pending.unavailable.contains(id),
                  let stored = storedByID[id], !row.isDeletedLocally else {
                throw Refusal.taskUnavailable
            }
            guard row.id == stored.id else { throw Refusal.targetChanged }
            let list = row.taskList
            guard list?.persistentModelID == stored.taskList?.persistentModelID else {
                throw Refusal.targetChanged
            }
            if let list, checkedLists.insert(list.persistentModelID).inserted,
               let storedList = storedListsByID[list.persistentModelID] {
                try checkWriterList(list, against: storedList, pending: pending)
            }
        }
    }

    private func checkStoredList(_ stored: TaskList, pending: PendingChanges) throws {
        guard !pending.unavailable.contains(stored.persistentModelID) else { throw Refusal.listUnavailable }
        if let accountID = stored.account?.persistentModelID, pending.unavailable.contains(accountID) {
            throw Refusal.listUnavailable
        }
        if stored.isReadOnly { throw Refusal.readOnly }
    }

    private func checkWriterList(_ row: TaskList, against stored: TaskList, pending: PendingChanges) throws {
        guard row.modelContext === writer, row.persistentModelID == stored.persistentModelID else {
            throw Refusal.listUnavailable
        }
        guard row.id == stored.id, row.account?.persistentModelID == stored.account?.persistentModelID else {
            throw Refusal.targetChanged
        }
        if pending.changedLists.contains(row.persistentModelID), row.isReadOnly { throw Refusal.readOnly }
    }

    private func makeReader() -> ModelContext {
        let reader = ModelContext(container)
        reader.autosaveEnabled = false
        return reader
    }

    /// Only use after a separate committed reader proved that this ID exists.
    /// A committed-only fetch in the writer can refresh its registered object
    /// and discard exactly the pending changes admission needs to inspect.
    private func writerRow<Row: PersistentModel>(with id: PersistentIdentifier) throws -> Row? {
        if let retained: Row = writer.registeredModel(for: id) { return retained }
        var descriptor = FetchDescriptor<Row>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try writer.fetch(descriptor).first
    }

    static func batches(_ ids: Set<PersistentIdentifier>) -> [[PersistentIdentifier]] {
        let ids = Array(ids)
        let size = 128
        return stride(from: 0, to: ids.count, by: size).map { start in
            Array(ids[start..<min(start + size, ids.count)])
        }
    }

    private struct PendingChanges {
        let unavailable: Set<PersistentIdentifier>
        let changedLists: Set<PersistentIdentifier>

        @MainActor
        init(in writer: ModelContext) {
            unavailable = Set((writer.insertedModelsArray + writer.deletedModelsArray).map(\.persistentModelID))
            changedLists = Set(writer.changedModelsArray.compactMap { ($0 as? TaskList)?.persistentModelID })
        }
    }
}

extension TaskWriteEligibility {
    struct DeletionScope: Equatable {
        struct ParentEdge: Hashable {
            let task: PersistentIdentifier
            let parent: PersistentIdentifier
        }

        struct Membership: Hashable {
            let task: PersistentIdentifier
            let list: PersistentIdentifier?
        }

        let root: PersistentIdentifier
        let rootParent: PersistentIdentifier?
        let edges: Set<ParentEdge>
        let memberships: Set<Membership>
        let softDeleted: Set<PersistentIdentifier>
    }

    struct DeletionAdmission {
        let rows: [TaskItem]
        let scope: DeletionScope
    }

    /// Admits and snapshots the exact committed descendant closure that a delete will write.
    /// The caller collects relationship rows once; this check independently verifies that
    /// the committed store has no omitted direct child, including below soft-deleted rows.
    func deletionSubtree(root: TaskItem, proposed rows: [TaskItem],
                         confirmed: DeletionScope? = nil) throws -> DeletionAdmission {
        let rootID = root.persistentModelID
        let ids = Set(rows.map(\.persistentModelID))
        guard !rows.isEmpty, ids.count == rows.count, ids.contains(rootID),
              root.modelContext === writer else { throw Refusal.taskUnavailable }

        let pending = PendingChanges(in: writer)
        guard !pending.unavailable.contains(rootID) else { throw Refusal.taskUnavailable }
        guard ids.subtracting([rootID]).isDisjoint(with: pending.unavailable) else {
            throw Refusal.targetChanged
        }
        let reader = makeReader()
        var storedByID: [PersistentIdentifier: TaskItem] = [:]
        for batch in Self.batches(ids) {
            var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { batch.contains($0.persistentModelID) })
            descriptor.includePendingChanges = false
            descriptor.relationshipKeyPathsForPrefetching = [\.taskList, \.parentTask, \.subtasks]
            for stored in try reader.fetch(descriptor) {
                storedByID[stored.persistentModelID] = stored
            }
        }
        guard storedByID.count == ids.count,
              let storedRoot = storedByID[rootID], !storedRoot.isDeletedLocally else {
            throw Refusal.taskUnavailable
        }

        var listIDs = Set<PersistentIdentifier>()
        var expectedEdges = Set<DeletionScope.ParentEdge>()
        var memberships = Set<DeletionScope.Membership>()
        var softDeleted = Set<PersistentIdentifier>()
        var rootParent: PersistentIdentifier?

        for row in rows {
            let id = row.persistentModelID
            guard row.modelContext === writer, !pending.unavailable.contains(id),
                  let stored = storedByID[id], row.id == stored.id,
                  row.isDeletedLocally == stored.isDeletedLocally,
                  row.taskList?.persistentModelID == stored.taskList?.persistentModelID,
                  row.parentTask?.persistentModelID == stored.parentTask?.persistentModelID else {
                throw Refusal.targetChanged
            }
            let parentID = stored.parentTask?.persistentModelID
            if id == rootID {
                rootParent = parentID
            } else if parentID.map(ids.contains) != true {
                throw Refusal.targetChanged
            }
            if let parentID, ids.contains(parentID) {
                expectedEdges.insert(.init(task: id, parent: parentID))
            }
            let listID = stored.taskList?.persistentModelID
            memberships.insert(.init(task: id, list: listID))
            if let listID { listIDs.insert(listID) }
            if stored.isDeletedLocally { softDeleted.insert(id) }
        }

        var storedLists: [PersistentIdentifier: TaskList] = [:]
        for batch in Self.batches(listIDs) {
            var descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { batch.contains($0.persistentModelID) })
            descriptor.includePendingChanges = false
            descriptor.relationshipKeyPathsForPrefetching = [\.account]
            for stored in try reader.fetch(descriptor) {
                try checkStoredList(stored, pending: pending)
                storedLists[stored.persistentModelID] = stored
            }
        }
        guard storedLists.count == listIDs.count else { throw Refusal.listUnavailable }
        var checkedLists = Set<PersistentIdentifier>()
        for row in rows {
            guard let list = row.taskList else { continue }
            let id = list.persistentModelID
            guard let stored = storedLists[id] else { throw Refusal.listUnavailable }
            if checkedLists.insert(id).inserted {
                try checkWriterList(list, against: stored, pending: pending)
            }
        }

        var actualEdges = Set<DeletionScope.ParentEdge>()
        for batch in Self.batches(ids) {
            for parentID in batch {
                guard let parent = storedByID[parentID] else { throw Refusal.taskUnavailable }
                for child in parent.subtasks {
                    let childID = child.persistentModelID
                    guard ids.contains(childID) else { throw Refusal.targetChanged }
                    actualEdges.insert(.init(task: childID, parent: parentID))
                }
            }
        }
        guard actualEdges == expectedEdges else { throw Refusal.targetChanged }

        var childrenByParent: [PersistentIdentifier: [PersistentIdentifier]] = [:]
        for edge in actualEdges {
            childrenByParent[edge.parent, default: []].append(edge.task)
        }
        var reachable: Set<PersistentIdentifier> = [rootID]
        var stack = [rootID]
        while let parent = stack.popLast() {
            for child in childrenByParent[parent, default: []] where reachable.insert(child).inserted {
                stack.append(child)
            }
        }
        guard reachable == ids else { throw Refusal.targetChanged }

        let scope = DeletionScope(root: rootID, rootParent: rootParent, edges: expectedEdges,
                                  memberships: memberships, softDeleted: softDeleted)
        if let confirmed, confirmed != scope { throw Refusal.targetChanged }
        return DeletionAdmission(rows: rows, scope: scope)
    }
}
