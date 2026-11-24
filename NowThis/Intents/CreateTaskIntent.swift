import AppIntents
import SwiftData
import WidgetKit
import os

/// Siri/Shortcuts intent that creates a new task in a specified list.
///
/// Exposed as a Shortcuts action and Siri phrase. When the user says
/// "Add a task to NowThis called Buy groceries," this intent creates
/// the task in the default (first) list or a user-specified list.
///
/// **Siri Phrases:**
/// - "Add a task to NowThis"
/// - "Create a task called {title} in NowThis"
struct CreateTaskIntent: AppIntent {

    static let title: LocalizedStringResource = "Add Task"
    static let description = IntentDescription("Creates a new task in NowThis.")

    private static let logger = Logger(subsystem: "com.asecretcompany.nowthis", category: "intents")

    /// The title of the new task.
    @Parameter(title: "Title")
    var taskTitle: String

    /// Optional list to add the task to. Defaults to the first available list.
    @Parameter(title: "List", default: nil)
    var list: TaskListEntity?

    /// Optional priority level for the new task.
    @Parameter(title: "Priority", default: IntentTaskPriority.none)
    var priority: IntentTaskPriority

    /// Optional due date for the new task.
    @Parameter(title: "Due Date")
    var dueDate: Date?

    /// Optional notes/description for the new task.
    @Parameter(title: "Notes", default: nil)
    var notes: String?

    /// Optional tag name to assign. Auto-creates the tag if it doesn't exist.
    @Parameter(title: "Tag", default: nil)
    var tag: String?

    /// Whether Siri asks "When is it due?" when no due date was given. On by default so
    /// the App Shortcut asks; a Shortcut meant to run unattended turns it off, and then an
    /// undated task takes the configured default without a question.
    @Parameter(title: "Ask for Due Date", default: true)
    var askForDueDate: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$taskTitle) to \(\.$list)") {
            \.$priority
            \.$dueDate
            \.$notes
            \.$tag
            \.$askForDueDate
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result: IntentDialogResult
        if #available(iOS 26.0, *) {
            result = try await performWithDueDateQuestion(makeContainer: { try SharedModelContainer.create() }, askDueDate: {
                try await requestDueDateRule(default: $0)
            })
        } else {
            result = try await performWithDueDateQuestion(makeContainer: { try SharedModelContainer.create() }, askDueDate: nil)
        }
        return .result(dialog: IntentDialog(result.dialog))
    }

    @MainActor
    func performWithDueDateQuestion(makeContainer: () throws -> ModelContainer,
                                    askDueDate: ((DefaultDueDateRule) async throws -> DefaultDueDateRule)?,
                                    onWidgetReload: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) async throws -> IntentDialogResult {
        _ = try TaskTextValidation.title(taskTitle)
        try TaskTextValidation.notes(notes)
        let container = try makeContainer()
        // `requestChoice` is iOS 26. Earlier systems skip the question, and an undated task
        // takes the configured default instead.
        if shouldAskForDueDate, let askDueDate {
            let preview = try creationPreview(in: ModelContext(container))
            let chosenRule = try await askDueDate(preview.rule)
            return try await create(in: ModelContext(container), dueDateRule: chosenRule,
                expectedDestination: preview.destination, onWidgetReload: onWidgetReload)
        }
        return try await perform(in: ModelContext(container), onWidgetReload: onWidgetReload)
    }

    @MainActor
    private func creationPreview(in context: ModelContext) throws ->
        (rule: DefaultDueDateRule, destination: TaskWriteEligibility.CreationDestination) {
        let (list, _) = try resolveTargetList(in: context)
        return (NewTaskDefaults.effectiveDueDateRule(for: list),
                .list(id: list.id, expectedPersistentID: list.persistentModelID))
    }

    /// Siri asks for a due date only when the invocation didn't carry one.
    var shouldAskForDueDate: Bool {
        dueDate == nil && askForDueDate
    }

    /// The rules Siri offers, in the order it offers them: the list's effective default
    /// first, so the expected answer is the first one, then the rest by date with
    /// "No Due Date" last.
    static func dueDateChoices(default rule: DefaultDueDateRule) -> [DefaultDueDateRule] {
        let order: [DefaultDueDateRule] = [.today, .tomorrow, .nextWeek, .none]
        return [rule] + order.filter { $0 != rule }
    }

    @available(iOS 26.0, *)
    private func requestDueDateRule(default rule: DefaultDueDateRule) async throws -> DefaultDueDateRule {
        let rules = Self.dueDateChoices(default: rule)
        let options = rules.map { IntentChoiceOption(title: Self.choiceTitle(for: $0)) }
        let chosen = try await requestChoice(
            between: options,
            dialog: IntentDialog(LocalizedStringResource(
                "intent.createTask.dueDatePrompt",
                defaultValue: "When is it due?",
                comment: "Siri's spoken question after the user names a task to add, offering Today, Tomorrow, Next Week and No Due Date as answers."))
        )
        guard let matched = Self.dueDateRule(forChoiceKey: chosen.title.key, among: rules) else {
            // Falling back to the default gives a plausible task rather than a failed add, but
            // silently; the log is what makes a framework change here findable.
            Self.logger.error("""
                Due-date answer '\(chosen.title.key, privacy: .public)' matched no offered option; \
                applying the default '\(rule.rawValue, privacy: .public)'
                """)
            return rule
        }
        return matched
    }

    /// The rule whose choice title carries `key`, or `nil` when none does.
    ///
    /// `requestChoice` returns an `IntentChoiceOption`, and how the framework compares two of
    /// them is not documented — so the answer is matched by its title's catalog key, the one
    /// thing a copy of the option is certain to carry unchanged. The four keys are distinct.
    static func dueDateRule(forChoiceKey key: String,
                            among rules: [DefaultDueDateRule]) -> DefaultDueDateRule? {
        rules.first { choiceTitle(for: $0).key == key }
    }

    /// The spoken and shown answer for `rule`. The three dates deliberately reuse
    /// `DefaultDueDateRule.displayName`'s keys — the same word for the same concept —
    /// while "None" does not, because it answers "Default due date: ?", not "When is it due?".
    static func choiceTitle(for rule: DefaultDueDateRule) -> LocalizedStringResource {
        switch rule {
        case .none:
            return LocalizedStringResource(
                "intent.createTask.dueChoice.none", defaultValue: "No Due Date",
                comment: "Siri answer to 'When is it due?': add the task without a due date. Offered beside Today, Tomorrow and Next Week.")
        case .today:
            return LocalizedStringResource(
                "defaultDueDate.today", defaultValue: "Today",
                comment: "New-task default due date: today.")
        case .tomorrow:
            return LocalizedStringResource(
                "defaultDueDate.tomorrow", defaultValue: "Tomorrow",
                comment: "New-task default due date: tomorrow.")
        case .nextWeek:
            return LocalizedStringResource(
                "defaultDueDate.nextWeek", defaultValue: "Next Week",
                comment: "New-task default due date: one week from today.")
        }
    }

    /// Testable entry point that accepts an injected container.
    ///
    /// - Parameter onWidgetReload: Runs once the task is saved. Defaults to reloading every
    ///   widget timeline, as the complete and delete intents do; injected so a test can count it.
    @MainActor
    func performWithContainer(_ container: ModelContainer,
                              dueDateRule: DefaultDueDateRule? = nil,
                              onWidgetReload: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) async throws -> IntentDialogResult {
        try await perform(in: container.mainContext, dueDateRule: dueDateRule, onWidgetReload: onWidgetReload)
    }

    @MainActor
    func perform(in context: ModelContext,
                 dueDateRule: DefaultDueDateRule? = nil,
                 onWidgetReload: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) async throws -> IntentDialogResult {
        try await create(in: context, dueDateRule: dueDateRule, expectedDestination: nil, onWidgetReload: onWidgetReload)
    }

    @MainActor
    private func create(in context: ModelContext, dueDateRule: DefaultDueDateRule?,
                        expectedDestination: TaskWriteEligibility.CreationDestination?,
                        onWidgetReload: () -> Void) async throws -> IntentDialogResult {
        _ = try TaskTextValidation.title(taskTitle)
        try TaskTextValidation.notes(notes)
        let (targetList, preferenceChange) = try resolveTargetList(in: context, expected: expectedDestination)

        // Done on an empty Title prompt arrives here as "" — named as Quick Add names it, so no
        // untitled task is saved and uploaded. The same key, so one translation serves both.
        let trimmedTitle = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmedTitle.isEmpty
            ? String(localized: "task.defaultTitle",
                     defaultValue: "New Task",
                     comment: "Title given to a task the user dictated with no recognisable words. Stored on the task and uploaded to the server, so it is not display-only.")
            : trimmedTitle

        // Create the task
        let task = TaskItem(
            title: resolvedTitle,
            priority: priority.toTaskPriority
        )
        task.taskList = targetList
        task.isDirty = true
        if let dueDate {
            task.dueDate = dueDate
        } else {
            // Undated: the answer Siri got, else the list's (or global) default — the same
            // resolver the in-app add paths use.
            let resolved = NewTaskDefaults.resolve(
                smartList: nil,
                rule: dueDateRule ?? NewTaskDefaults.effectiveDueDateRule(for: targetList),
                reminderEnabled: false
            )
            task.dueDate = resolved.dueDate
            task.isDueDateOnly = resolved.isDueDateOnly
        }
        // Default reminder, as QuickAddView applies it: any due date, however it was set.
        if task.dueDate != nil, NewTaskDefaults.effectiveReminderEnabled(for: targetList) {
            task.reminderOffset = 0
        }
        task.descriptionText = notes

        // Resolve tag
        if let tagName = tag, !tagName.isEmpty {
            let allTags = try context.fetch(FetchDescriptor<Tag>())
            // Locale-aware case folding. `lowercased()` is not: under a Turkish locale "I" and
            // "ı" are different letters and the same tag can be created twice, and tags serialize
            // to CATEGORIES, so the duplicate reaches the server. Deliberately **not**
            // diacritic-insensitive — "café" and "cafe" are different tags, and merging them would
            // silently retag the user's data. Search folds accents; identity does not.
            let existing = allTags.first {
                $0.name.localizedCaseInsensitiveCompare(tagName) == .orderedSame
            }
            if let existing {
                task.tags.append(existing)
            } else {
                let newTag = Tag(name: tagName)
                context.insert(newTag)
                task.tags.append(newTag)
            }
        }

        context.insert(task)
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        preferenceChange?.commit()
        let listName = targetList.name
        // Before the reminder pass, so the widgets start refreshing while it runs. With a Today
        // default the new task belongs in the Today widget at once, and nothing else reloads it:
        // the app's SyncScheduler only learns of saves the views tell it about.
        onWidgetReload()
        // Siri-created tasks reached no scheduler at all: the badge stayed blank when the due
        // date passed, on a synced account as much as a local one. Awaited, not coalesced: this
        // container is a local `let` in `perform()` and is released the moment it returns, so a
        // pass deferred past that point would fetch through a context with no container behind it.
        await ReminderScheduler.reconcileNow(modelContext: context)

        return IntentDialogResult(
            dialog: LocalizedStringResource(
                "intent.dialog.createTask.added",
                defaultValue: "Added \"\(resolvedTitle)\" to \(listName).",
                comment: "Siri's spoken confirmation after adding a task. First placeholder is the task's title, second is the list's name. The quotation marks should follow the target language's own convention.")
        )
    }

    /// Resolves the target list. A list named in the shortcut has to exist — falling
    /// back to the default would silently put the task somewhere the user didn't ask
    /// for. Without one, the user's default list applies.
    @MainActor
    private func resolveTargetList(in context: ModelContext, expected: TaskWriteEligibility.CreationDestination? = nil)
        throws -> (TaskList, NewTaskDefaults.PreferenceChange?) {
        let eligibility = TaskWriteEligibility(writingIn: context)
        let choice = list == nil ? try NewTaskDefaults.creationList(explicit: nil, in: context) : nil
        let destination: TaskWriteEligibility.CreationDestination
        if let list {
            destination = expected ?? .list(id: list.id, expectedPersistentID: nil)
        } else if let candidate = choice?.list {
            if case .list(let id, let persistentID) = expected,
               id != candidate.id || persistentID != candidate.persistentModelID {
                throw IntentError.listNotFound
            }
            destination = expected ?? .list(id: candidate.id, expectedPersistentID: candidate.persistentModelID)
        } else {
            throw IntentError.listNotFound
        }
        do {
            guard let target = try eligibility.destination(destination) else { throw IntentError.listNotFound }
            return (target, choice?.preferenceChange)
        } catch let refusal as TaskWriteEligibility.Refusal {
            throw IntentError.writeFailure(refusal, fallback: .listNotFound, creating: true)
        }
    }
}

// MARK: - Intent Priority Enum

/// Priority levels exposed in the Shortcuts/Siri parameter UI.
///
/// Maps to the app's `TaskPriority` enum but uses human-readable labels
/// for the Shortcuts action configuration sheet.
enum IntentTaskPriority: String, AppEnum {
    case none
    case low
    case medium
    case high

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Priority"

    static let caseDisplayRepresentations: [IntentTaskPriority: DisplayRepresentation] = [
        // Same sense as TaskPriority.displayName's `.none` and deliberately the same key: one
        // word, one concept, one translation. `defaultValue:` is mandatory for an explicit key —
        // the app ships no English string table, so a key without one renders as the key itself.
        .none: DisplayRepresentation(title: LocalizedStringResource(
            "priority.none", defaultValue: "None",
            comment: "Priority value meaning the task has no priority set. Answers 'Priority: ?', so the word agrees with the target language's word for priority — feminine in Spanish, French and Italian. Do not share this key with the reminder, location or empty-quadrant 'None'.")),
        .low: "Low",
        .medium: "Medium",
        .high: "High"
    ]

    /// Converts the intent priority to the app's `TaskPriority` value.
    var toTaskPriority: TaskPriority {
        switch self {
        case .none: return .none
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}
