import SwiftUI
import SwiftData

/// A compact task card for the Kanban board.
///
/// Displays the task title (2-line max), a priority-colored dot,
/// optional due date, and an optional tag strip. Tapping navigates
/// to the full `TaskDetailView`. Supports drag-and-drop via
/// `Transferable` for cross-column reordering.
struct KanbanCardView: View {

    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Priority dot + title
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(priorityColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                    .accessibilityHidden(true)

                Text(task.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(
                        task.status == .completed ? .secondary : .primary
                    )
                    .strikethrough(task.status == .completed)
            }

            // Bottom row: due date + tag
            HStack(spacing: 6) {
                if let due = task.dueDate {
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

                if let firstTag = task.tags.first {
                    Text(firstTag.name)
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
        task.priority == .none ? .gray.opacity(0.4) : task.priority.color
    }

    // MARK: - Accessibility

    private var cardAccessibilityLabel: String {
        var parts = [task.title]
        if task.priority != .none {
            parts.append("\(task.priority.displayName) priority")
        }
        if let due = task.dueDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append("due \(formatter.localizedString(for: due, relativeTo: Date()))")
        }
        if task.status == .completed {
            parts.append("completed")
        }
        return parts.joined(separator: ", ")
    }
}
