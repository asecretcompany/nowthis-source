import AppIntents
import SwiftData

/// Widget configuration intent that lets users choose which task lists
/// appear in the home screen widget.
///
/// Users long-press the widget → Edit Widget → select one or more lists.
/// Defaults to showing all lists when no selection is made.
struct SelectListsIntent: WidgetConfigurationIntent {

    static let title: LocalizedStringResource = "Select Lists"
    static let description = IntentDescription("Choose which lists to show in the widget.")

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
    /// Header shown when a task's own list cannot be resolved. Was the bare literal `"Tasks"`,
    /// which never entered a catalog and so read as English in the widget in every language.
    static var fallbackListName: String {
        String(localized: "widget.header.fallback",
               defaultValue: "Tasks",
               comment: "Widget header used when the selected list can no longer be found. A generic noun, not the name of any list.")
    }

    @MainActor
    static func fetchFilteredTasks(
        listIDs: [String],
        maxTasks: Int,
        showOverdue: Bool = false,
        container: ModelContainer,
        now: Date = Date(),
        calendar: Calendar = .current,
        onCandidatePage: ((Int) -> Void)? = nil
    ) throws -> (tasks: [WidgetFilteredTask], displayName: String) {
        let context = ModelContext(container)

        let filterIDs = Set(listIDs)
        let allLists = filterIDs.isEmpty
        let selectedIDs = Array(filterIDs)
        let local = DueDateHelper.localCalendar(in: calendar)
        let startOfToday = local.startOfDay(for: now)
        let endOfToday = local.date(byAdding: .day, value: 1, to: startOfToday)!
        let utcStart = DueDateHelper.dateOnlyValue(for: now, calendar: calendar)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcEnd = utc.date(byAdding: .day, value: 1, to: utcStart)!
        // A conservative union admits both local timed instants and UTC-stored all-day dates.
        // Exact calendar semantics are checked below, after the bounded candidate fetch.
        let lower = min(startOfToday, utcStart)
        let upper = max(endOfToday, utcEnd)
        let missingDate = Date.distantFuture
        let taskPredicate = #Predicate<TaskItem> {
            !$0.isDeletedLocally && $0.dueDate != nil
                && (allLists || ($0.taskList.flatMap { selectedIDs.contains($0.id) } ?? false))
                && ($0.dueDate ?? missingDate) < upper
                && (showOverdue || ($0.dueDate ?? missingDate) >= lower)
        }
        var descriptor = FetchDescriptor<TaskItem>(predicate: taskPredicate, sortBy: [
            SortDescriptor(\TaskItem.dueDate),
            SortDescriptor(\TaskItem.createdDate, order: .reverse)
        ])
        descriptor.fetchLimit = 128
        var tasks: [TaskItem] = []
        let limit = max(0, maxTasks)
        while tasks.count < limit {
            let page = try context.fetch(descriptor)
            onCandidatePage?(page.count)
            for task in page where task.status != .completed {
                guard let due = task.dueDate else { continue }
                let today = DueDateHelper.isOnDay(due, isDateOnly: task.isDueDateOnly,
                                                 sameAs: now, regionCalendar: calendar)
                let overdue = now >= DueDateHelper.effectiveDeadline(for: due,
                    isDateOnly: task.isDueDateOnly, regionCalendar: calendar)
                if today || (showOverdue && overdue) {
                    tasks.append(task)
                    if tasks.count == limit { break }
                }
            }
            if page.count < 128 { break }
            descriptor.fetchOffset = (descriptor.fetchOffset ?? 0) + page.count
        }
        let limited = tasks

        let widgetTasks = limited.map { task in
            WidgetFilteredTask(
                id: task.id,
                title: task.title,
                isCompleted: task.status == .completed,
                priority: task.priority,
                dueDate: task.dueDate,
                isDueDateOnly: task.isDueDateOnly,
                listName: task.taskList?.name ?? Self.fallbackListName
            )
        }

        // Compute display name
        let displayName: String
        if filterIDs.isEmpty {
            displayName = String(
                localized: "widget.header.allLists",
                defaultValue: "All Lists",
                comment: "Widget header when the widget is not filtered to particular lists.")
        } else if filterIDs.count == 1 {
            displayName = try EntityQueryLookup.lists(for: selectedIDs, in: context).first?.name
                ?? Self.fallbackListName
        } else {
            // Fetch the actual list names for the selected IDs
            let names = try EntityQueryLookup.lists(for: listIDs, in: context)
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

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "List"
    static let defaultQuery = WidgetListEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        // `stringLiteral:` and not `"\(name)"` — see `TaskListEntity`.
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

// MARK: - Widget List Entity Query

/// Provides task list lookup for the widget configuration picker.
struct WidgetListEntityQuery: EntityQuery {

    @MainActor
    func entities(for identifiers: [String]) async throws -> [WidgetListEntity] {
        let container = try SharedModelContainer.createReadOnly()
        return try entities(for: identifiers, in: ModelContext(container))
    }

    @MainActor
    func entities(for identifiers: [String], in context: ModelContext) throws -> [WidgetListEntity] {
        try EntityQueryLookup.lists(for: identifiers, in: context)
            .map { WidgetListEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [WidgetListEntity] {
        let container = try SharedModelContainer.createReadOnly()
        return try suggestedEntities(in: ModelContext(container))
    }

    @MainActor
    func suggestedEntities(in context: ModelContext) throws -> [WidgetListEntity] {
        let lists = try context.fetch(EntityQueryLookup.listSuggestionsDescriptor())
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
