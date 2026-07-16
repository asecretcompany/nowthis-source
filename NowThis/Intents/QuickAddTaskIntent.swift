import AppIntents
import SwiftData

/// Siri/Shortcuts intent that creates a task from a single natural-language phrase.
///
/// Unlike `CreateTaskIntent` (which collects each field separately), this intent
/// takes one free-text string — spoken in a single breath or dictated at the
/// prompt — and runs it through `NaturalLanguageParser` to extract the title and
/// due date/time. Over voice there are no `!`/`#`/`@` symbols, so the task lands
/// in the default list; typed sigils (via the Shortcuts text field) still apply.
///
/// **Siri Phrases** (see `NowThisShortcuts`):
/// - "Quick add {text} to NowThis"
/// - "Jot {text} in NowThis"
struct QuickAddTaskIntent: AppIntent {

    static let title: LocalizedStringResource = "Quick Add Task"
    static let description = IntentDescription(
        "Adds a task from a natural-language phrase like \"buy milk tomorrow at 5pm\"."
    )

    /// The full natural-language task description (title + optional date/time).
    @Parameter(title: "Task", requestValueDialog: "What's the task?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Quick add \(\.$text)")
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

        let parsed = NaturalLanguageParser.parse(text)
        let title = parsed.cleanTitle.isEmpty
            ? text.trimmingCharacters(in: .whitespacesAndNewlines)
            : parsed.cleanTitle
        let resolvedTitle = title.isEmpty ? "New Task" : title

        // Resolve the target list: a parsed #list name if present, otherwise the
        // user's configured default (falling back to first alphabetical).
        var targetList: TaskList?
        if let listName = parsed.listName {
            targetList = try fetchList(named: listName, in: context)
        }
        if targetList == nil {
            targetList = try resolveDefaultList(in: context)
        }
        guard let list = targetList else {
            throw IntentError.listNotFound
        }

        // Build the task.
        let task = TaskItem(title: resolvedTitle, priority: parsed.priority ?? .none)
        task.taskList = list
        task.dueDate = parsed.dueDate
        // A parsed date with no explicit clock time is an all-day (date-only) due date.
        task.isDueDateOnly = (parsed.dueDate != nil) && !parsed.dueHasTime
        task.isDirty = true

        // Resolve tags (create-or-find), matching QuickAddView / CreateTaskIntent.
        if !parsed.tagNames.isEmpty {
            let allTags = try context.fetch(FetchDescriptor<Tag>())
            for tagName in parsed.tagNames {
                if let existing = allTags.first(where: { $0.name.lowercased() == tagName.lowercased() }) {
                    task.tags.append(existing)
                } else {
                    let newTag = Tag(name: tagName)
                    context.insert(newTag)
                    task.tags.append(newTag)
                }
            }
        }

        context.insert(task)
        try context.save()

        return IntentDialogResult(
            dialog: confirmation(title: resolvedTitle,
                                 dueDate: parsed.dueDate,
                                 hasTime: parsed.dueHasTime,
                                 listName: list.name)
        )
    }

    // MARK: - Helpers

    /// Case-insensitive lookup of a list by name.
    private func fetchList(named name: String, in context: ModelContext) throws -> TaskList? {
        let allLists = try context.fetch(FetchDescriptor<TaskList>())
        return allLists.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// The user's configured default Siri list, falling back to first alphabetical.
    /// Mirrors `CreateTaskIntent`'s resolution.
    private func resolveDefaultList(in context: ModelContext) throws -> TaskList? {
        if let defaultID = UserDefaults.standard.string(forKey: "defaultSiriListID") {
            let savedID = defaultID
            var descriptor = FetchDescriptor<TaskList>(
                predicate: #Predicate<TaskList> { $0.id == savedID }
            )
            descriptor.fetchLimit = 1
            if let found = try context.fetch(descriptor).first {
                return found
            }
        }
        var fallback = FetchDescriptor<TaskList>(sortBy: [SortDescriptor<TaskList>(\TaskList.name)])
        fallback.fetchLimit = 1
        return try context.fetch(fallback).first
    }

    /// Spoken confirmation, e.g. "Added \"Buy milk\", due Jul 2 at 5:00 PM, to Inbox."
    private func confirmation(title: String, dueDate: Date?, hasTime: Bool, listName: String) -> String {
        guard let dueDate else {
            return "Added \"\(title)\" to \(listName)."
        }
        let due = hasTime
            ? dueDate.formatted(date: .abbreviated, time: .shortened)
            : dueDate.formatted(date: .abbreviated, time: .omitted)
        return "Added \"\(title)\", due \(due), to \(listName)."
    }
}
