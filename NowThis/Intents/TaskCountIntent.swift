import AppIntents
import SwiftData

/// Siri/Shortcuts intent that returns a count of active tasks.
///
/// **Siri Phrases:**
/// - "How many tasks do I have in NowThis"
/// - "Count my tasks in NowThis"
struct TaskCountIntent: AppIntent {

    static let title: LocalizedStringResource = "Task Count"
    static let description = IntentDescription("Counts your active tasks in NowThis.")

    /// Optional list to scope the count.
    @Parameter(title: "List", default: nil)
    var list: TaskListEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Count tasks in \(\.$list)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let container = try SharedModelContainer.create()
        let result = try await performWithContainer(container)
        return .result(value: result.value ?? 0, dialog: IntentDialog(result.dialog))
    }

    /// Testable entry point that accepts an injected container.
    @MainActor
    func performWithContainer(_ container: ModelContainer) async throws -> IntentDialogResult {
        let context = container.mainContext

        let predicate = #Predicate<TaskItem> { !$0.isDeletedLocally }
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: predicate
        )

        let allTasks = try context.fetch(descriptor)
            .filter { $0.status != .completed && $0.status != .cancelled }

        // Four complete sentences, not one template plus an "in %@" / "total" tail.
        //
        // The tail could not be translated even once the type was right: German puts *insgesamt*
        // in the middle of the clause, and a translator handed the fragment "total" on its own
        // has no way to know it lands at the end of a sentence about a count.
        let count: Int
        let dialog: LocalizedStringResource
        if let listEntity = list {
            let listID = listEntity.id
            count = allTasks.filter { $0.taskList?.id == listID }.count
            let name = listEntity.name
            dialog = LocalizedStringResource(
                "intent.dialog.taskCount.inList",
                defaultValue: "You have \(count) active tasks in \(name).",
                comment: "Siri's spoken reply counting the tasks in a named list. First placeholder is the count, second is the list's name. The count can be zero, which French renders in the singular.")
        } else {
            count = allTasks.count
            dialog = LocalizedStringResource(
                "intent.dialog.taskCount.total",
                defaultValue: "You have \(count) active tasks in total.",
                comment: "Siri's spoken reply counting tasks across every list. The placeholder is the count, which can be zero.")
        }

        return IntentDialogResult(dialog: dialog, value: count)
    }
}
