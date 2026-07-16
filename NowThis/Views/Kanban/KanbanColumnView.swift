import SwiftUI
import SwiftData

/// A single column in the Kanban board representing a `TaskStatus`.
///
/// Displays a colored header with task count and a scrollable list of
/// `KanbanCardView` items. Drop highlighting is managed by the parent
/// `KanbanBoardView` which owns the drop destination.
struct KanbanColumnView: View {

    let status: TaskStatus
    let tasks: [TaskItem]

    var body: some View {
        VStack(spacing: 0) {
            // Column header
            columnHeader

            // Task cards
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(tasks) { task in
                        // Snapshot to a value here, while `task` is a live model
                        // delivered by the parent's @Query. The card never holds
                        // the model, so a later deferred re-layout can't
                        // dereference a row a background sync has deleted.
                        if let data = KanbanCardData(task: task) {
                            NavigationLink(value: task) {
                                KanbanCardView(data: data)
                            }
                            .buttonStyle(.plain)
                            .draggable(task.id) {
                                // Drag preview
                                KanbanCardView(data: data)
                                    .frame(width: 240)
                                    .opacity(0.85)
                            }
                        }
                    }

                    // Empty column hint
                    if tasks.isEmpty {
                        Text("Drop tasks here")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGroupedBackground))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.displayName) column, \(tasks.count) tasks")
    }

    // MARK: - Column Header

    private var columnHeader: some View {
        HStack(spacing: 8) {
            // Colored accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(columnColor)
                .frame(width: 4, height: 20)
                .accessibilityHidden(true)

            // Status name
            Text(status.displayName)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            Spacer()

            // Task count badge
            Text("\(tasks.count)")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(columnColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(columnColor.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Colors

    var columnColor: Color {
        switch status {
        case .needsAction: return .blue
        case .inProcess: return .orange
        case .completed: return .green
        case .cancelled: return .gray
        }
    }
}
