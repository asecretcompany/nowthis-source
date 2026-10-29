import AppIntents
import SwiftData
import WidgetKit

/// Siri/Shortcuts intent that soft-deletes a task.
///
/// **Siri Phrases:**
/// - "Delete [task] in NowThis"
/// - "Remove [task] from NowThis"
struct DeleteTaskIntent: AppIntent {

    static let title: LocalizedStringResource = "Delete Task"
    static let description = IntentDescription("Deletes a task from NowThis.")

    /// The task to delete. Siri will prompt for this parameter.
    @Parameter(title: "Task")
    var task: TaskEntity

    /// Requires user confirmation before deleting.
    static var isDiscoverable: Bool { true }

    init() {}

    init(task: TaskEntity) {
        self.task = task
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Delete \(\.$task)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try SharedModelContainer.create()
        let result = try await performWithContainer(container)
        return .result(dialog: IntentDialog(result.dialog))
    }

    /// Testable entry point that accepts an injected container.
    @MainActor
    func performWithContainer(_ container: ModelContainer,
                              store: any NotificationStore = SystemNotificationStore(),
                              save: (() throws -> Void)? = nil) async throws -> IntentDialogResult {
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

        // Soft-delete for sync — the whole subtree, so every row gets its own
        // DELETE rather than being cascaded away with its parent.
        let deletedIDs = TaskListHelpers.markDeleted(taskItem)
        try ReminderSchedulingJournal.saveTaskChanges(in: context, save: save)
        await ReminderScheduler.cancelReminders(for: deletedIDs, modelContext: context, store: store)
        await ReminderScheduler.reconcileScheduledNotifications(modelContext: context,
            store: store, policy: .background)

        // Reload widget timelines
        WidgetCenter.shared.reloadAllTimelines()

        let title = task.title
        return IntentDialogResult(dialog: LocalizedStringResource(
            "intent.dialog.deleteTask.deleted",
            defaultValue: "Deleted \"\(title)\".",
            comment: "Siri's spoken confirmation after deleting a task. The placeholder is the task's title; the quotation marks should follow the target language's own convention."))
    }
}
