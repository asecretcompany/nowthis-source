import SwiftUI

/// Detail view showing all tasks due on a specific date.
///
/// Includes an overdue carry-forward section at the top for past-due
/// incomplete tasks, followed by tasks due on the selected day.
struct CalendarDayDetailView: View {

    let date: Date
    let projection: CalendarTaskProjection

    var body: some View {
        let sections = projection.sections(on: date)
        let overdueTasks = sections.overdue
        let dueTasks = sections.due
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
    }
}

// MARK: - Overdue Task Row

struct OverdueTaskRow: View {
    let data: TaskGlanceData

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: data.title)
                    .font(.subheadline)

                if let dueLabel = dueDateLabel() {
                    Text("Due \(dueLabel)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(data.title), overdue")
        .accessibilityValue(data.spokenAllDayDueDate() ?? "")
    }

    func dueDateLabel(timeZone: TimeZone = .current) -> String? {
        guard let due = data.dueDate else { return nil }
        if data.isDueDateOnly {
            return DueDateFormatter.format(due, isDateOnly: data.isDueDateOnly, timeZone: timeZone)
        }
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return due.formatted(Date.RelativeFormatStyle(presentation: .named, calendar: calendar))
    }
}

// MARK: - Day Task Row

struct DayTaskRow: View {
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

            if let dueLabel = dueDateLabel() {
                Text(dueLabel)
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
        .accessibilityValue(data.spokenAllDayDueDate() ?? "")
    }

    func dueDateLabel(timeZone: TimeZone = .current) -> String? {
        data.dueDate.map {
            DueDateFormatter.format($0, isDateOnly: data.isDueDateOnly, timeZone: timeZone,
                                    timedStyle: .dateTime.hour().minute())
        }
    }

    private var priorityColor: Color {
        data.priority.color
    }
}
