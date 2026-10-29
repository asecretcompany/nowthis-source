import SwiftUI
import SwiftData

/// Week strip view showing tasks as time blocks across a 7-day horizontal strip.
///
/// Each day is a column containing rounded-rect task blocks positioned by due date.
/// Overdue tasks are pinned to today's column with a red left-border indicator.
/// Swipe left/right to navigate between weeks.
struct CalendarWeekView: View {

    let tasks: [TaskItem]
    @Binding var selectedDate: Date
    @Binding var displayedMonth: Date
    var projection: CalendarTaskProjection? = nil
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        // Snapshot once for the whole strip: seven columns each used to re-walk
        // the task array, and each walk read `dueDate`/`status` off live models.
        let buckets = projection ?? CalendarTaskProjection(rows: tasks.glanceRows())
        let overdueTasks = buckets.overdueRows
        return VStack(spacing: 8) {
            // Week navigation
            weekHeader

            // Day columns
            HStack(alignment: .top, spacing: 4) {
                ForEach(weekDates, id: \.self) { date in
                    WeekDayColumn(
                        date: date,
                        isToday: Calendar.current.isDateInToday(date),
                        isSelected: Calendar.current.isDate(date, inSameDayAs: selectedDate),
                        tasks: buckets.bucket(on: date).rows.filter { $0.data.status != .completed },
                        overdueTasks: buckets.isToday(date) ? overdueTasks : []
                    )
                    .onTapGesture {
                        selectedDate = date
                    }
                    .dropDestination(for: String.self) { droppedIDs, _ in
                        reschedule(taskIDs: droppedIDs, to: date)
                        return true
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .gesture(
            DragGesture(minimumDistance: 50)
                .onEnded { value in
                    if value.translation.width < -50 {
                        advanceWeek(by: 1)
                    } else if value.translation.width > 50 {
                        advanceWeek(by: -1)
                    }
                }
        )
    }

    // MARK: - Week Header

    private var weekHeader: some View {
        HStack {
            Button {
                advanceWeek(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.medium))
            }
            .accessibilityLabel("Previous week")

            Spacer()

            if let first = weekDates.first, let last = weekDates.last, first < last {
                // Two dates and an en dash extracted as the key `%@%@` — one catalog entry shared
                // with every other two-placeholder string in the app, and a separator English
                // chose. `.interval` formats a whole range the way the reader's language does,
                // including whether the month is repeated on the right-hand side.
                Text((first..<last).formatted(.interval.month(.abbreviated).day()))
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Spacer()

            Button {
                advanceWeek(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.medium))
            }
            .accessibilityLabel("Next week")
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Data

    private var weekDates: [Date] {
        let calendar = Calendar.current
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start else {
            return []
        }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    /// Both take already-snapshotted rows: the filters read `dueDate` and
    /// `status`, so against live models they would trap on any task an account
    /// delete had cascaded away before a block ever rendered.
    private func advanceWeek(by value: Int) {
        if let newDate = Calendar.current.date(byAdding: .weekOfYear, value: value, to: selectedDate) {
            MotionManager.withAccessibleAnimation(.easeInOut(duration: 0.2)) {
                selectedDate = newDate
                displayedMonth = newDate
            }
        }
    }

    /// Reschedules tasks to a new date when dropped on a week day column.
    private func reschedule(taskIDs: [String], to newDate: Date) {
        for id in taskIDs {
            guard let task = tasks.first(where: { $0.modelContext != nil && $0.id == id })
            else { continue }
            if let oldDue = task.dueDate {
                let calendar = Calendar.current
                let timeComponents = calendar.dateComponents([.hour, .minute], from: oldDue)
                var newComponents = calendar.dateComponents([.year, .month, .day], from: newDate)
                newComponents.hour = timeComponents.hour
                newComponents.minute = timeComponents.minute
                task.dueDate = calendar.date(from: newComponents) ?? newDate
            } else {
                task.dueDate = newDate
            }
            task.isDirty = true
            task.lastModifiedDate = Date()
        }
        HapticManager.softImpact()
        try? ReminderSchedulingJournal.saveTaskChanges(in: modelContext)
        // The dragged task's already-pending notification is pinned to its old deadline, so
        // without this it alerts at the wrong time and carries a badge count for the wrong day.
        ReminderScheduler.requestReconcile(modelContext: modelContext)
    }
}

// MARK: - Week Day Column

private struct WeekDayColumn: View {
    let date: Date
    let isToday: Bool
    let isSelected: Bool
    let tasks: [TaskGlanceRow]
    let overdueTasks: [TaskGlanceRow]

    var body: some View {
        VStack(spacing: 4) {
            // Day label
            VStack(spacing: 1) {
                Text(date, format: .dateTime.weekday(.narrow))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Text(Calendar.current.component(.day, from: date), format: .number)
                    .font(.caption2)
                    .fontWeight(isToday ? .bold : .regular)
                    .foregroundStyle(isSelected ? .white : .primary)
                    .frame(width: 24, height: 24)
                    .background {
                        if isSelected {
                            Circle().fill(Color.accentColor)
                        } else if isToday {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                        }
                    }
            }

            // Task blocks
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 3) {
                    // Overdue tasks (today only)
                    ForEach(overdueTasks) { row in
                        WeekTaskBlock(data: row.data, isOverdue: true)
                            .draggable(row.id)
                    }

                    // Regular tasks
                    ForEach(tasks) { row in
                        WeekTaskBlock(data: row.data, isOverdue: false)
                            .draggable(row.id)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(
            localized: "calendar.week.a11y.taskCount",
            defaultValue: "\(date, format: .dateTime.weekday(.wide)), \(tasks.count + overdueTasks.count) tasks",
            comment: "VoiceOver label for one day column in the week view. First placeholder is the weekday name, second is how many tasks fall on that day."))
    }
}

// MARK: - Week Task Block

private struct WeekTaskBlock: View {
    let data: TaskGlanceData
    let isOverdue: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isOverdue {
                Rectangle()
                    .fill(.red)
                    .frame(width: 3)
            }

            Text(verbatim: data.title)
                .font(.system(size: 9))
                .lineLimit(2)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(priorityColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .combine)
        // `"\(title)\(flag ? ", overdue" : "")"` extracted as the key `%@%@`: both halves became
        // placeholders, so the word "overdue" was never offered to a translator at all, and the
        // key was shared with every other two-placeholder string.
        .accessibilityLabel(isOverdue
            ? String(localized: "calendar.week.block.a11y.overdue",
                     defaultValue: "\(data.title), overdue",
                     comment: "VoiceOver label for a task block in the week view when the task is past its due date. The placeholder is the user-entered task title.")
            : data.title)
    }

    private var priorityColor: Color {
        data.priority == .none ? .gray : data.priority.color
    }
}
