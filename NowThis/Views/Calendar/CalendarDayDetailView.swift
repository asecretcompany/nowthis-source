import SwiftUI
import SwiftData

/// Detail view showing all tasks due on a specific date.
///
/// Includes an overdue carry-forward section at the top for past-due
/// incomplete tasks, followed by tasks due on the selected day.
/// The "Add Task" button pre-fills the selected date as due date.
struct CalendarDayDetailView: View {

    let date: Date
    let tasks: [TaskItem]

    @Environment(\.modelContext) private var modelContext
    @State private var showingAddTask = false

    var body: some View {
        List {
            // Overdue carry-forward
            if !overdueTasks.isEmpty {
                Section {
                    ForEach(overdueTasks) { task in
                        NavigationLink(value: task) {
                            OverdueTaskRow(task: task)
                        }
                        .draggable(task.id)
                    }
                } header: {
                    Label("Overdue", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            // Tasks due on selected date
            Section {
                if dueTasks.isEmpty && overdueTasks.isEmpty {
                    ContentUnavailableView {
                        Label("No Tasks", systemImage: "calendar")
                    } description: {
                        Text("No tasks are due on this date.")
                    }
                } else {
                    ForEach(dueTasks) { task in
                        NavigationLink(value: task) {
                            DayTaskRow(task: task)
                        }
                        .draggable(task.id)
                    }
                }
            } header: {
                if !dueTasks.isEmpty {
                    Text(date, format: .dateTime.weekday(.wide).month(.wide).day())
                }
            }
        }
        .navigationTitle(dayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addTask()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add task due on this date")
            }
        }
    }

    // MARK: - Title

    private var dayTitle: String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: - Data

    private var dueTasks: [TaskItem] {
        return tasks.filter { task in
            guard let due = task.dueDate else { return false }
            return DueDateHelper.isOnDay(due, isDateOnly: task.isDueDateOnly, sameAs: date)
        }
    }

    private var overdueTasks: [TaskItem] {
        guard Calendar.current.isDateInToday(date) else { return [] }
        return tasks.filter { task in
            guard let due = task.dueDate else { return false }
            return DueDateHelper.isOverdue(dueDate: due, isDateOnly: task.isDueDateOnly)
                && task.status != .completed
                && task.status != .cancelled
        }
    }

    // MARK: - Actions

    private func addTask() {
        let task = TaskItem(title: "")
        task.dueDate = date
        task.taskList = tasks.first?.taskList
        modelContext.insert(task)
    }
}

// MARK: - Overdue Task Row

private struct OverdueTaskRow: View {
    let task: TaskItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline)

                if let due = task.dueDate {
                    Text("Due \(due, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title), overdue")
    }
}

// MARK: - Day Task Row

private struct DayTaskRow: View {
    let task: TaskItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: task.status.systemImageName)
                .font(.body)
                .foregroundStyle(task.status == .completed ? .green : .accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline)
                    .strikethrough(task.status == .completed)
                    .foregroundStyle(task.status == .completed ? .secondary : .primary)

                if task.priority != .none {
                    Text(task.priority.displayName)
                        .font(.caption2)
                        .foregroundStyle(priorityColor)
                }
            }

            Spacer()

            if let due = task.dueDate {
                Text(due, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title), \(task.status == .completed ? "completed" : "pending")")
    }

    private var priorityColor: Color {
        task.priority.color
    }
}
