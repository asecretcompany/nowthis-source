import AppIntents
import SwiftData
import UserNotifications
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
        return .result(value: try await perform(in: ModelContext(container)))
    }

    /// Testable entry point that accepts an injected container.
    ///
    /// - Returns: `true` when the task ended up completed.
    @MainActor
    func performWithContainer(_ container: ModelContainer) async throws -> Bool {
        try await perform(in: container.mainContext)
    }

    @MainActor
    func perform(in context: ModelContext) async throws -> Bool {
        let taskItem: TaskItem
        do {
            taskItem = try TaskWriteEligibility(writingIn: context).task(.id(task.id))
        } catch let refusal as TaskWriteEligibility.Refusal {
            throw IntentError.writeFailure(refusal, fallback: .taskNotFound)
        }

        // Toggle completion through the shared logic rather than by hand. This path serves
        // Siri, Shortcuts, and the interactive widget, and its hand-rolled copy had never
        // learned about recurrence: a repeating task completed from any of the three was
        // marked done, keeping its RRULE but never advancing, while the same task tapped in
        // the app moved to its next occurrence.
        let wasCompleted = taskItem.status == .completed
        let isNowCompleted: Bool
        if wasCompleted {
            TaskCompletionLogic.markUncompleted(taskItem)
            isNowCompleted = false
        } else {
            // Returns true when the task was recurring and advanced instead of completing.
            isNowCompleted = try !TaskCompletionLogic.markCompleted(taskItem)
        }

        try ReminderSchedulingJournal.saveTaskChanges(in: context)

        // Same as the in-app path: completing ends the task's reminders, including the hourly
        // nag, which otherwise repeats until the app is deleted. A repeating task that advanced
        // to its next occurrence is not completed and still wants them. Cancelled through
        // UNUserNotificationCenter directly rather than ReminderScheduler, because this file is
        // compiled into NowThisWidget and NowThis/Services/ is not in that target's sources.
        if isNowCompleted {
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: NotificationIdentifiers.all(forTaskID: taskItem.id))
        }

        // Reload widget timelines
        WidgetCenter.shared.reloadAllTimelines()

        return isNowCompleted
    }
}

// MARK: - Shared Container

/// Provides a shared `ModelContainer` accessible from both the main app and extensions.
///
/// Uses the App Group container so that task data is consistent across
/// the main app, widget extension, and Siri intents.
@MainActor
enum SharedModelContainer {
    private static let factory = Factory()

    static func create() throws -> ModelContainer {
        try factory.create()
    }

    static func createReadOnly() throws -> ModelContainer {
        try factory.createReadOnly()
    }

    /// Owns one container per access role. The optional URL supports stores outside
    /// the App Group (including isolated disk stores in integration tests).
    @MainActor
    final class Factory {
        private let storeURL: URL?
        private var readWrite: ModelContainer?
        private var readOnly: ModelContainer?

        init(storeURL: URL? = nil) {
            self.storeURL = storeURL
        }

        func create() throws -> ModelContainer {
            if let readWrite { return readWrite }
            let container = try open(allowsSave: true)
            readWrite = container
            return container
        }

        func createReadOnly() throws -> ModelContainer {
            if let readOnly { return readOnly }
            let container = try open(allowsSave: false)
            readOnly = container
            return container
        }

        private func open(allowsSave: Bool) throws -> ModelContainer {
            let schema = Schema(SchemaV2.models)
            let configuration: ModelConfiguration
            if let storeURL {
                configuration = ModelConfiguration(schema: schema, url: storeURL, allowsSave: allowsSave)
            } else {
                configuration = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: false,
                    allowsSave: allowsSave,
                    groupContainer: .identifier(AppConstants.appGroupID)
                )
            }

            // NOTE: Do NOT pass `migrationPlan:` here. `NowThisMigrationPlan` is
            // deprecated and empty — passing it triggers an unrecoverable NSException
            // inside NSLightweightMigrationStage on devices that have an existing
            // store. This must match `NowThisApp.sharedModelContainer`, which also
            // omits the plan (see MigrationCrashFixTests).
            // Cache only successful opens so a transient store error is retryable.
            return try ModelContainer(for: schema, configurations: [configuration])
        }
    }
}

// MARK: - Errors

/// Errors specific to NowThis AppIntents.
enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case taskNotFound
    case listNotFound
    case readOnly
    case readOnlyCreation
    case taskChanged

    static func writeFailure(_ refusal: TaskWriteEligibility.Refusal, fallback: IntentError,
                             creating: Bool = false) -> IntentError {
        switch refusal {
        case .readOnly: return creating ? .readOnlyCreation : .readOnly
        case .taskUnavailable, .listUnavailable: return fallback
        case .targetChanged: return .taskChanged
        }
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .taskNotFound:
            return "Task not found."
        case .listNotFound:
            return "List not found."
        case .readOnly:
            return TaskWriteEligibility.readOnlyEditMessage
        case .readOnlyCreation:
            return TaskWriteEligibility.readOnlyCreationMessage
        case .taskChanged:
            return LocalizedStringResource(
                "intent.task.changed", defaultValue: "This task changed. Review it and try again.",
                comment: "Shown in Siri or Shortcuts when an operation's task or subtree changed before the write.")
        }
    }
}
