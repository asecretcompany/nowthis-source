import AppIntents
import SwiftData

/// Siri/Shortcuts intent that searches tasks by title.
///
/// **Siri Phrases:**
/// - "Search for [query] in NowThis"
/// - "Find [query] in NowThis"
struct SearchTasksIntent: AppIntent {

    static let title: LocalizedStringResource = "Search Tasks"
    static let description = IntentDescription("Searches for tasks by name in NowThis.")

    /// The search query string.
    @Parameter(title: "Search Query")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search for \(\.$query)")
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

        let predicate = #Predicate<TaskItem> {
            !$0.isDeletedLocally
        }
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\TaskItem.createdDate, order: .reverse)]
        )

        let allTasks = try context.fetch(descriptor)
        let lowerQuery = query.lowercased()
        let matching = allTasks.filter { $0.title.lowercased().contains(lowerQuery) }

        guard !matching.isEmpty else {
            return IntentDialogResult(dialog: "No tasks found matching \"\(query)\".")
        }

        let count = matching.count
        let maxDisplay = 5
        let displayed = matching.prefix(maxDisplay)
        let titles = displayed.map { $0.title }.joined(separator: ", ")

        var dialog: String
        if count <= maxDisplay {
            dialog = "Found \(count) task\(count == 1 ? "" : "s") matching \"\(query)\": \(titles)."
        } else {
            let remaining = count - maxDisplay
            dialog = "Found \(count) tasks matching \"\(query)\": \(titles), and \(remaining) more."
        }

        return IntentDialogResult(dialog: dialog)
    }
}
