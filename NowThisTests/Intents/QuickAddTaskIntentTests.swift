import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - QuickAddTaskIntent Tests

/// Verifies the natural-language Siri quick-add intent: a single spoken/typed
/// phrase is parsed into a task (title + due date/time) via `NaturalLanguageParser`.
@Suite("QuickAddTaskIntent")
struct QuickAddTaskIntentTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    /// Clears both the current and legacy keys. `UserDefaults` is shared across the
    /// whole test host, and the resolver now *writes* the list it adopts — so a test
    /// that failed midway used to leave its choice behind for whatever ran next.
    private func clearStoredList() {
        UserDefaults.standard.removeObject(forKey: TaskDefaultsPreferences.defaultListIDKey)
        UserDefaults.standard.removeObject(forKey: TaskDefaultsPreferences.legacySiriListIDKey)
    }

    @Test("Parses title and clock time into a timed, non-all-day task")
    @MainActor
    func createsTimedTask() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let inbox = TaskList(serverURL: "", name: "Inbox", colorHex: "#FF0000")
        context.insert(inbox)
        try context.save()
        clearStoredList()
        defer { clearStoredList() }

        let intent = QuickAddTaskIntent()
        intent.text = "Buy milk tomorrow at 5pm"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let iso = ISO8601DateFormatter()
        let now = try #require(iso.date(from: "2026-03-07T20:00:00Z"))
        let expectedDue = try #require(iso.date(from: "2026-03-09T00:00:00Z"))
        let result = try await intent.performWithContainer(container, now: now, calendar: calendar)

        let read = ModelContext(container)
        let tasks = try read.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == 1)
        let task = try #require(tasks.first)
        #expect(task.title == "Buy milk")
        #expect(task.isDueDateOnly == false)
        #expect(task.dueDate == expectedDue)
        #expect(task.taskList?.id == inbox.id)
        #expect(task.isDirty == true)
        var spokenStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)
        spokenStyle.timeZone = calendar.timeZone
        #expect(result.spokenText == "Added \"Buy milk\", due \(expectedDue.formatted(spokenStyle)), to Inbox.")
    }

    @Test("Bare keyword date creates an all-day (date-only) task")
    @MainActor
    func createsAllDayTask() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let inbox = TaskList(serverURL: "", name: "Inbox", colorHex: "#FF0000")
        inbox.defaultDueDateRule = .nextWeek
        context.insert(inbox)
        try context.save()
        clearStoredList()
        defer { clearStoredList() }

        let intent = QuickAddTaskIntent()
        intent.text = "Buy milk tomorrow"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let iso = ISO8601DateFormatter()
        let now = try #require(iso.date(from: "2026-03-07T20:00:00Z"))
        let expectedDue = try #require(iso.date(from: "2026-03-08T00:00:00Z"))
        let localNoon = try #require(iso.date(from: "2026-03-08T19:00:00Z"))
        let result = try await intent.performWithContainer(container, now: now, calendar: calendar)

        let read = ModelContext(container)
        let tasks = try read.fetch(FetchDescriptor<TaskItem>())
        let task = try #require(tasks.first)
        #expect(task.title == "Buy milk")
        #expect(task.dueDate == expectedDue)
        #expect(task.isDueDateOnly == true)
        var spokenStyle = Date.FormatStyle(date: .abbreviated, time: .omitted)
        spokenStyle.timeZone = calendar.timeZone
        #expect(result.spokenText == "Added \"Buy milk\", due \(localNoon.formatted(spokenStyle)), to Inbox.")
    }

    @Test("Uses the configured default Siri list")
    @MainActor
    func usesConfiguredDefaultList() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let grocery = TaskList(serverURL: "", name: "Grocery", colorHex: "#00FF00")
        let work = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(grocery)
        context.insert(work)
        try context.save()
        TaskDefaultsPreferences.setDefaultListID(work.id)
        defer { clearStoredList() }

        let intent = QuickAddTaskIntent()
        intent.text = "Order coffee"
        _ = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let task = try #require(tasks.first)
        #expect(task.taskList?.id == work.id)
    }

    @Test("Falls back to first alphabetical list when no default configured")
    @MainActor
    func fallsBackToFirstList() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let alpha = TaskList(serverURL: "", name: "Alpha", colorHex: "#FF0000")
        let beta = TaskList(serverURL: "", name: "Beta", colorHex: "#00FF00")
        context.insert(alpha)
        context.insert(beta)
        try context.save()
        clearStoredList()
        defer { clearStoredList() }

        let intent = QuickAddTaskIntent()
        intent.text = "Water plants"
        _ = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let task = try #require(tasks.first)
        #expect(task.taskList?.id == alpha.id)
    }

    @Test("Throws when there are no lists to add to")
    @MainActor
    func throwsWithoutLists() async throws {
        let container = try makeContainer()
        clearStoredList()
        defer { clearStoredList() }

        let intent = QuickAddTaskIntent()
        intent.text = "Homeless task"
        await #expect(throws: IntentError.self) {
            _ = try await intent.performWithContainer(container)
        }
    }

    @Test("Applies typed priority and tag sigils from the text")
    @MainActor
    func appliesTypedSigils() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let inbox = TaskList(serverURL: "", name: "Inbox", colorHex: "#FF0000")
        context.insert(inbox)
        try context.save()
        clearStoredList()
        defer { clearStoredList() }

        let intent = QuickAddTaskIntent()
        intent.text = "Pay rent !high @finance tomorrow"
        _ = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let task = try #require(tasks.first)
        #expect(task.title == "Pay rent")
        #expect(task.priority == .high)
        #expect(task.tags.contains { $0.name == "finance" })
    }

    @Test(arguments: [false, true])
    @MainActor
    func repeatedTagsUseOneSavedIdentity(hasExistingTag: Bool) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let inbox = TaskList(serverURL: "", name: "Inbox", colorHex: "#FF0000")
        context.insert(inbox)
        let existing = NowThis.Tag(id: "existing-work", name: "Work")
        if hasExistingTag { context.insert(existing) }
        try context.save()
        clearStoredList()
        defer { clearStoredList() }

        let intent = QuickAddTaskIntent()
        intent.text = "Buy milk tomorrow @work @Work @work @cafe @café @CAFÉ"
        _ = try await intent.performWithContainer(container, onWidgetReload: {})

        let read = ModelContext(container)
        let task = try #require(try read.fetch(FetchDescriptor<TaskItem>()).first)
        let tags = try read.fetch(FetchDescriptor<NowThis.Tag>())
        #expect(task.title == "Buy milk")
        #expect(task.isDueDateOnly)
        #expect(tags.count == 3)
        #expect(task.tags.count == 3)
        #expect(Set(task.tags.map(\.id)) == Set(tags.map(\.id)))
        #expect(Set(tags.map(\.name)) == [hasExistingTag ? "Work" : "work", "cafe", "café"])
        if hasExistingTag {
            #expect(task.tags.contains { $0.id == existing.id && $0.name == "Work" })
        }
    }

    @Test @MainActor
    func unreadableTagsCannotStageTaskOrReloadWidgets() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(TaskList(serverURL: "", name: "Inbox", colorHex: "#FF0000"))
        let existing = NowThis.Tag(name: "Work")
        context.insert(existing)
        try context.save()
        clearStoredList()
        defer { clearStoredList() }

        struct FetchFailure: Error {}
        let intent = QuickAddTaskIntent()
        intent.text = "Buy milk @work @Work"
        var reloads = 0
        await #expect(throws: FetchFailure.self) {
            _ = try await intent.perform(in: context, fetchTags: { _ in throw FetchFailure() },
                                         onWidgetReload: { reloads += 1 })
        }

        #expect(reloads == 0)
        #expect(!context.hasChanges)
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<TaskItem>()).isEmpty)
        #expect(try read.fetch(FetchDescriptor<NowThis.Tag>()).map(\.id) == [existing.id])
        #expect(try ReminderSchedulingJournal.capture(in: read).isEmpty)
    }
}
