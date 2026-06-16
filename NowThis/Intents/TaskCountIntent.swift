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
        return .result(value: result.value ?? 0, dialog: "\(result.dialog)")
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

        // Filter by list if specified
        let count: Int
        let scope: String
        if let listEntity = list {
            let listID = listEntity.id
            count = allTasks.filter { $0.taskList?.id == listID }.count
            scope = "in \(listEntity.name)"
        } else {
            count = allTasks.count
            scope = "total"
        }

        let dialog = "You have \(count) active task\(count == 1 ? "" : "s") \(scope)."
        return IntentDialogResult(dialog: dialog, value: count)
    }
}
