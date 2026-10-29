import Foundation
import Testing
@testable import NowThis

/// Six enums used their English `rawValue` **simultaneously** as the visible label and as the
/// persistence or wire key. Localizing a rawValue is a data-loss bug, not a translation bug:
/// `@AppStorage` reads back a value it can no longer decode, `SavedFilter.rulesData` stops
/// matching, and `TaskStatus` would rewrite the VTODO `STATUS` on every user's server.
///
/// The fix is a separate localized `displayName`, leaving the rawValue frozen. These tests pin
/// both halves — the freeze, and the fact that the new property actually reaches the catalog.
///
/// **Why catalog membership rather than "is it localized".** A `displayName` returning a bare
/// English literal compiles, renders, and looks right. The only observable difference is that
/// the compiler never emits it, so it never enters `Localizable.xcstrings`. That is exactly the
/// property to assert, and it is the same two-layer idea as the prior
/// `AccountCopyLocalizationGuardTests`: a check that fails on the *shape* of the code rather
/// than on its output.
@Suite("Localization / enum display names")
struct EnumDisplayNameGuardTests {

    // MARK: The freeze

    /// Raw values that are persisted, encoded, or sent to a CalDAV server. Changing any of
    /// these is a migration, never a rename.
    @Test("Persisted and wire raw values are frozen")
    func persistedRawValuesAreFrozen() {
        // RFC-5545 §3.8.1.11. SyncEngine.swift passes these straight into ICalendarSerializer,
        // which emits `STATUS:\(status)`, and string-matches "STATUS:COMPLETED" against raw ICS.
        #expect(TaskStatus.needsAction.rawValue == "NEEDS-ACTION")
        #expect(TaskStatus.inProcess.rawValue == "IN-PROCESS")
        #expect(TaskStatus.completed.rawValue == "COMPLETED")
        #expect(TaskStatus.cancelled.rawValue == "CANCELLED")

        // @AppStorage in SidebarView and SettingsView; the sidebar selection is rebuilt from it.
        #expect(SmartList.allCases.map(\.rawValue)
                == ["Today", "Upcoming", "Overdue", "All Tasks", "Completed"])

        // @AppStorage, TaskListView.swift.
        #expect(TaskSortOption.allCases.map(\.rawValue)
                == ["Due Date", "Start Date", "Priority", "Title", "Created", "Modified",
                    "Completed Date", "Tags", "Relevance", "Manually"])
        #expect(SortDirection.allCases.map(\.rawValue) == ["Ascending", "Descending"])

        // Codable, inside SavedFilter.rulesData on disk.
        #expect(FilterField.allCases.map(\.rawValue)
                == ["Status", "Priority", "Tag", "List", "Due Before", "Due After",
                    "Has Due Date", "Title"])
        #expect(FilterComparison.allCases.map(\.rawValue)
                == ["is", "is not", "contains", "does not contain"])
        #expect(FilterLogic.allCases.map(\.rawValue) == ["AND", "OR"])

        // @AppStorage("tabBarVisible") and @SceneStorage("selectedTabToken");
        // the tab bar is rebuilt from these. Changing one resets a user's bar.
        #expect(AppTab.customizable.map(\.token)
                == ["board", "calendar", "matrix",
                    "smart:Today", "smart:Upcoming", "smart:Overdue",
                    "smart:All Tasks", "smart:Completed"])
        // Pinned, so absent from `customizable` — but persisted all the same:
        // `.tasks` is the default `selectedTabToken`, and both are offered in
        // "Open App To" as `tab:<token>`.
        #expect(AppTab.pinned.map(\.token) == ["tasks", "settings"])
    }

    // MARK: Display names reach the catalog

    /// One enum's display strings and the catalogs that must contain them.
    struct EnumUnderGuard {
        let name: String
        let displayNames: [String]
        /// Every catalog that must hold these keys. Types under `NowThis/Models/` are compiled
        /// into NowThisWidget too, and an extension resolves strings against **its own**
        /// `Bundle.main` — so a shared type needs its keys in both catalogs, separately.
        let catalogs: [String]
    }

    static let appOnly = ["NowThis/Localizable.xcstrings"]
    static let sharedWithWidget = ["NowThis/Localizable.xcstrings",
                                   "NowThisWidget/Localizable.xcstrings"]

    static var enumsUnderGuard: [EnumUnderGuard] {
        [
            // --- persisted: rawValue frozen above, displayName added ---
            EnumUnderGuard(name: "AppTab",
                           displayNames: (AppTab.pinned + AppTab.customizable).map(\.displayName),
                           catalogs: appOnly),
            EnumUnderGuard(name: "SmartList",
                           displayNames: SmartList.allCases.map(\.displayName),
                           catalogs: appOnly),
            EnumUnderGuard(name: "TaskSortOption",
                           displayNames: TaskSortOption.allCases.map(\.displayName),
                           catalogs: sharedWithWidget),
            EnumUnderGuard(name: "SortDirection",
                           displayNames: SortDirection.allCases.map(\.displayName),
                           catalogs: sharedWithWidget),
            EnumUnderGuard(name: "FilterField",
                           displayNames: FilterField.allCases.map(\.displayName),
                           catalogs: sharedWithWidget),
            EnumUnderGuard(name: "FilterComparison",
                           displayNames: FilterComparison.allCases.map(\.displayName),
                           catalogs: sharedWithWidget),
            EnumUnderGuard(name: "FilterLogic",
                           displayNames: FilterLogic.allCases.map(\.displayName),
                           catalogs: sharedWithWidget),
            // --- already correct; here so a regression is caught ---
            EnumUnderGuard(name: "TaskStatus",
                           displayNames: TaskStatus.allCases.map(\.displayName),
                           catalogs: sharedWithWidget),
        ]
    }

    @Test("Every enum display name is a real catalog key")
    func everyDisplayNameIsInTheCatalog() throws {
        var checked = 0
        var catalogCache: [String: Set<String>] = [:]

        for subject in Self.enumsUnderGuard {
            #expect(!subject.displayNames.isEmpty, "\(subject.name) produced no display names.")

            for catalogPath in subject.catalogs {
                if catalogCache[catalogPath] == nil {
                    guard let ref = LocalizationCatalogFixture.catalogs
                        .first(where: { $0.path == catalogPath }) else {
                        Issue.record("\(catalogPath) is not in the fixture's catalog list.")
                        continue
                    }
                    // *Renderings*, not keys. These enums use explicit namespaced keys
                    // (`sort.manually`) with the text in a language block, so comparing
                    // against the key set would never match.
                    //
                    // And renderings in the language the run is actually in, not English:
                    // `displayName` returns whatever `String(localized:)` resolves to, so
                    // under `-testLanguage de` — or on a simulator whose own Settings are
                    // German — every one of these is German. Pinned to English this guard
                    // failed 86 times in the first German run while the app was correct.
                    catalogCache[catalogPath] = try LocalizationCatalogFixture.renderings(
                        in: ref, language: LocalizationCatalogFixture.activeLanguage)
                }
                let keys = catalogCache[catalogPath] ?? []

                for name in subject.displayNames {
                    checked += 1
                    // Bound to a Bool first: `#expect(keys.contains(name), …)` renders the
                    // whole 429-key set into the failure output and buries the message.
                    let isInCatalog = keys.contains(name)
                    #expect(isInCatalog, """
                        \(subject.name) displays \u{201C}\(name)\u{201D}, and that string is not a key
                        in \(catalogPath).

                        The property is returning a bare English literal, so the compiler never
                        emitted it and it will ship English in all five languages — silently, with
                        every other guard green. Return String(localized:key, defaultValue:comment:)
                        instead, then re-run:
                          python3 Translations/tools/sync_catalogs.py --apply
                        """)
                }
            }
        }

        // Anti-vacuity: an empty `enumsUnderGuard` or an all-empty allCases would otherwise
        // sail through the loop above without a single comparison. The floor is the real
        // count, not a round number under it — a floor with slack in it stops noticing a
        // whole enum falling out of the table, which is the failure it exists to catch.
        #expect(checked >= 75, """
            Only \(checked) display-name/catalog pairs were compared. Expected at least 75:
            8 enums and 45 display names, of which the 30 shared with the widget are each
            checked against two catalogs (15 + 60).
            """)
    }

    /// The other half of the shared-file problem. Keys that exist in one catalog and not the
    /// other are how a widget ships English while the app is fully translated.
    @Test("Shared-model display names are in both catalogs")
    func sharedModelKeysAppearInBothCatalogs() throws {
        // Same reason as above: compared against runtime `displayName`s, so both sides must
        // be read in the language the run is in, or every row fails outside English.
        let language = LocalizationCatalogFixture.activeLanguage
        let app = try LocalizationCatalogFixture.renderings(
            in: LocalizationCatalogFixture.catalogs.first { $0.path == "NowThis/Localizable.xcstrings" }!,
            language: language)
        let widget = try LocalizationCatalogFixture.renderings(
            in: LocalizationCatalogFixture.catalogs.first { $0.path == "NowThisWidget/Localizable.xcstrings" }!,
            language: language)

        var compared = 0
        for subject in Self.enumsUnderGuard where subject.catalogs.count == 2 {
            for name in subject.displayNames {
                compared += 1
                let inBoth = app.contains(name) && widget.contains(name)
                #expect(inBoth, """
                    \u{201C}\(name)\u{201D} (\(subject.name)) is in \
                    \(app.contains(name) ? "the app catalog" : "no app catalog") and \
                    \(widget.contains(name) ? "the widget catalog" : "no widget catalog").

                    This type lives under NowThis/Models/, which NowThisWidget compiles too. An
                    extension resolves strings against its OWN Bundle.main, so the key must exist
                    in both catalogs — and plural rules do not propagate between them either.
                    """)
            }
        }
        #expect(compared >= 30, "Compared only \(compared) shared keys.")
    }
}
