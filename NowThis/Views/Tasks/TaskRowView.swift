import SwiftUI
import SwiftData
import WidgetKit

/// An immutable snapshot of the fields a `TaskRowView` renders.
///
/// The row is handed a plain value — never a live `TaskItem` to read from.
/// Deleting an account cascades `ServerAccount` → `TaskList` → `TaskItem` on the
/// **main** context (`AccountManager.removeAccount`), invalidating every task a
/// retained row still holds. SwiftUI keeps realized rows alive across updates,
/// so a later layout pass could read `task.status` on an invalidated model and
/// trip SwiftData's assertion:
///
///     SwiftData/BackingData.swift:249: Fatal error: This backing data was
///     detached from a context without resolving attribute faults: … \TaskItem.status
///
/// Snapshotting at row-build time — while the parent's `@Query` still
/// guarantees validity — removes that window entirely.
struct TaskRowData: Equatable {
    let title: String
    let descriptionText: String?
    let status: TaskStatus
    let priority: TaskPriority
    let dueDate: Date?
    let isDueDateOnly: Bool
    let firstTagName: String?
    let firstTagColorHex: String?
    /// Immediate children, counted exactly as the row did before: unfiltered,
    /// so the VoiceOver subtask count and the ring's visibility are unchanged.
    let directSubtaskCount: Int
    let subtasksCompleted: Int
    let subtasksTotal: Int
    let hasRecurrence: Bool

    /// Builds a snapshot from a live task, or `nil` if the task's backing row
    /// has been invalidated (deleted from the store, directly or by cascade).
    /// Reading a property of an invalidated `PersistentModel` traps in
    /// SwiftData, so we refuse to read one whose `modelContext` is gone.
    /// Callers treat `nil` as "row is gone — render nothing".
    init?(task: TaskItem, progress: TaskHierarchyProgress? = nil) {
        guard task.modelContext != nil else { return nil }
        self.title = task.title
        self.descriptionText = task.descriptionText
        self.status = task.status
        self.priority = task.priority
        self.dueDate = task.dueDate
        self.isDueDateOnly = task.isDueDateOnly
        let firstTag = task.tags.first
        self.firstTagName = firstTag?.name
        self.firstTagColorHex = firstTag?.color
        self.directSubtaskCount = task.subtasks.count
        let descendantProgress = progress ?? Self.aggregatedProgress(of: task)
        self.subtasksCompleted = descendantProgress.completed
        self.subtasksTotal = descendantProgress.total
        self.hasRecurrence = task.recurrenceRule != nil
    }

    /// A guarded iterative walk tolerates malformed cycles and very deep server hierarchies.
    private static func aggregatedProgress(of task: TaskItem) -> TaskHierarchyProgress {
        let descendants = TaskHierarchyTraversal.entries(from: task).dropFirst()
        return TaskHierarchyProgress(
            completed: descendants.filter { $0.task.status == .completed }.count,
            total: descendants.count
        )
    }

}

/// A single task row with checkbox, title, metadata badges, and swipe actions.
///
/// Renders exclusively from a `TaskRowData` snapshot; the live `task` is kept
/// only to mutate on user action, never to read during a layout pass.
///
/// Supports:
/// - Tap checkbox to toggle completion (with haptic feedback)
/// - Priority dot indicator
/// - Due date badge (red if overdue)
/// - Subtask count badge
/// - Swipe-right to complete
/// - Swipe-left to delete
/// - Context menu for quick actions
struct TaskRowView: View {

    let data: TaskRowData
    let task: TaskItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.saveErrorState) private var errorState
    @Environment(\.syncCommands) private var syncCommands
    @StateObject private var completionCoordinator = TaskCompletionCoordinator()
    @State private var moveRequest: MoveToListRequest?
    @State private var deletionCoordinator = TaskDeletionCoordinator()
    @State private var showDeleteConfirmation = false
    @State private var showSubtasksChangedError = false
    let onTap: () -> Void

    /// True when the completion animation is playing or the task is already completed.
    private var showCompletedVisuals: Bool {
        completionCoordinator.isAnimating || data.status == .completed
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                CheckboxButton(
                    isCompleted: showCompletedVisuals,
                    isAnimatingCompletion: completionCoordinator.isAnimating,
                    priority: data.priority
                ) {
                    toggleCompletion()
                }

                TaskInfoColumn(data: data, isCompletingAnimation: completionCoordinator.isAnimating)

                Spacer(minLength: 4)

                MetadataBadges(data: data)
            }
            .padding(.vertical, 4)
            .opacity(completionCoordinator.isAnimating ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.3), value: completionCoordinator.isAnimating)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                toggleCompletion()
            } label: {
                Label(
                    swipeToggleTitle,
                    systemImage: data.status == .completed
                        ? "arrow.uturn.backward" : "checkmark"
                )
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // A destructive swipe optimistically removes the row before its dialog.
            Button {
                deleteTask()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        .contextMenu {
            TaskContextMenu(
                data: data,
                task: task,
                onToggle: toggleCompletion,
                onMove: { moveRequest = MoveToListRequest(task: task) },
                onDelete: deleteTask
            )
        }
        .confirmationDialog(
            Text(deleteConfirmationTitle),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if deletionCoordinator.confirm(in: modelContext, errorState: errorState,
                                               delete: performDeletion) == .subtasksChanged {
                    showSubtasksChangedError = true
                }
            }
            Button("Cancel", role: .cancel) { deletionCoordinator.cancel() }
        }
        .onChange(of: showDeleteConfirmation) { _, isPresented in
            if !isPresented { deletionCoordinator.cancel() }
        }
        .alert("Delete", isPresented: $showSubtasksChangedError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The subtasks changed. Try deleting this task again.",
                 comment: "Task deletion was safely stopped because the number of active subtasks changed while the confirmation dialog was open. Ask the user to start deletion again to review the new count.")
        }
        .sheet(item: $moveRequest) { request in
            MoveToListSheet(request: request) { destination, errors in
                moveTask(request, to: destination, errorState: errors)
            }
        }

        .alert("Repeat", isPresented: Binding(
            get: { completionCoordinator.completionError != nil }, set: { if !$0 { completionCoordinator.completionError = nil } }
        )) {
            Button("OK", role: .cancel) { completionCoordinator.completionError = nil }
        } message: {
            if let error = completionCoordinator.completionError { Text(error.localizedStringResource) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(taskAccessibilityLabel)
        .accessibilityValue(data.status == .completed ? "Completed" : "Incomplete")
        .accessibilityHint("Double tap to view details")
        .accessibilityAction(named: data.status == .completed
                             ? String(localized: "tasks.row.a11y.markIncomplete",
                                      defaultValue: "Mark incomplete",
                                      comment: "VoiceOver rotor action that reopens a completed task. Spoken, not shown — sentence case, unlike the visible 'Reopen' swipe action and the 'Mark Incomplete' context-menu item, which are three renderings of one action.")
                             : String(localized: "tasks.row.a11y.markComplete",
                                      defaultValue: "Mark complete",
                                      comment: "VoiceOver rotor action that completes a task. Spoken, not shown — sentence case, unlike the visible 'Complete' swipe action and the 'Mark Complete' context-menu item, which are three renderings of one action.")) {
            toggleCompletion()
        }
        .accessibilityAction(named: "Delete") {
            deleteTask()
        }
        // The menu's Move to List…, which the combined row otherwise hides from VoiceOver.
        .accessibilityActions {
            if MoveDestinations.canMove(task) {
                Button {
                    moveRequest = MoveToListRequest(task: task)
                } label: {
                    Text("Move to List…", comment: "Context-menu item on a task that opens a picker to move the task, with its subtasks, to a different list.")
                }
            }
        }
    }

    // MARK: - Actions

    /// Title for the leading swipe action. Hoisted out of the `Label` because
    /// two `String(localized:)` calls inside a ternary inside an initialiser
    /// pushed the expression past the type-checker's budget.
    private var swipeToggleTitle: String {
        data.status == .completed
            ? String(localized: "tasks.swipe.reopen", defaultValue: "Reopen",
                     comment: "Swipe-action button that un-completes a task and puts it back on the list. A VERB, in this language's usual mood for an action button. NOT the system undo, and NOT cancel — this app has a real Cancelled status and the two must not read the same. Swipe buttons are narrow: keep it to one short word.")
            : String(localized: "tasks.swipe.complete", defaultValue: "Complete",
                     comment: "Swipe-action button that marks a task completed. A VERB, in this language's usual mood for an action button — not the adjective for the completed state, and not plural: it acts on the one task being swiped. Swipe buttons are narrow: keep it to one short word.")
    }

    private func toggleCompletion() {
        completionCoordinator.toggle(task, save: {
            try ReminderSchedulingJournal.saveTaskChanges(in: modelContext)
        }, errorState: errorState, requestReconcile: {
            try ReminderScheduler.requestReconcileOrThrow(modelContext: modelContext)
        }) { [modelContext, syncCommands, task] in
            HapticManager.checkbox()
            if task.modelContext != nil, task.status == .completed {
                ReminderScheduler.cancelReminder(for: task.id)
            }
            syncCommands.syncAfterChange(modelContext)
        }
    }

    private func moveTask(_ request: MoveToListRequest, to destination: MoveDestinations.Destination,
                          errorState: ErrorState) -> Bool {
        guard MoveDestinations.perform(request, to: destination, in: modelContext, errorState: errorState,
            revalidate: { syncCommands.syncAfterChange(modelContext) }) else { return false }
        HapticManager.softImpact()
        syncCommands.publishLocalTaskCommit()
        syncCommands.syncAfterChange(modelContext)
        return true
    }

    private var deleteConfirmationTitle: LocalizedStringResource {
        LocalizedStringResource(
            "tasks.row.deleteConfirmation",
            defaultValue: "Delete this task and \(deletionCoordinator.subtaskCount ?? 0) subtasks?",
            comment: "Destructive task deletion confirmation. The number is all active descendants, including nested subtasks, that will be deleted together with this task. Plural forms are in the catalog."
        )
    }

    private func deleteTask() {
        deletionCoordinator.request(task, in: modelContext, errorState: errorState,
                                    delete: performDeletion)
        showDeleteConfirmation = deletionCoordinator.subtaskCount != nil
    }

    private func performDeletion(_ task: TaskItem, confirmedScope: TaskWriteEligibility.DeletionScope) {
        // Same guard the context-menu actions carry: a swipe can land on a row
        // whose task an account delete has already cascaded away, and writing to
        // an invalidated model traps exactly like reading one.
        guard task.modelContext != nil, !task.isDeletedLocally else { return }
        // Restore this operation's tombstones on failure so the row can be retried.
        let result = MotionManager.withAccessibleAnimation {
            TaskDeletionPersistence.perform(task, in: modelContext, errorState: errorState,
                                            confirmed: confirmedScope)
        }
        guard let deletedIDs = result else { return }
        HapticManager.softImpact()
        // Every row that just went, not only the one that was swiped: a subtask's
        // reminders outlive it otherwise and fire for a task that is not there.
        for id in deletedIDs {
            ReminderScheduler.cancelReminder(for: id)
        }
        guard ReminderScheduler.requestReconcile(modelContext: modelContext, onSaveFailure: {
            ViewPersistence.report($0, to: errorState)
        }) else { return }
        syncCommands.syncAfterChange(modelContext)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private var taskAccessibilityLabel: String {
        var parts = [data.title]
        if data.status == .completed {
            parts.append(String(
                localized: "tasks.row.a11y.completed",
                defaultValue: "Completed",
                comment: "Appended after the task title into the task row's VoiceOver label when the task is completed."))
        }
        if let due = data.dueDate {
            parts.append(String(
                localized: "tasks.row.a11y.due",
                defaultValue: "Due \(DueDateFormatter.accessibilityLabel(due, isDateOnly: data.isDueDateOnly))",
                comment: "Appended after the task title into the task row's VoiceOver label; the interpolated value is the already-localized due-date accessibility text."))
        }
        if data.priority != TaskPriority.none {
            parts.append(String(
                localized: "tasks.row.a11y.priority",
                defaultValue: "Priority \(data.priority.displayName)",
                comment: "Appended after the task title into the task row's VoiceOver label; the interpolated value is the already-localized priority name."))
        }
        let subtaskCount = data.directSubtaskCount
        if subtaskCount > 0 {
            parts.append(String(
                localized: "tasks.row.a11y.subtaskCount",
                defaultValue: "\(subtaskCount) subtasks",
                comment: "Appended after the task title into the task row's VoiceOver label, stating how many subtasks the task has. The plural forms are in the catalog."))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Checkbox

private struct CheckboxButton: View {
    let isCompleted: Bool
    var isAnimatingCompletion: Bool = false
    let priority: TaskPriority
    let action: () -> Void

    @State private var checkScale: CGFloat = 1.0

    var body: some View {
        Button(action: {
            action()
            if !isCompleted {
                // Trigger scale-pop on completion
                withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) {
                    checkScale = 1.3
                }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.6).delay(0.15)) {
                    checkScale = 1.0
                }
            }
        }) {
            ZStack {
                Circle()
                    .strokeBorder(borderColor, lineWidth: 2)
                    .frame(width: 24, height: 24)

                if isCompleted {
                    Circle()
                        .fill(.green)
                        .frame(width: 24, height: 24)
                        .transition(.scale.combined(with: .opacity))

                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(checkScale)
            .animation(.easeInOut(duration: 0.2), value: isCompleted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCompleted ? "Completed" : "Not completed")
        .accessibilityAddTraits(.isButton)
    }

    private var borderColor: Color {
        if isCompleted { return .green }
        // Preserve the deliberately faint border for no-priority tasks;
        // delegate the priority hues to the shared TaskPriority.color.
        return priority == .none ? .secondary.opacity(0.5) : priority.color
    }
}

// MARK: - Task Info

private struct TaskInfoColumn: View {
    let data: TaskRowData
    var isCompletingAnimation: Bool = false

    /// Show completed text style during animation or when actually completed.
    private var showCompletedStyle: Bool {
        isCompletingAnimation || data.status == .completed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: data.title)
                .font(.body)
                .strikethrough(showCompletedStyle)
                .foregroundStyle(showCompletedStyle ? .secondary : .primary)
                .lineLimit(2)
                .animation(.easeInOut(duration: 0.2), value: showCompletedStyle)

            if let notes = data.descriptionText, !notes.isEmpty {
                Text(verbatim: notes)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Metadata Badges

private struct MetadataBadges: View {
    let data: TaskRowData

    var body: some View {
        HStack(spacing: 8) {
            if let tagName = data.firstTagName {
                Text(verbatim: tagName)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tagColor.opacity(0.1), in: Capsule())
                    .foregroundStyle(tagColor)
            }

            if data.directSubtaskCount > 0 {
                SubtaskProgressRing(
                    completed: data.subtasksCompleted,
                    total: data.subtasksTotal
                )
            }

            if let due = data.dueDate {
                DueDateBadge(
                    date: due,
                    isDateOnly: data.isDueDateOnly,
                    isOverdue: DueDateHelper.isOverdue(dueDate: due, isDateOnly: data.isDueDateOnly)
                )
            }

            if data.priority == .high {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if data.hasRecurrence {
                Image(systemName: "repeat")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tagColor: Color {
        if let hex = data.firstTagColorHex {
            return Color(hex: hex) ?? .purple
        }
        return .purple
    }
}

struct DueDateBadge: View {
    let date: Date
    var isDateOnly: Bool = false
    let isOverdue: Bool

    func label(timeZone: TimeZone = .current) -> String {
        DueDateFormatter.format(date, isDateOnly: isDateOnly, timeZone: timeZone)
    }

    var body: some View {
        Text(label())
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(isOverdue ? .red.opacity(0.12) : .blue.opacity(0.08))
            )
            .foregroundStyle(isOverdue ? .red : .blue)
    }
}

// MARK: - Context Menu

private struct TaskContextMenu: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.saveErrorState) private var errorState
    let data: TaskRowData
    let task: TaskItem
    let onToggle: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Label(
                data.status == .completed ? "Mark Incomplete" : "Mark Complete",
                systemImage: data.status == .completed ? "circle" : "checkmark.circle"
            )
        }

        Menu("Priority") {
            ForEach([TaskPriority.high, .medium, .low, TaskPriority.none], id: \.self) { pri in
                Button {
                    do {
                        _ = try TaskWriteEligibility(writingIn: modelContext).task(.retained(task))
                    } catch {
                        ViewPersistence.reportTaskWriteRefusal(error, to: errorState)
                        return
                    }
                    guard task.priority != pri else { return }
                    task.priority = pri
                    task.lastModifiedDate = Date()
                    task.isDirty = true
                    HapticManager.softImpact()
                } label: {
                    HStack {
                        Label(pri.displayName, systemImage: pri.icon)
                        if data.priority == pri {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

        // Hosted by the row: this menu is stateless and cannot present a sheet.
        Button(action: onMove) {
            Label {
                Text("Move to List…", comment: "Context-menu item on a task that opens a picker to move the task, with its subtasks, to a different list.")
            } icon: {
                Image(systemName: "folder")
            }
        }
        .disabled(!MoveDestinations.canMove(task))

        Divider()

        Button(role: .destructive, action: onDelete) {
            Label("Delete", systemImage: "trash")
        }
    }
}

// MARK: - TaskPriority UI Alias

extension TaskPriority {
    /// Alias for `systemImageName` used in UI labels.
    var icon: String { systemImageName }
}
