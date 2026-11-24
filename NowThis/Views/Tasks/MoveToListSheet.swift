import SwiftUI
import SwiftData

// MARK: - Destinations

/// The lists a task can be moved to, as value types.
///
/// Built once when the sheet renders rather than read live from `TaskList`, so a
/// sync or an account removal that deletes a list while the sheet is open cannot
/// trap the render (see the LazyVStack deleted-model crash).
enum MoveDestinations {

    struct Destination: Identifiable, Equatable {
        let id: String
        let persistentID: PersistentIdentifier
        let name: String
        let colorHex: String
        let accountName: String
        let isCurrent: Bool
        let isReadOnly: Bool

        /// The current list is a no-op, and a read-only one would refuse the PUT.
        var isSelectable: Bool { !isCurrent && !isReadOnly }
    }

    struct Section: Identifiable, Equatable {
        let id: String
        let accountName: String
        let lists: [Destination]
    }

    /// One section per account that has lists, accounts and lists both by name.
    static func sections(accounts: [ServerAccount], currentListID: String?) -> [Section] {
        accounts
            .filter { $0.modelContext != nil }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .compactMap { account in
                let lists = account.taskLists
                    .filter { $0.modelContext != nil }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    .map { list in
                        Destination(
                            id: list.id,
                            persistentID: list.persistentModelID,
                            name: list.name,
                            colorHex: list.colorHex,
                            accountName: account.displayName,
                            isCurrent: list.id == currentListID,
                            isReadOnly: list.isReadOnly
                        )
                    }
                guard !lists.isEmpty else { return nil }
                return Section(id: account.id, accountName: account.displayName, lists: lists)
            }
    }

    /// Whether `task` may be moved at all. A task in a read-only list cannot be:
    /// the server would refuse to remove it from there.
    static func canMove(_ task: TaskItem) -> Bool {
        guard task.modelContext != nil else { return false }
        return task.taskList?.isReadOnly != true
    }

    @MainActor
    @discardableResult
    static func perform(_ request: MoveToListRequest, to destination: Destination,
                        in context: ModelContext, errorState: ErrorState = .shared,
                        save: ((ModelContext) throws -> Void)? = nil,
                        revalidate: (() -> Void)? = nil) -> Bool {
        let owned = ModelContext(context.container)
        owned.autosaveEnabled = false
        let policy = TaskWriteEligibility(writingIn: owned)
        do {
            guard let list = try policy.destination(.list(id: destination.id, expectedPersistentID: destination.persistentID))
            else { throw TaskWriteEligibility.Refusal.listUnavailable }
            let root = try policy.task(.id(request.taskID))
            guard root.persistentModelID == request.rootID else { throw TaskWriteEligibility.Refusal.targetChanged }
            let nodes = TaskMover.subtree(of: root)
            guard Set(nodes.map(MoveToListRequest.Source.init)) == request.sources else {
                throw TaskWriteEligibility.Refusal.targetChanged
            }
            guard root.taskList?.persistentModelID != list.persistentModelID else { return false }
            try policy.tasks(nodes)
            // The shared context can contain a pending revocation or relationship change.
            // Resolve known committed rows without forcing a refresh of registered models.
            let sharedPolicy = TaskWriteEligibility(writingIn: context)
            _ = try sharedPolicy.destination(.list(id: destination.id, expectedPersistentID: destination.persistentID))
            let movedIDs = Set(nodes.map(\.persistentModelID))
            var sharedTasks: [TaskItem] = []
            for batch in TaskWriteEligibility.batches(movedIDs) {
                let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { batch.contains($0.persistentModelID) })
                sharedTasks += try context.fetch(descriptor)
            }
            guard Set(sharedTasks.map(\.persistentModelID)) == movedIDs,
                  sharedTasks.count == movedIDs.count else {
                throw TaskWriteEligibility.Refusal.targetChanged
            }
            try sharedPolicy.tasks(sharedTasks)
            guard Set(sharedTasks.map(MoveToListRequest.Source.init)) == request.sources else {
                throw TaskWriteEligibility.Refusal.targetChanged
            }
            let sourceParents = Set(nodes.compactMap { $0.parentTask?.persistentModelID })
            let lists = Set(nodes.compactMap { $0.taskList?.persistentModelID }).union([list.persistentModelID])
            let existingPhotos = Set(nodes.flatMap(\.photos).map(\.persistentModelID))
            let touchedRows = movedIDs.union(sourceParents).union(existingPhotos)
            let pending = context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray
            guard !pending.contains(where: { touchedRows.contains($0.persistentModelID) }) else {
                throw TaskWriteEligibility.Refusal.targetChanged
            }

            guard !TaskMover.move(root, to: list, in: owned, onShapeHold: { hold in
                errorState.show(hold)
                if case .needsRevalidation = hold { revalidate?() }
            }).isEmpty else { return false }
            try ReminderSchedulingJournal.saveTaskChanges(in: owned, save: {
                let ownedChanges = owned.insertedModelsArray + owned.changedModelsArray + owned.deletedModelsArray
                let ownedIDs = Set(ownedChanges.map(\.persistentModelID))
                let ownedMetadataKeys = Set(ownedChanges.compactMap { ($0 as? SyncMetadata)?.id })
                let pendingMetadataKeys = Set(pending.compactMap { ($0 as? SyncMetadata)?.id })
                guard pending.allSatisfy({ !ownedIDs.contains($0.persistentModelID) }),
                      pendingMetadataKeys.isDisjoint(with: ownedMetadataKeys) else {
                    throw TaskWriteEligibility.Refusal.targetChanged
                }
                if let save { try save(owned) } else { try owned.save() }
            })

            // Refresh only verified clean affected rows. The caller publishes the
            // committed task revision after this succeeds, even if a view fetch fails.
            for batch in TaskWriteEligibility.batches(movedIDs.union(sourceParents)) {
                var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { batch.contains($0.persistentModelID) })
                descriptor.includePendingChanges = false
                _ = try? context.fetch(descriptor)
            }
            for batch in TaskWriteEligibility.batches(lists) {
                let clean = batch.filter { id in !pending.contains(where: { $0.persistentModelID == id }) }
                guard !clean.isEmpty else { continue }
                var descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { clean.contains($0.persistentModelID) })
                descriptor.includePendingChanges = false
                _ = try? context.fetch(descriptor)
            }
            return true
        } catch {
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState)
            return false
        }
    }

    @MainActor
    @discardableResult
    static func perform(_ task: TaskItem, toListID listID: String, in context: ModelContext,
                        errorState: ErrorState = .shared,
                        save: (() throws -> Void)? = nil, revalidate: (() -> Void)? = nil) -> Bool {
        guard task.modelContext === context, let request = MoveToListRequest(task: task) else { return false }
        var descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })
        descriptor.fetchLimit = 1
        guard let list = try? context.fetch(descriptor).first else { return false }
        let destination = Destination(id: list.id, persistentID: list.persistentModelID, name: list.name,
            colorHex: list.colorHex, accountName: list.account?.displayName ?? "", isCurrent: false, isReadOnly: list.isReadOnly)
        return perform(request, to: destination, in: context, errorState: errorState,
            save: save.map { save in { _ in try save() } }, revalidate: revalidate)
    }

    @MainActor
    @discardableResult
    static func perform(taskID: String, toListID listID: String, in context: ModelContext,
                        errorState: ErrorState = .shared,
                        save: (() throws -> Void)? = nil, revalidate: (() -> Void)? = nil) -> Bool {
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })
        descriptor.fetchLimit = 1
        guard let task = try? context.fetch(descriptor).first else { return false }
        return perform(task, toListID: listID, in: context, errorState: errorState,
                       save: save, revalidate: revalidate)
    }
}

// MARK: - Request

/// Exact source identity captured when the sheet opens and retained across retries.
struct MoveToListRequest: Identifiable {
    struct Source: Hashable {
        let task: PersistentIdentifier
        let list: PersistentIdentifier?
        let parent: PersistentIdentifier?
        let parentUID: String?
        let account: PersistentIdentifier?
        let collectionPath: String?
        let href: String?
        let etag: String?
        let pendingHref: String?
        let pendingListID: String?

        init(_ row: TaskItem) {
            task = row.persistentModelID
            list = row.taskList?.persistentModelID
            parent = row.parentTask?.persistentModelID
            parentUID = row.parentUID
            account = row.taskList?.account?.persistentModelID
            collectionPath = row.taskList?.serverURL
            href = row.remoteHref
            etag = row.etag
            pendingHref = row.pendingMoveFromHref
            pendingListID = row.pendingMoveFromListID
        }
    }

    let id = UUID()
    let taskID: String
    let rootID: PersistentIdentifier
    let currentListID: String?
    let isSubtask: Bool
    let sources: Set<Source>

    init?(task: TaskItem) {
        guard task.modelContext != nil, !task.isDeletedLocally else { return nil }
        taskID = task.id
        rootID = task.persistentModelID
        currentListID = task.taskList?.id
        isSubtask = task.parentTask != nil
        sources = Set(TaskMover.subtree(of: task).map(Source.init))
    }
}

// MARK: - Sheet

/// Picks the list a task moves to. Accounts are sections, lists are rows; the
/// current list is checked, and lists the user cannot write to are shown but
/// cannot be chosen.
struct MoveToListSheet: View {
    let request: MoveToListRequest
    let onChoose: (MoveDestinations.Destination, ErrorState) -> Bool

    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [ServerAccount]
    @State private var pendingSubtaskMove: MoveDestinations.Destination?
    @State private var errorState = ErrorState()

    var body: some View {
        NavigationStack {
            List {
                ForEach(MoveDestinations.sections(accounts: accounts, currentListID: request.currentListID)) { section in
                    Section {
                        ForEach(section.lists) { destination in
                            DestinationRow(destination: destination) {
                                choose(destination)
                            }
                        }
                    } header: {
                        Text(verbatim: section.accountName)
                    }
                }
            }
            .errorBanner(errorState)
            .navigationTitle(Text("Move to List", comment: "Title of the sheet that picks which list a task is moved to."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog(
                Text("Move Subtask?", comment: "Title of the confirmation shown before a subtask is moved to another list on its own, without its parent task."),
                isPresented: Binding(
                    get: { pendingSubtaskMove != nil },
                    set: { if !$0 { pendingSubtaskMove = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button {
                    if let destination = pendingSubtaskMove { finish(destination) }
                } label: {
                    Text("Move", comment: "Confirms moving a subtask to another list. A verb, as on an action button.")
                }
                Button("Cancel", role: .cancel) { pendingSubtaskMove = nil }
            } message: {
                Text("It becomes a top-level task in that list. Its parent task stays where it is.",
                     comment: "Explains, before a subtask is moved to another list on its own, that it will no longer be a subtask there.")
            }
        }
    }

    private func choose(_ destination: MoveDestinations.Destination) {
        if request.isSubtask {
            pendingSubtaskMove = destination
        } else {
            finish(destination)
        }
    }

    private func finish(_ destination: MoveDestinations.Destination) {
        guard onChoose(destination, errorState) else { return }
        dismiss()
    }
}

private struct DestinationRow: View {
    let destination: MoveDestinations.Destination
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(hex: destination.colorHex) ?? .blue)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: destination.name)
                        .foregroundStyle(destination.isSelectable || destination.isCurrent ? .primary : .secondary)
                    if destination.isReadOnly {
                        Text("Read-only", comment: "Caption under a list in the move picker that is shared with the user without permission to change it, so a task cannot be moved into it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if destination.isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!destination.isSelectable)
        // Name and, for a read-only list, its caption; the account as the value,
        // because two accounts can hold lists with the same name.
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: destination.accountName))
        .accessibilityAddTraits(destination.isCurrent ? .isSelected : [])
    }
}
