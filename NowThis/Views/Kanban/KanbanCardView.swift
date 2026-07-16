import SwiftUI
import SwiftData

/// An immutable snapshot of the fields a `KanbanCardView` renders.
///
/// The board hands each card a plain value type — never a live `TaskItem`. A
/// card sits inside a `LazyVStack`, so SwiftUI retains it across updates and
/// can re-evaluate its `body` during a deferred layout/preference pass. If the
/// card held the model directly, that pass could dereference a `TaskItem` a
/// background sync had already hard-deleted, tripping SwiftData's
/// `BackingData.getValue` assertion (`TaskItem.priority.getter` crash).
/// Snapshotting to a value at build time removes that window entirely.
struct KanbanCardData {
    let title: String
    let status: TaskStatus
    let priority: TaskPriority
    let dueDate: Date?
    let firstTagName: String?

    /// Builds a snapshot from a live task, or `nil` if the task's backing row
    /// has been invalidated (deleted from the store). Reading a property of an
    /// invalidated `PersistentModel` traps in SwiftData, so we refuse to read
    /// one whose `modelContext` is gone. Callers treat `nil` as "row is gone —
    /// render nothing".
    init?(task: TaskItem) {
        guard task.modelContext != nil else { return nil }
        self.title = task.title
        self.status = task.status
        self.priority = task.priority
        self.dueDate = task.dueDate
        self.firstTagName = task.tags.first?.name
    }
}

/// A compact task card for the Kanban board.
///
/// Displays the task title (2-line max), a priority-colored dot,
/// optional due date, and an optional tag strip. Tapping navigates
/// to the full `TaskDetailView`. Supports drag-and-drop via
/// `Transferable` for cross-column reordering.
struct KanbanCardView: View {

    let data: KanbanCardData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Priority dot + title
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(priorityColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                    .accessibilityHidden(true)

                Text(data.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(
                        data.status == .completed ? .secondary : .primary
                    )
                    .strikethrough(data.status == .completed)
            }

            // Bottom row: due date + tag
            HStack(spacing: 6) {
                if let due = data.dueDate {
                    Label {
                        Text(due, format: .dateTime.month(.abbreviated).day())
                            .font(.caption2)
                    } icon: {
                        Image(systemName: "calendar")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(due < Date() ? .red : .secondary)
                }

                Spacer()

                if let firstTag = data.firstTagName {
                    Text(firstTag)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
        .shadow(color: .black.opacity(0.03), radius: 8, x: 0, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityHint("Double tap to open task details")
    }

    // MARK: - Priority Color

    private var priorityColor: Color {
        data.priority == .none ? .gray.opacity(0.4) : data.priority.color
    }

    // MARK: - Accessibility

    private var cardAccessibilityLabel: String {
        var parts = [data.title]
        if data.priority != .none {
            parts.append("\(data.priority.displayName) priority")
        }
        if let due = data.dueDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append("due \(formatter.localizedString(for: due, relativeTo: Date()))")
        }
        if data.status == .completed {
            parts.append("completed")
        }
        return parts.joined(separator: ", ")
    }
}
