import Foundation
import Testing

/// Counted strings must vary in the **catalog**, not in Swift.
///
/// The shape §2c replaced everywhere was `"\(n) task\(n == 1 ? "" : "s")"`, which extracts as
/// `%lld task%@` — a key no translator can act on, because the inflected part has been hidden
/// behind a placeholder. Replacing it with two keys and a Swift `if n == 1` fixed the *key* and
/// left the *rule* in Swift, where it is still English's rule:
///
/// > **French counts 0 as singular.** CLDR puts `i = 0,1` in category `one` for `fr`, so
/// > `n == 1 ? singular : plural` sends zero down the plural branch and renders
/// > *"Vous avez 0 tâches"* where French requires *"0 tâche"*. Nothing in a catalog can see
/// > that, because the catalog is not the thing choosing. Spanish, Italian and Portuguese also
/// > take a `many` category for large values that no `== 1` test can reach.
///
/// So the branch moves into the catalog and Swift passes only the number. The Swift
/// `defaultValue` still carries one English form — it has to, it is a literal — and the compiled
/// catalog overrides it. That divergence is deliberate and is the reason
/// `expectedEnglish` below is asserted against the catalog rather than against the source.
///
/// Two catalog shapes exist and both are used here:
/// - whole-string `variations.plural`, legal only with a single placeholder;
/// - `substitutions.<name>.variations.plural`, required the moment a second placeholder exists.
///
/// **The load-bearing test in this file is the runtime one.** A catalog can be structurally
/// perfect JSON and still not reach the device — that is exactly what happened to the whole
/// `%@`-splice family, which had valid entries the whole time.
@Suite("Localization / plural rules")
struct PluralRuleGuardTests {

    // MARK: - Registry

    /// One counted string that must resolve its plural from the catalog.
    struct PluralEntry {
        /// Catalog path, matching `LocalizationCatalogFixture.catalogs`.
        let catalog: String
        let key: String
        /// Substitution name, or `""` when the whole string varies.
        let slot: String
        /// The English `one` form, exactly as the catalog must carry it.
        let one: String
        /// The English `other` form, exactly as the catalog must carry it.
        let other: String
        /// Where the count comes from, for the failure message.
        let site: String
    }

    /// Every plural-varied key in the repository.
    ///
    /// `one`/`other` are asserted as **exact strings**, not merely "some forms exist". An entry
    /// that carries `variations.plural` whose two categories hold the same text is structurally
    /// a plural and semantically nothing, and that is the state a careless catalog edit produces.
    static let registry: [PluralEntry] = [
        // ---- NowThis, whole-string variations (one placeholder) ----
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "tasks.row.a11y.subtaskCount", slot: "",
                    one: "1 subtask", other: "%lld subtasks",
                    site: "TaskRowView — VoiceOver label fragment"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "calendar.month.cell.a11y.taskCount", slot: "",
                    one: ", 1 task", other: ", %lld tasks",
                    site: "CalendarMonthView — day cell VoiceOver fragment"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "kanban.list.taskCount", slot: "",
                    one: "1 task", other: "%lld tasks",
                    site: "KanbanListSwipeView — visible count under the list name"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "settings.sync.window.footer", slot: "",
                    one: "Only completed tasks from the last month will be synced. Active tasks are always synced.",
                    other: "Only completed tasks from the last %lld months will be synced. Active tasks are always synced.",
                    site: "SettingsView — sync window footer"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "notification.due.inMinutes", slot: "",
                    one: "Due in 1 minute", other: "Due in %lld minutes",
                    site: "ReminderScheduler — custom lead time under an hour"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "notification.due.inHours", slot: "",
                    one: "Due in 1 hour", other: "Due in %lld hours",
                    site: "ReminderScheduler — custom lead time of an hour or more"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "sidebar.journals.a11y.entryCount", slot: "",
                    one: "Journals, 1 entry", other: "Journals, %lld entries",
                    site: "SidebarView — Journals row VoiceOver label"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "intent.dialog.taskCount.total", slot: "",
                    one: "You have 1 active task in total.",
                    other: "You have %lld active tasks in total.",
                    site: "TaskCountIntent — spoken Siri reply, unscoped"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "recurrence.custom.interval.daily", slot: "",
                    one: "Every day", other: "Every %lld days",
                    site: "TaskDetailView — custom recurrence stepper"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "recurrence.custom.interval.weekly", slot: "",
                    one: "Every week", other: "Every %lld weeks",
                    site: "TaskDetailView — custom recurrence stepper"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "recurrence.custom.interval.monthly", slot: "",
                    one: "Every month", other: "Every %lld months",
                    site: "TaskDetailView — custom recurrence stepper"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "recurrence.custom.interval.yearly", slot: "",
                    one: "Every year", other: "Every %lld years",
                    site: "TaskDetailView — custom recurrence stepper"),

        // ---- NowThis, substitutions (two or more placeholders) ----
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "list.a11y.taskCount", slot: "taskCount",
                    one: "%arg task", other: "%arg tasks",
                    site: "SidebarView ×3, EisenhowerMatrixView, KanbanListSwipeView"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "kanban.column.a11y", slot: "taskCount",
                    one: "%arg task", other: "%arg tasks",
                    site: "KanbanColumnView — column VoiceOver label"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "calendar.week.a11y.taskCount", slot: "taskCount",
                    one: "%arg task", other: "%arg tasks",
                    site: "CalendarWeekView — day column VoiceOver label"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "subtasks.a11y.progress", slot: "total",
                    one: "%arg subtask", other: "%arg subtasks",
                    site: "SubtaskProgressRing — progress VoiceOver label"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "intent.dialog.taskCount.inList", slot: "taskCount",
                    one: "%arg active task", other: "%arg active tasks",
                    site: "TaskCountIntent — spoken Siri reply, scoped to a list"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "intent.dialog.dueToday", slot: "taskCount",
                    one: "%arg task", other: "%arg tasks",
                    site: "TasksDueTodayIntent — spoken Siri reply"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "intent.dialog.search", slot: "taskCount",
                    one: "%arg task", other: "%arg tasks",
                    site: "SearchTasksIntent — spoken Siri reply"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "intent.dialog.showTasks", slot: "taskCount",
                    one: "%arg active task", other: "%arg active tasks",
                    site: "ShowTasksIntent — spoken Siri reply"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "intent.dialog.search.truncated", slot: "remaining",
                    one: "%arg more", other: "%arg more",
                    site: "SearchTasksIntent — the tail count, which can be exactly 1"),
        PluralEntry(catalog: "NowThis/Localizable.xcstrings",
                    key: "intent.dialog.showTasks.truncated", slot: "remaining",
                    one: "%arg more", other: "%arg more",
                    site: "ShowTasksIntent — the tail count, which can be exactly 1"),

        // ---- Watch app ----
        PluralEntry(catalog: "NowThisWatch/Localizable.xcstrings",
                    key: "watch.list.a11y.taskCount", slot: "taskCount",
                    one: "%arg task", other: "%arg tasks",
                    site: "WatchListsView — smart-list row and list row"),

        // ---- Watch complication ----
        PluralEntry(catalog: "NowThisWatchWidget/Localizable.xcstrings",
                    key: "watchwidget.remaining.text", slot: "",
                    one: "1 task today", other: "%lld tasks today",
                    site: "NowThisWatchWidgetBundle — visible complication text"),
        PluralEntry(catalog: "NowThisWatchWidget/Localizable.xcstrings",
                    key: "watchwidget.remaining.a11y", slot: "",
                    one: "1 task remaining today", other: "%lld tasks remaining today",
                    site: "NowThisWatchWidgetBundle — complication VoiceOver label"),
    ]

    /// Count-bearing catalog keys that are deliberately **not** plural-varied. Each needs a
    /// reason, and each reason has to be a fact about the value, not a hope about it.
    static let notPlural: [String: String] = [
        "sync.progress.count":
            "Completed/total progress ratio with no noun. The separate progress phase names tasks, "
            + "so neither number selects an inflected word.",
        "caldav.error.serverError":
            "%lld is an HTTP status code, not a quantity. 404 does not inflect anything.",
        "subtask.a11y.level":
            "Nesting depth, read as an ordinal position. \"Subtask level 1\" is not a count of "
            + "levels and does not take a plural in any of the five target languages.",
        "notification.due.in1Day":
            "One of the six *named* lead times the picker offers, kept as its own key so a "
            + "translator seeing \"Due in 1 day\" whole can say \"morgen\" / \"demain\". Merging "
            + "it into a counted template would take that away. See ReminderScheduler.bodyText.",
        "Geofence radius, %lld meters":
            "The slider is `in: 50...1000, step: 25` (LocationPickerView.swift:116), so the value "
            + "is never 1 and the singular form is unreachable. Measured, not assumed.",
        "Keychain error: %d":
            "%d is an OSStatus code, not a quantity.",
        "%lld percent":
            "\"1 percent\" and \"2 percent\" are the same word in English and in all five target "
            + "languages — percent does not inflect with the numeral.",
        "%lld pending":
            "\"pending\" is an adjective here, not a counted noun. It does not inflect.",
        "tasks.photo.a11y.position":
            "The first value is an ordinal photo position and the second is a total; the label has "
            + "no inflected count noun, so neither number drives a plural form.",

        // L13's five degenerate keys used to sit here with "resolves by deletion in L13" as their
        // reason. L13 has landed and deleted them: `Text(count, format: .number)`,
        // `.percent`, and `Measurement` create no catalog key at all and are *more* correct,
        // because they apply the locale's digits, grouping and unit spacing where `"\(count)"`
        // does not. `notPluralEntriesStillApply` went red the moment they disappeared, which is
        // exactly what chaining the two was for.
    ]

    // MARK: - Runtime probes

    /// Resolves one registered key through the **compiled** catalog at a given count.
    ///
    /// Hand-written per key rather than generated, because the argument *order* is part of what
    /// is being tested: a substitution declares `argNum`, and getting it wrong swaps the count
    /// with the list name in a way no structural check notices.
    ///
    /// Only `NowThis/Localizable.xcstrings` can appear here. The widget, watch and complication
    /// catalogs are compiled into *other* bundles; `Bundle.main` in this test host is the app, so
    /// those keys resolve to their `defaultValue` and a probe over them would pass no matter what
    /// the catalog said. They are covered structurally and that difference is counted separately
    /// in the failure message rather than hidden.
    static let runtimeProbes: [String: @Sendable (Int) -> String] = [
        "tasks.row.a11y.subtaskCount": {
            String(localized: "tasks.row.a11y.subtaskCount", defaultValue: "\($0) subtasks") },
        "calendar.month.cell.a11y.taskCount": {
            String(localized: "calendar.month.cell.a11y.taskCount", defaultValue: ", \($0) tasks") },
        "kanban.list.taskCount": {
            String(localized: "kanban.list.taskCount", defaultValue: "\($0) tasks") },
        "settings.sync.window.footer": {
            String(localized: "settings.sync.window.footer",
                   defaultValue: "Only completed tasks from the last \($0) months will be synced. Active tasks are always synced.") },
        "notification.due.inMinutes": {
            String(localized: "notification.due.inMinutes", defaultValue: "Due in \($0) minutes") },
        "notification.due.inHours": {
            String(localized: "notification.due.inHours", defaultValue: "Due in \($0) hours") },
        "sidebar.journals.a11y.entryCount": {
            String(localized: "sidebar.journals.a11y.entryCount",
                   defaultValue: "Journals, \($0) entries") },
        "intent.dialog.taskCount.total": {
            String(localized: "intent.dialog.taskCount.total",
                   defaultValue: "You have \($0) active tasks in total.") },
        "recurrence.custom.interval.daily": {
            String(localized: "recurrence.custom.interval.daily", defaultValue: "Every \($0) days") },
        "recurrence.custom.interval.weekly": {
            String(localized: "recurrence.custom.interval.weekly", defaultValue: "Every \($0) weeks") },
        "recurrence.custom.interval.monthly": {
            String(localized: "recurrence.custom.interval.monthly", defaultValue: "Every \($0) months") },
        "recurrence.custom.interval.yearly": {
            String(localized: "recurrence.custom.interval.yearly", defaultValue: "Every \($0) years") },
        "list.a11y.taskCount": {
            String(localized: "list.a11y.taskCount", defaultValue: "\("Inbox"), \($0) tasks") },
        "kanban.column.a11y": {
            String(localized: "kanban.column.a11y", defaultValue: "\("To Do") column, \($0) tasks") },
        "calendar.week.a11y.taskCount": {
            String(localized: "calendar.week.a11y.taskCount", defaultValue: "\("Monday"), \($0) tasks") },
        "subtasks.a11y.progress": {
            String(localized: "subtasks.a11y.progress",
                   defaultValue: "\(1) of \($0) subtasks completed") },
        "intent.dialog.taskCount.inList": {
            String(localized: "intent.dialog.taskCount.inList",
                   defaultValue: "You have \($0) active tasks in \("Inbox").") },
        "intent.dialog.dueToday": {
            String(localized: "intent.dialog.dueToday",
                   defaultValue: "You have \($0) tasks due today: \("Milk").") },
        "intent.dialog.search": {
            String(localized: "intent.dialog.search",
                   defaultValue: "Found \($0) tasks matching \"\("milk")\": \("Milk").") },
        "intent.dialog.showTasks": {
            String(localized: "intent.dialog.showTasks",
                   defaultValue: "You have \($0) active tasks: \("Milk").") },
        // The tail count is the plural driver here, so the probe varies argument 4 and pins the
        // leading count at a value the branch can actually produce.
        "intent.dialog.search.truncated": {
            String(localized: "intent.dialog.search.truncated",
                   defaultValue: "Found \(6) tasks matching \"\("milk")\": \("Milk"), and \($0) more.") },
        "intent.dialog.showTasks.truncated": {
            String(localized: "intent.dialog.showTasks.truncated",
                   defaultValue: "You have \(11) active tasks. Here are the first \(10): \("Milk"), and \($0) more.") },
    ]

    // MARK: - Tests

    @Test("Every registered plural key carries distinct English forms in its catalog")
    func registeredKeysCarryEnglishPluralForms() throws {
        var examined = 0
        var findings: [String] = []
        var byCatalog: [String: [String: [String: Any]]] = [:]

        for entry in Self.registry {
            guard let ref = LocalizationCatalogFixture.catalogs.first(where: { $0.path == entry.catalog })
            else {
                findings.append("  \(entry.key): catalog \(entry.catalog) is not in the fixture list")
                continue
            }
            let strings = try byCatalog[entry.catalog] ?? {
                let loaded = try LocalizationCatalogFixture.load(ref)
                byCatalog[entry.catalog] = loaded
                return loaded
            }()

            examined += 1
            guard let raw = strings[entry.key] else {
                findings.append("  \(entry.key) — absent from \(ref.path)  [\(entry.site)]")
                continue
            }
            let slots = LocalizationCatalogFixture.pluralSlots(raw)
            guard let slot = slots.first(where: { $0.name == entry.slot }) else {
                findings.append("""
                      \(entry.key) — no plural slot named \(entry.slot.isEmpty ? "<whole string>" : entry.slot) \
                    in \(ref.path); found \(slots.isEmpty ? "none" : slots.map(\.name).description)  [\(entry.site)]
                    """)
                continue
            }
            if slot.forms["one"] != entry.one {
                findings.append("  \(entry.key) [one] — catalog has \(slot.forms["one"] ?? "nothing"), "
                                + "expected \(entry.one)")
            }
            if slot.forms["other"] != entry.other {
                findings.append("  \(entry.key) [other] — catalog has \(slot.forms["other"] ?? "nothing"), "
                                + "expected \(entry.other)")
            }
        }

        // The count measured on 2026-07-26, not a margin below it: a floor set safely under the
        // real number is the range in which a registry that has quietly emptied still passes.
        #expect(examined >= 25, """
            Only \(examined) plural entries were examined; the registry held 25 when this was
            written. Either the registry shrank or the catalog lookup stopped resolving.
            """)
        #expect(findings.isEmpty, """
            \(findings.count) registered plural key(s) do not carry the expected English forms:
            \(findings.joined(separator: "\n"))

            Author the forms in the catalog, not in Swift. The `defaultValue` in source can only
            carry one form; the catalog carries the rule.
            """)
    }

    @Test("Plural forms resolve through the compiled catalog at runtime, not just in JSON")
    func pluralFormsResolveAtRuntime() throws {
        var examined = 0
        var comparedForDistinctness = 0
        var findings: [String] = []

        for entry in Self.registry where entry.catalog == "NowThis/Localizable.xcstrings" {
            guard let probe = Self.runtimeProbes[entry.key] else {
                findings.append("  \(entry.key) — registered but has no runtime probe")
                continue
            }
            examined += 1

            // Applies to every key: a substitution that did not resolve leaves its own syntax
            // in the output. This is the check that catches a wrong `argNum` or a name the
            // top-level value never references.
            for count in [1, 2] {
                let out = probe(count)
                for residue in ["%#@", "%arg", "%lld", "%@"] where out.contains(residue) {
                    findings.append("  \(entry.key) at \(count) — left \(residue) unresolved: \(out)")
                }
            }

            // Applies only where English itself distinguishes. `intent.dialog.*.truncated`
            // varies on the *tail* count, and English says "1 more" and "2 more" the same way —
            // French does not ("1 autre" / "2 autres"), which is why the slot exists at all.
            guard entry.one != entry.other else { continue }
            comparedForDistinctness += 1
            if Self.withoutDigits(probe(1)) == Self.withoutDigits(probe(2)) {
                findings.append("""
                      \(entry.key) — resolves identically at 1 and 2:
                          \(probe(1))
                          \(probe(2))
                    """)
            }
        }

        // Probes that name a key nobody registered are dead weight and hide staleness.
        let orphanProbes = Set(Self.runtimeProbes.keys)
            .subtracting(Self.registry.map(\.key))
        #expect(orphanProbes.isEmpty,
                "runtime probe(s) for unregistered keys: \(orphanProbes.sorted())")

        let appKeys = Self.registry.filter { $0.catalog == "NowThis/Localizable.xcstrings" }.count
        #expect(examined == appKeys, """
            \(examined) of \(appKeys) app-catalog plural keys were probed at runtime. Every one
            needs a probe — the remaining \(Self.registry.count - appKeys) keys live in the
            widget, watch and complication bundles and cannot be resolved from this test host,
            which is why they are covered structurally instead.
            """)
        #expect(examined >= 22, "only \(examined) runtime probes ran; 22 existed when written")
        #expect(comparedForDistinctness >= 20, """
            only \(comparedForDistinctness) key(s) had English forms different enough to compare;
            20 did when this was written. If that number collapsed, the registry's `one` and
            `other` have been made identical and this test is checking almost nothing.
            """)
        #expect(findings.isEmpty, """
            \(findings.count) plural key(s) do not vary at runtime:
            \(findings.joined(separator: "\n"))

            The catalog JSON can be perfectly shaped and still not reach the device. Check that
            the entry is `variations.plural` (single placeholder) or
            `substitutions.<name>.variations.plural` with the right `argNum` (two or more), and
            that the app was rebuilt after the catalog changed.
            """)
    }

    @Test("No count-bearing catalog key escapes the registry")
    func everyCountBearingKeyIsAccountedFor() throws {
        var examined = 0
        var findings: [String] = []
        let registered = Set(Self.registry.map(\.key))

        for ref in LocalizationCatalogFixture.catalogs {
            for (key, entry) in try LocalizationCatalogFixture.load(ref) {
                let english = LocalizationCatalogFixture.englishRendering(ofKey: key, entry: entry)
                guard Self.carriesAnIntegerSpecifier(english) else { continue }
                examined += 1
                if registered.contains(key) || Self.notPlural[key] != nil { continue }
                if !LocalizationCatalogFixture.pluralSlots(entry).isEmpty { continue }
                findings.append("  \(ref.path)  \(key)\n      \(english)")
            }
        }

        #expect(examined >= 20, """
            Only \(examined) count-bearing keys were examined across \
            \(LocalizationCatalogFixture.catalogs.count) catalogs; there were 24 when this was
            written. A scanner that finds nothing to check reports success.
            """)
        #expect(findings.isEmpty, """
            \(findings.count) catalog key(s) carry an integer specifier and are neither
            plural-varied, registered, nor listed in `notPlural` with a reason:
            \(findings.joined(separator: "\n"))

            Either pluralise it or add it to `notPlural` with a fact about why the singular form
            is unreachable or meaningless.
            """)
    }

    /// Added because a falsification came back **green when it was predicted red**.
    ///
    /// The mutation disabled `englishRendering`'s plural fallback, which is the regression that
    /// made twelve keys invisible to the count-bearing scan. It was expected to trip that scan's
    /// anti-vacuity floor — and it did not, because the floor sits at 20 and the reduced count is
    /// still 21. A floor catches a *collapse*; it does not catch a *class* going missing.
    ///
    /// So the invariant is asserted directly instead: a plural-varied entry must render as its
    /// words, never as its key, and a substituted entry must render with the substitution spliced
    /// in rather than leaving `%#@name@` in the output for a glossary or length check to read.
    @Test("Plural entries render as their English, not as their key")
    func pluralEntriesRenderAsEnglish() throws {
        var examined = 0
        var findings: [String] = []

        for ref in LocalizationCatalogFixture.catalogs {
            for (key, entry) in try LocalizationCatalogFixture.load(ref) {
                let slots = LocalizationCatalogFixture.pluralSlots(entry)
                guard !slots.isEmpty else { continue }
                examined += 1
                let rendering = LocalizationCatalogFixture.englishRendering(ofKey: key, entry: entry)
                if rendering == key {
                    findings.append("  \(ref.path)  \(key) — renders as its own key, so every guard "
                                    + "that reads English sees no words here")
                }
                if rendering.contains("%#@") {
                    findings.append("  \(ref.path)  \(key) — substitution left unspliced: \(rendering)")
                }
                if rendering.contains("%arg") {
                    findings.append("  \(ref.path)  \(key) — `%arg` reached the rendering: \(rendering)")
                }
            }
        }

        #expect(examined >= 25, """
            Only \(examined) plural-varied entries were found across \
            \(LocalizationCatalogFixture.catalogs.count) catalogs; 25 existed when this was written.
            """)
        #expect(findings.isEmpty, """
            \(findings.count) plural entr(ies) do not render as English:
            \(findings.joined(separator: "\n"))

            `LocalizationCatalogFixture.englishRendering` must resolve both plural shapes. A guard
            reading a catalog field is reading one encoding of the answer, and a new encoding makes
            it fail open.
            """)
    }

    @Test("`notPlural` reasons still describe keys that exist")
    func notPluralEntriesStillApply() throws {
        var present: Set<String> = []
        for ref in LocalizationCatalogFixture.catalogs {
            present.formUnion(try LocalizationCatalogFixture.load(ref).keys)
        }
        let stale = Self.notPlural.keys.filter { !present.contains($0) }
        #expect(stale.isEmpty, """
            \(stale.count) `notPlural` entr(ies) name keys no catalog has any more:
            \(stale.sorted().map { "  \($0)" }.joined(separator: "\n"))

            A stale exemption is an exemption nobody is checking. Delete it, or fix the key name.
            """)
        #expect(!Self.notPlural.isEmpty, "the exemption list emptied out — that is not a pass")
    }

    @Test("No hand-rolled plural survives in Swift source or in a catalog key")
    func noHandRolledPlurals() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var examinedFiles = 0
        var findings: [String] = []

        for file in try LocalizationCatalogFixture.swiftSourceFiles() {
            examinedFiles += 1
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                guard Self.splicesAnEnglishPluralSuffix(line) else { continue }
                findings.append("  \(file):\(index + 1)  \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        var examinedKeys = 0
        for ref in LocalizationCatalogFixture.catalogs {
            for (key, entry) in try LocalizationCatalogFixture.load(ref) {
                examinedKeys += 1
                let english = LocalizationCatalogFixture.englishRendering(ofKey: key, entry: entry)
                if Self.hasSuffixSplicedSpecifier(english) {
                    findings.append("  \(ref.path)  \(key)\n      \(english)")
                }
            }
        }

        #expect(examinedFiles >= 129, "only \(examinedFiles) Swift files scanned; 129 existed when written")
        #expect(examinedKeys >= 600, "only \(examinedKeys) catalog keys scanned")
        #expect(findings.isEmpty, """
            \(findings.count) hand-rolled plural(s):
            \(findings.joined(separator: "\n"))

            `"\\(n) task\\(n == 1 ? "" : "s")"` extracts as `%lld task%@`, which hides the
            inflected word behind a placeholder. Use one key with catalog plural variations.
            """)
    }

    // MARK: - Helpers, and their self-checks

    /// Every ASCII digit removed, so `"1 task"` and `"2 tasks"` differ only where the *words* do.
    static func withoutDigits(_ text: String) -> String {
        String(text.filter { !$0.isASCII || !$0.isNumber })
    }

    /// True when a format value carries an integer specifier — `%lld`, `%d`, or positional.
    static func carriesAnIntegerSpecifier(_ value: String) -> Bool {
        let scalars = Array(value)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "%" else { index += 1; continue }
            var cursor = index + 1
            if cursor < scalars.count, scalars[cursor] == "%" { index = cursor + 1; continue }
            while cursor < scalars.count, scalars[cursor].isNumber || scalars[cursor] == "$" {
                cursor += 1
            }
            var conversion = ""
            while cursor < scalars.count, "lhqzjt".contains(scalars[cursor]) {
                conversion.append(scalars[cursor]); cursor += 1
            }
            if cursor < scalars.count, "diu".contains(scalars[cursor]) { return true }
            index = cursor + 1
        }
        return false
    }

    /// True when a `%@` sits directly against the preceding word — the signature of an English
    /// plural suffix spliced into a placeholder (`task%@`, `month%@`, `subtask%@`).
    static func hasSuffixSplicedSpecifier(_ value: String) -> Bool {
        let scalars = Array(value)
        for index in scalars.indices where scalars[index] == "@" {
            guard index >= 1, scalars[index - 1] == "%", index >= 2 else { continue }
            if scalars[index - 2].isLetter { return true }
        }
        return false
    }

    /// True when a Swift line splices an English plural suffix into an interpolation.
    static func splicesAnEnglishPluralSuffix(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact.contains(#"?"":"s""#) || compact.contains(#"?"s":"""#)
    }

    @Test("The helpers detect what they claim to, and not more")
    func helperSelfChecks() {
        #expect(Self.withoutDigits("1 task") == " task")
        #expect(Self.withoutDigits("%lld tasks") == "%lld tasks")
        #expect(Self.withoutDigits("1 task") != Self.withoutDigits("2 tasks"))
        #expect(Self.withoutDigits("Every 1 day") != Self.withoutDigits("Every 2 days"))
        // The failure this comparison exists to catch: forms that differ only by the number.
        #expect(Self.withoutDigits("1 tasks") == Self.withoutDigits("2 tasks"))

        #expect(Self.carriesAnIntegerSpecifier("%lld tasks"))
        #expect(Self.carriesAnIntegerSpecifier("You have %1$lld in %2$@."))
        #expect(Self.carriesAnIntegerSpecifier("Keychain error: %d"))
        #expect(!Self.carriesAnIntegerSpecifier("%@, due %@"))
        #expect(!Self.carriesAnIntegerSpecifier("100%% complete"))
        #expect(!Self.carriesAnIntegerSpecifier("Sort by %@, %@"))

        #expect(Self.hasSuffixSplicedSpecifier("%lld task%@"))
        #expect(Self.hasSuffixSplicedSpecifier("%lld of %lld subtask%@ completed"))
        #expect(!Self.hasSuffixSplicedSpecifier("%@, %lld tasks"))
        #expect(!Self.hasSuffixSplicedSpecifier("%@ – %@"))
        // A `%@` after a space is an ordinary placeholder, not a spliced suffix.
        #expect(!Self.hasSuffixSplicedSpecifier("Every %lld %@"))

        #expect(Self.splicesAnEnglishPluralSuffix(#"Text("\(n) task\(n == 1 ? "" : "s")")"#))
        #expect(Self.splicesAnEnglishPluralSuffix(#"let s = count == 1 ? "" : "s""#))
        #expect(!Self.splicesAnEnglishPluralSuffix(#"let x = flag ? "Ascending" : "Descending""#))
        #expect(!Self.splicesAnEnglishPluralSuffix(#"return count == 1 ? "day" : "days""#))
    }
}
