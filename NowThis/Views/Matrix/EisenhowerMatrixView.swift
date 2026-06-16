import SwiftUI
import SwiftData

/// Eisenhower Matrix view — a 2×2 grid organizing tasks by urgency × importance.
///
/// Quadrants:
/// - Q1 (Do First): High priority + due within 3 days or overdue
/// - Q2 (Schedule): High priority + due later or no due date
/// - Q3 (Delegate): Lower priority + due within 3 days or overdue
/// - Q4 (Eliminate): Lower priority + due later or no due date
struct EisenhowerMatrixView: View {

    static let activeTasksPredicate = #Predicate<TaskItem> { !$0.isDeletedLocally }
    @Query(filter: Self.activeTasksPredicate) private var allTasks: [TaskItem]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncScheduler: SyncScheduler
    @State private var selectedTask: TaskItem?

    private let urgencyThresholdDays = 3

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let quadrants = classifyTasks()
                let cellWidth = (geo.size.width - 36) / 2  // 12 padding each side + 12 gap
                let cellHeight = (geo.size.height - 36) / 2

                VStack(spacing: 12) {
                    // Row labels
                    HStack(spacing: 12) {
                        QuadrantCell(
                            quadrant: .doFirst,
                            tasks: quadrants.doFirst,
                            width: cellWidth,
                            height: cellHeight,
                            onSelect: { selectedTask = $0 }
                        )
                        QuadrantCell(
                            quadrant: .schedule,
                            tasks: quadrants.schedule,
                            width: cellWidth,
                            height: cellHeight,
                            onSelect: { selectedTask = $0 }
                        )
                    }
                    HStack(spacing: 12) {
                        QuadrantCell(
                            quadrant: .delegate,
                            tasks: quadrants.delegate,
                            width: cellWidth,
                            height: cellHeight,
                            onSelect: { selectedTask = $0 }
                        )
                        QuadrantCell(
                            quadrant: .eliminate,
                            tasks: quadrants.eliminate,
                            width: cellWidth,
                            height: cellHeight,
                            onSelect: { selectedTask = $0 }
                        )
                    }
                }
                .padding(12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Matrix")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await syncScheduler.syncNow(modelContext: modelContext)
            }
            .sheet(item: $selectedTask) { task in
                NavigationStack {
                    TaskDetailView(task: task)
                }
            }
        }
    }

    // MARK: - Classification

    private struct ClassifiedTasks {
        var doFirst: [TaskItem] = []
        var schedule: [TaskItem] = []
        var delegate: [TaskItem] = []
        var eliminate: [TaskItem] = []
    }

    private func classifyTasks() -> ClassifiedTasks {
        let activeTasks = allTasks.filter { task in
            task.parentTask == nil
                && task.status != .completed
                && task.status != .cancelled
        }

        let now = Date()
        let threshold = Calendar.current.date(
            byAdding: .day, value: urgencyThresholdDays, to: now
        ) ?? now

        var result = ClassifiedTasks()

        for task in activeTasks {
            let isImportant = task.priority == .high
            let isUrgent: Bool = {
                guard let due = task.dueDate else { return false }
                return due <= threshold
                    || DueDateHelper.isOverdue(dueDate: due, isDateOnly: task.isDueDateOnly)
            }()

            switch (isImportant, isUrgent) {
            case (true, true):   result.doFirst.append(task)
            case (true, false):  result.schedule.append(task)
            case (false, true):  result.delegate.append(task)
            case (false, false): result.eliminate.append(task)
            }
        }

        // Sort each quadrant by due date (soonest first), then by title
        let sortByDue: (TaskItem, TaskItem) -> Bool = { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (d1?, d2?): return d1 < d2
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.title < b.title
            }
        }

        result.doFirst.sort(by: sortByDue)
        result.schedule.sort(by: sortByDue)
        result.delegate.sort(by: sortByDue)
        result.eliminate.sort(by: sortByDue)

        return result
    }
}

// MARK: - Quadrant Definition

private enum Quadrant {
    case doFirst, schedule, delegate, eliminate

    var title: String {
        switch self {
        case .doFirst:  return "Do First"
        case .schedule: return "Schedule"
        case .delegate: return "Delegate"
        case .eliminate: return "Eliminate"
        }
    }

    var emoji: String {
        switch self {
        case .doFirst:  return "🔥"
        case .schedule: return "📅"
        case .delegate: return "🤝"
        case .eliminate: return "🗑️"
        }
    }

    var tintColor: Color {
        switch self {
        case .doFirst:  return .red
        case .schedule: return .blue
        case .delegate: return .orange
        case .eliminate: return .secondary
        }
    }

    var subtitle: String {
        switch self {
        case .doFirst:  return "Urgent & Important"
        case .schedule: return "Important, Not Urgent"
        case .delegate: return "Urgent, Not Important"
        case .eliminate: return "Neither"
        }
    }
}

// MARK: - Quadrant Cell

private struct QuadrantCell: View {
    let quadrant: Quadrant
    let tasks: [TaskItem]
    let width: CGFloat
    let height: CGFloat
    let onSelect: (TaskItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text(quadrant.emoji)
                    .font(.caption)
                Text(quadrant.title)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(quadrant.tintColor)
                Spacer()
                Text("\(tasks.count)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Text(quadrant.subtitle)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 10)

            // Task list
            if tasks.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("None")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                    Spacer()
                }
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(tasks) { task in
                            MatrixTaskRow(task: task, tintColor: quadrant.tintColor) {
                                onSelect(task)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: width, height: height)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(quadrant.tintColor.opacity(0.15), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(quadrant.title), \(tasks.count) task\(tasks.count == 1 ? "" : "s")")
    }
}

// MARK: - Matrix Task Row

private struct MatrixTaskRow: View {
    let task: TaskItem
    let tintColor: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tintColor.opacity(0.6))
                    .frame(width: 5, height: 5)

                Text(task.title)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Spacer(minLength: 2)

                if let due = task.dueDate {
                    Text(due, format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 9))
                        .foregroundStyle(
                            DueDateHelper.isOverdue(dueDate: due, isDateOnly: task.isDueDateOnly)
                                ? .red : .secondary
                        )
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.title)
        .accessibilityHint("Double tap to open task details")
    }
}
