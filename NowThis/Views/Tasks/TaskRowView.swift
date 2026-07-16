import SwiftUI
import SwiftData
import WidgetKit

/// A single task row with checkbox, title, metadata badges, and swipe actions.
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

    @Bindable var task: TaskItem
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncScheduler: SyncScheduler
    @StateObject private var completionCoordinator = TaskCompletionCoordinator()
    let onTap: () -> Void

    /// True when the completion animation is playing or the task is already completed.
    private var showCompletedVisuals: Bool {
        completionCoordinator.isAnimating || task.status == .completed
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                CheckboxButton(
                    isCompleted: showCompletedVisuals,
                    isAnimatingCompletion: completionCoordinator.isAnimating,
                    priority: task.priority
                ) {
                    toggleCompletion()
                }

                TaskInfoColumn(task: task, isCompletingAnimation: completionCoordinator.isAnimating)

                Spacer(minLength: 4)

                MetadataBadges(task: task)
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
                    task.status == .completed ? "Undo" : "Complete",
                    systemImage: task.status == .completed
                        ? "arrow.uturn.backward" : "checkmark"
                )
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteTask()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            TaskContextMenu(task: task, onToggle: toggleCompletion, onDelete: deleteTask)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(taskAccessibilityLabel)
        .accessibilityValue(task.status == .completed ? "Completed" : "Incomplete")
        .accessibilityHint("Double tap to view details")
        .accessibilityAction(named: task.status == .completed ? "Mark incomplete" : "Mark complete") {
            toggleCompletion()
        }
        .accessibilityAction(named: "Delete") {
            deleteTask()
        }
    }

    // MARK: - Actions

    private func toggleCompletion() {
        HapticManager.checkbox()
        completionCoordinator.toggle(task) { [modelContext, syncScheduler] in
            Task { @MainActor in
                try? modelContext.save()
                await ReminderScheduler.updateBadgeCount(modelContext: modelContext)
                syncScheduler.syncAfterChange(modelContext: modelContext)
            }
        }
    }

    private func deleteTask() {
        HapticManager.softImpact()
        MotionManager.withAccessibleAnimation {
            task.isDeletedLocally = true
            task.isDirty = true
            try? modelContext.save()
        }
        Task { @MainActor in
            await ReminderScheduler.updateBadgeCount(modelContext: modelContext)
        }
        syncScheduler.syncAfterChange(modelContext: modelContext)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private var taskAccessibilityLabel: String {
        var parts = [task.title]
        if task.status == .completed {
            parts.append("Completed")
        }
        if let due = task.dueDate {
            parts.append("Due \(DueDateFormatter.accessibilityLabel(due, isDateOnly: task.isDueDateOnly))")
        }
        if task.priority != TaskPriority.none {
            parts.append("Priority \(task.priority.displayName)")
        }
        let subtaskCount = task.subtasks.count
        if subtaskCount > 0 {
            parts.append("\(subtaskCount) subtask\(subtaskCount == 1 ? "" : "s")")
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
    let task: TaskItem
    var isCompletingAnimation: Bool = false

    /// Show completed text style during animation or when actually completed.
    private var showCompletedStyle: Bool {
        isCompletingAnimation || task.status == .completed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.title)
                .font(.body)
                .strikethrough(showCompletedStyle)
                .foregroundStyle(showCompletedStyle ? .secondary : .primary)
                .lineLimit(2)
                .animation(.easeInOut(duration: 0.2), value: showCompletedStyle)

            if let notes = task.descriptionText, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Metadata Badges

private struct MetadataBadges: View {
    let task: TaskItem

    var body: some View {
        HStack(spacing: 8) {
            if let firstTag = task.tags.first {
                Text(firstTag.name)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tagColor(firstTag).opacity(0.1), in: Capsule())
                    .foregroundStyle(tagColor(firstTag))
            }

            if !task.subtasks.isEmpty {
                SubtaskProgressRing(task: task)
            }

            if let due = task.dueDate {
                DueDateBadge(
                    date: due,
                    isDateOnly: task.isDueDateOnly,
                    isOverdue: DueDateHelper.isOverdue(dueDate: due, isDateOnly: task.isDueDateOnly)
                )
            }

            if task.priority == .high {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if task.recurrenceRule != nil {
                Image(systemName: "repeat")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tagColor(_ tag: Tag) -> Color {
        if let hex = tag.color {
            return Color(hex: hex) ?? .purple
        }
        return .purple
    }
}

private struct SubtaskBadge: View {
    let count: Int
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "list.bullet")
            Text("\(count)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct DueDateBadge: View {
    let date: Date
    var isDateOnly: Bool = false
    let isOverdue: Bool

    var body: some View {
        Text(DueDateFormatter.format(date, isDateOnly: isDateOnly))
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
    @Bindable var task: TaskItem
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Label(
                task.status == .completed ? "Mark Incomplete" : "Mark Complete",
                systemImage: task.status == .completed ? "circle" : "checkmark.circle"
            )
        }

        Menu("Priority") {
            ForEach([TaskPriority.high, .medium, .low, TaskPriority.none], id: \.self) { pri in
                Button {
                    task.priority = pri
                    task.lastModifiedDate = Date()
                    task.isDirty = true
                    HapticManager.softImpact()
                } label: {
                    HStack {
                        Label(pri.displayName, systemImage: pri.icon)
                        if task.priority == pri {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

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
