import WidgetKit
import SwiftUI
import SwiftData

/// The main NowThis widget bundle providing small, medium, and large task widgets.
@main
struct NowThisWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowThisTaskWidget()
    }
}

// MARK: - Timeline Entry

/// A single snapshot of task data for the widget timeline.
struct TaskWidgetEntry: TimelineEntry {
    let date: Date
    let tasks: [WidgetTaskItem]
    let listName: String
}

/// Lightweight task representation for widget rendering.
///
/// This avoids pulling the full SwiftData `TaskItem` into the widget view,
/// keeping the widget extension memory-efficient.
struct WidgetTaskItem: Identifiable {
    let id: String
    let title: String
    let isCompleted: Bool
    let priority: TaskPriority
    let dueDate: Date?
    let isDueDateOnly: Bool
    let listName: String
}

// MARK: - Timeline Provider

/// Provides task data snapshots for widget timeline rendering.
///
/// Uses the shared App Group `ModelContainer` to read tasks from the same
/// SwiftData store as the main app. Filters by the user's selected lists
/// from the `SelectListsIntent` configuration.
struct TaskIntentTimelineProvider: AppIntentTimelineProvider {

    func placeholder(in context: Context) -> TaskWidgetEntry {
        TaskWidgetEntry(
            date: Date(),
            tasks: [
                WidgetTaskItem(id: "1", title: "Plan your day", isCompleted: false, priority: .high, dueDate: Date(), isDueDateOnly: false, listName: "Inbox"),
                WidgetTaskItem(id: "2", title: "Check messages", isCompleted: false, priority: .medium, dueDate: nil, isDueDateOnly: false, listName: "Inbox"),
                WidgetTaskItem(id: "3", title: "Review notes", isCompleted: true, priority: .none, dueDate: nil, isDueDateOnly: false, listName: "Inbox")
            ],
            listName: "Inbox"
        )
    }

    func snapshot(for configuration: SelectListsIntent, in context: Context) async -> TaskWidgetEntry {
        await fetchEntry(for: configuration, maxTasks: maxTasks(for: context.family))
    }

    func timeline(for configuration: SelectListsIntent, in context: Context) async -> Timeline<TaskWidgetEntry> {
        let entry = await fetchEntry(for: configuration, maxTasks: maxTasks(for: context.family))

        // Refresh every 15 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    // MARK: - Private

    private func maxTasks(for family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall: return 3
        case .systemMedium: return 5
        case .systemLarge: return 10
        default: return 3
        }
    }

    @MainActor
    private func fetchEntry(for configuration: SelectListsIntent, maxTasks: Int) -> TaskWidgetEntry {
        do {
            let container = try SharedModelContainer.create()
            let listIDs = configuration.selectedLists.map(\.id)

            let result = try SelectListsIntent.fetchFilteredTasks(
                listIDs: listIDs,
                maxTasks: maxTasks,
                showOverdue: configuration.showOverdue,
                container: container
            )

            let widgetTasks = result.tasks.map { task in
                WidgetTaskItem(
                    id: task.id,
                    title: task.title,
                    isCompleted: task.isCompleted,
                    priority: task.priority,
                    dueDate: task.dueDate,
                    isDueDateOnly: task.isDueDateOnly,
                    listName: task.listName
                )
            }

            return TaskWidgetEntry(
                date: Date(),
                tasks: widgetTasks,
                listName: result.displayName
            )
        } catch {
            return TaskWidgetEntry(date: Date(), tasks: [], listName: "Tasks")
        }
    }
}

// MARK: - Widget Configuration

/// The NowThis task widget supporting small, medium, and large sizes.
///
/// Users can long-press the widget → Edit Widget to select which task lists
/// appear. Defaults to showing all lists.
struct NowThisTaskWidget: Widget {
    let kind = "com.asecretcompany.nowthis.widget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectListsIntent.self, provider: TaskIntentTimelineProvider()) { entry in
            TaskWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("NowThis Tasks")
        .description("View your tasks due today at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Widget View

/// The main widget view that adapts layout to the widget family size.
struct TaskWidgetView: View {
    let entry: TaskWidgetEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Small Widget

/// Compact view showing next 3 due tasks.
private struct SmallWidgetView: View {
    let entry: TaskWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checklist")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .widgetAccentable()
                Text("NowThis")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            if entry.tasks.isEmpty {
                Spacer()
                Text("All caught up! 🎉")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.tasks.prefix(3)) { task in
                    SmallTaskRow(task: task)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SmallTaskRow: View {
    let task: WidgetTaskItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(task.isCompleted ? .green : task.priority.color)

            Text(task.title)
                .font(.caption)
                .lineLimit(1)
                .strikethrough(task.isCompleted)
                .foregroundStyle(task.isCompleted ? .secondary : .primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title), \(task.isCompleted ? "completed" : "pending")")
    }
}

// MARK: - Medium Widget

/// List view with interactive checkboxes (tap-to-complete via AppIntent).
private struct MediumWidgetView: View {
    let entry: TaskWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "checklist")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .widgetAccentable()
                Text(entry.listName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(entry.tasks.filter { !$0.isCompleted }.count) pending")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if entry.tasks.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("No tasks — enjoy your free time! ☀️")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            } else {
                ForEach(entry.tasks.prefix(5)) { task in
                    MediumTaskRow(task: task)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct MediumTaskRow: View {
    let task: WidgetTaskItem

    var body: some View {
        Button(intent: CompleteTaskIntent(task: TaskEntity(
            id: task.id,
            title: task.title,
            isCompleted: task.isCompleted,
            listName: task.listName
        ))) {
            HStack(spacing: 8) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                    .foregroundStyle(task.isCompleted ? .green : task.priority.color)

                Text(task.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)

                Spacer()

                if let due = task.dueDate {
                    Text(due, format: .dateTime.month(.abbreviated).day())
                        .font(.caption2)
                        .foregroundStyle(DueDateHelper.isOverdue(dueDate: due, isDateOnly: task.isDueDateOnly) ? Color.red : Color.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(task.title), \(task.isCompleted ? "completed" : "pending")")
        .accessibilityHint(task.isCompleted ? "Double tap to mark as incomplete" : "Double tap to complete")
    }
}

// MARK: - Large Widget

/// Full task list with priority badges and due dates.
private struct LargeWidgetView: View {
    let entry: TaskWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "checklist")
                    .foregroundStyle(.blue)
                    .widgetAccentable()
                Text(entry.listName)
                    .font(.headline)
                Spacer()
                Text("\(entry.tasks.filter { !$0.isCompleted }.count) pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            if entry.tasks.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.green)
                        Text("All tasks complete!")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                ForEach(entry.tasks.prefix(10)) { task in
                    LargeTaskRow(task: task)
                    if task.id != entry.tasks.last?.id {
                        Divider()
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct LargeTaskRow: View {
    let task: WidgetTaskItem

    var body: some View {
        Button(intent: CompleteTaskIntent(task: TaskEntity(
            id: task.id,
            title: task.title,
            isCompleted: task.isCompleted,
            listName: task.listName
        ))) {
            HStack(spacing: 10) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(task.isCompleted ? .green : task.priority.color)

                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)

                    if let due = task.dueDate {
                        Text(due, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(DueDateHelper.isOverdue(dueDate: due, isDateOnly: task.isDueDateOnly) ? Color.red : Color.secondary)
                    }
                }

                Spacer()

                if task.priority != .none {
                    priorityBadge
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(task.title), \(task.priority != .none ? "\(task.priority.label) priority, " : "")\(task.isCompleted ? "completed" : "pending")")
        .accessibilityHint(task.isCompleted ? "Double tap to mark as incomplete" : "Double tap to complete")
    }

    @ViewBuilder
    private var priorityBadge: some View {
        Text(task.priority.label)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(task.priority.color.opacity(0.15), in: Capsule())
            .foregroundStyle(task.priority.color)
    }
}

// MARK: - Priority Label Extension

private extension TaskPriority {
    var label: String {
        switch self {
        case .high: return "HIGH"
        case .medium: return "MED"
        case .low: return "LOW"
        case .none: return ""
        }
    }
}
