import SwiftUI
import SwiftData

/// Month grid view showing tasks by due date as colored priority dots.
///
/// Uses a `LazyVGrid` with 7 columns (Sun–Sat). Each day cell shows
/// a dot colored by the highest-priority task due that day.
/// Today is highlighted with an accent ring. Tapping a date selects it.
/// Supports drag-to-reschedule: drop a task on a date cell to update its due date.
struct CalendarMonthView: View {

    /// The fixed grid position is the identity. The label or date can change in that position.
    struct Slot<Value>: Identifiable {
        let id: Int
        let value: Value
    }

    let tasks: [TaskItem]
    @Binding var selectedDate: Date
    @Binding var displayedMonth: Date
    let projection: CalendarTaskProjection
    @Environment(\.modelContext) private var modelContext
    @Environment(\.saveErrorState) private var errorState

    private let columns = Array(repeating: GridItem(.flexible()), count: 7)

    /// The seven column headers, **rotated to start on the calendar's first weekday**.
    ///
    /// `veryShortWeekdaySymbols` is always Sunday-first, whatever the locale, while the day grid
    /// below offsets by `firstWeekday`. Rendering the symbols unrotated therefore put every date
    /// under the wrong column in any Monday-first region — de, es, fr, it and nl all have
    /// `firstWeekday == 2`, and so does en-GB, so this was already wrong before any translation.
    ///
    /// Computed rather than stored: a stored property is evaluated once at init and would not
    /// follow a region change made while the app is running.
    static func weekdayHeaderSymbols(for calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    /// How many blank cells precede the 1st of `month` in the grid. Shared with the header so the
    /// two cannot drift: the guard asserts the column they agree on.
    static func leadingEmptyCells(before firstOfMonth: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let leading = weekday - calendar.firstWeekday
        return leading < 0 ? leading + 7 : leading
    }

    static func weekdayHeaderSlots(for calendar: Calendar) -> [Slot<String>] {
        weekdayHeaderSymbols(for: calendar).enumerated().map { Slot(id: $0.offset, value: $0.element) }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Month navigation header
            monthHeader

            // Weekday labels
            weekdayRow

            // Day grid
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Self.monthSlots(for: displayedMonth, calendar: .current)) { slot in
                    if let day = slot.value {
                        let bucket = projection.bucket(on: day)
                        DayCell(
                            date: day,
                            isToday: Calendar.current.isDateInToday(day),
                            isSelected: Calendar.current.isDate(day, inSameDayAs: selectedDate),
                            highestPriority: bucket.highestPriority,
                            taskCount: bucket.rows.count
                        )
                        .onTapGesture {
                            selectedDate = day
                        }
                        .dropDestination(for: String.self) { droppedIDs, _ in
                            CalendarTaskRescheduling.drop(taskIDs: droppedIDs, to: day, among: tasks,
                                                          in: modelContext, errorState: errorState)
                        }
                        .id(Calendar.current.startOfDay(for: day))
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
            ForEach(Self.weekdayHeaderSlots(for: .current)) { slot in
                Text(slot.value)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Data

    static func monthSlots(for month: Date, calendar: Calendar) -> [Slot<Date?>] {
        guard let range = calendar.range(of: .day, in: .month, for: month),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: month))
        else { return [] }

        var days: [Date?] = Array(repeating: nil,
                                  count: Self.leadingEmptyCells(before: firstOfMonth,
                                                                calendar: calendar))
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) {
                days.append(date)
            }
        }
        return days.enumerated().map { Slot(id: $0.offset, value: $0.element) }
    }

    private func advanceMonth(by value: Int) {
        if let newMonth = Calendar.current.date(byAdding: .month, value: value, to: displayedMonth) {
            MotionManager.withAccessibleAnimation(.easeInOut(duration: 0.2)) {
                displayedMonth = newMonth
            }
        }
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
            Text(Calendar.current.component(.day, from: date), format: .number)
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
            label += String(localized: "calendar.month.cell.a11y.taskCount", defaultValue: ", \(taskCount) tasks",
                             comment: "Calendar month cell accessibility label fragment appended after the date, stating how many tasks fall on this day. Leading comma-space continues the spoken label. The plural forms are in the catalog.")
        }
        if isToday {
            label += String(localized: "calendar.month.cell.a11y.today", defaultValue: ", today",
                             comment: "Calendar month cell accessibility label fragment appended after the date to mark the current day. Leading comma-space continues the spoken label.")
        }
        return label
    }

    private func priorityColor(_ priority: TaskPriority) -> Color {
        priority == .none ? .gray : priority.color
    }
}
