import AppIntents
import SwiftData

/// Siri/Shortcuts intent that lists active tasks, optionally filtered by list.
///
/// **Siri Phrases:**
/// - "Show my tasks in NowThis"
/// - "What tasks do I have in NowThis"
struct ShowTasksIntent: AppIntent {

    static let title: LocalizedStringResource = "Show Tasks"
    static let description = IntentDescription("Shows your active tasks in NowThis.")

    /// Optional list to scope results.
    @Parameter(title: "List", default: nil)
    var list: TaskListEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Show tasks in \(\.$list)")
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

        let predicate = #Predicate<TaskItem> { !$0.isDeletedLocally }
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\TaskItem.createdDate, order: .reverse)]
        )

        let allActive = try context.fetch(descriptor)
            .filter { $0.status != .completed && $0.status != .cancelled }

        // Filter by list if specified
        let tasks: [TaskItem]
        if let listEntity = list {
            let listID = listEntity.id
            tasks = allActive.filter { $0.taskList?.id == listID }
        } else {
            tasks = allActive
        }

        guard !tasks.isEmpty else {
            let scope = list?.name ?? "NowThis"
            return IntentDialogResult(dialog: "You have no active tasks in \(scope).")
        }

        let count = tasks.count
        let maxDisplay = 10
        let displayed = tasks.prefix(maxDisplay)
        let titles = displayed.map { $0.title }.joined(separator: ", ")

        var dialog: String
        if count <= maxDisplay {
            dialog = "You have \(count) active task\(count == 1 ? "" : "s"): \(titles)."
        } else {
            let remaining = count - maxDisplay
            dialog = "You have \(count) active tasks. Here are the first \(maxDisplay): \(titles), and \(remaining) more."
        }

        return IntentDialogResult(dialog: dialog)
    }
}
