import SwiftUI
import SwiftData
import WidgetKit

/// The Kanban board view providing a visual pipeline of task columns.
///
/// Columns are mapped to `TaskStatus` values: To Do → In Progress → Done → Cancelled.
/// Tasks can be dragged between columns to update their status, and within a column
/// to reorder it; each column shows the list's manual order. The board is scoped
/// to a single `TaskList` selected via a toolbar picker.
///
/// On iPhone, the board scrolls horizontally with snap-paging behavior.
/// On iPad, all columns are visible simultaneously.
struct KanbanBoardView: View {

    static let allListsPredicate = #Predicate<TaskList> { _ in true }
    static let activeTasksPredicate = #Predicate<TaskItem> { !$0.isDeletedLocally && $0.parentTask == nil }

    @State private var taskLists: [TaskList] = []
    @State private var allTasks: [TaskItem] = []

    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncCommands) private var syncCommands

    /// The way out when this screen is the hidden-destination sheet rather than a tab.
    ///
    /// The sheet cannot supply it. This view opens on its own `NavigationStack`, so a `.toolbar`
    /// applied at the presentation site has no bar of this view's to land on — and wrapping it in
    /// a second container to give it one is exactly the nesting `-[UINavigationBar layoutSubviews]`
    /// aborts on. Gated on `isPresented`, so the tab that hosts this same view keeps no Done
    /// button. See `NavigationContainerGuardTests`.
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss
    /// The one list selection, shared by both board modes and persisted.
    ///
    /// `@AppStorage` rather than the `@SceneStorage` that `MainShellView` uses for
    /// `sidebarSelection`, because scene storage is restoration state: it survives a
    /// rebuild and a backgrounding, but iOS discards it when the user force-quits,
    /// and it is not re-read on plain view construction. Verified in the simulator —
    /// with `@SceneStorage` the board came back in Status mode on the first list
    /// after a relaunch, which is the same complaint this fix is answering. The cost
    /// is that two iPad windows share one board selection, exactly as they already
    /// share `showCompletedTasks` in `KanbanListSwipeView`.
    @AppStorage("kanbanSelectedListID") private var selectedListID = KanbanListScope.unset
    @AppStorage("kanbanBoardMode") private var boardMode: BoardMode = .statusBoard
    @State private var draggedTaskID: String?
    /// Where each card is on screen, so a drop can tell which cards it landed between.
    @State private var cardFrames = KanbanCardFrames()
    /// The column a dragged card is over, which is the one that takes the drop.
    @State private var targetedStatus: TaskStatus?
    /// Where each column is on screen, so a drag resting on one partly off it can
    /// scroll it into view.
    @State private var columnSpans = KanbanColumnSpans()

    /// Board display modes.
    enum BoardMode: String, CaseIterable {
        case statusBoard = "Status"
        case listSwipe = "Lists"

        var displayName: String {
            switch self {
            case .statusBoard:
                return String(localized: "kanban.mode.status", defaultValue: "Status",
                              comment: "Kanban board mode: columns are task statuses. Segmented control, very short.")
            case .listSwipe:
                return String(localized: "kanban.mode.lists", defaultValue: "Lists",
                              comment: "Kanban board mode: columns are the user's lists. Segmented control, very short.")
            }
        }
    }

    /// The space between two columns. It is split between the columns on either
    /// side as padding inside their drop areas, rather than left as `LazyHStack`
    /// spacing that belonged to neither — a card released in the gap used to
    /// snap back as though the drop had missed.
    private static let columnGap: CGFloat = 14

    /// Names the board's visible area, which each column measures its position in.
    private static let boardSpace = "kanbanBoard"

    /// How long a drag rests over a partly visible column before the board
    /// scrolls to it — long enough that a card merely passing over it on the way
    /// to a drop does not throw the board sideways.
    private static let autoScrollDelay: Duration = .milliseconds(450)

    /// How long after a drop the board waits to settle on the column that took
    /// the card, so the card's own move has been laid out first.
    private static let settleDelay: Duration = .milliseconds(300)

    /// The visible columns (exclude Cancelled by default).
    private let visibleStatuses: [TaskStatus] = [
        .needsAction, .inProcess, .completed
    ]

    var body: some View {
        NavigationStack {
            Group {
                if liveLists.isEmpty {
                    emptyState
                } else if boardMode == .listSwipe {
                    KanbanListSwipeView(
                        taskLists: liveLists,
                        allTasks: liveRoots,
                        selectedListID: $selectedListID
                    )
                    .refreshable { await refresh() }
                } else {
                    boardContent
                }
            }
            .background(InboundQueryReader(descriptor: FetchDescriptor<TaskList>(sortBy: [SortDescriptor(\TaskList.name)])) { taskLists = $0 })
            .background(InboundQueryReader(descriptor: FetchDescriptor(predicate: Self.activeTasksPredicate,
                sortBy: [SortDescriptor(\TaskItem.createdDate, order: .reverse)])) { allTasks = $0 })
            .navigationTitle("Board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationDestination(for: TaskItem.self) { task in
                TaskDetailView(task: task)
            }
        }
    }

    // MARK: - Board Content

    private var boardContent: some View {
        ScrollViewReader { proxy in
            let projection = KanbanTaskProjection(tasks: liveRoots)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(visibleStatuses) { status in
                        let columnTasks = projection.column(status, listID: selectedList?.id)
                        // Ids, not models, for the drop closure: it runs a turn later,
                        // by which time a sync may have deleted one of these rows.
                        let columnIDs = columnTasks.map(\.id)
                        KanbanColumnView(
                            status: status,
                            tasks: columnTasks,
                            cardFrames: cardFrames,
                            isDropTarget: targetedStatus == status
                        ) { taskID, move in
                            moveTask(taskID, move, inColumn: status)
                        }
                        // On each column, and never above the horizontal scroll view.
                        // `.refreshable` there, which is where it used to be, drew the
                        // columns about 120pt below where they took touches — verified
                        // on iOS 26.5 and 27 — so pressing a short column's card grabbed
                        // the one further down, or nothing at all.
                        .refreshable { await refresh() }
                        .padding(.horizontal, Self.columnGap / 2)
                        .onGeometryChange(for: ClosedRange<CGFloat>.self) { geometry in
                            let frame = geometry.frame(in: .named(Self.boardSpace))
                            return frame.minX...frame.maxX
                        } action: { span in
                            columnSpans.spans[status] = span
                        }
                        .contentShape(Rectangle())
                        .coordinateSpace(.named(KanbanColumnView.coordinateSpace))
                        .dropDestination(for: String.self) { droppedIDs, location in
                            let otherIDs = columnIDs.filter { !droppedIDs.contains($0) }
                            let index = KanbanReorder.insertionIndex(
                                forDropAtY: location.y,
                                cardMidYs: otherIDs.map { cardFrames.midY(of: $0) }
                            )
                            targetedStatus = nil
                            moveTasks(ids: droppedIDs, to: status, at: index)
                            // A drop can interrupt a scroll still under way and leave
                            // the board resting between columns. Settle on the one
                            // that took the card, so the user sees where it went.
                            Task {
                                try? await Task.sleep(for: Self.settleDelay)
                                reveal(status, with: proxy)
                            }
                            return true
                        } isTargeted: { isTargeted in
                            dropTargetChanged(to: status, isTargeted: isTargeted, proxy: proxy)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16 - Self.columnGap / 2)
                .padding(.vertical, 12)
            }
            .scrollTargetBehavior(.viewAligned)
            .coordinateSpace(.named(Self.boardSpace))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                columnSpans.viewportWidth = width
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private func refresh() async {
        await syncCommands.syncNow(modelContext)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Lists", systemImage: "rectangle.split.3x1")
        } description: {
            Text("Create a list to start using the Kanban board.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isPresented {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }

        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: $boardMode) {
                ForEach(BoardMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .accessibilityLabel("Board mode")
        }

        if boardMode == .statusBoard {
            ToolbarItem(placement: .topBarTrailing) {
                if liveLists.count > 1 {
                    Menu {
                        ForEach(liveLists) { list in
                            Button {
                                selectedListID = list.id
                            } label: {
                                HStack {
                                    Text(list.name)
                                    // Against the resolved list, not the raw stored id,
                                    // so the list the board actually shows is ticked
                                    // even before the user has picked one.
                                    if list.id == selectedList?.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedList?.name ?? String(localized: "calendar.title.allLists", defaultValue: "All Lists", comment: "Toolbar title shown where a selected list's name would otherwise appear, used when no specific list is selected (effectively all lists); previously said List in English here, changed to respect the glossary since Calendar is reserved for the separate Apple/EventKit calendar feature in Settings and a CalDAV collection is called a List"))
                                .font(.subheadline)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Select list")
                    .accessibilityHint("Double tap to choose a different list")
                }
            }
        }
    }

    // MARK: - Data

    /// Liveness at the array boundary, matching `KanbanListSwipeView.liveLists`.
    ///
    /// Every `TaskList` read in this view goes through here: the empty-state test,
    /// the toolbar's count and menu, and the id handed to `KanbanListScope`, whose
    /// `resolvedList` documents that it is given lists "known to be live" and reads
    /// `$0.id` on each. Deleting an account cascades `ServerAccount` -> `TaskList`
    /// -> `TaskItem` on the main context and deleting a list cascades to its tasks,
    /// so a board still on screen re-renders over models whose backing rows have
    /// gone.
    private var liveLists: [TaskList] {
        TaskListHelpers.liveModels(taskLists, in: modelContext)
    }

    private var liveRoots: [TaskItem] {
        TaskListHelpers.liveTasks(allTasks, in: modelContext,
            matching: FetchDescriptor(predicate: Self.activeTasksPredicate))
    }

    private var selectedList: TaskList? {
        KanbanListScope.resolvedList(id: selectedListID, in: liveLists)
    }

    /// A column's cards in the list's manual order. Sorted here rather than by the
    /// `@Query`, which can only sort on a stored key path and not on the
    /// `effectiveSortOrder` a push actually writes.
    private func tasksForColumn(_ status: TaskStatus) -> [TaskItem] {
        KanbanTaskProjection(tasks: liveRoots).column(status, listID: selectedList?.id)
    }

    // MARK: - Drag & Drop

    /// Moves dropped cards into `status`'s column, at `index` among the cards
    /// already there.
    ///
    /// A card dropped on its own column only changes place. One dropped on another
    /// column changes status first and then takes its place. `index` counts the
    /// column's other cards — see `KanbanReorder`.
    private func moveTasks(ids: [String], to status: TaskStatus, at index: Int) {
        // Liveness, for the same reason the row's swipe actions carry it: a
        // drop resolves a turn after the drag began, and writing to a task an
        // account delete has cascaded away traps exactly like reading one.
        let moving = ids.compactMap { id in
            allTasks.first { $0.modelContext != nil && $0.id == id }
        }
        let others = tasksForColumn(status).filter { !ids.contains($0.id) }

        var completedIDs: [String] = []
        var changedStatus = false
        for task in moving where task.status != status {
            changedStatus = true
            // Shared with the checkbox rather than copied beside it. The copy that
            // used to live here had drifted: it advanced a recurring task's due
            // date without moving its start date with it.
            if TaskCompletionLogic.apply(status, to: task) {
                completedIDs.append(task.id)
            }
        }

        // A repeating card dragged to Done advances to its next occurrence and
        // stays in To Do, so only the cards that actually arrived take a place.
        KanbanReorder.place(moving.filter { $0.status == status }, at: index, among: others)

        // A card dropped back where it was changes nothing, and is not worth a
        // save, a widget reload or a sync.
        guard modelContext.hasChanges else { return }
        do { try ReminderSchedulingJournal.saveTaskChanges(in: modelContext) }
        catch { return }
        // Completing a task ends its reminders, including the hourly nag — the
        // same call `TaskRowView` makes for the checkbox. Dragging a card to Done
        // never made it, and the bulk sweep only runs after a sync, so on a
        // local-only Vault account nothing ever cancelled them.
        for id in completedIDs {
            ReminderScheduler.cancelReminder(for: id)
        }
        WidgetCenter.shared.reloadAllTimelines()
        // See TaskRowView: dragging a recurring card to Done advances its due date.
        // A reorder moves no dates, so it skips the reconcile.
        if changedStatus {
            ReminderScheduler.requestReconcile(modelContext: modelContext)
        }
        // The task list's own reorder and checkbox both ask for this. The board
        // never did, so a drag reached the server only when something else next
        // triggered a sync.
        syncCommands.syncAfterChange(modelContext)
    }

    /// Highlights the column a card is over and, when the drag rests there,
    /// scrolls it into view — see ``KanbanAutoScroll``.
    private func dropTargetChanged(to status: TaskStatus, isTargeted: Bool, proxy: ScrollViewProxy) {
        guard isTargeted else {
            if targetedStatus == status { targetedStatus = nil }
            return
        }
        targetedStatus = status
        Task {
            try? await Task.sleep(for: Self.autoScrollDelay)
            guard targetedStatus == status else { return }
            reveal(status, with: proxy)
        }
    }

    /// Scrolls `status`'s column fully on screen, if it is not already.
    private func reveal(_ status: TaskStatus, with proxy: ScrollViewProxy) {
        guard let span = columnSpans.spans[status],
              let alignment = KanbanAutoScroll.alignment(
                forColumnFrom: span.lowerBound, to: span.upperBound,
                inViewportOfWidth: columnSpans.viewportWidth)
        else { return }
        withAnimation {
            // The column's `ForEach` identity is `status.id`, its raw value, not
            // the status itself; a `TaskStatus` here matches nothing and scrolls
            // nowhere.
            proxy.scrollTo(status.id, anchor: alignment == .leading ? .leading : .trailing)
        }
    }

    /// Carries out a Move action from a card's menu or its VoiceOver actions.
    private func moveTask(_ taskID: String, _ move: KanbanReorder.Move, inColumn status: TaskStatus) {
        let column = tasksForColumn(status)
        guard let position = column.firstIndex(where: { $0.id == taskID }),
              let target = KanbanReorder.targetIndex(for: move, from: position, count: column.count)
        else { return }
        moveTasks(ids: [taskID], to: status, at: target)
    }
}

/// Where each board column is within the board's visible area.
///
/// Not observed, like ``KanbanCardFrames``: columns report their position on
/// every frame of a scroll, and it is read only when a drag rests on one.
@MainActor
final class KanbanColumnSpans {
    var spans: [TaskStatus: ClosedRange<CGFloat>] = [:]
    var viewportWidth: CGFloat = 0
}
