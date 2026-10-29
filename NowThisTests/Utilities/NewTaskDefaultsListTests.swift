import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Default List Resolution

/// Covers ``NewTaskDefaults/resolveList(explicit:in:)`` and its adopting twin — the
/// single rule every creation surface now shares for "which list does this task go in?"
///
/// The pure/adopting split is the point of most of these tests. `resolveList` is read
/// during `body` evaluation (`TaskListView` labels the add bar's due-date chip before
/// any task exists), so it must never write; `resolveListAdopting` runs only at real
/// creation moments and at Settings' `.onAppear`, where persisting is the whole idea.
@Suite("New Task Default List")
@MainActor
struct NewTaskDefaultsListTests {

    /// Held by the caller for the test's lifetime. Returning `.mainContext` from a
    /// factory instead deallocates the container out from under the context and
    /// SIGTRAPs the whole test process — which Swift Testing then reports as a green
    /// suite with zero tests.
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    /// Both keys cleared, so a test starts from "user has never chosen a list".
    private func clearStoredList() {
        UserDefaults.standard.removeObject(forKey: TaskDefaultsPreferences.defaultListIDKey)
        UserDefaults.standard.removeObject(forKey: TaskDefaultsPreferences.legacySiriListIDKey)
    }

    @discardableResult
    private func insertLists(_ names: [String], into context: ModelContext) throws -> [TaskList] {
        let lists = names.map { TaskList(serverURL: "", name: $0, colorHex: "#FF0000") }
        for list in lists { context.insert(list) }
        try context.save()
        return lists
    }

    // MARK: - Precedence

    @Test("An explicitly supplied list beats the stored default")
    func explicitListWins() throws {
        let container = try makeContainer()
        defer { clearStoredList() }
        let context = container.mainContext
        let lists = try insertLists(["Grocery", "Work"], into: context)
        UserDefaults.standard.set(lists[1].id, forKey: TaskDefaultsPreferences.defaultListIDKey)

        let resolved = NewTaskDefaults.resolveList(explicit: lists[0], in: context)

        #expect(resolved?.id == lists[0].id)
    }

    @Test("A stored ID that resolves is returned, and nothing is written")
    func storedIDIsReturned() throws {
        let container = try makeContainer()
        defer { clearStoredList() }
        let context = container.mainContext
        let lists = try insertLists(["Grocery", "Work"], into: context)
        UserDefaults.standard.set(lists[1].id, forKey: TaskDefaultsPreferences.defaultListIDKey)

        let resolved = NewTaskDefaults.resolveListAdopting(explicit: nil, in: context)

        #expect(resolved?.id == lists[1].id)
        // Already concrete — adoption must be a no-op, not a rewrite.
        #expect(UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey) == lists[1].id)
    }

    // MARK: - Adoption

    @Test("An unset key adopts the first list by localized name and persists it")
    func unsetKeyAdoptsAndPersists() throws {
        let container = try makeContainer()
        defer { clearStoredList() }
        let context = container.mainContext
        clearStoredList()
        let lists = try insertLists(["Work", "Grocery"], into: context)
        let grocery = try #require(lists.first { $0.name == "Grocery" })

        let resolved = NewTaskDefaults.resolveListAdopting(explicit: nil, in: context)

        #expect(resolved?.id == grocery.id)
        #expect(UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey) == grocery.id)
    }

    /// The old picker tagged its "First List" row with `""`, so a user who chose the
    /// abstract option has an empty string stored — not a missing key. A nil-check
    /// alone cannot tell "opted out" from "never set"; both must adopt.
    @Test("An empty-string stored value counts as unset and adopts")
    func emptyStringAdoptsAndPersists() throws {
        let container = try makeContainer()
        defer { clearStoredList() }
        let context = container.mainContext
        clearStoredList()
        UserDefaults.standard.set("", forKey: TaskDefaultsPreferences.defaultListIDKey)
        let lists = try insertLists(["Work", "Admin"], into: context)
        let admin = try #require(lists.first { $0.name == "Admin" })

        let resolved = NewTaskDefaults.resolveListAdopting(explicit: nil, in: context)

        #expect(resolved?.id == admin.id)
        #expect(UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey) == admin.id)
    }

    @Test("A dangling stored ID adopts a live list and heals the stored value")
    func danglingIDAdoptsAndHeals() throws {
        let container = try makeContainer()
        defer { clearStoredList() }
        let context = container.mainContext
        UserDefaults.standard.set("no-such-list", forKey: TaskDefaultsPreferences.defaultListIDKey)
        let lists = try insertLists(["Work", "Alpha"], into: context)
        let alpha = try #require(lists.first { $0.name == "Alpha" })

        let resolved = NewTaskDefaults.resolveListAdopting(explicit: nil, in: context)

        #expect(resolved?.id == alpha.id)
        #expect(UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey) == alpha.id)
    }

    @Test("No lists at all resolves to nil and writes nothing")
    func noListsResolvesToNilWithoutWriting() throws {
        let container = try makeContainer()
        defer { clearStoredList() }
        let context = container.mainContext
        clearStoredList()

        let resolved = NewTaskDefaults.resolveListAdopting(explicit: nil, in: context)

        #expect(resolved == nil)
        #expect(UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey) == nil)
    }

    // MARK: - Purity

    /// `resolveList` feeds a render path. A write there is a mutation during `body`.
    @Test("The pure variant never writes, on any branch")
    func pureVariantNeverWrites() throws {
        let container = try makeContainer()
        defer { clearStoredList() }
        let context = container.mainContext
        let lists = try insertLists(["Work", "Alpha"], into: context)
        let alpha = try #require(lists.first { $0.name == "Alpha" })

        for stored in [nil, "", "no-such-list"] as [String?] {
            clearStoredList()
            if let stored { UserDefaults.standard.set(stored, forKey: TaskDefaultsPreferences.defaultListIDKey) }

            let resolved = NewTaskDefaults.resolveList(explicit: nil, in: context)

            #expect(resolved?.id == alpha.id, "Expected the fallback list for stored value \(String(describing: stored)).")
            #expect(
                UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey) == stored,
                "resolveList wrote to UserDefaults for stored value \(String(describing: stored))."
            )
        }
    }

    // MARK: - Ordering

    /// Pins localized collation. A naive `<` puts "Équipe" after "Work" (É is U+00C9,
    /// above every ASCII letter) and "item 10" before "item 2".
    @Test("Ordering is localized, not code-point")
    func orderingIsLocalized() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let lists = try insertLists(["Work", "Équipe", "Personal", "item 10", "item 2"], into: context)

        let ordered = try #require(NewTaskDefaults.firstByLocalizedName(lists))

        #expect(ordered.name == "Équipe")

        let sorted = lists.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.map(\.name)
        #expect(sorted == ["Équipe", "item 2", "item 10", "Personal", "Work"])
    }

    @Test("An empty array has no first list")
    func firstByLocalizedNameOnEmptyArray() {
        #expect(NewTaskDefaults.firstByLocalizedName([]) == nil)
    }

    // MARK: - Legacy key migration

    @Test("The legacy Siri key migrates into the new key on first read")
    func legacyKeyMigrates() throws {
        defer { clearStoredList() }
        clearStoredList()
        UserDefaults.standard.set("legacy-list-id", forKey: TaskDefaultsPreferences.legacySiriListIDKey)

        #expect(TaskDefaultsPreferences.defaultListID == "legacy-list-id")
        #expect(UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey) == "legacy-list-id")
    }

    @Test("A legacy empty string is treated as unset and does not migrate")
    func legacyEmptyStringDoesNotMigrate() {
        defer { clearStoredList() }
        clearStoredList()
        UserDefaults.standard.set("", forKey: TaskDefaultsPreferences.legacySiriListIDKey)

        #expect(TaskDefaultsPreferences.defaultListID == nil)
        #expect(UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey) == nil)
    }

    @Test("The new key wins over a stale legacy value")
    func newKeyWinsOverLegacy() {
        defer { clearStoredList() }
        clearStoredList()
        UserDefaults.standard.set("legacy-list-id", forKey: TaskDefaultsPreferences.legacySiriListIDKey)
        UserDefaults.standard.set("current-list-id", forKey: TaskDefaultsPreferences.defaultListIDKey)

        #expect(TaskDefaultsPreferences.defaultListID == "current-list-id")
    }
}
