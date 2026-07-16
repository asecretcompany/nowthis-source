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
    @AppStorage("taskSortOption") private var activeSort: TaskSortOption = .dueDate
    @AppStorage("taskSortDirection") private var sortDirection: SortDirection = .ascending
    @AppStorage("showCompletedTasks") private var showCompleted = false
    @State private var priorityFilter: TaskPriority?

    @AppStorage("upcomingGrouping") private var upcomingGrouping = "weekly"

    @State private var inlineTaskTitle = ""
    @FocusState private var inlineFieldFocused: Bool
    /// Per-entry due-date override chosen from the add bar's chip. `nil` uses the
    /// resolved contextual/default rule.
    @State private var inlineDueOverride: DefaultDueDateRule?

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
                        tappableEmptyState
                    } else {
                        SectionedTaskListContent(
                            sections: sections,
                            onSelect: { selectedTask = $0 },
                            showGroupingToggle: currentSmartList == .upcoming,
                            grouping: $upcomingGrouping
                        )
                    }
                } else if displayedTasks.isEmpty {
                    tappableEmptyState
                } else {
                    TasksListContent(
                        tasks: displayedTasks,
                        manualReorder: activeSort == .manually,
                        activeSort: activeSort,
                        ascending: sortDirection.isAscending,
                        onSelect: { selectedTask = $0 },
                        onMove: moveTasks,
                        onMoveSubtasks: moveSubtasks,
                        onTapEmptyArea: focusInlineField
                    )
                }
            }
            .refreshable {
                await syncScheduler.syncNow(modelContext: modelContext)
            }
        }
        .safeAreaInset(edge: .bottom) {
            InlineAddBar(
                title: $inlineTaskTitle,
                isFocused: $inlineFieldFocused,
                dueRuleLabel: inlineDueChipLabel,
                dueRuleIsSet: inlineEffectiveRule != .none,
                onPickRule: { inlineDueOverride = $0 },
                onSubmit: createInlineTask,
                onExpandTap: { showingQuickAdd = true }
            )
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "Search tasks…")
        .toolbar { TaskListToolbar(onAdd: { showingQuickAdd = true }) }
        .sheet(isPresented: $showingQuickAdd) {
            QuickAddView(defaultList: defaultTaskList, defaultSmartList: currentSmartList)
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

        // Sort — completed tasks always sink below active ones, so a freshly
        // added task never lands under the "done" items, while the chosen
        // sort field is still honored within each group.
        result = TaskListHelpers.sortedWithCompletedLast(
            result,
            by: activeSort,
            ascending: sortDirection.isAscending
        )

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

    private func createInlineTask() {
        let trimmed = inlineTaskTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let task = TaskItem(title: trimmed, priority: .none)
        task.taskList = defaultTaskList

        // Place new tasks above existing ones (and, via completed-at-bottom,
        // above done items) and give them a manual order to push to the server.
        task.manualSortOrder = TaskListHelpers.topSortOrder(forInsertingInto: displayedTasks)

        // Apply the resolved due-date + reminder defaults so the task stays
        // visible in the view that created it and honors per-list/global settings.
        applyNewTaskDefaults(to: task)

        task.isDirty = true
        modelContext.insert(task)
        try? modelContext.save()
        if task.reminderOffset != nil {
            ReminderScheduler.requestPermissionIfNeeded()
            ReminderScheduler.scheduleReminder(for: task)
        }
        syncScheduler.syncAfterChange(modelContext: modelContext)
        HapticManager.success()

        inlineTaskTitle = ""
        inlineDueOverride = nil
        // Keep focus so the user can add multiple tasks quickly.
        inlineFieldFocused = true
    }

    /// Empty state that also acts as a large tap target: a single tap on the
    /// blank area focuses the inline add field and raises the keyboard, matching
    /// Apple Reminders. Suppressed during search (no task to add from a query).
    @ViewBuilder
    private var tappableEmptyState: some View {
        EmptyTasksView(smartList: currentSmartList, hasSearch: !searchText.isEmpty)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                guard searchText.isEmpty else { return }
                focusInlineField()
            }
    }

    /// Focuses the inline add field (raising the keyboard).
    private func focusInlineField() {
        inlineFieldFocused = true
    }

    /// Label for the add bar's due-date chip reflecting the effective rule.
    private var inlineDueChipLabel: String {
        inlineEffectiveRule == .none ? "No date" : inlineEffectiveRule.displayName
    }

    /// The due-date rule that will apply to the next inline task: the per-entry
    /// chip override if set, else the Today context, else the per-list/global default.
    private var inlineEffectiveRule: DefaultDueDateRule {
        if let inlineDueOverride { return inlineDueOverride }
        if currentSmartList == .today { return .today }
        return NewTaskDefaults.effectiveDueDateRule(for: defaultTaskList)
    }

    /// Stamps the resolved due-date and reminder defaults onto a new task. The
    /// contextual override is already folded into `inlineEffectiveRule`, so the
    /// pure resolver is called with `smartList: nil`.
    private func applyNewTaskDefaults(to task: TaskItem) {
        let resolved = NewTaskDefaults.resolve(
            smartList: nil,
            rule: inlineEffectiveRule,
            reminderEnabled: NewTaskDefaults.effectiveReminderEnabled(for: task.taskList)
        )
        task.dueDate = resolved.dueDate
        task.isDueDateOnly = resolved.isDueDateOnly
        task.reminderOffset = resolved.reminderOffset
    }

    /// Handles a long-press drag reorder (only active when sorting Manually).
    /// Renumbers `manualSortOrder` to match the new order and pushes upstream
    /// so the change mirrors into Nextcloud (X-APPLE-SORT-ORDER).
    private func moveTasks(from source: IndexSet, to destination: Int) {
        var reordered = displayedTasks
        reordered.move(fromOffsets: source, toOffset: destination)
        TaskListHelpers.assignManualOrder(reordered)
        try? modelContext.save()
        syncScheduler.syncAfterChange(modelContext: modelContext)
        HapticManager.softImpact()
    }

    /// Handles a long-press drag reorder of a parent's subtasks (only active when
    /// sorting Manually). Renumbers the moved sibling group's `manualSortOrder`
    /// off the same display order the rows render in, so the new order mirrors
    /// into Nextcloud (X-APPLE-SORT-ORDER) exactly like the root list.
    private func moveSubtasks(of parent: TaskItem, from source: IndexSet, to destination: Int) {
        var reordered = TaskListHelpers.orderedSubtasks(
            of: parent,
            by: activeSort,
            ascending: sortDirection.isAscending
        )
        reordered.move(fromOffsets: source, toOffset: destination)
        TaskListHelpers.assignManualOrder(reordered)
        try? modelContext.save()
        syncScheduler.syncAfterChange(modelContext: modelContext)
        HapticManager.softImpact()
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
    /// True when sorting Manually — enables long-press drag-to-reorder and
    /// disables drag-to-reparent so the two gestures don't conflict.
    let manualReorder: Bool
    /// The active sort/direction, threaded down so subtasks render in the same
    /// order as the root list (completed-last, manual order honored).
    let activeSort: TaskSortOption
    let ascending: Bool
    let onSelect: (TaskItem) -> Void
    let onMove: (IndexSet, Int) -> Void
    let onMoveSubtasks: (TaskItem, IndexSet, Int) -> Void
    /// Tapping the blank area beneath the last row focuses the inline add field.
    let onTapEmptyArea: () -> Void

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List {
            ForEach(tasks) { task in
                RecursiveTaskRow(
                    task: task,
                    depth: 0,
                    manualReorder: manualReorder,
                    activeSort: activeSort,
                    ascending: ascending,
                    onSelect: onSelect,
                    onReparent: reparentTask,
                    onMoveSubtasks: onMoveSubtasks,
                    enableReparentDrag: !manualReorder
                )
                .listRowSeparator(.hidden)
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
            .onMove(perform: manualReorder ? onMove : nil)

            // Blank tap target below the tasks: a single tap raises the keyboard
            // for quick entry, like Apple Reminders. Not draggable/selectable.
            Color.clear
                .frame(height: 240)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTapEmptyArea)
                .accessibilityHidden(true)
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
    /// True when the list is sorting Manually — enables subtask drag-to-reorder.
    var manualReorder: Bool = false
    /// The active sort/direction so subtasks render in the same order as roots.
    var activeSort: TaskSortOption = .dueDate
    var ascending: Bool = true
    let onSelect: (TaskItem) -> Void
    var onReparent: ((TaskItem, TaskItem?) -> Void)?
    /// Reorders this task's children when one is dragged in manual-sort mode.
    var onMoveSubtasks: ((TaskItem, IndexSet, Int) -> Void)?
    /// Drag-to-reparent is disabled while the list is in manual-reorder mode
    /// so it doesn't conflict with the long-press drag-to-reorder gesture.
    var enableReparentDrag: Bool = true

    @State private var isExpanded = true

    /// Subtasks in the same display order as the root list — completed pinned to
    /// the bottom, the active sort (incl. manual order) honored — instead of the
    /// arbitrary SwiftData relationship order.
    private var orderedSubtasks: [TaskItem] {
        TaskListHelpers.orderedSubtasks(of: task, by: activeSort, ascending: ascending)
    }

    var body: some View {
        // A Group (not a VStack) so the task and each subtask are separate List
        // rows — that's what lets the subtask ForEach (in `SubtaskRows`) own an
        // `.onMove` for sibling reordering, while a parent's whole subtree still
        // moves together when the parent row is dragged.
        Group {
            taskRow
            if isExpanded && !orderedSubtasks.isEmpty {
                SubtaskRows(
                    parent: task,
                    subtasks: orderedSubtasks,
                    depth: depth + 1,
                    manualReorder: manualReorder,
                    activeSort: activeSort,
                    ascending: ascending,
                    onSelect: onSelect,
                    onReparent: onReparent,
                    onMoveSubtasks: onMoveSubtasks,
                    enableReparentDrag: enableReparentDrag
                )
            }
        }
    }

    /// This task's own row, with drag-to-indent enabled outside manual mode.
    @ViewBuilder
    private var taskRow: some View {
        if enableReparentDrag {
            paddedRow
                .draggable(task.id) // Enable drag-to-indent
                .dropDestination(for: String.self) { droppedIDs, _ in
                    guard let droppedID = droppedIDs.first,
                          droppedID != task.id,
                          let droppedTask = findTask(id: droppedID) else { return false }
                    onReparent?(droppedTask, task)
                    return true
                }
        } else {
            paddedRow
        }
    }

    /// The task's own row (chevron + content), indented for its depth.
    private var paddedRow: some View {
        HStack(spacing: 4) {
            // Collapse/expand chevron
            if !orderedSubtasks.isEmpty {
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
    }

    /// Traverses the hierarchy to find a task by ID.
    private func findTask(id: String) -> TaskItem? {
        if task.id == id { return task }
        for subtask in orderedSubtasks {
            if subtask.id == id { return subtask }
        }
        return nil
    }
}

/// Renders one parent's subtasks as sibling List rows with a `.onMove` reorder.
///
/// This lives in its own `View` struct — not a computed property of
/// `RecursiveTaskRow` — on purpose: it makes the `ForEach` content the *nominal*
/// `RecursiveTaskRow` type instead of a self-referential opaque type. Attaching
/// `.onMove` (a `DynamicViewContent` modifier) inside the recursive view itself
/// makes the type-checker try to fully expand the recursion and bail out with
/// "failed to produce diagnostic"; the struct boundary breaks that cycle.
private struct SubtaskRows: View {
    let parent: TaskItem
    let subtasks: [TaskItem]
    let depth: Int
    let manualReorder: Bool
    let activeSort: TaskSortOption
    let ascending: Bool
    let onSelect: (TaskItem) -> Void
    var onReparent: ((TaskItem, TaskItem?) -> Void)?
    var onMoveSubtasks: ((TaskItem, IndexSet, Int) -> Void)?
    let enableReparentDrag: Bool

    /// Reorder handler — `nil` outside manual mode so the rows aren't draggable.
    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard manualReorder else { return nil }
        return { onMoveSubtasks?(parent, $0, $1) }
    }

    var body: some View {
        ForEach(subtasks) { subtask in
            RecursiveTaskRow(
                task: subtask,
                depth: depth,
                manualReorder: manualReorder,
                activeSort: activeSort,
                ascending: ascending,
                onSelect: onSelect,
                onReparent: onReparent,
                onMoveSubtasks: onMoveSubtasks,
                enableReparentDrag: enableReparentDrag
            )
            .listRowSeparator(.hidden)
        }
        .onMove(perform: moveHandler)
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
