import SwiftUI
import SwiftData

/// Month grid view showing tasks by due date as colored priority dots.
///
/// Uses a `LazyVGrid` with 7 columns (Sun–Sat). Each day cell shows
/// a dot colored by the highest-priority task due that day.
/// Today is highlighted with an accent ring. Tapping a date selects it.
/// Supports drag-to-reschedule: drop a task on a date cell to update its due date.
struct CalendarMonthView: View {

    let tasks: [TaskItem]
    @Binding var selectedDate: Date
    @Binding var displayedMonth: Date
    @Environment(\.modelContext) private var modelContext

    private let columns = Array(repeating: GridItem(.flexible()), count: 7)
    private let weekdaySymbols = Calendar.current.veryShortWeekdaySymbols

    var body: some View {
        VStack(spacing: 12) {
            // Month navigation header
            monthHeader

            // Weekday labels
            weekdayRow

            // Day grid
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(daysInMonth, id: \.self) { day in
                    if let day = day {
                        DayCell(
                            date: day,
                            isToday: Calendar.current.isDateInToday(day),
                            isSelected: Calendar.current.isDate(day, inSameDayAs: selectedDate),
                            highestPriority: highestPriority(for: day),
                            taskCount: taskCount(for: day)
                        )
                        .onTapGesture {
                            selectedDate = day
                        }
                        .dropDestination(for: String.self) { droppedIDs, _ in
                            reschedule(taskIDs: droppedIDs, to: day)
                            return true
                        }
                    } else {
                        // Empty cell for padding
                        Color.clear
                            .frame(height: 40)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Month Header

    private var monthHeader: some View {
        HStack {
            Button {
                advanceMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
            }
            .accessibilityLabel("Previous month")

            Spacer()

            Text(displayedMonth, format: .dateTime.month(.wide).year())
                .font(.headline)

            Spacer()

            Button {
                advanceMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.medium))
            }
            .accessibilityLabel("Next month")
        }
    }

    // MARK: - Weekday Row

    private var weekdayRow: some View {
        HStack {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Data

    /// Generates the array of dates (with nil for empty leading cells).
    private var daysInMonth: [Date?] {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth))
        else { return [] }

        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let leadingEmpties = weekday - calendar.firstWeekday
        let adjustedLeading = leadingEmpties < 0 ? leadingEmpties + 7 : leadingEmpties

        var days: [Date?] = Array(repeating: nil, count: adjustedLeading)
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) {
                days.append(date)
            }
        }
        return days
    }

    private func highestPriority(for date: Date) -> TaskPriority? {
        let dayTasks = tasks.filter { task in
            guard let due = task.dueDate else { return false }
            return DueDateHelper.isOnDay(due, isDateOnly: task.isDueDateOnly, sameAs: date)
        }
        return dayTasks.map(\.priority).filter { $0 != .none }.min()
    }

    private func taskCount(for date: Date) -> Int {
        return tasks.filter { task in
            guard let due = task.dueDate else { return false }
            return DueDateHelper.isOnDay(due, isDateOnly: task.isDueDateOnly, sameAs: date)
        }.count
    }

    private func advanceMonth(by value: Int) {
        if let newMonth = Calendar.current.date(byAdding: .month, value: value, to: displayedMonth) {
            MotionManager.withAccessibleAnimation(.easeInOut(duration: 0.2)) {
                displayedMonth = newMonth
            }
        }
    }

    /// Reschedules tasks to a new date when dropped on a day cell.
    private func reschedule(taskIDs: [String], to newDate: Date) {
        for id in taskIDs {
            guard let task = tasks.first(where: { $0.id == id }) else { continue }
            // Preserve the time-of-day if the task already had a due date
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

// MARK: - Day Cell

private struct DayCell: View {
    let date: Date
    let isToday: Bool
    let isSelected: Bool
    let highestPriority: TaskPriority?
    let taskCount: Int

    var body: some View {
        VStack(spacing: 3) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.subheadline)
                .fontWeight(isToday ? .bold : .regular)
                .foregroundStyle(isSelected ? .white : (isToday ? .accentColor : .primary))
                .frame(width: 32, height: 32)
                .background {
                    if isSelected {
                        Circle().fill(Color.accentColor)
                    } else if isToday {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                }

            // Priority dot
            if let priority = highestPriority {
                Circle()
                    .fill(priorityColor(priority))
                    .frame(width: 5, height: 5)
            } else {
                Color.clear.frame(width: 5, height: 5)
            }
        }
        .frame(height: 40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cellLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var cellLabel: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        var label = formatter.string(from: date)
        if taskCount > 0 {
            label += ", \(taskCount) task\(taskCount == 1 ? "" : "s")"
        }
        if isToday {
            label += ", today"
        }
        return label
    }

    private func priorityColor(_ priority: TaskPriority) -> Color {
        priority == .none ? .gray : priority.color
    }
}
