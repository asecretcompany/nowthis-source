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

    static let activeTasksPredicate = #Predicate<TaskItem> { !$0.isDeletedLocally && $0.parentTask == nil }
    @State private var allTasks: [TaskItem] = []
    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncCommands) private var syncCommands
    @State private var selectedTask: SelectedTask?

    /// The way out when this screen is the hidden-destination sheet rather than a tab.
    ///
    /// The sheet cannot supply it. This view opens on its own `NavigationStack`, so a `.toolbar`
    /// applied at the presentation site has no bar of this view's to land on — and wrapping it in
    /// a second container to give it one is exactly the nesting `-[UINavigationBar layoutSubviews]`
    /// aborts on. Gated on `isPresented`, so the tab that hosts this same view keeps no Done
    /// button. See `NavigationContainerGuardTests`.
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss

    private let urgencyThresholdDays = 3

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let quadrants = classifyTasks()
                // Clamp to 0: during transient layout passes geo.size can be < 36,
                // which would make the cell dimensions negative and trip SwiftUI's
                // "Invalid frame dimension (negative or non-finite)" runtime warning.
                let cellWidth = max(0, (geo.size.width - 36) / 2)  // 12 padding each side + 12 gap
                let cellHeight = max(0, (geo.size.height - 36) / 2)

                VStack(spacing: 12) {
                    // Row labels
                    HStack(spacing: 12) {
                        QuadrantCell(
                            quadrant: .doFirst,
                            tasks: quadrants.doFirst,
                            width: cellWidth,
                            height: cellHeight,
                            onSelect: { selectedTask = SelectedTask($0) }
                        )
                        QuadrantCell(
                            quadrant: .schedule,
                            tasks: quadrants.schedule,
                            width: cellWidth,
                            height: cellHeight,
                            onSelect: { selectedTask = SelectedTask($0) }
                        )
                    }
                    HStack(spacing: 12) {
                        QuadrantCell(
                            quadrant: .delegate,
                            tasks: quadrants.delegate,
                            width: cellWidth,
                            height: cellHeight,
                            onSelect: { selectedTask = SelectedTask($0) }
                        )
                        QuadrantCell(
                            quadrant: .eliminate,
                            tasks: quadrants.eliminate,
                            width: cellWidth,
                            height: cellHeight,
                            onSelect: { selectedTask = SelectedTask($0) }
                        )
                    }
                }
                .padding(12)
            }
            .background(InboundQueryReader(descriptor: FetchDescriptor(predicate: Self.activeTasksPredicate)) { allTasks = $0 })
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Matrix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isPresented {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .refreshable {
                await syncCommands.syncNow(modelContext)
            }
            .sheet(item: $selectedTask) { selection in
                NavigationStack {
                    TaskDetailView(task: selection.task)
                }
            }
        }
    }

    // MARK: - Classification

    private struct ClassifiedTasks {
        var doFirst: [TaskGlanceRow] = []
        var schedule: [TaskGlanceRow] = []
        var delegate: [TaskGlanceRow] = []
        var eliminate: [TaskGlanceRow] = []
    }

    private func classifyTasks() -> ClassifiedTasks {
        // Snapshot first, classify second. Classification reads `priority`,
        // `status` and `dueDate`, so an account delete that cascaded a task away
        // would trap here, before any quadrant row ever ran.
        let activeTasks = TaskListHelpers.liveTasks(allTasks, in: modelContext,
            matching: FetchDescriptor(predicate: Self.activeTasksPredicate)).glanceRows().filter { row in
            row.data.status != .completed
                && row.data.status != .cancelled
                // `parentTask` is a relationship rather than a snapshotted field.
                // Reading it is safe here and only here: `glanceRows()` verified
                // this task's liveness moments ago, in the same synchronous pass.
                && row.task.parentTask == nil
        }

        let now = Date()
        let threshold = Calendar.current.date(
            byAdding: .day, value: urgencyThresholdDays, to: now
        ) ?? now

        var result = ClassifiedTasks()

        for row in activeTasks {
            let isImportant = row.data.priority == .high
            let isUrgent: Bool = {
                guard let due = row.data.dueDate else { return false }
                return due <= threshold
                    || DueDateHelper.isOverdue(dueDate: due, isDateOnly: row.data.isDueDateOnly)
            }()

            switch (isImportant, isUrgent) {
            case (true, true):   result.doFirst.append(row)
            case (true, false):  result.schedule.append(row)
            case (false, true):  result.delegate.append(row)
            case (false, false): result.eliminate.append(row)
            }
        }

        // Sort each quadrant by due date (soonest first), then by title
        let sortByDue: (TaskGlanceRow, TaskGlanceRow) -> Bool = { a, b in
            switch (a.data.dueDate, b.data.dueDate) {
            case let (d1?, d2?): return d1 < d2
            case (_?, nil): return true
            case (nil, _?): return false
            // `<` on String is Unicode code-point order: "Ärzte" sorts after "Zoo" in German,
            // and ñ, é and ij are all misplaced in the other four languages.
            case (nil, nil):
                return a.data.title.localizedStandardCompare(b.data.title) == .orderedAscending
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
        case .doFirst:
            return String(localized: "matrix.quadrant.doFirst.title", defaultValue: "Do First",
                          comment: "Eisenhower Matrix quadrant header (urgent & important) rendered in a tiny .caption cell header — very tight width budget.")
        case .schedule:
            return String(localized: "matrix.quadrant.schedule.title", defaultValue: "Schedule",
                          comment: "Eisenhower Matrix quadrant header (important, not urgent) rendered in a tiny .caption cell header — very tight width budget.")
        case .delegate:
            return String(localized: "matrix.quadrant.delegate.title", defaultValue: "Delegate",
                          comment: "Eisenhower Matrix quadrant header (urgent, not important) rendered in a tiny .caption cell header — very tight width budget.")
        case .eliminate:
            return String(localized: "matrix.quadrant.eliminate.title", defaultValue: "Eliminate",
                          comment: "Eisenhower Matrix quadrant header (neither urgent nor important) rendered in a tiny .caption cell header — very tight width budget.")
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
        case .doFirst:
            return String(localized: "matrix.quadrant.doFirst.subtitle", defaultValue: "Urgent & Important",
                          comment: "Eisenhower Matrix quadrant subtitle explaining the doFirst quadrant, rendered at .system(size: 9) — extremely tight width budget.")
        case .schedule:
            return String(localized: "matrix.quadrant.schedule.subtitle", defaultValue: "Important, Not Urgent",
                          comment: "Eisenhower Matrix quadrant subtitle explaining the schedule quadrant, rendered at .system(size: 9) — extremely tight width budget.")
        case .delegate:
            return String(localized: "matrix.quadrant.delegate.subtitle", defaultValue: "Urgent, Not Important",
                          comment: "Eisenhower Matrix quadrant subtitle explaining the delegate quadrant, rendered at .system(size: 9) — extremely tight width budget.")
        case .eliminate:
            return String(localized: "matrix.quadrant.eliminate.subtitle", defaultValue: "Neither",
                          comment: "Eisenhower Matrix quadrant subtitle for the eliminate quadrant, rendered at .system(size: 9) — extremely tight width budget. Means neither urgent nor important; the word alone is ambiguous out of context.")
        }
    }
}

// MARK: - Quadrant Cell

private struct QuadrantCell: View {
    let quadrant: Quadrant
    let tasks: [TaskGlanceRow]
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
                Text(tasks.count, format: .number)
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
                    Text(verbatim: String(
                        localized: "matrix.quadrant.empty", defaultValue: "None",
                        comment: "Shown inside an Eisenhower Matrix quadrant that holds no tasks. It means 'no tasks', not 'no priority' — the quadrant cell is tiny, so keep it to one short word. Do not share this key with the priority, reminder or location 'None'."))
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                    Spacer()
                }
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(tasks) { row in
                            MatrixTaskRow(data: row.data, tintColor: quadrant.tintColor) {
                                onSelect(row.task)
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
        .accessibilityLabel(String(
            localized: "list.a11y.taskCount",
            defaultValue: "\(quadrant.title), \(tasks.count) tasks",
            comment: "VoiceOver label for a row that names a collection and how many tasks are in it. First placeholder is the name (a list, tag, smart list or board quadrant), second is the count."))
    }
}

// MARK: - Matrix Task Row

private struct MatrixTaskRow: View {
    let data: TaskGlanceData
    let tintColor: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tintColor.opacity(0.6))
                    .frame(width: 5, height: 5)

                Text(verbatim: data.title)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Spacer(minLength: 2)

                if let due = data.dueDate {
                    Text(due, format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 9))
                        .foregroundStyle(
                            DueDateHelper.isOverdue(dueDate: due, isDateOnly: data.isDueDateOnly)
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
        .accessibilityLabel(Text(verbatim: data.title))
        .accessibilityHint("Double tap to open task details")
    }
}
