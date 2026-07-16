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
    @State private var selectedPage: String?
    @State private var selectedTask: TaskItem?
    @AppStorage("showCompletedTasks") private var showCompleted = false

    var body: some View {
        TabView(selection: $selectedPage) {
            ForEach(taskLists) { list in
                ListPage(
                    list: list,
                    tasks: tasksForList(list),
                    onSelect: { selectedTask = $0 }
                )
                .tag(list.id as String?)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .onAppear {
            if selectedPage == nil {
                selectedPage = taskLists.first?.id
            }
        }
        .sheet(item: $selectedTask) { task in
            NavigationStack {
                TaskDetailView(task: task)
            }
        }
    }

    private func tasksForList(_ list: TaskList) -> [TaskItem] {
        allTasks.filter { task in
            task.taskList?.id == list.id
                && task.parentTask == nil
                && (showCompleted || task.status != .completed)
        }
    }
}

// MARK: - List Page

private struct ListPage: View {
    let list: TaskList
    let tasks: [TaskItem]
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
                Text("\(tasks.count) task\(tasks.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(list.name), \(tasks.count) task\(tasks.count == 1 ? "" : "s")")
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if tasks.isEmpty {
                ContentUnavailableView {
                    Label("No Tasks", systemImage: "checkmark.circle")
                } description: {
                    Text("All tasks in \(list.name) are completed.")
                }
            } else {
                List {
                    ForEach(tasks) { task in
                        TaskRowView(task: task, onTap: { onSelect(task) })
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}
