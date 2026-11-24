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
        let result = try await performWithConfirmation(context: { ModelContext(container) }) { dialog in
            try await requestConfirmation(
                actionName: .custom(acceptLabel: LocalizedStringResource("Delete"), acceptAlternatives: [],
                    denyLabel: LocalizedStringResource("Cancel"), denyAlternatives: [], destructive: true),
                dialog: IntentDialog(dialog))
        }
        return .result(dialog: IntentDialog(result.dialog))
    }

    /// Orchestrates the system confirmation before the headless mutation path.
    @MainActor
    func performWithConfirmation(_ container: ModelContainer,
                                 store: any NotificationStore = SystemNotificationStore(),
                                 save: (() throws -> Void)? = nil,
                                 confirmation: (LocalizedStringResource) async throws -> Void) async throws -> IntentDialogResult {
        try await performWithConfirmation(context: { container.mainContext }, store: store,
                                          save: save, confirmation: confirmation)
    }

    @MainActor
    func performWithConfirmation(context makeContext: () -> ModelContext,
                                 store: any NotificationStore = SystemNotificationStore(),
                                 save: (() throws -> Void)? = nil,
                                 confirmation: (LocalizedStringResource) async throws -> Void) async throws -> IntentDialogResult {
        // Capture the complete committed deletion scope before suspension. The
        // same scope is checked against a fresh writer context after confirmation.
        let (title, confirmedScope) = try {
            let context = makeContext()
            let root = try taskForDeletion(in: context)
            do {
                let admission = try TaskDeletionPersistence.admit(root, in: context)
                return (root.title, admission.scope)
            } catch let refusal as TaskWriteEligibility.Refusal {
                throw IntentError.writeFailure(refusal, fallback: .taskNotFound)
            }
        }()
        let dialog = LocalizedStringResource(
            "intent.deleteTask.confirm",
            defaultValue: "Delete “\(title)” and any subtasks?",
            comment: "Siri's spoken question before deleting a task and its entire subtree. The placeholder is the current saved task title. Quotation marks follow the language's convention.")
        try await confirmation(dialog)
        // Cancellation throws above. Re-fetch and revalidate the stable ID before
        // any task mutation, save, journal, reminder or widget effects.
        return try await perform(in: makeContext(), store: store, confirmed: confirmedScope,
                                 save: save)
    }

    /// Testable entry point that accepts an injected container.
    @MainActor
    func performWithContainer(_ container: ModelContainer,
                              store: any NotificationStore = SystemNotificationStore(),
                              save: (() throws -> Void)? = nil) async throws -> IntentDialogResult {
        try await perform(in: container.mainContext, store: store, save: save)
    }

    @MainActor
    func perform(in context: ModelContext,
                 store: any NotificationStore = SystemNotificationStore(),
                 confirmed: TaskWriteEligibility.DeletionScope? = nil,
                 save: (() throws -> Void)? = nil) async throws -> IntentDialogResult {
        let taskItem = try taskForDeletion(in: context)
        let title = taskItem.title
        let admission: TaskWriteEligibility.DeletionAdmission
        do {
            admission = try TaskDeletionPersistence.admit(taskItem, in: context, confirmed: confirmed)
        } catch let refusal as TaskWriteEligibility.Refusal {
            throw IntentError.writeFailure(refusal, fallback: .taskNotFound)
        }

        // Soft-delete for sync — the whole subtree, so every row gets its own
        // DELETE rather than being cascaded away with its parent.
        let deletedIDs = TaskListHelpers.markDeleted(admission.rows)
        try ReminderSchedulingJournal.saveTaskChanges(in: context, save: save)
        await ReminderScheduler.cancelReminders(for: deletedIDs, modelContext: context, store: store)
        await ReminderScheduler.reconcileScheduledNotifications(modelContext: context,
            store: store, policy: .background)

        // Reload widget timelines
        WidgetCenter.shared.reloadAllTimelines()

        return IntentDialogResult(dialog: LocalizedStringResource(
            "intent.dialog.deleteTask.deleted",
            defaultValue: "Deleted \"\(title)\".",
            comment: "Siri's spoken confirmation after deleting a task. The placeholder is the task's title; the quotation marks should follow the target language's own convention."))
    }

    @MainActor
    private func taskForDeletion(in context: ModelContext) throws -> TaskItem {
        let taskID = task.id
        var descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { $0.id == taskID })
        descriptor.fetchLimit = 1
        guard let taskItem = try context.fetch(descriptor).first,
              !taskItem.isDeletedLocally else {
            throw IntentError.taskNotFound
        }
        return taskItem
    }
}
