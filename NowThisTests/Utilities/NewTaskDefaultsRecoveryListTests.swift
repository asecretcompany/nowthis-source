import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - The Recovery List Is Not a Default

/// Covers which lists ``NewTaskDefaults`` may silently adopt as the user's default.
///
/// `allLists` is an unpredicated `FetchDescriptor<TaskList>()`, so every list in the store
/// was a candidate — including the one that holds tasks rescued from a removed account.
/// Its localized name ("Recovered Tasks") sorts before most real list names in English, and
/// `resolveListAdopting` *persists* whatever it picks. So one account removal could send
/// every task afterwards created from a Smart List, a tag, Siri or the watch into the
/// recovery list, for good — which reads exactly like "one of the lists randomly has every
/// task in it".
@Suite("New Task Default List — Recovery List")
@MainActor
struct NewTaskDefaultsRecoveryListTests {

    /// Held by the caller for the test's lifetime; see `NewTaskDefaultsListTests`.
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

    /// Named so it sorts first — the whole point is that sort order must not be able to
    /// promote it.
    private func insertRecoveryList(into context: ModelContext) -> TaskList {
        let list = TaskList(
            serverURL: TaskList.recoveryListServerURL,
            name: "Aaa Recovered Tasks",
            colorHex: "#007AFF"
        )
        context.insert(list)
        return list
    }

    @Test("The recovery list is never adopted while an ordinary list exists")
    func recoveryListNotAdopted() throws {
        let container = try makeContainer()
        defer { clearStoredList() }
        clearStoredList()
        let context = container.mainContext

        let recovery = insertRecoveryList(into: context)
        let ordinary = TaskList(serverURL: "/calendars/work/", name: "Work", colorHex: "#FF3B30")
        context.insert(ordinary)
        try context.save()

        let resolved = NewTaskDefaults.resolveListAdopting(explicit: nil, in: context)

        #expect(resolved?.id == ordinary.id,
                "a rescued-tasks holding pen must not become where new tasks go")
        #expect(resolved?.id != recovery.id)
    }

    @Test("The pure resolver agrees, so the add bar and the creation path cannot disagree")
    func pureResolverSkipsRecoveryList() throws {
        let container = try makeContainer()
        defer { clearStoredList() }
        clearStoredList()
        let context = container.mainContext

        _ = insertRecoveryList(into: context)
        let ordinary = TaskList(serverURL: "/calendars/work/", name: "Work", colorHex: "#FF3B30")
        context.insert(ordinary)
        try context.save()

        let resolved = NewTaskDefaults.resolveList(explicit: nil, in: context)

        #expect(resolved?.id == ordinary.id)
    }

    @Test("With nothing else in the store the recovery list is still a home for a new task")
    func recoveryListUsedWhenItIsTheOnlyList() throws {
        let container = try makeContainer()
        defer { clearStoredList() }
        clearStoredList()
        let context = container.mainContext

        let recovery = insertRecoveryList(into: context)
        try context.save()

        let resolved = NewTaskDefaults.resolveListAdopting(explicit: nil, in: context)

        #expect(resolved?.id == recovery.id,
                "excluding it entirely would leave a task with nowhere to go")
    }

    @Test("An explicitly chosen recovery list is still honoured")
    func explicitRecoveryListWins() throws {
        let container = try makeContainer()
        defer { clearStoredList() }
        clearStoredList()
        let context = container.mainContext

        let recovery = insertRecoveryList(into: context)
        let ordinary = TaskList(serverURL: "/calendars/work/", name: "Work", colorHex: "#FF3B30")
        context.insert(ordinary)
        try context.save()

        let resolved = NewTaskDefaults.resolveListAdopting(explicit: recovery, in: context)

        #expect(resolved?.id == recovery.id,
                "the rule is about silent adoption, not about forbidding the list")
    }
}
