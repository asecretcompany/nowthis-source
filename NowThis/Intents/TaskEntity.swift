import AppIntents
import Foundation
import SwiftData

/// The task identity and display metadata used by Shortcuts, Siri, and interactive widgets.
struct TaskEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Task"
    static let defaultQuery = TaskEntityQuery()

    /// Subtitle for a task that belongs to no list. Was the bare literal `"Unknown"`, which was
    /// both untranslated and inaccurate — the list is not unknown, there is not one.
    static var noListName: String {
        String(localized: "intent.task.noList",
               defaultValue: "No list",
               comment: "Shown under a task's name in the Shortcuts and Siri task picker when the task belongs to no list.")
    }

    var id: String
    var isCompleted: Bool

    @Property(title: LocalizedStringResource("intent.entity.taskTitle", defaultValue: "Title",
                                             comment: "Shortcuts property for the user-entered title of a task."))
    var title: String

    @Property(title: LocalizedStringResource("intent.entity.status", defaultValue: "Status",
                                             comment: "Shortcuts property for the current status of a task."))
    var statusName: String

    @Property(title: LocalizedStringResource("intent.entity.listName", defaultValue: "List Name",
                                             comment: "Shortcuts property for the user-entered list name."))
    var listName: String

    @Property(title: LocalizedStringResource("intent.entity.dueDate", defaultValue: "Due Date",
                                             comment: "Shortcuts property for the due date of a task."))
    var dueDate: Date?

    @Property(title: LocalizedStringResource("intent.entity.dueDateOnly", defaultValue: "Due Date Without Time",
                                             comment: "Boolean Shortcuts property indicating that the task has a date-only due date."))
    var isDueDateOnly: Bool

    @Property(title: LocalizedStringResource("intent.entity.startDate", defaultValue: "Start Date",
                                             comment: "Shortcuts property for the start date of a task."))
    var startDate: Date?

    @Property(title: LocalizedStringResource("intent.entity.startDateOnly", defaultValue: "Start Date Without Time",
                                             comment: "Boolean Shortcuts property indicating that the task has a date-only start date."))
    var isStartDateOnly: Bool

    @Property(title: LocalizedStringResource("intent.entity.priority", defaultValue: "Priority",
                                             comment: "Shortcuts property for the current priority of a task."))
    var priorityName: String

    @Property(title: LocalizedStringResource("intent.entity.tags", defaultValue: "Tags",
                                             comment: "Shortcuts property listing the names of tags assigned to a task."))
    var tagNames: [String]

    @Property(title: LocalizedStringResource("intent.entity.repeating", defaultValue: "Repeating",
                                             comment: "Boolean Shortcuts property indicating that the task has a recurrence rule."))
    var isRecurring: Bool

    @Property(title: LocalizedStringResource("intent.entity.accountName", defaultValue: "Account Name",
                                             comment: "Shortcuts property for the account's display name."))
    var accountName: String?

    /// Used by widget completion buttons built from a lightweight timeline snapshot.
    init(id: String, title: String, isCompleted: Bool, listName: String) {
        self.id = id
        self.isCompleted = isCompleted
        self.title = title
        self.listName = listName
        statusName = (isCompleted ? TaskStatus.completed : .needsAction).displayName
        dueDate = nil
        isDueDateOnly = false
        startDate = nil
        isStartDateOnly = false
        priorityName = TaskPriority.none.displayName
        tagNames = []
        isRecurring = false
        accountName = nil
    }

    @MainActor
    init(task: TaskItem) {
        let list = task.taskList
        id = task.id
        isCompleted = task.status == .completed
        title = task.title
        statusName = task.status.displayName
        listName = list?.name ?? Self.noListName
        dueDate = task.dueDate
        isDueDateOnly = task.isDueDateOnly
        startDate = task.startDate
        isStartDateOnly = task.isStartDateOnly
        priorityName = task.priority.displayName
        tagNames = task.tags.map(\.name).sorted()
        isRecurring = task.recurrenceRule?.isEmpty == false
        accountName = list?.account?.displayName
    }

    var displayRepresentation: DisplayRepresentation {
        var subtitleParts = [listName]
        if let accountName {
            subtitleParts.append(accountName)
        }
        if let dueDate {
            var style = Date.FormatStyle(date: .abbreviated, time: isDueDateOnly ? .omitted : .shortened)
            style.timeZone = DueDateFormatter.formattingTimeZone(isDateOnly: isDueDateOnly, localTimeZone: .current)
            subtitleParts.append(dueDate.formatted(style))
        }

        // User-authored names are already display text. Avoid extracting a shared "%@" key.
        return DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: title),
            subtitle: LocalizedStringResource(stringLiteral: subtitleParts.joined(separator: " · "))
        )
    }
}

/// Resolves saved tasks and offers live title matches for intent parameters.
struct TaskEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [TaskEntity] {
        let container = try SharedModelContainer.createReadOnly()
        return try entities(for: identifiers, in: ModelContext(container))
    }

    @MainActor
    func entities(for identifiers: [String], in context: ModelContext) throws -> [TaskEntity] {
        try EntityQueryLookup.tasks(for: identifiers, in: context)
            .map { TaskEntity(task: $0) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [TaskEntity] {
        let container = try SharedModelContainer.createReadOnly()
        return try entities(matching: string, in: ModelContext(container))
    }

    @MainActor
    func entities(matching string: String, in context: ModelContext) throws -> [TaskEntity] {
        let name = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDeletedLocally && $0.title.localizedStandardContains(name) },
            sortBy: [SortDescriptor(\TaskItem.createdDate, order: .reverse), SortDescriptor(\TaskItem.id)]
        )
        return try context.fetch(descriptor).map { TaskEntity(task: $0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TaskEntity] {
        let container = try SharedModelContainer.createReadOnly()
        return try suggestedEntities(in: ModelContext(container))
    }

    @MainActor
    func suggestedEntities(in context: ModelContext) throws -> [TaskEntity] {
        let suggestedPredicate = #Predicate<TaskItem> { !$0.isDeletedLocally }
        var descriptor = FetchDescriptor<TaskItem>(
            predicate: suggestedPredicate,
            sortBy: [SortDescriptor(\TaskItem.createdDate, order: .reverse)]
        )
        descriptor.fetchLimit = 20

        return try context.fetch(descriptor).map { TaskEntity(task: $0) }
    }
}
