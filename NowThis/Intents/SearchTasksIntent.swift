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
        return .result(dialog: IntentDialog(result.dialog))
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
        // Folds case and diacritics in the reader's language. This one feeds **spoken** Siri
        // results, where the user's pronunciation is transcribed without accents more often than
        // with them — "cherche café" arrives as "cafe" and must still match.
        let matching = allTasks.filter { $0.title.localizedStandardContains(query) }

        guard !matching.isEmpty else {
            return IntentDialogResult(dialog: LocalizedStringResource(
                "intent.dialog.search.none",
                defaultValue: "No tasks found matching \"\(query)\".",
                comment: "Siri's spoken reply when a search matched nothing. The placeholder is what the user searched for; the quotation marks around it should follow the target language's own convention."))
        }

        let count = matching.count
        let maxDisplay = 5
        let displayed = matching.prefix(maxDisplay)
        let titles = displayed.map { $0.title }.joined(separator: ", ")

        let dialog: LocalizedStringResource
        if count <= maxDisplay {
            dialog = LocalizedStringResource(
                "intent.dialog.search",
                defaultValue: "Found \(count) tasks matching \"\(query)\": \(titles).",
                comment: "Siri's spoken reply reading out every search hit. Placeholders in order: the count, the search text, the titles joined with commas.")
        } else {
            let remaining = count - maxDisplay
            dialog = LocalizedStringResource(
                "intent.dialog.search.truncated",
                defaultValue: "Found \(count) tasks matching \"\(query)\": \(titles), and \(remaining) more.",
                comment: "Siri's spoken reply when a search matched more than it will read out. Placeholders in order: total count, search text, the titles read out, how many are left.")
        }

        return IntentDialogResult(dialog: dialog)
    }
}
