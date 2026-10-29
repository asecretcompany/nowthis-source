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

    /// Moves `task`, with its subtree, to the list with `listID`, and saves.
    ///
    /// - Returns: `false` when nothing moved — the task or the list is gone, or the
    ///   task is already there. The caller schedules a sync only on `true`.
    @discardableResult
    static func perform(_ task: TaskItem, toListID listID: String, in context: ModelContext) -> Bool {
        guard task.modelContext != nil else { return false }
        var descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })
        descriptor.fetchLimit = 1
        guard let destination = try? context.fetch(descriptor).first else { return false }
        guard !TaskMover.move(task, to: destination, in: context).isEmpty else { return false }
        try? ReminderSchedulingJournal.saveTaskChanges(in: context)
        return true
    }

    /// `perform(_:toListID:in:)` for a caller that holds only the task's ID — a
    /// board card, whose closures must not read the model they were built from.
    @discardableResult
    static func perform(taskID: String, toListID listID: String, in context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })
        descriptor.fetchLimit = 1
        guard let task = try? context.fetch(descriptor).first else { return false }
        return perform(task, toListID: listID, in: context)
    }
}

// MARK: - Request

/// What the sheet needs to know about the task being moved, captured when it is
/// opened so the sheet never reads the live model.
struct MoveToListRequest: Identifiable {
    let id = UUID()
    let taskID: String
    let currentListID: String?
    /// A subtask moved on its own leaves its parent behind and becomes top level.
    let isSubtask: Bool

    init?(task: TaskItem) {
        guard task.modelContext != nil else { return nil }
        taskID = task.id
        currentListID = task.taskList?.id
        isSubtask = task.parentTask != nil
    }
}

// MARK: - Sheet

/// Picks the list a task moves to. Accounts are sections, lists are rows; the
/// current list is checked, and lists the user cannot write to are shown but
/// cannot be chosen.
struct MoveToListSheet: View {
    let request: MoveToListRequest
    let onChoose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [ServerAccount]
    @State private var pendingSubtaskMove: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(MoveDestinations.sections(accounts: accounts, currentListID: request.currentListID)) { section in
                    Section {
                        ForEach(section.lists) { destination in
                            DestinationRow(destination: destination) {
                                choose(destination.id)
                            }
                        }
                    } header: {
                        Text(verbatim: section.accountName)
                    }
                }
            }
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
                    if let listID = pendingSubtaskMove { finish(listID) }
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

    private func choose(_ listID: String) {
        if request.isSubtask {
            pendingSubtaskMove = listID
        } else {
            finish(listID)
        }
    }

    private func finish(_ listID: String) {
        onChoose(listID)
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
