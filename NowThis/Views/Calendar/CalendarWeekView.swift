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
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 8) {
            // Week navigation
            weekHeader

            // Day columns
            HStack(alignment: .top, spacing: 4) {
                ForEach(weekDates, id: \.self) { date in
                    WeekDayColumn(
                        date: date,
                        isToday: Calendar.current.isDateInToday(date),
                        isSelected: Calendar.current.isDate(date, inSameDayAs: selectedDate),
                        tasks: tasksForDay(date),
                        overdueTasks: Calendar.current.isDateInToday(date) ? overdueTasks : []
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

            if let first = weekDates.first, let last = weekDates.last {
                Text("\(first, format: .dateTime.month(.abbreviated).day()) – \(last, format: .dateTime.month(.abbreviated).day())")
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

    private func tasksForDay(_ date: Date) -> [TaskItem] {
        return tasks.filter { task in
            guard let due = task.dueDate else { return false }
            return DueDateHelper.isOnDay(due, isDateOnly: task.isDueDateOnly, sameAs: date)
                && task.status != .completed
        }
    }

    private var overdueTasks: [TaskItem] {
        return tasks.filter { task in
            guard let due = task.dueDate else { return false }
            return DueDateHelper.isOverdue(dueDate: due, isDateOnly: task.isDueDateOnly)
                && task.status != .completed
                && task.status != .cancelled
        }
    }

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
            guard let task = tasks.first(where: { $0.id == id }) else { continue }
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
        try? modelContext.save()
    }
}

// MARK: - Week Day Column

private struct WeekDayColumn: View {
    let date: Date
    let isToday: Bool
    let isSelected: Bool
    let tasks: [TaskItem]
    let overdueTasks: [TaskItem]

    var body: some View {
        VStack(spacing: 4) {
            // Day label
            VStack(spacing: 1) {
                Text(date, format: .dateTime.weekday(.narrow))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Text("\(Calendar.current.component(.day, from: date))")
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
                VStack(spacing: 3) {
                    // Overdue tasks (today only)
                    ForEach(overdueTasks) { task in
                        WeekTaskBlock(task: task, isOverdue: true)
                            .draggable(task.id)
                    }

                    // Regular tasks
                    ForEach(tasks) { task in
                        WeekTaskBlock(task: task, isOverdue: false)
                            .draggable(task.id)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(date, format: .dateTime.weekday(.wide)), \(tasks.count + overdueTasks.count) tasks")
    }
}

// MARK: - Week Task Block

private struct WeekTaskBlock: View {
    let task: TaskItem
    let isOverdue: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isOverdue {
                Rectangle()
                    .fill(.red)
                    .frame(width: 3)
            }

            Text(task.title)
                .font(.system(size: 9))
                .lineLimit(2)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(priorityColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title)\(isOverdue ? ", overdue" : "")")
    }

    private var priorityColor: Color {
        task.priority == .none ? .gray : task.priority.color
    }
}
