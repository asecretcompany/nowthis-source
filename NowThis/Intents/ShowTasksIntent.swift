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
        return .result(dialog: IntentDialog(result.dialog))
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
            // Two complete sentences rather than one template with an "in %@" tail. The tail
            // used to fall back to the product name — "You have no active tasks in NowThis." —
            // which reads as though NowThis were one list among several.
            if let name = list?.name {
                return IntentDialogResult(dialog: LocalizedStringResource(
                    "intent.dialog.showTasks.noneInList",
                    defaultValue: "You have no active tasks in \(name).",
                    comment: "Siri's spoken reply when the list the user named has no active tasks. The placeholder is that list's name."))
            }
            return IntentDialogResult(dialog: LocalizedStringResource(
                "intent.dialog.showTasks.none",
                defaultValue: "You have no active tasks.",
                comment: "Siri's spoken reply when no list was named and nothing is active anywhere."))
        }

        let count = tasks.count
        let maxDisplay = 10
        let displayed = tasks.prefix(maxDisplay)
        let titles = displayed.map { $0.title }.joined(separator: ", ")

        let dialog: LocalizedStringResource
        if count <= maxDisplay {
            dialog = LocalizedStringResource(
                "intent.dialog.showTasks",
                defaultValue: "You have \(count) active tasks: \(titles).",
                comment: "Siri's spoken reply listing every active task. First placeholder is the count, second is the titles joined with commas.")
        } else {
            let remaining = count - maxDisplay
            dialog = LocalizedStringResource(
                "intent.dialog.showTasks.truncated",
                defaultValue: "You have \(count) active tasks. Here are the first \(maxDisplay): \(titles), and \(remaining) more.",
                comment: "Siri's spoken reply when there are too many tasks to read out. Placeholders in order: total count, how many are read out, the titles, how many are left.")
        }

        return IntentDialogResult(dialog: dialog)
    }
}
