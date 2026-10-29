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
    var projection: CalendarTaskProjection? = nil

    @Environment(\.modelContext) private var modelContext
    @State private var showingAddTask = false

    /// Settings > Show Completed Tasks. The day list applied no status filter at all, so
    /// completed tasks appeared here whatever the setting said.
    @AppStorage("showCompletedTasks") private var showCompleted = false

    var body: some View {
        // Snapshot once per pass. Both lists are read several times below, and
        // every read used to re-walk the whole task array.
        let buckets = projection ?? CalendarTaskProjection(rows: tasks.glanceRows())
        let overdueTasks = buckets.isToday(date) ? buckets.overdueRows : []
        let dueTasks = buckets.bucket(on: date).rows.filter { showCompleted || $0.data.status != .completed }
        return List {
            // Overdue carry-forward
            if !overdueTasks.isEmpty {
                Section {
                    ForEach(overdueTasks) { row in
                        NavigationLink(value: row.task) {
                            OverdueTaskRow(data: row.data)
                        }
                        .draggable(row.id)
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
                    ForEach(dueTasks) { row in
                        NavigationLink(value: row.task) {
                            DayTaskRow(data: row.data)
                        }
                        .draggable(row.id)
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

    // MARK: - Actions

    private func addTask() {
        let task = TaskItem(title: "")
        task.dueDate = date
        // Was: inherit from `tasks.first`. But `tasks` is the calendar-wide filtered
        // array, not this day's — day-scoping happens in `dueTasks(from:)`, which this
        // never calls. So an empty day inherited whichever task sorted first across the
        // entire range. Use the user's default list like every other creation surface.
        task.taskList = NewTaskDefaults.resolveListAdopting(explicit: nil, in: modelContext)
        modelContext.insert(task)
        // Created with a due date and never a reminder — the case that scheduled nothing at all.
        ReminderScheduler.requestReconcile(modelContext: modelContext)
    }
}

// MARK: - Overdue Task Row

private struct OverdueTaskRow: View {
    let data: TaskGlanceData

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: data.title)
                    .font(.subheadline)

                if let due = data.dueDate {
                    Text("Due \(due, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(data.title), overdue")
    }
}

// MARK: - Day Task Row

private struct DayTaskRow: View {
    let data: TaskGlanceData

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: data.status.systemImageName)
                .font(.body)
                .foregroundStyle(data.status == .completed ? .green : .accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: data.title)
                    .font(.subheadline)
                    .strikethrough(data.status == .completed)
                    .foregroundStyle(data.status == .completed ? .secondary : .primary)

                if data.priority != .none {
                    Text(data.priority.displayName)
                        .font(.caption2)
                        .foregroundStyle(priorityColor)
                }
            }

            Spacer()

            if let due = data.dueDate {
                Text(due, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        // `"\(title), \(done ? "completed" : "pending")"` extracts as `%@, %@`: both halves are
        // placeholders, so neither word ever reaches a translator.
        .accessibilityLabel(data.status == .completed
            ? String(localized: "calendar.day.task.a11y.completed",
                     defaultValue: "\(data.title), completed",
                     comment: "VoiceOver label for a task row in the calendar's day list when the task is done. The placeholder is the user-entered task title.")
            : String(localized: "calendar.day.task.a11y.pending",
                     defaultValue: "\(data.title), pending",
                     comment: "VoiceOver label for a task row in the calendar's day list when the task is not done yet. The placeholder is the user-entered task title."))
    }

    private var priorityColor: Color {
        data.priority.color
    }
}
