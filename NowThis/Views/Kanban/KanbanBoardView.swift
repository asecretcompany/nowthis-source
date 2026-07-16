import SwiftUI
import SwiftData
import WidgetKit

/// The Kanban board view providing a visual pipeline of task columns.
///
/// Columns are mapped to `TaskStatus` values: To Do → In Progress → Done → Cancelled.
/// Tasks can be dragged between columns to update their status. The board is scoped
/// to a single `TaskList` selected via a toolbar picker.
///
/// On iPhone, the board scrolls horizontally with snap-paging behavior.
/// On iPad, all columns are visible simultaneously.
struct KanbanBoardView: View {

    static let allListsPredicate = #Predicate<TaskList> { _ in true }
    static let activeTasksPredicate = #Predicate<TaskItem> { !$0.isDeletedLocally }

    @Query(
        filter: Self.allListsPredicate,
        sort: \TaskList.name
    ) private var taskLists: [TaskList]

    @Query(
        filter: Self.activeTasksPredicate,
        sort: \TaskItem.createdDate, order: .reverse
    ) private var allTasks: [TaskItem]

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncScheduler: SyncScheduler
    @State private var selectedListID: String?
    @State private var draggedTaskID: String?
    @State private var boardMode: BoardMode = .statusBoard

    /// Board display modes.
    enum BoardMode: String, CaseIterable {
        case statusBoard = "Status"
        case listSwipe = "Lists"
    }

    /// The visible columns (exclude Cancelled by default).
    private let visibleStatuses: [TaskStatus] = [
        .needsAction, .inProcess, .completed
    ]

    var body: some View {
        NavigationStack {
            Group {
                if taskLists.isEmpty {
                    emptyState
                } else if boardMode == .listSwipe {
                    KanbanListSwipeView(taskLists: taskLists, allTasks: allTasks)
                } else {
                    boardContent
                }
            }
            .refreshable {
                await syncScheduler.syncNow(modelContext: modelContext)
            }
            .navigationTitle("Board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationDestination(for: TaskItem.self) { task in
                TaskDetailView(task: task)
            }
            .onAppear {
                if selectedListID == nil {
                    selectedListID = taskLists.first?.id
                }
            }
        }
    }

    // MARK: - Board Content

    private var boardContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(visibleStatuses) { status in
                    KanbanColumnView(
                        status: status,
                        tasks: tasksForColumn(status)
                    )
                    .dropDestination(for: String.self) { droppedIDs, _ in
                        moveTasksToStatus(ids: droppedIDs, newStatus: status)
                        return true
                    } isTargeted: { _ in }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollTargetBehavior(.viewAligned)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Task Lists", systemImage: "rectangle.split.3x1")
        } description: {
            Text("Create a task list to start using the Kanban board.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: $boardMode) {
                ForEach(BoardMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .accessibilityLabel("Board mode")
        }

        if boardMode == .statusBoard {
            ToolbarItem(placement: .topBarTrailing) {
                if taskLists.count > 1 {
                    Menu {
                        ForEach(taskLists) { list in
                            Button {
                                selectedListID = list.id
                            } label: {
                                HStack {
                                    Text(list.name)
                                    if list.id == selectedListID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedList?.name ?? "List")
                                .font(.subheadline)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Select task list")
                    .accessibilityHint("Double tap to choose a different list")
                }
            }
        }
    }

    // MARK: - Data

    private var selectedList: TaskList? {
        taskLists.first { $0.id == selectedListID } ?? taskLists.first
    }

    private func tasksForColumn(_ status: TaskStatus) -> [TaskItem] {
        allTasks.filter { task in
            task.status == status
                && task.taskList?.id == (selectedListID ?? taskLists.first?.id)
        }
    }

    // MARK: - Drag & Drop

    /// Moves tasks to a new status column when dropped.
    ///
    /// Updates the task's `status`, sets `isDirty` for sync,
    /// and updates `completedDate`/`percentComplete` for
    /// completed/uncompleted transitions.
    private func moveTasksToStatus(ids: [String], newStatus: TaskStatus) {
        for id in ids {
            guard let task = allTasks.first(where: { $0.id == id }) else {
                continue
            }

            guard task.status != newStatus else { continue }

            task.status = newStatus
            task.isDirty = true
            task.lastModifiedDate = Date()

            // Handle completion metadata
            switch newStatus {
            case .completed:
                // Recurring task: advance to next occurrence instead of completing
                if let rrule = task.recurrenceRule,
                   let rule = RecurrenceRule.parse(rrule),
                   let currentDue = task.dueDate,
                   let nextDue = rule.nextDate(after: currentDue) {
                    task.dueDate = nextDue
                    task.status = .needsAction
                    task.completedDate = nil
                    task.percentComplete = 0
                } else {
                    task.completedDate = Date()
                    task.percentComplete = 100
                }
            case .needsAction:
                task.completedDate = nil
                task.percentComplete = 0
            case .inProcess:
                task.completedDate = nil
                if task.percentComplete == 0 || task.percentComplete == 100 {
                    task.percentComplete = 50
                }
            case .cancelled:
                task.completedDate = nil
                task.percentComplete = 0
            }
        }

        try? modelContext.save()
        WidgetCenter.shared.reloadAllTimelines()
        Task { @MainActor in
            await ReminderScheduler.updateBadgeCount(modelContext: modelContext)
        }
    }
}
