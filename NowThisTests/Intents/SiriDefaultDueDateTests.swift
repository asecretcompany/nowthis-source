import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Siri Default Due Date Tests

/// Tasks added through Siri skipped `NewTaskDefaults` entirely: the configured default due
/// date and default reminder applied to every in-app add path but neither intent.
///
/// Every test sets the rule as a **per-list** override rather than the global preference.
/// `UserDefaults` is shared by the whole test host and suites run in parallel, so writing the
/// global rule here would put due dates on tasks other suites expect to have none.
@Suite("Siri Default Due Date")
struct SiriDefaultDueDateTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    private func clearStoredList() {
        UserDefaults.standard.removeObject(forKey: TaskDefaultsPreferences.defaultListIDKey)
        UserDefaults.standard.removeObject(forKey: TaskDefaultsPreferences.legacySiriListIDKey)
    }

    /// Whole days from today to `date` in the current calendar.
    private func daysFromToday(_ date: Date) -> Int? {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)
        ).day
    }

    @MainActor
    private func insertList(_ context: ModelContext,
                            rule: DefaultDueDateRule?,
                            reminder: Bool? = nil) throws -> TaskList {
        let list = TaskList(serverURL: "", name: "Inbox", colorHex: "#FF0000")
        list.defaultDueDateRule = rule
        list.defaultReminderEnabledOverride = reminder
        context.insert(list)
        try context.save()
        return list
    }

    // MARK: CreateTaskIntent

    @Test("Add Task with no due date gets the list's default due date")
    @MainActor
    func createAppliesDefaultRule() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        // `reminder: false` pins the input: with the override left `nil` the assertion below
        // would read the global setting, and pass or fail with the simulator's Settings.
        _ = try insertList(context, rule: .tomorrow, reminder: false)
        clearStoredList()
        defer { clearStoredList() }

        let intent = CreateTaskIntent()
        intent.taskTitle = "Call the dentist"
        _ = try await intent.performWithContainer(container)

        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        let due = try #require(task.dueDate)
        #expect(daysFromToday(due) == 1)
        #expect(task.isDueDateOnly == false)
        #expect(task.reminderOffset == nil)
    }

    @Test("Add Task keeps an explicit due date over the default")
    @MainActor
    func createKeepsExplicitDueDate() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = try insertList(context, rule: .tomorrow)
        clearStoredList()
        defer { clearStoredList() }

        let explicit = Calendar.current.date(byAdding: .day, value: 3, to: Date())!
        let intent = CreateTaskIntent()
        intent.taskTitle = "Call the dentist"
        intent.dueDate = explicit
        _ = try await intent.performWithContainer(container)

        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(task.dueDate == explicit)
    }

    @Test("The due date Siri was told replaces the list's default")
    @MainActor
    func createUsesChosenRule() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = try insertList(context, rule: .tomorrow)
        clearStoredList()
        defer { clearStoredList() }

        let intent = CreateTaskIntent()
        intent.taskTitle = "Call the dentist"
        _ = try await intent.performWithContainer(container, dueDateRule: .nextWeek)

        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        let due = try #require(task.dueDate)
        #expect(daysFromToday(due) == 7)
    }

    @Test("Answering \"No Due Date\" leaves the task undated despite a default")
    @MainActor
    func createChosenNoneLeavesUndated() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = try insertList(context, rule: .tomorrow)
        clearStoredList()
        defer { clearStoredList() }

        let intent = CreateTaskIntent()
        intent.taskTitle = "Call the dentist"
        _ = try await intent.performWithContainer(container, dueDateRule: DefaultDueDateRule.none)

        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(task.dueDate == nil)
    }

    @Test("Add Task gets the default reminder when the task ends up with a due date")
    @MainActor
    func createAppliesDefaultReminder() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = try insertList(context, rule: .today, reminder: true)
        clearStoredList()
        defer { clearStoredList() }

        let intent = CreateTaskIntent()
        intent.taskTitle = "Call the dentist"
        _ = try await intent.performWithContainer(container)

        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(task.dueDate != nil)
        #expect(task.reminderOffset == 0)
    }

    @Test("Add Task with an explicit due date also gets the default reminder")
    @MainActor
    func createExplicitDueGetsDefaultReminder() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = try insertList(context, rule: nil, reminder: true)
        clearStoredList()
        defer { clearStoredList() }

        let intent = CreateTaskIntent()
        intent.taskTitle = "Call the dentist"
        intent.dueDate = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        _ = try await intent.performWithContainer(container)

        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(task.reminderOffset == 0)
    }

    @Test("Siri asks for a due date only when none was given and asking is on")
    func createAsksOnlyWhenUndated() {
        let intent = CreateTaskIntent()
        intent.taskTitle = "Call the dentist"
        // The App Shortcut runs with parameter defaults, so the default is what Siri gets.
        #expect(intent.askForDueDate == true)
        #expect(intent.shouldAskForDueDate == true)

        intent.dueDate = Date()
        #expect(intent.shouldAskForDueDate == false)

        intent.dueDate = nil
        intent.askForDueDate = false
        #expect(intent.shouldAskForDueDate == false)
    }

    @Test("The configured default is offered first, then the rest in date order",
          arguments: [
            (DefaultDueDateRule.tomorrow, [DefaultDueDateRule.tomorrow, .today, .nextWeek, .none]),
            (.none, [.none, .today, .tomorrow, .nextWeek]),
            (.nextWeek, [.nextWeek, .today, .tomorrow, .none]),
          ])
    func choicesLeadWithDefault(rule: DefaultDueDateRule, expected: [DefaultDueDateRule]) {
        #expect(CreateTaskIntent.dueDateChoices(default: rule) == expected)
    }

    /// `requestChoice` hands back an `IntentChoiceOption`, and how the framework compares two
    /// of them is not documented. The answer is matched by its title's catalog key instead —
    /// the one thing a copy of the option is certain to carry unchanged.
    @Test("Siri's answer is matched by its catalog key, not by option identity")
    func chosenRuleMatchesByKey() {
        let choices = CreateTaskIntent.dueDateChoices(default: .tomorrow)
        let nextWeekKey = CreateTaskIntent.choiceTitle(for: .nextWeek).key
        #expect(CreateTaskIntent.dueDateRule(forChoiceKey: nextWeekKey, among: choices) == .nextWeek)

        let noneKey = CreateTaskIntent.choiceTitle(for: DefaultDueDateRule.none).key
        #expect(CreateTaskIntent.dueDateRule(forChoiceKey: noneKey, among: choices)
                == DefaultDueDateRule.none)
    }

    @Test("An answer whose key matches nothing is reported as no match, not as the default")
    func unknownChoiceKeyIsNoMatch() {
        let choices = CreateTaskIntent.dueDateChoices(default: .tomorrow)
        // A rendered title rather than a key — what a re-localized copy of the option would carry.
        #expect(CreateTaskIntent.dueDateRule(forChoiceKey: "Morgen", among: choices) == nil)
    }

    // MARK: QuickAddTaskIntent

    @Test("Quick Add with no spoken date gets the list's default due date")
    @MainActor
    func quickAddAppliesDefaultRule() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = try insertList(context, rule: .tomorrow)
        clearStoredList()
        defer { clearStoredList() }

        let intent = QuickAddTaskIntent()
        intent.text = "Buy milk"
        _ = try await intent.performWithContainer(container)

        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        let due = try #require(task.dueDate)
        #expect(daysFromToday(due) == 1)
        #expect(task.isDueDateOnly == false)
    }

    @Test("Quick Add keeps a spoken date over the default")
    @MainActor
    func quickAddKeepsParsedDate() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = try insertList(context, rule: .nextWeek)
        clearStoredList()
        defer { clearStoredList() }

        let intent = QuickAddTaskIntent()
        intent.text = "Buy milk tomorrow at 5pm"
        _ = try await intent.performWithContainer(container)

        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        let due = try #require(task.dueDate)
        #expect(daysFromToday(due) == 1)
        #expect(Calendar.current.component(.hour, from: due) == 17)
    }

    @Test("Quick Add gets the default reminder when the task has a due date")
    @MainActor
    func quickAddAppliesDefaultReminder() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = try insertList(context, rule: nil, reminder: true)
        clearStoredList()
        defer { clearStoredList() }

        let intent = QuickAddTaskIntent()
        intent.text = "Buy milk tomorrow at 5pm"
        _ = try await intent.performWithContainer(container)

        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(task.reminderOffset == 0)
    }
}
