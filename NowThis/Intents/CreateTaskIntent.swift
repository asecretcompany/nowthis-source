import AppIntents
import SwiftData

/// Siri/Shortcuts intent that creates a new task in a specified list.
///
/// Exposed as a Shortcuts action and Siri phrase. When the user says
/// "Add a task to NowThis called Buy groceries," this intent creates
/// the task in the default (first) list or a user-specified list.
///
/// **Siri Phrases:**
/// - "Add a task to NowThis"
/// - "Create a task called {title} in NowThis"
struct CreateTaskIntent: AppIntent {

    static let title: LocalizedStringResource = "Add Task"
    static let description = IntentDescription("Creates a new task in NowThis.")

    /// The title of the new task.
    @Parameter(title: "Title")
    var taskTitle: String

    /// Optional list to add the task to. Defaults to the first available list.
    @Parameter(title: "List", default: nil)
    var list: TaskListEntity?

    /// Optional priority level for the new task.
    @Parameter(title: "Priority", default: IntentTaskPriority.none)
    var priority: IntentTaskPriority

    /// Optional due date for the new task.
    @Parameter(title: "Due Date")
    var dueDate: Date?

    /// Optional notes/description for the new task.
    @Parameter(title: "Notes", default: nil)
    var notes: String?

    /// Optional tag name to assign. Auto-creates the tag if it doesn't exist.
    @Parameter(title: "Tag", default: nil)
    var tag: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$taskTitle) to \(\.$list)") {
            \.$priority
            \.$dueDate
            \.$notes
            \.$tag
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try SharedModelContainer.create()
        let result = try await performWithContainer(container)
        return .result(dialog: "\(result.dialog)")
    }

    /// Testable entry point that accepts an injected container.
    @MainActor
    func performWithContainer(_ container: ModelContainer) async throws -> IntentDialogResult {
        let context = container.mainContext

        // Resolve the target list
        let targetList: TaskList
        if let listEntity = list {
            let listID = listEntity.id
            let listPredicate = #Predicate<TaskList> { $0.id == listID }
            var descriptor = FetchDescriptor<TaskList>(
                predicate: listPredicate
            )
            descriptor.fetchLimit = 1
            guard let found = try context.fetch(descriptor).first else {
                throw IntentError.listNotFound
            }
            targetList = found
        } else {
            // Use the user's configured default list, falling back to first alphabetical
            var resolved: TaskList?
            if let defaultID = UserDefaults.standard.string(forKey: "defaultSiriListID") {
                let savedID = defaultID
                let defaultPredicate = #Predicate<TaskList> { $0.id == savedID }
                var defaultDesc = FetchDescriptor<TaskList>(
                    predicate: defaultPredicate
                )
                defaultDesc.fetchLimit = 1
                resolved = try context.fetch(defaultDesc).first
            }
            if resolved == nil {
                var fallbackDesc = FetchDescriptor<TaskList>(
                    sortBy: [SortDescriptor<TaskList>(\TaskList.name)]
                )
                fallbackDesc.fetchLimit = 1
                resolved = try context.fetch(fallbackDesc).first
            }
            guard let list = resolved else {
                throw IntentError.listNotFound
            }
            targetList = list
        }

        // Create the task
        let task = TaskItem(
            title: taskTitle,
            priority: priority.toTaskPriority
        )
        task.taskList = targetList
        task.isDirty = true
        task.dueDate = dueDate
        task.descriptionText = notes

        // Resolve tag
        if let tagName = tag, !tagName.isEmpty {
            let allTags = try context.fetch(FetchDescriptor<Tag>())
            let existing = allTags.first { $0.name.lowercased() == tagName.lowercased() }
            if let existing {
                task.tags.append(existing)
            } else {
                let newTag = Tag(name: tagName)
                context.insert(newTag)
                task.tags.append(newTag)
            }
        }

        context.insert(task)
        try context.save()

        return IntentDialogResult(
            dialog: "Added \"\(taskTitle)\" to \(targetList.name)."
        )
    }
}

// MARK: - Task List Entity

/// An AppEntity representing a `TaskList` for use in Intents and Shortcuts.
struct TaskListEntity: AppEntity {

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Task List"
    static let defaultQuery = TaskListEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

// MARK: - Task List Entity Query

/// Provides task list lookup for Siri parameter resolution.
struct TaskListEntityQuery: EntityQuery {

    @MainActor
    func entities(for identifiers: [String]) async throws -> [TaskListEntity] {
        let container = try SharedModelContainer.create()
        let context = container.mainContext

        let allLists = try context.fetch(FetchDescriptor<TaskList>())
        return allLists
            .filter { identifiers.contains($0.id) }
            .map { TaskListEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TaskListEntity] {
        let container = try SharedModelContainer.create()
        let context = container.mainContext

        let lists = try context.fetch(
            FetchDescriptor<TaskList>(sortBy: [SortDescriptor<TaskList>(\TaskList.name)])
        )
        return lists.map { TaskListEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: - Intent Priority Enum

/// Priority levels exposed in the Shortcuts/Siri parameter UI.
///
/// Maps to the app's `TaskPriority` enum but uses human-readable labels
/// for the Shortcuts action configuration sheet.
enum IntentTaskPriority: String, AppEnum {
    case none
    case low
    case medium
    case high

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Priority"

    static let caseDisplayRepresentations: [IntentTaskPriority: DisplayRepresentation] = [
        .none: "None",
        .low: "Low",
        .medium: "Medium",
        .high: "High"
    ]

    /// Converts the intent priority to the app's `TaskPriority` value.
    var toTaskPriority: TaskPriority {
        switch self {
        case .none: return .none
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}
