import SwiftUI
import SwiftData

/// Paged swipe view showing one task list per page.
///
/// Swipe left/right to navigate between different task lists,
/// similar to Google Tasks. Each page shows the list's tasks
/// in a simple scrollable list using `TaskRowView`.
struct KanbanListSwipeView: View {

    let taskLists: [TaskList]
    let allTasks: [TaskItem]
    /// The board's one list selection, owned and persisted by `KanbanBoardView`.
    /// Swiping to a page writes it, so the Status columns open on the list the
    /// user last swiped to — and a list picked there opens as this view's page.
    @Binding var selectedListID: String
    @State private var selectedTask: SelectedTask?
    @AppStorage("showCompletedTasks") private var showCompleted = false

    /// Liveness at the array boundary: `ForEach` reads each list's `id` to diff
    /// identity before any page body runs, and `tasksForList` dereferences both
    /// the list and every task. An account delete cascades all of them away on the
    /// main context.
    private var liveLists: [TaskList] {
        taskLists.filter { $0.modelContext != nil }
    }

    /// The shared selection resolved to a page that actually exists.
    ///
    /// Reading through ``KanbanListScope`` means a stored id that names no live
    /// list — never chosen yet, or deleted by a sync while the board was open —
    /// still lands on a real page instead of leaving the `TabView` matching no
    /// tag. Writing passes the swipe straight back to the shared selection.
    private var pageSelection: Binding<String> {
        Binding(
            get: { KanbanListScope.resolvedList(id: selectedListID, in: liveLists)?.id ?? "" },
            set: { selectedListID = $0 }
        )
    }

    var body: some View {
        let projection = KanbanTaskProjection(tasks: allTasks)
        TabView(selection: pageSelection) {
            ForEach(liveLists) { list in
                ListPage(
                    list: list,
                    tasks: projection.page(listID: list.id, showCompleted: showCompleted),
                    listIsEmpty: projection.isEmpty(listID: list.id),
                    onSelect: { selectedTask = SelectedTask($0) }
                )
                .tag(list.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .sheet(item: $selectedTask) { selection in
            NavigationStack {
                TaskDetailView(task: selection.task)
            }
        }
    }


}

// MARK: - List Page

private struct ListPage: View {
    let list: TaskList
    let tasks: [TaskItem]
    /// Whether the list holds nothing at all, which is a different thing from
    /// this page having no rows — see ``KanbanListScope/listIsEmpty(_:inListWithID:)``.
    let listIsEmpty: Bool
    let onSelect: (TaskItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // List header
            HStack {
                Circle()
                    .fill(Color(hex: list.colorHex) ?? .blue)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(list.name)
                    .font(.title2.bold())
                Spacer()
                Text(verbatim: String(
                    localized: "kanban.list.taskCount",
                    defaultValue: "\(tasks.count) tasks",
                    comment: "Count shown beside a list's name in the board's list picker. The plural forms are in the catalog — this literal can only carry one of them."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(
                localized: "list.a11y.taskCount",
                defaultValue: "\(list.name), \(tasks.count) tasks",
                comment: "VoiceOver label for a row that names a collection and how many tasks are in it. First placeholder is the name (a list, tag, smart list or board quadrant), second is the count."))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if tasks.isEmpty {
                ContentUnavailableView {
                    Label("No Tasks", systemImage: "checkmark.circle")
                } description: {
                    // Two literals in two branches, not one interpolated
                    // ternary: a mixed ternary binds the `verbatim` overload
                    // and neither string would ever enter the catalog.
                    if listIsEmpty {
                        Text("Nothing in \(list.name) yet.")
                    } else {
                        Text("All tasks in \(list.name) are completed.")
                    }
                }
            } else {
                List {
                    ForEach(tasks) { task in
                        if let data = TaskRowData(task: task) {
                            TaskRowView(data: data, task: task, onTap: { onSelect(task) })
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}
