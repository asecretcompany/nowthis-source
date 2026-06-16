import AppIntents
import SwiftData
import WidgetKit

/// Siri/Shortcuts intent that toggles a task's completion status.
///
/// This intent is exposed to both the Shortcuts app and interactive widgets.
/// It uses the shared App Group `ModelContainer` so it can be invoked from
/// the widget extension as well as the main app.
///
/// **Siri Phrases:**
/// - "Complete [task] in NowThis"
/// - "Mark [task] as done in NowThis"
struct CompleteTaskIntent: AppIntent {

    static let title: LocalizedStringResource = "Complete Task"
    static let description = IntentDescription("Toggles a task's completion status in NowThis.")

    /// The task to complete. Siri will prompt for this parameter.
    @Parameter(title: "Task")
    var task: TaskEntity

    init() {}

    init(task: TaskEntity) {
        self.task = task
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle completion of \(\.$task)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let container = try SharedModelContainer.create()
        let context = container.mainContext

        let taskID = task.id
        let predicate = #Predicate<TaskItem> { $0.id == taskID }
        var descriptor = FetchDescriptor<TaskItem>(
            predicate: predicate
        )
        descriptor.fetchLimit = 1

        guard let taskItem = try context.fetch(descriptor).first else {
            throw IntentError.taskNotFound
        }

        // Toggle completion
        let wasCompleted = taskItem.status == .completed
        if wasCompleted {
            taskItem.status = .needsAction
            taskItem.completedDate = nil
            taskItem.percentComplete = 0
        } else {
            taskItem.status = .completed
            taskItem.completedDate = Date()
            taskItem.percentComplete = 100
        }

        taskItem.isDirty = true
        taskItem.lastModifiedDate = Date()
        try context.save()

        // Reload widget timelines
        WidgetCenter.shared.reloadAllTimelines()

        return .result(value: !wasCompleted)
    }
}

// MARK: - Task Entity

/// An AppEntity representing a `TaskItem` for use in Intents and Shortcuts.
///
/// Maps SwiftData `TaskItem` records to the AppIntents entity system,
/// enabling Siri parameter resolution and Shortcuts selection UI.
struct TaskEntity: AppEntity {

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Task"
    static let defaultQuery = TaskEntityQuery()

    var id: String
    var title: String
    var isCompleted: Bool
    var listName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(listName)"
        )
    }
}

// MARK: - Task Entity Query

/// Provides task lookup for Siri parameter resolution and Shortcuts picker.
struct TaskEntityQuery: EntityQuery {

    @MainActor
    func entities(for identifiers: [String]) async throws -> [TaskEntity] {
        let container = try SharedModelContainer.create()
        let context = container.mainContext

        let allTasks = try context.fetch(FetchDescriptor<TaskItem>())
        return allTasks
            .filter { identifiers.contains($0.id) }
            .map { TaskEntity(
                id: $0.id,
                title: $0.title,
                isCompleted: $0.status == .completed,
                listName: $0.taskList?.name ?? "Unknown"
            )}
    }

    @MainActor
    func suggestedEntities() async throws -> [TaskEntity] {
        let container = try SharedModelContainer.create()
        let context = container.mainContext

        let suggestedPredicate = #Predicate<TaskItem> { !$0.isDeletedLocally }
        var descriptor = FetchDescriptor<TaskItem>(
            predicate: suggestedPredicate,
            sortBy: [SortDescriptor(\TaskItem.createdDate, order: .reverse)]
        )
        descriptor.fetchLimit = 20

        let tasks = try context.fetch(descriptor)
        return tasks.map { TaskEntity(
            id: $0.id,
            title: $0.title,
            isCompleted: $0.status == .completed,
            listName: $0.taskList?.name ?? "Unknown"
        )}
    }
}

// MARK: - Shared Container

/// Provides a shared `ModelContainer` accessible from both the main app and extensions.
///
/// Uses the App Group container so that task data is consistent across
/// the main app, widget extension, and Siri intents.
enum SharedModelContainer {

    static func create() throws -> ModelContainer {
        let schema = Schema(SchemaV2.models)

        // NOTE: Do NOT pass `migrationPlan:` here. `NowThisMigrationPlan` is
        // deprecated and empty — passing it triggers an unrecoverable NSException
        // inside NSLightweightMigrationStage on devices that have an existing
        // store. This must match `NowThisApp.sharedModelContainer`, which also
        // omits the plan (see MigrationCrashFixTests). The widget timeline
        // provider and every App Intent open the store through here, so a
        // mismatch crashed the widget / interactive complete button on upgrade.
        return try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: false,
                    groupContainer: .identifier(AppConstants.appGroupID)
                )
            ]
        )
    }
}

// MARK: - Errors

/// Errors specific to NowThis AppIntents.
enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case taskNotFound
    case listNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .taskNotFound:
            return "Task not found."
        case .listNotFound:
            return "Task list not found."
        }
    }
}
