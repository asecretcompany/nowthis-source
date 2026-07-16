import AppIntents
import SwiftData

/// Widget configuration intent that lets users choose which task lists
/// appear in the home screen widget.
///
/// Users long-press the widget → Edit Widget → select one or more lists.
/// Defaults to showing all lists when no selection is made.
struct SelectListsIntent: WidgetConfigurationIntent {

    static let title: LocalizedStringResource = "Select Lists"
    static let description = IntentDescription("Choose which task lists to show in the widget.")

    /// The lists to display. Empty = show all lists.
    @Parameter(title: "Lists", default: [])
    var selectedLists: [WidgetListEntity]

    /// Whether to include overdue tasks alongside today's tasks.
    @Parameter(title: "Show Overdue", default: false)
    var showOverdue: Bool

    /// Fetches tasks filtered by the selected list IDs, scoped to today
    /// (and optionally overdue tasks).
    ///
    /// - Parameters:
    ///   - listIDs: IDs of lists to include. Empty means all lists.
    ///   - maxTasks: Maximum number of tasks to return.
    ///   - showOverdue: When true, include overdue tasks alongside today's.
    ///   - container: The SwiftData container to query.
    /// - Returns: Filtered tasks and a display name for the widget header.
    @MainActor
    static func fetchFilteredTasks(
        listIDs: [String],
        maxTasks: Int,
        showOverdue: Bool = false,
        container: ModelContainer
    ) throws -> (tasks: [WidgetFilteredTask], displayName: String) {
        let context = ModelContext(container)

        // Fetch non-deleted tasks
        let taskPredicate = #Predicate<TaskItem> { !$0.isDeletedLocally }
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: taskPredicate,
            sortBy: [
                SortDescriptor(\TaskItem.createdDate, order: .reverse)
            ]
        )

        var tasks = try context.fetch(descriptor)

        // Exclude completed tasks (predicate can't filter enums reliably)
        tasks = tasks.filter { $0.status != .completed }

        // Filter by selected lists if any are specified
        let filterIDs = Set(listIDs)
        if !filterIDs.isEmpty {
            tasks = tasks.filter { task in
                guard let listID = task.taskList?.id else { return false }
                return filterIDs.contains(listID)
            }
        }

        // Scope to today's tasks (and optionally overdue)
        let now = Date()
        tasks = tasks.filter { task in
            guard let dueDate = task.dueDate else { return false }
            if DueDateHelper.isOnDay(dueDate, isDateOnly: task.isDueDateOnly, sameAs: now) {
                return true
            }
            if showOverdue && DueDateHelper.isOverdue(dueDate: dueDate, isDateOnly: task.isDueDateOnly) {
                return true
            }
            return false
        }

        // Sort: tasks with due dates first (soonest first), then no-due-date tasks
        tasks.sort { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (aDate?, bDate?):
                return aDate < bDate
            case (_?, nil):
                return true   // a has due date, b doesn't → a first
            case (nil, _?):
                return false  // b has due date, a doesn't → b first
            case (nil, nil):
                return false  // preserve existing order (by createdDate desc)
            }
        }

        // Apply limit
        let limited = Array(tasks.prefix(maxTasks))

        let widgetTasks = limited.map { task in
            WidgetFilteredTask(
                id: task.id,
                title: task.title,
                isCompleted: task.status == .completed,
                priority: task.priority,
                dueDate: task.dueDate,
                isDueDateOnly: task.isDueDateOnly,
                listName: task.taskList?.name ?? "Tasks"
            )
        }

        // Compute display name
        let displayName: String
        if filterIDs.isEmpty {
            displayName = "All Lists"
        } else if filterIDs.count == 1 {
            displayName = widgetTasks.first?.listName
                ?? tasks.first?.taskList?.name
                ?? "Tasks"
        } else {
            // Fetch the actual list names for the selected IDs
            let listDescriptor = FetchDescriptor<TaskList>()
            let allLists = try context.fetch(listDescriptor)
            let names = allLists
                .filter { filterIDs.contains($0.id) }
                .map(\.name)
                .sorted()
            displayName = names.joined(separator: ", ")
        }

        return (tasks: widgetTasks, displayName: displayName)
    }
}

// MARK: - Widget List Entity

/// Lightweight entity for widget list selection — separate from Siri's
/// `TaskListEntity` to avoid pulling CreateTaskIntent into the widget target.
struct WidgetListEntity: AppEntity {

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Task List"
    static let defaultQuery = WidgetListEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

// MARK: - Widget List Entity Query

/// Provides task list lookup for the widget configuration picker.
struct WidgetListEntityQuery: EntityQuery {

    @MainActor
    func entities(for identifiers: [String]) async throws -> [WidgetListEntity] {
        let container = try SharedModelContainer.create()
        let context = container.mainContext

        let allLists = try context.fetch(FetchDescriptor<TaskList>())
        return allLists
            .filter { identifiers.contains($0.id) }
            .map { WidgetListEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [WidgetListEntity] {
        let container = try SharedModelContainer.create()
        let context = container.mainContext

        let lists = try context.fetch(
            FetchDescriptor<TaskList>(sortBy: [SortDescriptor<TaskList>(\TaskList.name)])
        )
        return lists.map { WidgetListEntity(id: $0.id, name: $0.name) }
    }
}

/// Lightweight struct for widget-filtered task results.
/// Keeps the filtering logic decoupled from WidgetKit types.
struct WidgetFilteredTask: Identifiable {
    let id: String
    let title: String
    let isCompleted: Bool
    let priority: TaskPriority
    let dueDate: Date?
    let isDueDateOnly: Bool
    let listName: String
}
