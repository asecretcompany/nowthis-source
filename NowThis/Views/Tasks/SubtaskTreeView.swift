import SwiftUI

/// Recursively renders a task and its subtasks as an indented tree.
///
/// Each level is indented by 20pt. Subtasks can be collapsed/expanded
/// with a disclosure chevron. Supports infinite nesting.
struct SubtaskTreeView: View {

    @Bindable var task: TaskItem
    let depth: Int
    let onSelect: (TaskItem) -> Void

    init(task: TaskItem, depth: Int = 0, onSelect: @escaping (TaskItem) -> Void) {
        self.task = task
        self.depth = depth
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: 0) {
            TaskRowView(task: task) { onSelect(task) }
                .padding(.leading, CGFloat(depth) * 20)
                .accessibilityLabel(depth > 0 ? "Subtask level \(depth), \(task.title)" : task.title)

            ForEach(sortedSubtasks) { subtask in
                SubtaskTreeView(task: subtask, depth: depth + 1, onSelect: onSelect)
            }
        }
    }

    private var sortedSubtasks: [TaskItem] {
        task.subtasks
            .filter { !$0.isDeletedLocally }
            .sorted { ($0.createdDate) < ($1.createdDate) }
    }
}
