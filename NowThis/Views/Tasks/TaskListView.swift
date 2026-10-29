import SwiftUI
import SwiftData
import Observation

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
    @Environment(\.syncCommands) private var syncCommands
    /// Fetches only what this screen can ever show: live roots, and — for a
    /// specific list — only that list's roots. The `#Predicate` excludes
    /// subtasks (`parentTask != nil`), soft-deleted tasks, and — for a list
    /// selection — tasks belonging to other lists. It does not exclude
    /// completed tasks: the Completed smart list and the show-completed
    /// toggle both still need those in `allTasks`. Doing this filter in the
    /// `#Predicate` means SwiftData does it once, at fetch time, instead of
    /// the view redoing it two or three times per render and per add.
    static func taskQueryPredicate(for selection: SidebarSelection) -> Predicate<TaskItem> {
        switch selection {
        case .taskList(let listID):
            return #Predicate<TaskItem> { !$0.isDeletedLocally && $0.parentTask == nil && $0.taskList?.id == listID }
        default:
            return #Predicate<TaskItem> { !$0.isDeletedLocally && $0.parentTask == nil }
        }
    }
    @State private var allTasks: [TaskItem] = []
    @State private var queryRevision: UInt64 = 0
    @State private var showingQuickAdd = false
    @State private var selectedTask: SelectedTask?
    @State private var searchText = ""
    @AppStorage("taskSortOption") private var activeSort: TaskSortOption = .dueDate
    @AppStorage("taskSortDirection") private var sortDirection: SortDirection = .ascending
    @AppStorage("showCompletedTasks") private var showCompleted = false
    @State private var priorityFilter: TaskPriority?

    @AppStorage("upcomingGrouping") private var upcomingGrouping = "weekly"

    @AppStorage("tabBarVisible") private var visibleTabsJSON = ""
    @SceneStorage("selectedTabToken") private var selectedTabToken = AppTab.tasks.token
    @SceneStorage("sidebarSelection") private var sidebarSelectionKey = "smart:Today"
    /// A destination the title menu can't reach by selecting a tab: a Board,
    /// Calendar or Matrix the user has hidden. See ``resolveJump(to:visible:)``.
    @State private var presentedHiddenTab: AppTab?

    @State private var inlineTaskTitle = ""
    @FocusState private var inlineFieldFocused: Bool
    /// Per-entry due-date override chosen from the add bar's chip. `nil` uses the
    /// resolved contextual/default rule.
    @State private var inlineDueOverride: DefaultDueDateRule?

    /// Selection scopes the replaceable query reader, preserving this screen's state.
    init(selection: SidebarSelection) {
        self.selection = selection
    }

    private var queryListID: String? {
        if case .taskList(let id) = selection { return id }
        return nil
    }

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
                            onSelect: { selectedTask = SelectedTask($0) },
                            showGroupingToggle: currentSmartList == .upcoming,
                            grouping: $upcomingGrouping
                        )
                    }
                } else {
                    let tasks = displayedTasks
                    if tasks.isEmpty {
                        tappableEmptyState
                    } else {
                        TasksListContent(
                            tasks: tasks,
                            dataRevision: queryRevision,
                            manualReorder: activeSort == .manually,
                            activeSort: activeSort,
                            ascending: sortDirection.isAscending,
                            onSelect: { selectedTask = SelectedTask($0) },
                            onMove: moveTasks,
                            onMoveSubtasks: moveSubtasks,
                            onTapEmptyArea: focusInlineField
                        )
                    }
                }
            }
            .refreshable {
                await syncCommands.syncNow(modelContext)
            }
        }
        .background(InboundQueryReader(
            descriptor: FetchDescriptor(predicate: Self.taskQueryPredicate(for: selection)),
            scope: selection.encoded, listID: queryListID) {
                allTasks = $0
                queryRevision &+= 1
            })
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
        // Required for `.toolbarTitleMenu` below to actually produce a tappable
        // menu at all — verified by hand on this SDK (iOS 26.5 simulator): under
        // `.automatic`/`.large` the title renders as inert text (confirmed via
        // `idb ui describe-point`: role `AXHeading`, no actions, no visible
        // chevron, unresponsive to tap and long-press); switching to `.inline`
        // is what makes the system draw the chevron and expose the title as an
        // `AXButton` ("<title>, Actions Menu"). This also matches every other
        // screen's title style (Board, Calendar, Matrix, Journal all use
        // `.inline` already) — Tasks was the one outlier.
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            let visible = AppTab.decodeVisible(from: visibleTabsJSON)
            // All five, always — a smart list that is also a tab is still a
            // reasonable thing to pick from here.
            ForEach(SmartList.allCases) { smart in
                Button {
                    jump(to: .smart(smart), visible: visible)
                } label: {
                    Label(smart.displayName, systemImage: smart.icon)
                }
            }
            let hiddenPresentations = AppTab.titleMenuHiddenPresentations(visible: visible)
            if !hiddenPresentations.isEmpty {
                Divider()
                ForEach(hiddenPresentations) { tab in
                    Button {
                        jump(to: tab, visible: visible)
                    } label: {
                        Label(tab.displayName, systemImage: tab.icon)
                    }
                }
            }
        }
        // Verified by hand: selecting a hidden Board/Calendar/Matrix from the
        // title menu set `selectedTabToken` to a tab that isn't in the
        // `TabView`, and `MainTabView.resolveSelection` silently clamped it back
        // to the first visible tab — the jump did nothing. Presenting the hidden
        // destination as a sheet from here (instead of trying to select it as a
        // tab) is the fix; see ``jump(to:visible:)`` and ``hiddenDestination(for:)``.
        //
        // No `NavigationStack` around the destination. Board, Calendar and Matrix each open on
        // one of their own, so wrapping them here put a second navigation bar in the sheet — the
        // nesting `-[UINavigationBar layoutSubviews]` asserts on, and the reason the sheet showed
        // "Done" beside the Board's segmented control with the Board's own title dropped. Each
        // branch of ``hiddenDestination(for:)`` now carries exactly one container and its own way
        // out; see `NavigationContainerGuardTests`.
        .sheet(item: $presentedHiddenTab) { tab in
            hiddenDestination(for: tab)
        }
        // `.always` — not the default `.automatic`. Under `.automatic` the search
        // field is a *collapsible* navigation-bar drawer, and this screen ends up
        // with two pull-down affordances stacked on one gesture: the drawer, owned
        // by the navigation bar above `FilterBar`, and the `List`'s refresh control
        // below it. Verified by hand on the iPhone 17 simulator (iOS 26.5): with the
        // drawer collapsed, one pull reveals it *and* starts the refresh, and the two
        // render in each other's slots — the spinner appears in the drawer band above
        // the filter chips while the search field is pushed down inside the list,
        // above the first row. `.always` pins the drawer open, so a pull can only
        // mean refresh and the spinner stays at the top of the list where it belongs.
        //
        // It also stops the field vanishing outright: collapsed, it is not merely
        // scrolled out of view but absent from the accessibility hierarchy
        // (confirmed via `idb ui describe-all` — no search element at all), so
        // search was unreachable by VoiceOver until the user happened to pull down.
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search tasks…")
        .toolbar { TaskListToolbar(onAdd: { showingQuickAdd = true }) }
        .sheet(isPresented: $showingQuickAdd) {
            QuickAddView(defaultList: defaultTaskList, defaultSmartList: currentSmartList)
        }
        .sheet(item: $selectedTask) { selection in
            NavigationStack {
                TaskDetailView(task: selection.task)
            }
        }
    }

    /// Where a title-menu tap on a destination should route to. Pure and
    /// stateless so the routing rules are testable without a view — the same
    /// move `MainTabView.resolveSelection` makes for tab-selection clamping.
    enum TitleMenuJump: Equatable {
        /// `tab` is in the bar — pinned, or one the user chose. Select it directly.
        case selectTab(AppTab)
        /// `list` has no tab of its own, so the pinned Tasks tab hosts it —
        /// write the sidebar selection and switch to Tasks.
        case showInTasksTab(SmartList)
        /// Nothing in the bar can host this destination — present it as a sheet.
        /// Only a hidden Board, Calendar or Matrix ever reaches here.
        case presentSheet(AppTab)

        /// Whether applying this jump must close an open hidden-destination
        /// sheet. Picking a tab from inside the sheet used to write
        /// `selectedTabToken` and leave the sheet up, so the tab changed
        /// invisibly behind it and nothing appeared to happen.
        var dismissesPresentedSheet: Bool {
            switch self {
            case .selectTab, .showInTasksTab: return true
            case .presentSheet: return false
            }
        }
    }

    /// Resolves a title-menu tap into a ``TitleMenuJump``.
    ///
    /// Order matters: a tab that is in the bar always wins (rule 1), even if it
    /// is itself a `.smart` case — only *then* does the Tasks-tab fallback
    /// (rule 2) apply. `.tasks` is pinned, so rule 2 always has a host and no
    /// smart list can reach rule 3; the old `visible.first { $0 == .tasks } ??
    /// visible.first` fallback could silently misroute a smart-list pick to
    /// whatever tab was first — Board, say. Only a hidden presentation falls
    /// through to the sheet (rule 3).
    static func resolveJump(to tab: AppTab, visible: [AppTab]) -> TitleMenuJump {
        if tab.isPinned || visible.contains(tab) {
            return .selectTab(tab)
        }
        if case .smart(let list) = tab {
            return .showInTasksTab(list)
        }
        return .presentSheet(tab)
    }

    /// Jumps to a destination from the title menu by applying
    /// ``resolveJump(to:visible:)`` to view state.
    @MainActor
    private func jump(to tab: AppTab, visible: [AppTab]) {
        let route = Self.resolveJump(to: tab, visible: visible)
        if route.dismissesPresentedSheet { presentedHiddenTab = nil }
        switch route {
        case .selectTab(let tab):
            selectedTabToken = tab.token
        case .showInTasksTab(let list):
            // A deliberate choice made after launch, so "Open App To" must not
            // reapply over it when the Tasks tab first appears.
            SidebarStartupOverride.consume()
            sidebarSelectionKey = SidebarSelection.smart(list).encoded
            selectedTabToken = AppTab.tasks.token
        case .presentSheet(let tab):
            presentedHiddenTab = tab
        }
    }

    /// The screen shown in the hidden-destination sheet.
    ///
    /// Only `.board`, `.calendar` and `.matrix` are reachable — the three
    /// screens `ContentView` alone constructs, which is why hiding one needs a
    /// route back at all. `.smart` is here because a `.smart` sheet is still
    /// the shape `ContentView` builds, though ``resolveJump(to:visible:)`` now
    /// sends every smart list to the pinned Tasks tab instead.
    @ViewBuilder
    private func hiddenDestination(for tab: AppTab) -> some View {
        switch tab {
        case .board:
            KanbanBoardView().refreshOnInboundSync()
        case .calendar:
            CalendarContainerView().refreshOnInboundSync()
        case .matrix:
            EisenhowerMatrixView().refreshOnInboundSync()
        case .smart(let list):
            // Matches `ContentView.destination(for:)`'s `.smart` case:
            // `TaskListView` supplies no navigation container of its own, so this branch is the
            // one that has to — and, being the container, the one that carries the way out.
            NavigationStack {
                TaskListView(selection: .smart(list))
                    .refreshOnInboundSync()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { presentedHiddenTab = nil }
                        }
                    }
            }
        case .tasks, .settings:
            // Both are pinned, so `resolveJump` selects them as tabs and neither
            // can arrive here. `.tasks` used to, presenting `MainShellView` — a
            // `NavigationSplitView` nested inside a navigation container, which
            // renders its sidebar and never pushes. Lists, Tags, Saved Filters
            // and Journals were all unreachable through it.
            EmptyView()
        }
    }

    // MARK: - Computed Properties

    private var title: String {
        switch selection {
        // `rawValue` is the **persisted** token: `@AppStorage` stores it and
        // `SidebarSelection.decode` parses it back on launch. Rendering it as the navigation
        // title meant all five smart-list screens showed the stored identifier, so they shipped
        // English whatever the catalog said — and localizing `rawValue` to fix that would lose
        // the user's sidebar selection on a language change. `displayName` is the separate
        // user-facing label that exists for exactly this reason.
        case .smart(let smart): return smart.displayName
        case .taskList(let listID):
            let targetID = listID
            let p = #Predicate<TaskList> { $0.id == targetID }
            var desc = FetchDescriptor<TaskList>(predicate: p)
            desc.fetchLimit = 1
            return (try? modelContext.fetch(desc))?.first?.name ?? String(
                localized: "tasks.title.list",
                defaultValue: "Tasks",
                comment: "Navigation title fallback shown when a selected list's name cannot be resolved from the store.")
        case .savedFilter(let filterID):
            let targetID = filterID
            let p = #Predicate<SavedFilter> { $0.id == targetID }
            var desc = FetchDescriptor<SavedFilter>(predicate: p)
            desc.fetchLimit = 1
            return (try? modelContext.fetch(desc))?.first?.name ?? String(
                localized: "tasks.title.filter",
                defaultValue: "Filter",
                comment: "Navigation title fallback shown when a selected saved filter's name cannot be resolved from the store.")
        case .tag(let tagID):
            let targetID = tagID
            let p = #Predicate<Tag> { $0.id == targetID }
            var desc = FetchDescriptor<Tag>(predicate: p)
            desc.fetchLimit = 1
            return (try? modelContext.fetch(desc))?.first?.name ?? String(
                localized: "tasks.title.tag",
                defaultValue: "Tag",
                comment: "Navigation title fallback shown when a selected tag's name cannot be resolved from the store.")
        case .journals:
            return String(
                localized: "tasks.title.journals",
                defaultValue: "Journals",
                comment: "Navigation title shown when the Journals section is selected in the sidebar.")
        }
    }

    private var currentSmartList: SmartList? {
        if case .smart(let list) = selection { return list }
        return nil
    }

    /// Live roots from `allTasks` — non-deleted, root-only, and (for a
    /// `.taskList` selection) list-scoped, all via `taskQueryPredicate` in the
    /// `@Query`, then the liveness guard applied here.
    ///
    /// The liveness check comes first, and this is the boundary where it has to
    /// happen: every filter downstream dereferences the task, `ForEach` reads
    /// its `id` to diff identity before any row body runs, and `moveTasks`
    /// indexes back into this same array. An account delete cascades tasks
    /// away on the main context, so one invalidated task here traps the whole
    /// screen.
    ///
    /// Both guards are needed, and in this order. `liveTasks` reads only
    /// `persistentModelID` and catches the task the `SyncEngine` hard-deleted on
    /// its background context — still attached to *this* context, so
    /// `modelContext` is non-nil and only the store knows it is gone.
    /// `modelContext != nil` then catches the main-context delete that has been
    /// made but not yet saved, where the model is detached while its row is
    /// still on disk. Neither signal subsumes the other.
    ///
    /// Shared by `displayedTasks` and `createInlineTask()` so this rationale —
    /// and the order the two guards run in — lives in exactly one place.
    private var liveRoots: [TaskItem] {
        TaskListHelpers.liveTasks(allTasks, in: modelContext,
            matching: FetchDescriptor(predicate: Self.taskQueryPredicate(for: selection)))
            .filter { $0.modelContext != nil }
    }

    /// Pipeline: live roots (already non-deleted, root-only, and — for a
    /// `.taskList` selection — list-scoped, via `taskQueryPredicate`) →
    /// smart/saved-filter/tag filter → search → priority → completed → sort
    private var displayedTasks: [TaskItem] {
        // isDeletedLocally, parentTask == nil, and (for `.taskList`) the list
        // scope are already filtered by `taskQueryPredicate` in the @Query.
        // See `liveRoots` for the liveness-guard rationale.
        var result = liveRoots

        // Smart list, task list, or saved filter
        switch selection {
        case .smart(let smart):
            result = filterForSmartList(smart, from: result)
        case .taskList:
            break // The query already scoped this to the selected list's roots.
        case .savedFilter(let filterID):
            result = applyCustomFilter(filterID, to: result)
        case .tag(let tagID):
            result = result.filter { $0.tags.contains(where: { $0.id == tagID }) }
        case .journals:
            return [] // Journals handled by JournalListView
        }

        // Full-text search.
        //
        // `localizedStandardContains` rather than `.lowercased().contains` — it folds case *and*
        // diacritics the way the reader's language does. Typing "grusse" finds "Grüße", "cafe"
        // finds "café", and Turkish's dotted and dotless I stop being two different letters.
        // `lowercased()` does none of that: it is not locale-aware, and it leaves every accent in
        // place, so a French user could not find their own task by typing it without the accent.
        if !searchText.isEmpty {
            let query = searchText
            result = result.filter { task in
                task.title.localizedStandardContains(query)
                    || (task.descriptionText?.localizedStandardContains(query) ?? false)
                    || (task.locationName?.localizedStandardContains(query) ?? false)
                    || task.tags.contains(where: { $0.name.localizedStandardContains(query) })
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

    /// The list currently in view, if the selection names one. `nil` for smart
    /// lists, tags, saved filters and journals — where the user's default applies.
    private var selectedTaskList: TaskList? {
        guard case .taskList(let listID) = selection else { return nil }
        let targetID = listID
        let listPredicate = #Predicate<TaskList> { $0.id == targetID }
        var desc = FetchDescriptor<TaskList>(predicate: listPredicate)
        desc.fetchLimit = 1
        return (try? modelContext.fetch(desc))?.first
    }

    /// The list a new task would land in. Read during `body` (see
    /// ``inlineEffectiveRule``), so it uses the non-persisting resolver — the
    /// adoption write happens in ``createInlineTask()``.
    private var defaultTaskList: TaskList? {
        NewTaskDefaults.resolveList(explicit: selectedTaskList, in: modelContext)
    }

    private func createInlineTask() {
        let trimmed = inlineTaskTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let task = TaskItem(title: trimmed, priority: .none)
        task.taskList = NewTaskDefaults.resolveListAdopting(explicit: selectedTaskList, in: modelContext)

        // Place new tasks above existing ones (and, via completed-at-bottom,
        // above done items) and give them a manual order to push to the server.
        //
        // Computed from `liveRoots` rather than `displayedTasks` — a superset
        // (it skips the smart/saved-filter/tag/search/priority/completed
        // narrowing `displayedTasks` applies), but a superset is fine here:
        // `topSortOrder` only needs the *minimum* sort order among the
        // candidates, and including more roots can only push that minimum
        // lower, so the new task still lands above every visible row. Reusing
        // `displayedTasks`' own filters would mean recomputing the whole
        // pipeline a third time just to answer this one question.
        task.manualSortOrder = TaskListHelpers.topSortOrder(forInsertingInto: liveRoots)

        // Apply the resolved due-date + reminder defaults so the task stays
        // visible in the view that created it and honors per-list/global settings.
        applyNewTaskDefaults(to: task)

        task.isDirty = true
        modelContext.insert(task)
        try? ReminderSchedulingJournal.saveTaskChanges(in: modelContext)
        if task.reminderOffset != nil {
            ReminderScheduler.requestPermissionIfNeeded()
        }
        // Unconditional — see QuickAddView. The inline row's default rule can hand the task a
        // due date with no reminder, which is precisely the case that scheduled nothing.
        ReminderScheduler.requestReconcile(modelContext: modelContext)
        syncCommands.syncAfterChange(modelContext)
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
        inlineEffectiveRule == .none ? String(
            localized: "tasks.inlineAdd.due.noDate",
            defaultValue: "No date",
            comment: "Label on the inline add bar's due-date chip when no due-date rule is set for the next task being created.") : inlineEffectiveRule.displayName
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
        guard source.allSatisfy({ $0 < reordered.count }),
              (0...reordered.count).contains(destination) else { return }
        reordered.move(fromOffsets: source, toOffset: destination)
        TaskListHelpers.assignManualOrder(reordered)
        try? ReminderSchedulingJournal.saveTaskChanges(in: modelContext)
        syncCommands.syncAfterChange(modelContext)
        HapticManager.softImpact()
    }

    /// Handles a long-press drag reorder of a parent's subtasks (only active when
    /// sorting Manually). Renumbers the moved sibling group's `manualSortOrder`
    /// off the same display order the rows render in, so the new order mirrors
    /// into Nextcloud (X-APPLE-SORT-ORDER) exactly like the root list.
    private func moveSubtasks(of parent: TaskItem, from source: IndexSet, to destination: Int) {
        var reordered = TaskListHelpers.orderedSubtasksIfLive(
            of: parent,
            by: activeSort,
            ascending: sortDirection.isAscending
        )
        // An invalidated parent yields no children, but the offsets came from the
        // rows that were on screen a moment ago — moving them would trade a
        // SwiftData trap for an index-out-of-range one.
        guard source.allSatisfy({ $0 < reordered.count }), destination <= reordered.count
        else { return }
        reordered.move(fromOffsets: source, toOffset: destination)
        TaskListHelpers.assignManualOrder(reordered)
        try? ReminderSchedulingJournal.saveTaskChanges(in: modelContext)
        syncCommands.syncAfterChange(modelContext)
        HapticManager.softImpact()
    }

    // MARK: - Sectioned Occurrences (Upcoming / Overdue)

    /// Groups each task's current occurrence by time period.
    private var sectionedOccurrences: [TaskSection] {
        guard let smartList = currentSmartList,
              (smartList == .upcoming || smartList == .overdue) else { return [] }

        // Start from all live, non-completed tasks — the query's `#Predicate`
        // already scoped `allTasks` to non-deleted roots. Liveness first, for
        // the same reason as `displayedTasks`: the reads below would trap on a
        // task an account delete has already cascaded away.
        var baseTasks = liveRoots.filter { $0.status != .completed }

        // Apply search filter. See the note on the other search above: folding is
        // `localizedStandardContains`, not `lowercased()`.
        if !searchText.isEmpty {
            baseTasks = baseTasks.filter { task in
                task.title.localizedStandardContains(searchText)
                    || (task.descriptionText?.localizedStandardContains(searchText) ?? false)
            }
        }

        // Apply priority filter
        if let pri = priorityFilter {
            baseTasks = baseTasks.filter { $0.priority == pri }
        }

        // Deduplicate by UID
        baseTasks = TaskListHelpers.deduplicateByUID(baseTasks)

        let cal = Calendar.current
        let occurrences = TaskListHelpers.occurrences(
            from: baseTasks, smartList: smartList, now: Date()
        )

        if smartList == .upcoming {
            return groupOccurrences(occurrences, by: upcomingGrouping == "weekly" ? .weekOfYear : .month, calendar: cal)
        } else {
            // Overdue: group by month going back
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

        // Fixed `dateFormat` patterns ("MMM d", "MMM d, yyyy", "MMMM yyyy") hardcode English's
        // month-before-day order and an en-dash join. In de, es, fr, it and nl the day comes
        // first, and each language has its own range separator and its own idea of whether the
        // year is repeated on both sides. `Date.FormatStyle` and its interval form know all of
        // that; a pattern string knows none of it. These were the only display-facing fixed
        // patterns in the repository — the other nine formatters are ICS protocol and must keep
        // their patterns and their `en_US_POSIX` locale.
        return grouped.keys.sorted().map { key in
            if component == .weekOfYear {
                let end = calendar.date(byAdding: .day, value: 6, to: key) ?? key
                // `..<` needs a strictly ascending range; `end` is six days on, so the only way
                // it can equal `key` is the `date(byAdding:)` failure above.
                let label = end > key
                    ? (key..<end).formatted(.interval.year().month(.abbreviated).day())
                    : key.formatted(.dateTime.year().month(.abbreviated).day())
                return TaskSection(title: label, occurrences: grouped[key] ?? [])
            } else {
                return TaskSection(title: key.formatted(.dateTime.year().month(.wide)),
                                   occurrences: grouped[key] ?? [])
            }
        }
    }
}

// MARK: - Task List Content

private struct TasksListContent: View {
    let tasks: [TaskItem]
    let dataRevision: UInt64
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
            // Keep the original root ForEach and root move offsets. Constructing
            // a root group reads no relationships; only an appearing row activates it.
            ForEach(tasks) { task in
                TaskRootHierarchyContent(
                    task: task,
                    rootID: task.id,
                    dataRevision: dataRevision,
                    manualReorder: manualReorder,
                    activeSort: activeSort,
                    ascending: ascending,
                    onSelect: onSelect,
                    onReparent: reparentTask,
                    onMoveSubtasks: onMoveSubtasks
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
        try? ReminderSchedulingJournal.saveTaskChanges(in: modelContext)
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
                        if let data = TaskRowData(task: occurrence.task) {
                            TaskRowView(data: data, task: occurrence.task) {
                                onSelect(occurrence.task)
                            }
                            .accessibilityLabel("\(data.title), due \(occurrence.occurrenceDate.formatted(date: .abbreviated, time: .omitted))")
                            .listRowSeparator(.hidden)
                        }
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

/// A root and a single flat descendant ForEach, regardless of hierarchy depth.
/// Cached rows let List resolve group structure without faulting offscreen roots.
private struct TaskRootHierarchyContent: View {
    let task: TaskItem
    let rootID: String
    let dataRevision: UInt64
    let manualReorder: Bool
    let activeSort: TaskSortOption
    let ascending: Bool
    let onSelect: (TaskItem) -> Void
    let onReparent: (TaskItem?, TaskItem?) -> Void
    let onMoveSubtasks: (TaskItem, IndexSet, Int) -> Void

    private typealias Hierarchy = TaskListHierarchyProjection<TaskItem, String>
    @State private var hierarchyState = TaskListRootHierarchyState<TaskItem, String>()
    /// Owned by the root group, surviving an ancestor collapse and reorder.
    @State private var collapsedTaskIDs: Set<String> = []
    @State private var visibleTaskIDs: Set<String> = []
    @State private var projectionSort: TaskSortOption?
    @State private var projectionAscending: Bool?
    @State private var projectionTaskIdentity: ObjectIdentifier?

    var body: some View {
        hierarchyRows
            .onChange(of: activeSort) { _, _ in configurationChanged() }
            .onChange(of: ascending) { _, _ in configurationChanged() }
            .onChange(of: ObjectIdentifier(task)) { _, _ in configurationChanged() }
            .onChange(of: dataRevision) { _, value in
                hierarchyState.receiveRevision(value)
                if !visibleTaskIDs.isEmpty { activateHierarchy() }
            }
    }

    @ViewBuilder
    private var hierarchyRows: some View {
        rootRow
        descendantRows
    }

    private var rootRow: some View {
        TaskHierarchyRow(task: task, depth: 0,
            hasChildren: hierarchyState.projection?.rows.first?.hasChildren ?? false,
            isExpanded: expansion(for: rootID), activeSort: activeSort,
            ascending: ascending, onSelect: onSelect,
            onReparent: { child, parent in onReparent(child, parent) },
            enableReparentDrag: !manualReorder)
            .onAppear { rowAppeared(rootID) }
            .onDisappear { visibleTaskIDs.remove(rootID) }
    }

    private var descendantRows: some View {
        let rows: [Hierarchy.Row] = Array(hierarchyState.projection?.rows.dropFirst() ?? [])
        return ForEach(rows) { entry in
            TaskHierarchyRow(task: entry.node, depth: entry.depth,
                hasChildren: entry.hasChildren, isExpanded: expansion(for: entry.id),
                activeSort: activeSort, ascending: ascending, onSelect: onSelect,
                onReparent: { child, parent in onReparent(child, parent) },
                enableReparentDrag: !manualReorder)
                .listRowSeparator(.hidden)
                .onAppear { rowAppeared(entry.id) }
                .onDisappear { visibleTaskIDs.remove(entry.id) }
        }
        .onMove(perform: manualReorder ? { source, destination in
            moveDescendants(from: source, to: destination)
        } : nil)
    }

    private func expansion(for id: String) -> Binding<Bool> {
        Binding(get: { !collapsedTaskIDs.contains(id) }, set: { expanded in
            if expanded { collapsedTaskIDs.remove(id) }
            else { collapsedTaskIDs.insert(id) }
            invalidateHierarchy()
        })
    }

    private func rowAppeared(_ id: String) {
        visibleTaskIDs.insert(id)
        hierarchyState.receiveRevision(dataRevision)
        configurationChanged()
        activateHierarchy()
    }

    private func configurationChanged() {
        guard projectionSort != activeSort || projectionAscending != ascending
            || projectionTaskIdentity != ObjectIdentifier(task) else { return }
        invalidateHierarchy()
    }

    private func invalidateHierarchy() {
        hierarchyState.invalidate()
        // Offscreen roots retain their cached structure and defer all model reads.
        if !visibleTaskIDs.isEmpty { activateHierarchy() }
    }

    private func activateHierarchy() {
        guard hierarchyState.needsRefresh else { return }
        projectionSort = activeSort
        projectionAscending = ascending
        projectionTaskIdentity = ObjectIdentifier(task)
        let collapsed = collapsedTaskIDs
        let sort = activeSort
        let direction = ascending
        hierarchyState.activate {
            // Relationships and sort fields observed during this root's walk
            // invalidate only its cache. Defer the callback until the mutation
            // has finished; Observation invokes onChange before the write.
            withObservationTracking {
                Hierarchy(roots: [task], collapsedIDs: collapsed,
                    isVisible: { $0.modelContext != nil && !$0.isDeletedLocally },
                    id: { $0.id }, orderedChildren: { parent in
                        TaskListHelpers.sortedWithCompletedLast(
                            parent.subtasks.filter { $0.modelContext != nil && !$0.isDeletedLocally },
                            by: sort, ascending: direction)
                    })
            } onChange: {
                Task { @MainActor in invalidateHierarchy() }
            }
        }
    }

    private func moveDescendants(from source: IndexSet, to destination: Int) {
        // This ForEach omits the root; the cached projection includes it.
        guard let move = hierarchyState.projection?.move(
            from: IndexSet(source.map { $0 + 1 }), to: destination + 1),
            let parent = move.parent else { return }
        onMoveSubtasks(parent, move.source, move.destination)
    }
}

/// One lazily instantiated task row. Descendants are separate rows in the flat List.
/// Chevron, drag and row actions keep their existing behavior. Visual indentation
/// stops at four levels while the projection preserves the full hierarchy depth.
private struct TaskHierarchyRow: View {
    let task: TaskItem
    let depth: Int
    let hasChildren: Bool
    @Binding var isExpanded: Bool
    var activeSort: TaskSortOption = .dueDate
    var ascending: Bool = true
    let onSelect: (TaskItem) -> Void
    var onReparent: ((TaskItem, TaskItem?) -> Void)?
    /// Disabled in manual mode so reparenting does not conflict with reorder.
    var enableReparentDrag: Bool = true

    var body: some View {
        // A fixed outer container gives List one row per identity, so it can
        // defer row snapshots instead of resolving a conditional row count.
        HStack(spacing: 0) {
            // Establish liveness before chevron, content or drag reads.
            if let data = TaskRowData(task: task) {
                taskRow(data: data)
            }
        }
    }

    @ViewBuilder
    private func taskRow(data: TaskRowData) -> some View {
        if enableReparentDrag {
            paddedRow(data: data)
                .draggable(task.id)
                .dropDestination(for: String.self) { droppedIDs, _ in
                    guard task.modelContext != nil,
                          let droppedID = droppedIDs.first,
                          droppedID != task.id,
                          let droppedTask = findTask(id: droppedID) else { return false }
                    onReparent?(droppedTask, task)
                    return true
                }
        } else {
            paddedRow(data: data)
        }
    }

    private func paddedRow(data: TaskRowData) -> some View {
        HStack(spacing: 4) {
            if hasChildren {
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
                Color.clear.frame(width: 16, height: 16)
            }

            TaskRowView(data: data, task: task) {
                onSelect(task)
            }
        }
        .padding(.leading, CGFloat(TaskListHierarchyLayout.visualDepth(depth)) * 24)
    }

    /// Retains the existing drop lookup within this task's direct children.
    private func findTask(id: String) -> TaskItem? {
        guard task.modelContext != nil else { return nil }
        if task.id == id { return task }
        for subtask in TaskListHelpers.orderedSubtasksIfLive(
            of: task, by: activeSort, ascending: ascending
        ) {
            if subtask.modelContext != nil && subtask.id == id { return subtask }
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
        case .today: return String(
            localized: "tasks.empty.today.title",
            defaultValue: "All Clear Today",
            comment: "ContentUnavailableView heading shown for the Today smart list when there are no tasks due today.")
        case .upcoming: return String(
            localized: "tasks.empty.upcoming.title",
            defaultValue: "Nothing Upcoming",
            comment: "ContentUnavailableView heading shown for the Upcoming smart list when there are no tasks due in its window.")
        case .overdue: return String(
            localized: "tasks.empty.overdue.title",
            defaultValue: "Nothing Overdue",
            comment: "ContentUnavailableView heading shown for the Overdue smart list when there are no overdue tasks.")
        case .all: return String(
            localized: "tasks.empty.all.title",
            defaultValue: "No Tasks",
            comment: "ContentUnavailableView heading shown for the All smart list when there are no tasks at all.")
        case .completed: return String(
            localized: "tasks.empty.completed.title",
            defaultValue: "No Completed Tasks",
            comment: "ContentUnavailableView heading shown for the Completed smart list when there are no completed tasks.")
        }
    }

    private var emptyDescription: String {
        switch smartList {
        case .today: return String(
            localized: "tasks.empty.today.description",
            defaultValue: "You have no tasks due today. Enjoy your day!",
            comment: "ContentUnavailableView description shown for the Today smart list when there are no tasks due today.")
        case .upcoming: return String(
            localized: "empty.upcoming", defaultValue: "No tasks due in the next four weeks.",
            comment: "Empty state for the Upcoming smart list. Four weeks is the list's actual window (28 days); do not change the number without changing TaskListView's cutoff.")
        case .overdue: return String(
            localized: "tasks.empty.overdue.description",
            defaultValue: "Great job — you're all caught up!",
            comment: "ContentUnavailableView description shown for the Overdue smart list when there are no overdue tasks.")
        case .all: return String(
            localized: "tasks.empty.all.description",
            defaultValue: "Tap the + button to add your first task.",
            comment: "ContentUnavailableView description shown for the All smart list when there are no tasks at all; the plus sign refers to the toolbar's add button icon and must stay a literal plus sign.")
        case .completed: return String(
            localized: "tasks.empty.completed.description",
            defaultValue: "Completed tasks will appear here.",
            comment: "ContentUnavailableView description shown for the Completed smart list when there are no completed tasks.")
        }
    }
}

private struct GenericEmptyState: View {
    var body: some View {
        // These two literals are identical to `SmartListEmptyState`'s `.all` case. Written as
        // literals they extract correctly — but as *separate* English-as-key entries, so the same
        // sentence would be translated twice and could drift between two empty states the user
        // sees in the same session. Referencing the explicit keys instead keeps it one string.
        ContentUnavailableView {
            Label {
                Text(verbatim: String(
                    localized: "tasks.empty.all.title",
                    defaultValue: "No Tasks",
                    comment: "ContentUnavailableView heading shown for the All smart list when there are no tasks at all."))
            } icon: {
                Image(systemName: "checkmark.circle")
            }
        } description: {
            Text(verbatim: String(
                localized: "tasks.empty.all.description",
                defaultValue: "Tap the + button to add your first task.",
                comment: "ContentUnavailableView body shown for the All smart list when there are no tasks at all. The + is the toolbar add button's icon and must stay a literal plus sign."))
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
            .accessibilityLabel(String(localized: "tasks.a11y.addTask",
                                       defaultValue: "Add task",
                                       comment: "VoiceOver label for the toolbar button that opens the new-task sheet. Spoken, not shown — sentence case, unlike the visible 'Add Task' button and Shortcuts action of the same name."))
        }
    }
}
