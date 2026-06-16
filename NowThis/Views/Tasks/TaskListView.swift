import SwiftUI
import SwiftData

/// Displays tasks for a selected sidebar item — either a smart list filter
/// or a specific user task list.
///
/// Features:
/// - `.searchable` full-text search
/// - Sort options (due date, priority, title, created, modified)
/// - Filter chips (completed, priority)
/// - Smart empty states per list type
/// - Pull-to-refresh sync trigger
/// - Row animations on insert/delete
struct TaskListView: View {

    let selection: SidebarSelection
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncScheduler: SyncScheduler
    static let activeTasksPredicate = #Predicate<TaskItem> { !$0.isDeletedLocally }
    @Query(filter: Self.activeTasksPredicate) private var allTasks: [TaskItem]
    @State private var showingQuickAdd = false
    @State private var selectedTask: TaskItem?
    @State private var searchText = ""
    @State private var activeSort: TaskSortOption = .dueDate
    @State private var sortDirection: SortDirection = .ascending
    @State private var showCompleted = false
    @State private var priorityFilter: TaskPriority?

    @AppStorage("upcomingGrouping") private var upcomingGrouping = "weekly"

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(
                activeSort: $activeSort,
                sortDirection: $sortDirection,
                showCompleted: $showCompleted,
                priorityFilter: $priorityFilter
            )

            Divider().opacity(0.5)

            Group {
                if currentSmartList == .upcoming || currentSmartList == .overdue {
                    let sections = sectionedOccurrences
                    if sections.isEmpty {
                        EmptyTasksView(
                            smartList: currentSmartList,
                            hasSearch: !searchText.isEmpty
                        )
                    } else {
                        SectionedTaskListContent(
                            sections: sections,
                            onSelect: { selectedTask = $0 },
                            showGroupingToggle: currentSmartList == .upcoming,
                            grouping: $upcomingGrouping
                        )
                    }
                } else if displayedTasks.isEmpty {
                    EmptyTasksView(
                        smartList: currentSmartList,
                        hasSearch: !searchText.isEmpty
                    )
                } else {
                    TasksListContent(
                        tasks: displayedTasks,
                        onSelect: { selectedTask = $0 }
                    )
                }
            }
            .refreshable {
                await syncScheduler.syncNow(modelContext: modelContext)
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "Search tasks…")
        .toolbar { TaskListToolbar(onAdd: { showingQuickAdd = true }) }
        .sheet(isPresented: $showingQuickAdd) {
            QuickAddView(defaultList: defaultTaskList)
        }
        .sheet(item: $selectedTask) { task in
            NavigationStack {
                TaskDetailView(task: task)
            }
        }
    }

    // MARK: - Computed Properties

    private var title: String {
        switch selection {
        case .smart(let smart): return smart.rawValue
        case .taskList(let listID):
            let targetID = listID
            let p = #Predicate<TaskList> { $0.id == targetID }
            var desc = FetchDescriptor<TaskList>(predicate: p)
            desc.fetchLimit = 1
            return (try? modelContext.fetch(desc))?.first?.name ?? "Tasks"
        case .savedFilter(let filterID):
            let targetID = filterID
            let p = #Predicate<SavedFilter> { $0.id == targetID }
            var desc = FetchDescriptor<SavedFilter>(predicate: p)
            desc.fetchLimit = 1
            return (try? modelContext.fetch(desc))?.first?.name ?? "Filter"
        case .tag(let tagID):
            let targetID = tagID
            let p = #Predicate<Tag> { $0.id == targetID }
            var desc = FetchDescriptor<Tag>(predicate: p)
            desc.fetchLimit = 1
            return (try? modelContext.fetch(desc))?.first?.name ?? "Tag"
        case .journals:
            return "Journals"
        }
    }

    private var currentSmartList: SmartList? {
        if case .smart(let list) = selection { return list }
        return nil
    }

    /// Pipeline: all tasks → non-deleted → root only → smart/list filter
    /// → search → priority → completed → sort
    private var displayedTasks: [TaskItem] {
        // isDeletedLocally is already filtered by @Query predicate
        var result = allTasks.filter { $0.parentTask == nil }

        // Smart list, task list, or saved filter
        switch selection {
        case .smart(let smart):
            result = filterForSmartList(smart, from: result)
        case .taskList(let listID):
            result = result.filter { $0.taskList?.id == listID }
        case .savedFilter(let filterID):
            result = applyCustomFilter(filterID, to: result)
        case .tag(let tagID):
            result = result.filter { $0.tags.contains(where: { $0.id == tagID }) }
        case .journals:
            return [] // Journals handled by JournalListView
        }

        // Full-text search
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { task in
                task.title.lowercased().contains(query)
                    || (task.descriptionText?.lowercased().contains(query) ?? false)
                    || (task.locationName?.lowercased().contains(query) ?? false)
                    || task.tags.contains(where: { $0.name.lowercased().contains(query) })
            }
        }

        // Priority filter
        if let pri = priorityFilter {
            result = result.filter { $0.priority == pri }
        }

        // Completed filter (for non-smart lists, default hide completed)
        if currentSmartList != .completed && !showCompleted {
            result = result.filter { $0.status != .completed }
        }

        // Sort
        result.sort(by: activeSort.comparator(ascending: sortDirection.isAscending))

        // Deduplicate by UID (safety net for overlapping calendar sync)
        result = TaskListHelpers.deduplicateByUID(result)

        return result
    }

    // MARK: - Smart List Filters

    private func filterForSmartList(
        _ smartList: SmartList,
        from tasks: [TaskItem]
    ) -> [TaskItem] {
        let now = Date()
        let endOfWeek = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now

        switch smartList {
        case .today:
            return tasks.filter { task in
                guard let due = task.dueDate else { return false }
                return TaskListFilter.shouldIncludeInToday(
                    dueDate: due,
                    isDueDateOnly: task.isDueDateOnly,
                    isCompleted: task.status == .completed,
                    now: now
                )
            }
        case .upcoming:
            // Upcoming uses the expanded sectioned view, but flat filter
            // still needed for displayedTasks fallback and counts
            return tasks.filter { task in
                guard task.status != .completed else { return false }
                guard let due = task.dueDate else { return false }
                return due >= now && due <= endOfWeek
            }
        case .overdue:
            return tasks.filter { task in
                guard task.status != .completed else { return false }
                guard let due = task.dueDate else { return false }
                return DueDateHelper.isOverdue(dueDate: due, isDateOnly: task.isDueDateOnly)
            }
        case .all:
            return tasks.filter { $0.status != .completed }
        case .completed:
            return tasks.filter { $0.status == .completed }
        }
    }

    /// Applies a saved custom filter's rules to the task list.
    private func applyCustomFilter(_ filterID: String, to tasks: [TaskItem]) -> [TaskItem] {
        let targetID = filterID
        let filterPredicate = #Predicate<SavedFilter> { $0.id == targetID }
        var filterDesc = FetchDescriptor<SavedFilter>(predicate: filterPredicate)
        filterDesc.fetchLimit = 1
        guard let savedFilter = (try? modelContext.fetch(filterDesc))?.first else { return tasks }

        let rules = savedFilter.rules
        guard !rules.isEmpty else { return tasks }

        // Only fetch lists if a rule actually needs them
        let needsLists = rules.contains { $0.field == .list }
        let lists: [TaskList] = needsLists
            ? ((try? modelContext.fetch(FetchDescriptor<TaskList>())) ?? [])
            : []

        return tasks.filter { task in
            switch savedFilter.logic {
            case .and:
                return rules.allSatisfy { $0.matches(task, allLists: lists) }
            case .or:
                return rules.contains { $0.matches(task, allLists: lists) }
            }
        }
    }

    private var defaultTaskList: TaskList? {
        if case .taskList(let listID) = selection {
            let targetID = listID
            let listPredicate = #Predicate<TaskList> { $0.id == targetID }
            var desc = FetchDescriptor<TaskList>(predicate: listPredicate)
            desc.fetchLimit = 1
            return (try? modelContext.fetch(desc))?.first
        }
        var desc = FetchDescriptor<TaskList>()
        desc.fetchLimit = 1
        return (try? modelContext.fetch(desc))?.first
    }

    // MARK: - Sectioned Occurrences (Upcoming / Overdue)

    /// Expands recurring tasks into individual occurrences and groups by time period.
    private var sectionedOccurrences: [TaskSection] {
        guard let smartList = currentSmartList,
              (smartList == .upcoming || smartList == .overdue) else { return [] }

        // Start from all root, non-deleted, non-completed tasks
        var baseTasks = allTasks.filter { $0.parentTask == nil && $0.status != .completed }

        // Apply search filter
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            baseTasks = baseTasks.filter { task in
                task.title.lowercased().contains(query)
                    || (task.descriptionText?.lowercased().contains(query) ?? false)
            }
        }

        // Apply priority filter
        if let pri = priorityFilter {
            baseTasks = baseTasks.filter { $0.priority == pri }
        }

        // Deduplicate by UID
        baseTasks = TaskListHelpers.deduplicateByUID(baseTasks)

        let now = Date()
        let cal = Calendar.current
        var occurrences: [TaskOccurrence] = []

        if smartList == .upcoming {
            // Upcoming: 4 weeks out
            let cutoff = cal.date(byAdding: .day, value: 28, to: now) ?? now

            for task in baseTasks {
                guard let due = task.dueDate, due >= now else { continue }

                // The task's own due date (if within window)
                if due <= cutoff {
                    occurrences.append(TaskOccurrence(task: task, occurrenceDate: due))
                }

                // Expand recurring occurrences
                if let rrule = task.recurrenceRule,
                   let rule = RecurrenceRule.parse(rrule) {
                    let futureDates = rule.nextDates(after: due, through: cutoff)
                    for date in futureDates {
                        occurrences.append(TaskOccurrence(task: task, occurrenceDate: date))
                    }
                }
            }

            occurrences.sort { $0.occurrenceDate < $1.occurrenceDate }
            return groupOccurrences(occurrences, by: upcomingGrouping == "weekly" ? .weekOfYear : .month, calendar: cal)

        } else {
            // Overdue: group by month going back
            for task in baseTasks {
                guard let due = task.dueDate else { continue }
                guard DueDateHelper.isOverdue(dueDate: due, isDateOnly: task.isDueDateOnly) else { continue }

                occurrences.append(TaskOccurrence(task: task, occurrenceDate: due))

                // Expand missed recurring occurrences between original due and now
                if let rrule = task.recurrenceRule,
                   let rule = RecurrenceRule.parse(rrule) {
                    let missedDates = rule.nextDates(after: due, through: now, limit: 12)
                    for date in missedDates where DueDateHelper.isOverdue(dueDate: date, isDateOnly: task.isDueDateOnly) {
                        occurrences.append(TaskOccurrence(task: task, occurrenceDate: date))
                    }
                }
            }

            occurrences.sort { $0.occurrenceDate < $1.occurrenceDate }
            return groupOccurrences(occurrences, by: .month, calendar: cal)
        }
    }

    /// Groups occurrences into titled sections by calendar component.
    private func groupOccurrences(
        _ occurrences: [TaskOccurrence],
        by component: Calendar.Component,
        calendar: Calendar
    ) -> [TaskSection] {
        let grouped = Dictionary(grouping: occurrences) { occurrence -> Date in
            if component == .weekOfYear {
                // Start of the week containing this date
                return calendar.dateInterval(of: .weekOfYear, for: occurrence.occurrenceDate)?.start ?? occurrence.occurrenceDate
            } else {
                // Start of the month
                return calendar.dateInterval(of: .month, for: occurrence.occurrenceDate)?.start ?? occurrence.occurrenceDate
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale.current

        return grouped.keys.sorted().map { key in
            if component == .weekOfYear {
                let end = calendar.date(byAdding: .day, value: 6, to: key) ?? key
                let df = DateFormatter()
                df.dateFormat = "MMM d"
                formatter.dateFormat = "MMM d, yyyy"
                let label = "\(df.string(from: key)) – \(formatter.string(from: end))"
                return TaskSection(title: label, occurrences: grouped[key] ?? [])
            } else {
                formatter.dateFormat = "MMMM yyyy"
                return TaskSection(title: formatter.string(from: key), occurrences: grouped[key] ?? [])
            }
        }
    }
}

// MARK: - Task List Content

private struct TasksListContent: View {
    let tasks: [TaskItem]
    let onSelect: (TaskItem) -> Void

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List {
            ForEach(tasks) { task in
                RecursiveTaskRow(
                    task: task,
                    depth: 0,
                    onSelect: onSelect,
                    onReparent: reparentTask
                )
                .listRowSeparator(.hidden)
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
        }
        .listStyle(.plain)
        .animation(.easeInOut(duration: 0.3), value: tasks.count)
    }

    /// Reparents a dragged task under a new parent (or nil for root).
    private func reparentTask(_ child: TaskItem?, _ newParent: TaskItem?) {
        guard let child = child else { return }
        // Prevent circular references
        guard child.id != newParent?.id else { return }

        child.parentTask = newParent
        child.parentUID = newParent?.uid
        child.lastModifiedDate = Date()
        child.isDirty = true
        HapticManager.softImpact()
        try? modelContext.save()
    }
}

// MARK: - Task Occurrence Model

/// A virtual occurrence of a task at a specific date.
///
/// Used to represent recurring task instances in Upcoming/Overdue views
/// without creating additional database records.
struct TaskOccurrence: Identifiable {
    let task: TaskItem
    let occurrenceDate: Date

    var id: String { "\(task.id)-\(occurrenceDate.timeIntervalSince1970)" }
}

/// A section of task occurrences with a display title (e.g., "Jun 2 – Jun 8, 2026").
struct TaskSection: Identifiable {
    let title: String
    let occurrences: [TaskOccurrence]

    var id: String { title }
}

// MARK: - Sectioned Task List Content

/// Displays task occurrences grouped by time period with section banners.
private struct SectionedTaskListContent: View {
    let sections: [TaskSection]
    let onSelect: (TaskItem) -> Void
    let showGroupingToggle: Bool
    @Binding var grouping: String

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List {
            if showGroupingToggle {
                Picker("Group by", selection: $grouping) {
                    Text("Week").tag("weekly")
                    Text("Month").tag("monthly")
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .padding(.vertical, 4)
            }

            ForEach(sections) { section in
                Section {
                    ForEach(section.occurrences) { occurrence in
                        TaskRowView(task: occurrence.task) {
                            onSelect(occurrence.task)
                        }
                        .accessibilityLabel("\(occurrence.task.title), due \(occurrence.occurrenceDate.formatted(date: .abbreviated, time: .omitted))")
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(section.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
    }
}

/// Recursively renders a task and its subtasks with visual nesting.
///
/// Each depth level adds 24pt indentation. Subtasks are shown in a
/// collapsible group with a chevron toggle. Supports drag-to-indent
/// (drop onto a task to make it a child) and drag-out to un-indent.
/// Supports infinite nesting per the TRD requirements.
private struct RecursiveTaskRow: View {
    let task: TaskItem
    let depth: Int
    let onSelect: (TaskItem) -> Void
    var onReparent: ((TaskItem, TaskItem?) -> Void)?

    @State private var isExpanded = true

    private var activeSubtasks: [TaskItem] {
        task.subtasks.filter { !$0.isDeletedLocally }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                // Collapse/expand chevron
                if !activeSubtasks.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.2), value: isExpanded)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse subtasks" : "Expand subtasks")
                } else {
                    // Spacer to align rows without subtasks
                    Color.clear.frame(width: 16, height: 16)
                }

                TaskRowView(task: task) {
                    onSelect(task)
                }
            }
            .padding(.leading, CGFloat(depth) * 24)
            .draggable(task.id) // Enable drag-to-indent
            .dropDestination(for: String.self) { droppedIDs, _ in
                guard let droppedID = droppedIDs.first,
                      droppedID != task.id,
                      let droppedTask = findTask(id: droppedID) else { return false }
                onReparent?(droppedTask, task)
                return true
            }

            // Subtasks (collapsible)
            if isExpanded && !activeSubtasks.isEmpty {
                ForEach(activeSubtasks) { subtask in
                    RecursiveTaskRow(
                        task: subtask,
                        depth: depth + 1,
                        onSelect: onSelect,
                        onReparent: onReparent
                    )
                }
            }
        }
    }

    /// Traverses the hierarchy to find a task by ID.
    private func findTask(id: String) -> TaskItem? {
        if task.id == id { return task }
        for subtask in activeSubtasks {
            if subtask.id == id { return subtask }
        }
        return nil
    }
}

// MARK: - Smart Empty States

private struct EmptyTasksView: View {
    let smartList: SmartList?
    let hasSearch: Bool

    var body: some View {
        if hasSearch {
            SearchEmptyState()
        } else if let smart = smartList {
            SmartListEmptyState(smartList: smart)
        } else {
            GenericEmptyState()
        }
    }
}

private struct SearchEmptyState: View {
    var body: some View {
        ContentUnavailableView.search
    }
}

private struct SmartListEmptyState: View {
    let smartList: SmartList

    var body: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: smartList.icon)
        } description: {
            Text(emptyDescription)
        }
    }

    private var emptyTitle: String {
        switch smartList {
        case .today: return "All Clear Today"
        case .upcoming: return "Nothing Upcoming"
        case .overdue: return "Nothing Overdue"
        case .all: return "No Tasks"
        case .completed: return "No Completed Tasks"
        }
    }

    private var emptyDescription: String {
        switch smartList {
        case .today: return "You have no tasks due today. Enjoy your day!"
        case .upcoming: return "No tasks due in the next 7 days."
        case .overdue: return "Great job — you're all caught up!"
        case .all: return "Tap the + button to add your first task."
        case .completed: return "Completed tasks will appear here."
        }
    }
}

private struct GenericEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Tasks", systemImage: "checkmark.circle")
        } description: {
            Text("Tap the + button to add your first task.")
        }
    }
}

// MARK: - Toolbar

private struct TaskListToolbar: ToolbarContent {
    let onAdd: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
            .accessibilityLabel("Add task")
        }
    }
}
