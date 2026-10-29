import Foundation
import SwiftData
import Testing
@testable import NowThis

/// Four bugs that exist **today**, before a single word is translated, and that a language
/// change turns from latent into user-visible. Each one compares a *localized* value against
/// something durable — a filter saved to disk, a list name on a CalDAV server, a Focus
/// configuration in the system database.
///
/// The shared shape: `String(localized:)` produces different bytes per language, so anything
/// that stores or matches on its output stops matching the moment the language changes. The fix
/// is always the same — persist a stable token, display a localized one — and the tests below
/// pin both halves plus the migration for data already on disk.
@Suite("Localization / logic coupling")
struct LocalizationLogicCouplingTests {

    // MARK: - Bug 1 — saved priority filters

    /// `SavedFilter.rulesData` is JSON on disk. It stored `TaskPriority.displayName`, and
    /// `FilterRule.matches` compared against `task.priority.displayName.lowercased()`.
    /// Shipping five languages makes **every existing priority filter match nothing**.
    @Test("Priority filter tokens are frozen")
    func priorityFilterTokensAreFrozen() {
        #expect(TaskPriority.none.filterToken == "none")
        #expect(TaskPriority.high.filterToken == "high")
        #expect(TaskPriority.medium.filterToken == "medium")
        #expect(TaskPriority.low.filterToken == "low")

        // These are written into SavedFilter.rulesData. Changing one is a migration.
        #expect(Set(TaskPriority.allCases.map(\.filterToken)).count == TaskPriority.allCases.count,
                "Two priorities share a filter token — saved filters would become ambiguous.")
    }

    @Test("A stored token resolves back to its priority")
    func storedTokenResolvesToPriority() {
        for priority in TaskPriority.allCases {
            #expect(TaskPriority(filterToken: priority.filterToken) == priority)
        }
        #expect(TaskPriority(filterToken: "nonsense") == nil)
        #expect(TaskPriority(filterToken: "") == nil)
    }

    /// Filters already on disk hold the English display name. They must keep working — the
    /// user did not do anything wrong, and there is no UI that would tell them to re-create it.
    @Test("Filters saved before the fix still match")
    func legacyEnglishFilterValuesStillMatch() {
        #expect(TaskPriority(filterToken: "High") == .high)
        #expect(TaskPriority(filterToken: "high") == .high)
        #expect(TaskPriority(filterToken: "Medium") == .medium)
        #expect(TaskPriority(filterToken: "Low") == .low)
        // Spelled out: in an `Optional<TaskPriority>` context, `.none` binds `Optional.none`
        // (nil), not `TaskPriority.none`. The first version of this test compared against nil
        // and passed for the wrong reason.
        #expect(TaskPriority(filterToken: "None") == TaskPriority.none)
    }

    @Test("A priority rule matches on the token, not the label")
    @MainActor
    func priorityRuleMatchesByToken() throws {
        let container = try Self.makeContainer()
        let task = TaskItem(title: "Ship it")
        task.priority = .high
        container.mainContext.insert(task)

        let current = FilterRule(field: .priority, comparison: .equals, value: "high")
        let legacy = FilterRule(field: .priority, comparison: .equals, value: "High")
        let other = FilterRule(field: .priority, comparison: .equals, value: "low")

        #expect(current.matches(task, allLists: []))
        #expect(legacy.matches(task, allLists: []))
        #expect(!other.matches(task, allLists: []))
    }

    /// The behavioural tests above pass whichever way `matches` is written, because the suite
    /// runs in English. This is the assertion that does not.
    @Test("The filter matcher does not read a localized display name")
    func filterMatcherIsNotCoupledToDisplayName() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let source = try String(contentsOf: root.appendingPathComponent("NowThis/Models/SavedFilter.swift"),
                                encoding: .utf8)

        // Scoped to FilterRule. Display properties legitimately live in this file — FilterLogic,
        // FilterField and FilterComparison all carry a localized displayName. It is the
        // *matcher*, which runs against data read off disk, that must not resolve one.
        guard let start = source.range(of: "struct FilterRule"),
              let end = source.range(of: "enum FilterField", range: start.upperBound..<source.endIndex) else {
            Issue.record("""
                Could not locate the FilterRule region in SavedFilter.swift. The file was
                restructured; fix this guard rather than deleting it — a scan that cannot find
                its subject must not report "no findings".
                """)
            return
        }
        let matcher = String(source[start.upperBound..<end.lowerBound])
        #expect(matcher.count > 500, "FilterRule region is only \(matcher.count) characters — the scan is looking at the wrong text.")

        #expect(!matcher.contains("displayName"), """
            FilterRule compares against a displayName, which is String(localized:). The rule
            value it is compared to was saved to disk in whatever language the user had at the
            time. Compare a stable token instead.
            """)
        #expect(!matcher.contains("String(localized:"), """
            FilterRule evaluates rules against persisted data and must not resolve any localized
            string while doing it. Display strings live on the enums; matching does not.
            """)
    }

    // MARK: - Bug 2 — the recovery list

    /// `AccountManager` looked the recovery list up by `name == String(localized: "Recovered
    /// Tasks")`. Remove an account in English, switch to German, remove another — and a second
    /// recovery list is created, with the first one's tasks stranded in it.
    @Test("The recovery list is identified by a stable marker, not its name")
    @MainActor
    func recoveryListIsFoundByStableMarker() throws {
        let container = try Self.makeContainer()
        let context = container.mainContext

        let recovered = TaskList(serverURL: TaskList.recoveryListServerURL,
                                 name: "Recovered Tasks", colorHex: "#007AFF")
        let ordinary = TaskList(serverURL: "", name: "Recovered Tasks", colorHex: "#007AFF")
        context.insert(recovered)
        context.insert(ordinary)

        #expect(recovered.isRecoveryList)
        #expect(!ordinary.isRecoveryList,
                "A user's own list that happens to be called 'Recovered Tasks' is not the recovery list.")

        // The name is free to be translated, renamed by the user, or both.
        recovered.name = "Wiederhergestellte Aufgaben"
        #expect(recovered.isRecoveryList)
    }

    @Test("AccountManager does not look the recovery list up by name")
    func accountManagerIsNotCoupledToTheRecoveryListName() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let source = try String(contentsOf: root.appendingPathComponent("NowThis/Keychain/AccountManager.swift"),
                                encoding: .utf8)
        #expect(!source.contains("$0.name == recoveryName"), """
            AccountManager still finds the recovery list by comparing a localized name. Switching
            device language creates a second recovery list and strands the tasks in the first.
            Match on TaskList.isRecoveryList.
            """)
    }

    // MARK: - Bug 3 — Focus filters

    /// The worst of the four, because it is **unmigratable**: the configuration lives in the
    /// system's Focus database, outside the app container, so no app update can fix it after
    /// localized list names ship. A German user's Focus filter configured against "Inbox" stops
    /// matching "Posteingang", and their Focus mode silently shows everything.
    @Test("Focus visibility matches on list identity")
    @MainActor
    func focusFilterMatchesByListIdentity() throws {
        let container = try Self.makeContainer()
        let inbox = TaskList(serverURL: "", name: "Inbox", colorHex: "#007AFF")
        let work = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        container.mainContext.insert(inbox)
        container.mainContext.insert(work)

        let state = FocusFilterState()
        state.update(visibleListIDs: [inbox.id], legacyNames: [])

        #expect(state.isVisible(inbox))
        #expect(!state.isVisible(work))

        // The whole point: renaming — or translating — the list changes nothing.
        inbox.name = "Posteingang"
        #expect(state.isVisible(inbox))
    }

    @Test("Focus configurations made before the fix still work")
    @MainActor
    func focusFilterHonoursLegacyNameConfiguration() throws {
        let container = try Self.makeContainer()
        let inbox = TaskList(serverURL: "", name: "Inbox", colorHex: "#007AFF")
        let work = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        container.mainContext.insert(inbox)
        container.mainContext.insert(work)

        let state = FocusFilterState()
        state.update(visibleListIDs: [], legacyNames: ["Inbox"])

        #expect(state.isVisible(inbox))
        #expect(!state.isVisible(work))
    }

    @Test("No filter means everything is visible")
    @MainActor
    func focusFilterInactiveShowsEverything() throws {
        let container = try Self.makeContainer()
        let list = TaskList(serverURL: "", name: "Anything", colorHex: "#007AFF")
        container.mainContext.insert(list)

        let state = FocusFilterState()
        state.update(visibleListIDs: [], legacyNames: [])
        #expect(!state.isActive)
        #expect(state.isVisible(list))
    }

    /// The `","` separator assumption is the same class of bug one layer down: German and Dutch
    /// users routinely separate with `;`, and a list name may legitimately contain a comma.
    @Test("Legacy name parsing accepts both separators")
    func legacyNameParsingAcceptsBothSeparators() {
        #expect(NowThisFocusFilter.parseLegacyNames("Inbox, Work") == ["Inbox", "Work"])
        #expect(NowThisFocusFilter.parseLegacyNames("Inbox; Work") == ["Inbox", "Work"])
        #expect(NowThisFocusFilter.parseLegacyNames("  Inbox ,, Work ") == ["Inbox", "Work"])
        #expect(NowThisFocusFilter.parseLegacyNames("") == [])
        #expect(NowThisFocusFilter.parseLegacyNames(nil) == [])
    }

    // MARK: - Bug 4 — journal preview

    /// `Text(LocalizedStringKey(content))` ran the user's own journal prose through catalog
    /// lookup. Once catalogs exist, a journal entry whose text happens to match a key is
    /// silently replaced by a translation of it.
    @Test("Journal preview never resolves a catalog key")
    func journalPreviewDoesNotResolveCatalogKeys() {
        // "sort.manually" is a real key in NowThis/Localizable.xcstrings whose English is
        // "Manually". LocalizedStringKey would render "Manually" here.
        let rendered = String(JournalMarkdown.render("sort.manually").characters)
        #expect(rendered == "sort.manually", """
            The journal preview resolved \u{201C}sort.manually\u{201D} to \u{201C}\(rendered)\u{201D} — it is
            still passing the user's own writing through the string catalog.
            """)

        let plain = String(JournalMarkdown.render("Today").characters)
        #expect(plain == "Today")
    }

    @Test("Journal preview still renders Markdown")
    func journalPreviewRendersMarkdown() {
        // Markdown syntax is consumed; the text survives.
        #expect(String(JournalMarkdown.render("**bold**").characters) == "bold")
        #expect(String(JournalMarkdown.render("*italic*").characters) == "italic")
        #expect(String(JournalMarkdown.render("plain text").characters) == "plain text")
        // Newlines must survive — a journal entry is prose, not a label.
        #expect(String(JournalMarkdown.render("line one\nline two").characters)
                == "line one\nline two")
    }

    @Test("The journal preview does not use LocalizedStringKey")
    func journalEditorIsNotCoupledToTheCatalog() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("NowThis/Views/Journal/JournalEditorView.swift"),
            encoding: .utf8)
        #expect(!source.contains("LocalizedStringKey(content)"), """
            JournalEditorView is passing the user's journal text through LocalizedStringKey, which
            performs a catalog lookup on it.
            """)
    }

    // MARK: - Helpers

    static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}
