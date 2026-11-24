import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - CreateTaskIntent Default List Tests

@Suite("CreateTaskIntent Default List")
struct CreateTaskIntentDefaultListTests {

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

    enum DueQuestionDestination: CaseIterable {
        case explicit, configured, alphabetical, migratedLegacy
    }

    @Test("Siri rechecks the destination after its due date question and keeps denied saves side effect free",
          arguments: DueQuestionDestination.allCases)
    @MainActor
    func revocationDuringDueDateQuestion(destination: DueQuestionDestination) async throws {
        let defaults = UserDefaults.standard
        let keys = [TaskDefaultsPreferences.defaultListIDKey, TaskDefaultsPreferences.legacySiriListIDKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        clearStoredList()
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let container = try makeContainer()
        let context = container.mainContext
        let account = ServerAccount(displayName: "Shared", serverBaseURL: "https://siri-creation.invalid", username: "fixture")
        let chosen = TaskList(serverURL: "/shared/", name: "Alpha", colorHex: "#123456")
        let neighbor = TaskList(serverURL: "/other/", name: "Zulu", colorHex: "#123456")
        context.insert(account)
        context.insert(chosen)
        context.insert(neighbor)
        chosen.account = account
        neighbor.account = account
        chosen.defaultDueDateRule = .nextWeek
        chosen.defaultReminderEnabledOverride = false
        neighbor.defaultDueDateRule = .today
        try context.save()
        let chosenID = chosen.id
        let expectedPreference: String?
        switch destination {
        case .explicit:
            TaskDefaultsPreferences.setDefaultListID(neighbor.id)
            expectedPreference = neighbor.id
        case .configured:
            TaskDefaultsPreferences.setDefaultListID(chosenID)
            expectedPreference = chosenID
        case .alphabetical:
            expectedPreference = nil
        case .migratedLegacy:
            defaults.set(chosenID, forKey: TaskDefaultsPreferences.legacySiriListIDKey)
            expectedPreference = nil
        }
        let intent = CreateTaskIntent()
        intent.taskTitle = "Retain dictated title"
        intent.notes = "Retain dictated notes"
        intent.tag = "new-siri-tag"
        intent.askForDueDate = true
        if destination == .explicit { intent.list = TaskListEntity(id: chosenID, name: chosen.name) }
        var asked: [DefaultDueDateRule] = []
        var reloads = 0
        let descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == chosenID })
        func commitPermission(_ readOnly: Bool) throws {
            let writer = ModelContext(container)
            let rows = try writer.fetch(descriptor)
            let current = try #require(rows.first)
            current.isReadOnly = readOnly
            try writer.save()
            let saved = try ModelContext(container).fetch(descriptor).first?.isReadOnly
            try #require(saved == readOnly)
        }

        var reportedError: String?
        do {
            _ = try await intent.performWithDueDateQuestion(makeContainer: { container }, askDueDate: { rule in
                asked.append(rule)
                #expect(defaults.string(forKey: TaskDefaultsPreferences.defaultListIDKey) == expectedPreference)
                if destination == .migratedLegacy {
                    #expect(defaults.string(forKey: TaskDefaultsPreferences.legacySiriListIDKey) == chosenID)
                }
                await Task.yield()
                try commitPermission(true)
                return .tomorrow
            }, onWidgetReload: { reloads += 1 })
        } catch { reportedError = error.localizedDescription }
        #expect(asked == [.nextWeek])
        #expect(reportedError?.isEmpty == false)
        #expect(reloads == 0)
        #expect(defaults.string(forKey: TaskDefaultsPreferences.defaultListIDKey) == expectedPreference)
        if destination == .migratedLegacy {
            #expect(defaults.string(forKey: TaskDefaultsPreferences.legacySiriListIDKey) == chosenID)
        }
        let denied = ModelContext(container)
        let saved = try denied.fetch(FetchDescriptor<TaskItem>())
        #expect(saved.isEmpty)
        #expect(try denied.fetchCount(FetchDescriptor<NowThis.Tag>()) == 0)
        #expect(try denied.fetchCount(FetchDescriptor<SyncMetadata>()) == 0)
        guard saved.isEmpty else { return }

        try commitPermission(false)
        let beforeRetry = Date()
        let result = try await intent.performWithDueDateQuestion(makeContainer: { container }, askDueDate: { rule in
            asked.append(rule)
            return .tomorrow
        }, onWidgetReload: { reloads += 1 })
        let read = ModelContext(container)
        let tasks = try read.fetch(FetchDescriptor<TaskItem>())
        #expect(asked == [.nextWeek, .nextWeek] && reloads == 1)
        #expect(tasks.count == 1 && tasks.first?.taskList?.id == chosenID)
        #expect(tasks.first?.title == "Retain dictated title" && tasks.first?.descriptionText == "Retain dictated notes")
        #expect(tasks.first?.tags.map(\.name) == ["new-siri-tag"])
        let afterRetry = Date()
        let calendar = Calendar.current
        let possibleDueDays = [beforeRetry, afterRetry].compactMap { calendar.date(byAdding: .day, value: 1, to: $0) }
        let due = try #require(tasks.first?.dueDate)
        #expect(possibleDueDays.contains { calendar.isDate(due, inSameDayAs: $0) })
        #expect(tasks.first?.isDueDateOnly == false)
        #expect(result.spokenText.contains(chosen.name))
        #expect(defaults.string(forKey: TaskDefaultsPreferences.defaultListIDKey) ==
            (destination == .alphabetical || destination == .migratedLegacy ? chosenID : expectedPreference))
        if destination == .migratedLegacy {
            #expect(defaults.string(forKey: TaskDefaultsPreferences.legacySiriListIDKey) == chosenID)
        }
    }

    @Test("Uses configured default list instead of first alphabetical list")
    @MainActor
    func usesConfiguredDefaultList() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        // Create three lists — alphabetically: Grocery, Personal, Work
        let grocery = TaskList(serverURL: "", name: "Grocery", colorHex: "#00FF00")
        let personal = TaskList(serverURL: "", name: "Personal", colorHex: "#0000FF")
        let work = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(grocery)
        context.insert(personal)
        context.insert(work)
        try context.save()

        // Configure "Work" as the default list
        TaskDefaultsPreferences.setDefaultListID(work.id)
        defer { clearStoredList() }

        let intent = CreateTaskIntent()
        intent.taskTitle = "Buy coffee beans"
        // list is nil — should use the configured default, not alphabetical first
        let result = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == 1)
        #expect(tasks.first?.taskList?.id == work.id)
        #expect(result.spokenText.contains("Work"))
    }

    @Test("Falls back to first list when configured default list is deleted")
    @MainActor
    func fallsBackWhenDefaultListDeleted() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let alpha = TaskList(serverURL: "", name: "Alpha", colorHex: "#FF0000")
        let beta = TaskList(serverURL: "", name: "Beta", colorHex: "#00FF00")
        context.insert(alpha)
        context.insert(beta)
        try context.save()

        // Point to a non-existent list ID
        TaskDefaultsPreferences.setDefaultListID("deleted-list-id-that-does-not-exist")
        defer { clearStoredList() }

        let intent = CreateTaskIntent()
        intent.taskTitle = "Fallback task"
        let result = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == 1)
        // Should fall back to first alphabetical list
        #expect(tasks.first?.taskList?.id == alpha.id)
        #expect(result.spokenText.contains("Alpha"))
    }

    @Test("Falls back to first list when no default is configured")
    @MainActor
    func fallsBackWhenNoDefaultConfigured() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let alpha = TaskList(serverURL: "", name: "Alpha", colorHex: "#FF0000")
        let beta = TaskList(serverURL: "", name: "Beta", colorHex: "#00FF00")
        context.insert(alpha)
        context.insert(beta)
        try context.save()

        // Ensure no default is set
        clearStoredList()
        defer { clearStoredList() }

        let intent = CreateTaskIntent()
        intent.taskTitle = "No default task"
        let result = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == 1)
        // Should use first alphabetical list (existing behavior)
        #expect(tasks.first?.taskList?.id == alpha.id)
        #expect(result.spokenText.contains("Alpha"))
    }

    @Test("Explicit read-only destination refuses creation before tag or widget effects")
    @MainActor
    func explicitReadOnlyDestinationRefusesCreate() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let list = TaskList(serverURL: "", name: "Read only", colorHex: "#FF0000")
        list.isReadOnly = true
        context.insert(list)
        try context.save()

        let intent = CreateTaskIntent()
        intent.taskTitle = "Do not create"
        intent.list = TaskListEntity(id: list.id, name: list.name)
        intent.tag = "New tag"
        var widgetReloads = 0
        await #expect(throws: IntentError.self) {
            _ = try await intent.performWithContainer(container,
                onWidgetReload: { widgetReloads += 1 })
        }

        let reader = ModelContext(container)
        #expect(try reader.fetch(FetchDescriptor<TaskItem>()).isEmpty)
        #expect(try reader.fetch(FetchDescriptor<NowThis.Tag>()).isEmpty)
        #expect(try ReminderSchedulingJournal.capture(in: reader).isEmpty)
        #expect(widgetReloads == 0)
        #expect(!context.hasChanges)
    }
}
