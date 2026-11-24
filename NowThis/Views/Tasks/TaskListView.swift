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
    let savedFilter: SavedFilterSnapshot?
    private let lastKnownFilterName: String?
    private let retrySavedFilters: (() -> Void)?
    @Binding private var deepLinkTaskID: String?
    let allowsDeepLinkPresentation: Bool
    private let showsSidebarButton: Bool
    @State private var taskSheetIsActive = false
    @State private var quickAddSheetIsActive = false
    @State private var hiddenSheetIsActive = false
    @State private var editingFilter: SavedFilterSnapshot?
    @State private var filterSheetIsActive = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.saveErrorState) private var errorState
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
    @State private var sourceProjection = ObservedProjectionCache<SourceProjectionKey, [TaskItem]>()

    private struct SourceProjectionKey: Equatable {
        let roots: [ObjectIdentifier]
        let revision: UInt64
        let selection: String
        let sort: TaskSortOption
        let ascending: Bool
        let showCompleted: Bool
        let priority: TaskPriority?
        let calendar: Calendar
        let day: Date
        let locale: String
    }
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

    @State private var creationDraft = TaskCreationDraft()
    @State private var inlineTaskTitle = ""
    @FocusState private var inlineFieldFocused: Bool
    /// Per-entry due-date override chosen from the add bar's chip. `nil` uses the
    /// resolved contextual/default rule.
    @State private var inlineDueOverride: DefaultDueDateRule?

    /// Selection scopes the replaceable query reader, preserving this screen's state.
    init(selection: SidebarSelection, savedFilter: SavedFilterSnapshot? = nil,
         lastKnownFilterName: String? = nil, retrySavedFilters: (() -> Void)? = nil,
         deepLinkTaskID: Binding<String?> = .constant(nil),
         allowsDeepLinkPresentation: Bool = true, showsSidebarButton: Bool = false) {
        self.selection = selection
        self.savedFilter = savedFilter
        self.lastKnownFilterName = lastKnownFilterName
        self.retrySavedFilters = retrySavedFilters
        self._deepLinkTaskID = deepLinkTaskID
        self.allowsDeepLinkPresentation = allowsDeepLinkPresentation
        self.showsSidebarButton = showsSidebarButton
    }

    private func selectTask(_ task: TaskItem) {
        taskSheetIsActive = true
        selectedTask = SelectedTask(task)
    }

    private func showQuickAdd() {
        quickAddSheetIsActive = true
        showingQuickAdd = true
    }

    private func presentPendingTaskLink() {
        let busy = !allowsDeepLinkPresentation || quickAddSheetIsActive || showingQuickAdd
            || hiddenSheetIsActive || presentedHiddenTab != nil || taskSheetIsActive
            || filterSheetIsActive || editingFilter != nil
            || !inlineTaskTitle.isEmpty || creationDraft.hasPendingTask
        do {
            try Self.routeDeepLink(request: $deepLinkTaskID,
                selectedTask: Binding(get: { selectedTask }, set: {
                    selectedTask = $0
                    if $0 != nil { taskSheetIsActive = true }
                }), context: modelContext, isBusy: busy)
        } catch { (errorState ?? .shared).show(error) }
    }

    static func routeDeepLink(request: Binding<String?>, selectedTask: Binding<SelectedTask?>,
        context: ModelContext, isBusy: Bool) throws {
        guard let id = request.wrappedValue else { return }
        if let current = selectedTask.wrappedValue,
           current.id == id, current.task.modelContext != nil {
            // The editor already owns this task; retain its unsaved text and nested sheets.
            request.wrappedValue = nil
            return
        }
        guard !isBusy, selectedTask.wrappedValue == nil else { return }
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id && !$0.isDeletedLocally })
        descriptor.fetchLimit = 1
        if let task = try context.fetch(descriptor).first {
            selectedTask.wrappedValue = SelectedTask(task)
        }
        // Missing/deleted targets are safe no-ops. A fetch error leaves the request pending.
        request.wrappedValue = nil
    }

    static func showsInlineComposer(verticalSizeClass: UserInterfaceSizeClass?,
        dynamicTypeSize: DynamicTypeSize, isFocused: Bool, title: String, hasPendingTask: Bool = false) -> Bool {
        verticalSizeClass != .compact || !dynamicTypeSize.isAccessibilitySize
            || isFocused || !title.isEmpty || hasPendingTask
    }

    private var queryListID: String? {
        if case .taskList(let id) = selection { return id }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showsSidebarButton {
                    CompactSidebarButton().padding(.leading, 8)
                }
                FilterBar(
                    activeSort: $activeSort,
                    sortDirection: $sortDirection,
                    showCompleted: $showCompleted,
                    priorityFilter: $priorityFilter
                )
            }

            Divider().opacity(0.5)

            Group {
                if case .savedFilter = selection, savedFilter?.criteria == nil {
                    savedFilterUnavailable
                } else if currentSmartList == .upcoming || currentSmartList == .overdue {
                    let sections = sectionedOccurrences
                    if sections.isEmpty {
                        tappableEmptyState
                    } else {
                        SectionedTaskListContent(
                            sections: sections,
                            onSelect: selectTask,
                            showGroupingToggle: currentSmartList == .upcoming,
                            grouping: $upcomingGrouping
                        )
                    }
                } else {
                    let tasks = displayedTasks
                    let ascending = sortDirection.isAscending
                    if tasks.isEmpty {
                        tappableEmptyState
                    } else {
                        TasksListContent(
                            tasks: tasks,
                            dataRevision: queryRevision,
                            manualReorder: activeSort == .manually,
                            activeSort: activeSort,
                            ascending: ascending,
                            onSelect: selectTask,
                            onMove: { source, destination in
                                _ = moveTasks(tasks, from: source, to: destination, ascending: ascending)
                            },
                            onMoveSubtasks: { siblings, parentID, source, destination in
                                moveTasks(siblings, from: source, to: destination, ascending: ascending, parentID: parentID)
                            },
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
            // In short large-text windows the toolbar's Add button remains available.
            // Keep any active inline entry mounted so adaptation cannot drop its draft.
            if Self.showsInlineComposer(verticalSizeClass: verticalSizeClass,
                dynamicTypeSize: dynamicTypeSize, isFocused: inlineFieldFocused, title: inlineTaskTitle,
                hasPendingTask: creationDraft.hasPendingTask) {
                InlineAddBar(
                    title: $inlineTaskTitle,
                    isFocused: $inlineFieldFocused,
                    dueRuleLabel: inlineDueChipLabel,
                    dueRuleIsSet: inlineEffectiveRule != .none,
                    onPickRule: { inlineDueOverride = $0 },
                    onSubmit: createInlineTask,
                    onExpandTap: showQuickAdd,
                    onCancel: inlineCancellationAction
                )
            }
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
        .sheet(item: $presentedHiddenTab, onDismiss: {
            hiddenSheetIsActive = false
            presentPendingTaskLink()
        }) { tab in
            hiddenDestination(for: tab)
                .modifier(HiddenDestinationErrorScope())
                .blocksTaskLinks()
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
        .toolbar {
            TaskListToolbar(onAdd: showQuickAdd)
            if let savedFilter, savedFilter.criteria != nil {
                ToolbarItem(placement: .secondaryAction) {
                    Button { editFilter(savedFilter) } label: { Label("Edit Filter", systemImage: "pencil") }
                }
            }
        }
        .sheet(item: $editingFilter, onDismiss: {
            filterSheetIsActive = false
            presentPendingTaskLink()
        }) { filter in
            FilterBuilderView(existingFilter: filter)
        }
        .sheet(isPresented: $showingQuickAdd, onDismiss: {
            quickAddSheetIsActive = false
            presentPendingTaskLink()
        }) {
            QuickAddView(defaultList: defaultTaskList, defaultSmartList: currentSmartList,
                         explicitListID: selectedTaskListID)
        }
        .sheet(item: $selectedTask, onDismiss: {
            taskSheetIsActive = false
            presentPendingTaskLink()
        }) { selection in
            NavigationStack {
                TaskDetailView(task: selection.task)
            }
        }
        .blocksTaskLinks(isActive: !inlineTaskTitle.isEmpty || creationDraft.hasPendingTask)
        .onChange(of: deepLinkTaskID, initial: true) { _, _ in presentPendingTaskLink() }
        .onChange(of: allowsDeepLinkPresentation) { _, allowed in
            if allowed { presentPendingTaskLink() }
        }
        .onChange(of: inlineTaskTitle) { _, _ in presentPendingTaskLink() }
        .onChange(of: creationDraft.hasPendingTask) { _, _ in presentPendingTaskLink() }
        .onChange(of: queryRevision) { _, _ in presentPendingTaskLink() }
        .onChange(of: presentedHiddenTab) { _, tab in
            if tab != nil { hiddenSheetIsActive = true }
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
            KanbanBoardView()
        case .calendar:
            CalendarContainerView()
        case .matrix:
            EisenhowerMatrixView()
        case .smart(let list):
            // Matches `ContentView.destination(for:)`'s `.smart` case:
            // `TaskListView` supplies no navigation container of its own, so this branch is the
            // one that has to — and, being the container, the one that carries the way out.
            NavigationStack {
                TaskListView(selection: .smart(list))
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
        case .savedFilter:
            return savedFilter?.name ?? lastKnownFilterName ?? String(
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
        // Keep the fresh identifier guard even on a cache hit: a worker-context
        // cascade can delete a retained model before its query publication arrives.
        let roots = liveRoots
        let sorted: [TaskItem]
        let calendar = Calendar.current
        let key = SourceProjectionKey(roots: roots.map(ObjectIdentifier.init), revision: queryRevision,
            selection: selection.encoded, sort: activeSort, ascending: sortDirection.isAscending,
            showCompleted: showCompleted, priority: priorityFilter, calendar: calendar,
            day: calendar.startOfDay(for: Date()), locale: Locale.current.identifier)
        // Recompute saved-filter results from the selected committed criteria snapshot.
        if case .savedFilter = selection {
            sorted = sortedSourceTasks(from: roots)
        } else if activeSort == .relevance {
            sorted = sortedSourceTasks(from: roots)
        } else {
            sorted = sourceProjection.value(for: key) { sortedSourceTasks(from: roots) }
        }
        // Search changes only filter the already ordered source. Deduplicate after
        // searching so a different copy of the same UID can satisfy the query.
        return TaskListHelpers.searchAndDeduplicate(sorted, query: searchText)
    }

    private func sortedSourceTasks(from roots: [TaskItem]) -> [TaskItem] {
        let interval = PerformanceTrace.begin("TaskListSort", count: roots.count)
        defer { PerformanceTrace.end("TaskListSort", interval) }
        var result = roots
        switch selection {
        case .smart(let smart): result = filterForSmartList(smart, from: result)
        case .taskList: break
        case .savedFilter: result = applyCustomFilter(to: result)
        case .tag(let tagID): result = result.filter { $0.tags.contains(where: { $0.id == tagID }) }
        case .journals: return []
        }
        if let priorityFilter { result = result.filter { $0.priority == priorityFilter } }
        if currentSmartList != .completed && !showCompleted {
            result = result.filter { $0.status != .completed }
        }
        return TaskListHelpers.sortedWithCompletedLast(result, by: activeSort,
            ascending: sortDirection.isAscending)
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
    private func applyCustomFilter(to tasks: [TaskItem]) -> [TaskItem] {
        guard let criteria = savedFilter?.criteria else { return [] }

        return criteria.matchingTasks(tasks)
    }

    private func editFilter(_ filter: SavedFilterSnapshot) {
        filterSheetIsActive = true
        editingFilter = filter
    }

    private var savedFilterUnavailable: some View {
        ContentUnavailableView {
            Label(title, systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            if retrySavedFilters != nil {
                Text(FilterRepairCopy.loadFailed)
            } else {
                Text(savedFilter == nil ? FilterRepairCopy.unavailable : FilterRepairCopy.required)
            }
        } actions: {
            if let retrySavedFilters {
                Button("Retry", action: retrySavedFilters)
            } else if let savedFilter {
                Button("Edit Filter") { editFilter(savedFilter) }
            }
        }
    }

    /// The list currently in view, if the selection names one. `nil` for smart
    /// lists, tags, saved filters and journals — where the user's default applies.
    private var selectedTaskListID: String? {
        guard case .taskList(let listID) = selection else { return nil }
        return listID
    }

    private var selectedTaskList: TaskList? {
        guard let targetID = selectedTaskListID else { return nil }
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

    private var inlineCancellationAction: (() -> Void)? {
        guard creationDraft.hasPendingTask else { return nil }
        return { cancelInlineTask() }
    }

    private func cancelInlineTask() {
        do { try creationDraft.cancelInlineAddition(in: modelContext) }
        catch { (errorState ?? .shared).show(error); return }
        inlineTaskTitle = ""
        inlineDueOverride = nil
        inlineFieldFocused = false
        presentPendingTaskLink()
    }

    private func createInlineTask() {
        let trimmed = inlineTaskTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let manualAscending = activeSort != .manually || sortDirection.isAscending
        Self.commitInlineCreation(title: trimmed, selectedTaskList: selectedTaskList,
            explicitListID: selectedTaskListID, liveRoots: liveRoots,
            manualAscending: manualAscending, dueDateRule: { inlineEffectiveRule }, creationDraft: creationDraft,
            modelContext: modelContext, errorState: errorState
        ) { task in
            if task.reminderOffset != nil {
                ReminderScheduler.requestPermissionIfNeeded()
            }
            // Unconditional — see QuickAddView. The inline row's default rule can hand the task a
            // due date with no reminder, which is precisely the case that scheduled nothing.
            ViewPersistence.recoverRemindersAfterCommit(errorState: errorState) {
                try ReminderScheduler.requestReconcileOrThrow(modelContext: modelContext)
            }
            syncCommands.syncAfterChange(modelContext)
            HapticManager.success()

            inlineTaskTitle = ""
            inlineDueOverride = nil
            // Keep focus so the user can add multiple tasks quickly.
            inlineFieldFocused = true
        }
    }

    @MainActor
    static func commitInlineCreation(title trimmed: String, selectedTaskList: TaskList?,
                                     explicitListID: String? = nil, liveRoots: [TaskItem],
                                     manualAscending: Bool, dueDateRule: () -> DefaultDueDateRule,
                                     creationDraft: TaskCreationDraft, modelContext: ModelContext,
                                     errorState: ErrorState?, save: (() throws -> Void)? = nil,
                                     didCommit: (TaskItem) -> Void) {
        let list: TaskList?
        let preferenceChange: NewTaskDefaults.PreferenceChange?
        do {
            let destination: TaskWriteEligibility.CreationDestination
            if let id = explicitListID ?? selectedTaskList?.id {
                destination = .list(id: id, expectedPersistentID: selectedTaskList?.persistentModelID)
                preferenceChange = nil
            } else {
                let choice = try NewTaskDefaults.creationList(explicit: nil, in: ModelContext(modelContext.container))
                destination = choice.list.map { .list(id: $0.id, expectedPersistentID: $0.persistentModelID) } ?? .unbound
                preferenceChange = choice.preferenceChange
            }
            list = try TaskWriteEligibility(writingIn: modelContext).destination(destination)
        } catch {
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState, creating: true)
            return
        }

        let task: TaskItem
        do { task = try creationDraft.task(title: trimmed) }
        catch { (errorState ?? .shared).show(error); return }
        task.taskList = list

        // Apply the resolved due-date + reminder defaults so the task stays
        // visible in the view that created it and honors per-list/global settings.
        let resolved = NewTaskDefaults.resolve(
            smartList: nil,
            rule: dueDateRule(),
            reminderEnabled: NewTaskDefaults.effectiveReminderEnabled(for: task.taskList)
        )
        task.dueDate = resolved.dueDate
        task.isDueDateOnly = resolved.isDueDateOnly
        task.reminderOffset = resolved.reminderOffset

        // Give the draft a low rank. Manual ascending shows it first within
        // its scope, while manual descending shows it after other active rows.
        guard TaskListHelpers.saveInlineTask(task, withLowerRankThan: liveRoots,
            manualAscending: manualAscending, in: modelContext, errorState: errorState, save: save) else {
            // The field keeps the title and due override for a new attempt.
            // The failed insertion and its journal were discarded by the save.
            creationDraft.didSave()
            return
        }
        preferenceChange?.commit()
        creationDraft.didSave()
        didCommit(task)
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

    /// Save the drag against the roots or siblings that supplied its offsets.
    private func moveTasks(_ displayed: [TaskItem], from source: IndexSet, to destination: Int,
                           ascending: Bool, parentID: String? = nil) -> Bool {
        let predicate: Predicate<TaskItem>
        if let parentID {
            predicate = #Predicate { !$0.isDeletedLocally && $0.parentTask?.id == parentID }
        } else {
            predicate = Self.taskQueryPredicate(for: selection)
        }
        guard TaskListHelpers.saveManualMove(displayed, from: source, to: destination,
            ascending: ascending, in: modelContext, matching: FetchDescriptor(predicate: predicate),
            errorState: errorState) else { return false }
        syncCommands.syncAfterChange(modelContext)
        HapticManager.softImpact()
        return true
    }

    // MARK: - Sectioned Occurrences (Upcoming / Overdue)

    /// Groups each task's current occurrence by time period.
    private var sectionedOccurrences: [TaskSection] {
        guard let smartList = currentSmartList,
              (smartList == .upcoming || smartList == .overdue) else { return [] }

        let cal = Calendar.current
        let occurrences = Self.sectionedTaskOccurrences(from: liveRoots, smartList: smartList,
                                                        searchText: searchText, priority: priorityFilter, now: Date())
        if smartList == .upcoming {
            return Self.groupOccurrences(occurrences, by: upcomingGrouping == "weekly" ? .weekOfYear : .month, calendar: cal)
        } else {
            // Overdue: group by month going back
            return Self.groupOccurrences(occurrences, by: .month, calendar: cal)
        }
    }

    /// The caller supplies live roots from the selected view's query.
    static func sectionedTaskOccurrences(from roots: [TaskItem], smartList: SmartList, searchText: String,
                                        priority: TaskPriority?, now: Date) -> [TaskOccurrence] {
        var baseTasks = roots.filter { $0.status != .completed }

        // Search before UID deduplication so the matching copy can survive.
        if !searchText.isEmpty {
            baseTasks = baseTasks.filter { TaskListHelpers.matchesSearch($0, query: searchText) }
        }

        // Apply priority filter
        if let priority {
            baseTasks = baseTasks.filter { $0.priority == priority }
        }

        // Deduplicate by UID
        baseTasks = TaskListHelpers.deduplicateByUID(baseTasks)

        return TaskListHelpers.occurrences(from: baseTasks, smartList: smartList, now: now)
    }

    /// Groups occurrences into titled sections by calendar component.
    static func groupOccurrences(
        _ occurrences: [TaskOccurrence],
        by component: Calendar.Component,
        calendar: Calendar
    ) -> [TaskSection] {
        let grouped = Dictionary(grouping: occurrences) { occurrence -> Date in
            let day = DueDateHelper.localStartOfDay(for: occurrence.occurrenceDate,
                                                    isDateOnly: occurrence.isDueDateOnly,
                                                    regionCalendar: calendar)
            return calendar.dateInterval(of: component, for: day)?.start ?? day
        }

        var dateStyle = Date.FormatStyle.dateTime.year()
        dateStyle.calendar = calendar
        dateStyle.timeZone = calendar.timeZone
        let weekStyle = Date.IntervalFormatStyle(calendar: calendar, timeZone: calendar.timeZone)
            .year().month(.abbreviated).day()

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
                    ? (key..<end).formatted(weekStyle)
                    : key.formatted(dateStyle.month(.abbreviated).day())
                return TaskSection(title: label, occurrences: grouped[key] ?? [])
            } else {
                return TaskSection(title: key.formatted(dateStyle.month(.wide)),
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
    let onMoveSubtasks: ([TaskItem], String, IndexSet, Int) -> Bool
    /// Tapping the blank area beneath the last row focuses the inline add field.
    let onTapEmptyArea: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.saveErrorState) private var errorState

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
    private func reparentTask(_ droppedTaskID: String?, _ newParent: TaskItem?) -> Bool {
        guard let droppedTaskID,
              TaskHierarchyTraversal.reparent(taskID: droppedTaskID, under: newParent, in: modelContext, errorState: errorState)
        else { return false }
        guard ViewPersistence.saveOrReport(in: modelContext, errorState: errorState) else { return false }
        HapticManager.softImpact()
        return true
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
    let isDueDateOnly: Bool
    let id: String

    init(task: TaskItem, occurrenceDate: Date) {
        self.task = task
        self.occurrenceDate = occurrenceDate
        self.isDueDateOnly = task.isDueDateOnly
        self.id = "\(task.id)-\(occurrenceDate.timeIntervalSince1970)"
    }

    func spokenDueDate(timeZone: TimeZone = .current) -> String {
        DueDateFormatter.accessibilityLabel(occurrenceDate, isDateOnly: isDueDateOnly, timeZone: timeZone,
                                            timedStyle: Date.FormatStyle(date: .abbreviated, time: .omitted))
    }
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
                            .accessibilityLabel("\(data.title), due \(occurrence.spokenDueDate())")
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
    let onReparent: (String?, TaskItem?) -> Bool
    let onMoveSubtasks: ([TaskItem], String, IndexSet, Int) -> Bool

    private typealias Hierarchy = TaskListHierarchyProjection<TaskItem, String>
    private struct ProgressKey: Equatable {
        let rootIdentity: ObjectIdentifier
        let dataRevision: UInt64
    }

    @State private var hierarchyState = TaskListRootHierarchyState<TaskItem, String>()
    @State private var progressCache = ObservedProjectionCache<
        ProgressKey, TaskHierarchyProgressIndex<TaskItem>
    >()
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
        TaskHierarchyRow(task: task, progressIndex: hierarchyProgress, depth: 0,
            hasChildren: hierarchyState.projection?.rows.first?.hasChildren ?? false,
            isExpanded: expansion(for: rootID), onSelect: onSelect,
            onReparent: { child, parent in onReparent(child, parent) },
            enableReparentDrag: !manualReorder)
            .onAppear { rowAppeared(rootID) }
            .onDisappear { visibleTaskIDs.remove(rootID) }
    }

    private var descendantRows: some View {
        let projection = hierarchyState.projection
        let rows: [Hierarchy.Row] = Array(projection?.rows.dropFirst() ?? [])
        let progressIndex = hierarchyProgress
        return ForEach(rows) { entry in
            TaskHierarchyRow(task: entry.node, progressIndex: progressIndex, depth: entry.depth,
                hasChildren: entry.hasChildren, isExpanded: expansion(for: entry.id),
                onSelect: onSelect,
                onReparent: { child, parent in onReparent(child, parent) },
                enableReparentDrag: !manualReorder)
                .listRowSeparator(.hidden)
                .onAppear { rowAppeared(entry.id) }
                .onDisappear { visibleTaskIDs.remove(entry.id) }
        }
        .onMove(perform: manualReorder ? { source, destination in
            // This ForEach omits the root, while the projection includes it.
            guard let move = projection?.move(from: IndexSet(source.map { $0 + 1 }), to: destination + 1),
                  let siblings = move.siblings,
                  let parentID = move.parentID,
                  onMoveSubtasks(siblings, parentID, move.source, move.destination) else { return }
            // A committed move can leave this cached projection out of date.
            invalidateHierarchy()
        } : nil)
    }

    /// Lazily shares progress only while this root's rows are realized. The
    /// cache key changes for replacement roots and every parent-owned revision;
    /// observed model reads also invalidate it for unsaved local mutations.
    private var hierarchyProgress: TaskHierarchyProgressIndex<TaskItem>? {
        guard !visibleTaskIDs.isEmpty, task.modelContext != nil else { return nil }
        let key = ProgressKey(rootIdentity: ObjectIdentifier(task), dataRevision: dataRevision)
        return progressCache.value(for: key) {
            TaskHierarchyProgressIndex(
                roots: [task],
                isVisible: { $0.modelContext != nil && !$0.isDeletedLocally },
                children: { $0.subtasks },
                isCompleted: { $0.status == .completed }
            )
        }
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

    private func invalidateHierarchy(fromObservation generation: UInt64? = nil) {
        guard hierarchyState.invalidate(fromObservation: generation) else { return }
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
        let generation = hierarchyState.observationGeneration
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
                Task { @MainActor in invalidateHierarchy(fromObservation: generation) }
            }
        }
    }
}

/// One lazily instantiated task row. Descendants are separate rows in the flat List.
/// Chevron, drag and row actions keep their existing behavior. Visual indentation
/// stops at four levels while the projection preserves the full hierarchy depth.
private struct TaskHierarchyRow: View {
    let task: TaskItem
    let progressIndex: TaskHierarchyProgressIndex<TaskItem>?
    let depth: Int
    let hasChildren: Bool
    @Binding var isExpanded: Bool
    let onSelect: (TaskItem) -> Void
    var onReparent: ((String, TaskItem?) -> Bool)?
    /// Disabled in manual mode so reparenting does not conflict with reorder.
    var enableReparentDrag: Bool = true

    var body: some View {
        // A fixed outer container gives List one row per identity, so it can
        // defer row snapshots instead of resolving a conditional row count.
        HStack(spacing: 0) {
            // Establish liveness before chevron, content or drag reads.
            if task.modelContext != nil,
               let data = TaskRowData(task: task, progress: progressIndex?.progress(for: task)) {
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
                          let onReparent else { return false }
                    return onReparent(droppedID, task)
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
                Label(String(localized: "tasks.a11y.addTask",
                             defaultValue: "Add task",
                             comment: "VoiceOver label for the toolbar button that opens the new-task sheet. Spoken, not shown — sentence case, unlike the visible 'Add Task' button and Shortcuts action of the same name."),
                      systemImage: "plus")
            }
            .labelStyle(.iconOnly)
        }
    }
}

/// Board, Calendar and Matrix can be presented above ContentView's shared alert.
/// Their save reporters must target this active sheet instead of its presenter.
private struct HiddenDestinationErrorScope: ViewModifier {
    @State private var errorState = ErrorState()

    func body(content: Content) -> some View {
        content
            .environment(\.saveErrorState, errorState)
            .errorBanner(errorState)
    }
}
