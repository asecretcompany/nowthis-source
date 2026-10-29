import SwiftUI

/// Iteratively renders a task and its subtasks as an indented tree.
///
/// The first four levels are indented by 20pt. Subtasks can be collapsed/expanded
/// with a disclosure chevron. Deep hierarchies use a lazy flat sequence.
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
        LazyVStack(spacing: 0) {
            ForEach(TaskHierarchyTraversal.entries(from: task, depth: depth)) { entry in
                if let data = TaskRowData(task: entry.task) {
                    TaskRowView(data: data, task: entry.task) { onSelect(entry.task) }
                        .padding(.leading, CGFloat(min(entry.depth, 4)) * 20)
                        .accessibilityLabel(entry.depth > 0 ? String(
                            localized: "subtask.a11y.level",
                            defaultValue: "Subtask level \(entry.depth), \(data.title)",
                            comment: "VoiceOver label for a nested subtask row; first interpolated value is the numeric nesting depth, second is the user's task title") : data.title)
                }
            }
        }
    }
}
