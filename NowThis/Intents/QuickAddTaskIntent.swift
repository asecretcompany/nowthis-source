import AppIntents
import SwiftData
import WidgetKit

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
        LocalizedStringResource(
            "intent.quickAdd.description",
            defaultValue: "Adds a task from an English phrase like \"buy milk tomorrow at 5pm\". Dates and times are only recognised in English.",
            comment: "Shortcuts description for the quick-add action. The parser is English-only and stays that way, so the copy says so outright rather than inviting the user's own language — translate the sentence but leave the quoted example in English exactly as written.")
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
        return .result(dialog: IntentDialog(result.dialog))
    }

    /// Testable entry point that accepts an injected container.
    ///
    /// - Parameter onWidgetReload: Runs once the task is saved — see `CreateTaskIntent`.
    @MainActor
    func performWithContainer(_ container: ModelContainer,
                              onWidgetReload: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) async throws -> IntentDialogResult {
        let context = container.mainContext

        let parsed = NaturalLanguageParser.parse(text)
        let title = parsed.cleanTitle.isEmpty
            ? text.trimmingCharacters(in: .whitespacesAndNewlines)
            : parsed.cleanTitle
        // This becomes the task's stored title and syncs to the server, so it is one of the
        // strings TRANSLATION.md §7 covers: translated, but it travels.
        let resolvedTitle = title.isEmpty
            ? String(localized: "task.defaultTitle",
                     defaultValue: "New Task",
                     comment: "Title given to a task the user dictated with no recognisable words. Stored on the task and uploaded to the server, so it is not display-only.")
            : title

        // Resolve the target list: a parsed #list name if present, otherwise the
        // user's default list.
        let namedList = try parsed.listName.flatMap { try fetchList(named: $0, in: context) }
        guard let list = NewTaskDefaults.resolveListAdopting(explicit: namedList, in: context) else {
            throw IntentError.listNotFound
        }

        // Build the task.
        let task = TaskItem(title: resolvedTitle, priority: parsed.priority ?? .none)
        task.taskList = list
        if let parsedDue = parsed.dueDate {
            task.dueDate = parsedDue
            // A parsed date with no explicit clock time is an all-day (date-only) due date.
            task.isDueDateOnly = !parsed.dueHasTime
        } else {
            // Nothing spoken: the list's (or global) default due date, as the in-app add
            // paths apply it.
            let resolved = NewTaskDefaults.resolve(smartList: nil, list: list)
            task.dueDate = resolved.dueDate
            task.isDueDateOnly = resolved.isDueDateOnly
        }
        // Default reminder, as QuickAddView applies it: any due date, however it was set.
        if task.dueDate != nil, NewTaskDefaults.effectiveReminderEnabled(for: list) {
            task.reminderOffset = 0
        }
        task.isDirty = true

        // Resolve tags (create-or-find), matching QuickAddView / CreateTaskIntent.
        if !parsed.tagNames.isEmpty {
            let allTags = try context.fetch(FetchDescriptor<Tag>())
            for tagName in parsed.tagNames {
                // Locale-aware case folding, not diacritic folding — see CreateTaskIntent.
                if let existing = allTags.first(where: {
                    $0.name.localizedCaseInsensitiveCompare(tagName) == .orderedSame
                }) {
                    task.tags.append(existing)
                } else {
                    let newTag = Tag(name: tagName)
                    context.insert(newTag)
                    task.tags.append(newTag)
                }
            }
        }

        context.insert(task)
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        // Before the reminder pass, as in CreateTaskIntent: nothing else reloads the widgets
        // for a task saved here.
        onWidgetReload()
        // See CreateTaskIntent — a quick-add's parsed due date scheduled nothing, and the
        // re-plan is awaited because this container does not outlive `perform()`.
        await ReminderScheduler.reconcileNow(modelContext: context)

        return IntentDialogResult(
            dialog: confirmation(title: resolvedTitle,
                                 dueDate: task.dueDate,
                                 hasTime: !task.isDueDateOnly,
                                 listName: list.name)
        )
    }

    // MARK: - Helpers

    /// Case-insensitive lookup of a list by name.
    private func fetchList(named name: String, in context: ModelContext) throws -> TaskList? {
        let allLists = try context.fetch(FetchDescriptor<TaskList>())
        return allLists.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// Spoken confirmation, e.g. "Added \"Buy milk\", due Jul 2 at 5:00 PM, to Inbox."
    private func confirmation(title: String,
                              dueDate: Date?,
                              hasTime: Bool,
                              listName: String) -> LocalizedStringResource {
        guard let dueDate else {
            return LocalizedStringResource(
                "intent.dialog.quickAdd.added",
                defaultValue: "Added \"\(title)\" to \(listName).",
                comment: "Siri's spoken confirmation after a quick add with no due date. First placeholder is the task's title, second is the list's name.")
        }
        let due = hasTime
            ? dueDate.formatted(date: .abbreviated, time: .shortened)
            : dueDate.formatted(date: .abbreviated, time: .omitted)
        return LocalizedStringResource(
            "intent.dialog.quickAdd.addedWithDue",
            defaultValue: "Added \"\(title)\", due \(due), to \(listName).",
            comment: "Siri's spoken confirmation after a quick add that parsed a due date. Placeholders in order: the task's title, the already-formatted due date, the list's name.")
    }
}
