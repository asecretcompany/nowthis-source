import AppIntents
import SwiftData

/// Siri/Shortcuts intent that reports tasks due today.
///
/// **Siri Phrases:**
/// - "What's due today in NowThis"
/// - "Tasks due today in NowThis"
struct TasksDueTodayIntent: AppIntent {

    static let title: LocalizedStringResource = "Tasks Due Today"
    static let description = IntentDescription("Shows tasks that are due today in NowThis.")

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

        let allTasks = try context.fetch(descriptor)
            .filter { $0.status != .completed && $0.status != .cancelled }
        let today = Date()

        let dueTodayTasks = allTasks.filter { task in
            guard let dueDate = task.dueDate else { return false }
            return DueDateHelper.isOnDay(dueDate, isDateOnly: task.isDueDateOnly, sameAs: today)
        }

        guard !dueTodayTasks.isEmpty else {
            return IntentDialogResult(dialog: "Nothing due today! You're all clear.")
        }

        let count = dueTodayTasks.count
        let titles = dueTodayTasks.prefix(10).map { $0.title }.joined(separator: ", ")
        let dialog = "You have \(count) task\(count == 1 ? "" : "s") due today: \(titles)."

        return IntentDialogResult(dialog: dialog)
    }
}
