import Foundation
import Testing

/// Phase 0's exit criterion, made machine-checkable.
///
/// "One word, frozen" is prose, and prose decays the first time someone adds a screen. These
/// tests are what makes the glossary in `TRANSLATION.md` survive contact with the next feature.
///
/// Two decisions are pinned here:
///
/// - A CalDAV collection is a **List**. Never a "Task List", never a "calendar".
///   "Calendar" is reserved for the *entirely different* EventKit concept.
/// - The completed state is **Completed**. "Done" survives only as a toolbar dismiss verb,
///   which is a different string with a different comment — expressible only because the
///   explicit-key decision is locked.
///
/// Each check ships with the allowlist it needs, in this same commit. A guard that fails sixty
/// times on day one gets disabled; a guard whose allowlist has an asserted exact count cannot
/// be silently widened.
@Suite("Localization / glossary")
struct LocalizationGlossaryGuardTests {

    // MARK: Allowlists

    /// `"Done"` as a **toolbar dismiss verb** — not the completed state. Counts are exact:
    /// adding a fifth site anywhere goes red, which is the point.
    static let doneAsDismissVerb: [String: Int] = [
        "NowThis/Views/Tasks/TaskDetailView.swift": 3,
        "NowThis/Views/Journal/JournalEditorView.swift": 1,
        "NowThis/Views/Tasks/TaskListView.swift": 1,
        // Added deliberately: TrashedListsNotice's toolbar button dismisses a purely
        // informational sheet — nothing is completed or confirmed by it — which is exactly the
        // dismiss-verb sense this allowlist exists to permit.
        "NowThis/Views/Root/TrashedListsNotice.swift": 1,
        // Closes the optional support sheet without completing a task, purchasing,
        // or changing the selected icon. Uses the existing localized dismiss key.
        "NowThis/Views/Settings/AppIconPickerView.swift": 1,
        // Added deliberately: the same dismiss verb, moved rather than multiplied. The
        // hidden-destination sheet used to wrap these three screens in a second navigation
        // container purely to have a bar to hang one Done on — the nesting that aborts the app in
        // `-[UINavigationBar layoutSubviews]`. Each screen now carries its own, gated on
        // `isPresented` so the tab that hosts the same view shows none. Nothing is completed or
        // confirmed by any of them. See `NavigationContainerGuardTests`.
        "NowThis/Views/Kanban/KanbanBoardView.swift": 1,
        "NowThis/Views/Calendar/CalendarContainerView.swift": 1,
        "NowThis/Views/Matrix/EisenhowerMatrixView.swift": 1,
        // TaskPhotosSection's viewer toolbar closes the viewer and completes no task or action.
        "NowThis/Views/Tasks/TaskPhotosSection.swift": 1,
    ]

    /// `"Complete"` as the **toggle action verb** on the swipe action.
    /// Whether this stays "Complete" or becomes "Toggle" is issue B2 and is still open; the
    /// guard pins today's answer so the change is deliberate rather than incidental.
    static let completeAsActionVerb: [String: Int] = [
        "NowThis/Views/Tasks/TaskRowView.swift": 1,
    ]

    /// Files whose user-facing copy describes a **CalDAV collection**, where "calendar" is the
    /// wrong noun. `SettingsView.swift` is deliberately absent: its "Calendar" strings are
    /// EventKit and are correct.
    static let caldavCopyFiles = [
        "NowThis/Sync/SyncFailure.swift",
    ]

    // MARK: Guards

    @Test("A CalDAV collection is never called a Task List")
    func noRetiredCollectionNoun() throws {
        let literals = try LocalizationCatalogFixture.allSourceLiterals()
        let offenders = literals.filter {
            $0.text.range(of: "task list", options: .caseInsensitive) != nil
        }
        #expect(offenders.isEmpty, """
            The glossary retires "Task List" as a UI noun — a CalDAV collection is a **List**.
            \(offenders.count) literal(s) still say it:
            \(offenders.map { "  \($0.location)  \u{201C}\($0.text)\u{201D}" }.joined(separator: "\n"))
            Rename them before the string freeze. Translating three nouns for one concept into
            five languages produces fifteen inconsistencies that no length or completeness
            check can see.
            """)
    }

    @Test("A CalDAV collection is never called a calendar")
    func caldavCollectionsAreNotCalledCalendars() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var offenders: [SwiftStringLiteral] = []

        for file in Self.caldavCopyFiles {
            let url = root.appendingPathComponent(file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                Issue.record("""
                    Allowlisted CalDAV-copy file is missing or unreadable: \(file)
                    A missing file must not read as "no violations".
                    """)
                continue
            }
            offenders += SwiftSourceScanner.stringLiterals(in: source, file: file).filter {
                $0.text.range(of: "calendar", options: .caseInsensitive) != nil
            }
        }

        #expect(offenders.isEmpty, """
            "Calendar" is reserved for the EventKit concept. These sync-error strings describe a
            CalDAV collection and must say "list":
            \(offenders.map { "  \($0.location)  \u{201C}\($0.text)\u{201D}" }.joined(separator: "\n"))
            """)
    }

    @Test("The completed state is one word, and Done means only dismiss")
    func completedStateIsOneWord() throws {
        let literals = try LocalizationCatalogFixture.allSourceLiterals()

        // "To Do" is the retired half of TaskStatus's two competing display properties.
        let toDo = literals.filter { $0.text == "To Do" }
        #expect(toDo.isEmpty, """
            "To Do" is retired — TaskStatus.needsAction displays as "Needs Action".
            \(toDo.map { "  \($0.location)" }.joined(separator: "\n"))
            TaskStatus carried two competing display properties on adjacent screens
            (TaskStatus.displayName and TaskDetailView's displayLabel). Only displayName survives.
            """)

        try assertExactUse(of: "Done", allowlist: Self.doneAsDismissVerb, in: literals, meaning: """
            "Done" is the completed state's retired synonym. It survives ONLY as a toolbar
            dismiss verb, which is a separate catalog key with its own comment.
            """)

        try assertExactUse(of: "Complete", allowlist: Self.completeAsActionVerb, in: literals, meaning: """
            "Complete" as a bare literal is the completed state's retired synonym. It survives
            ONLY as the swipe-action verb.
            """)
    }

    /// Asserts a literal appears **exactly** where the allowlist says and nowhere else, and
    /// that every allowlist entry is still real. An allowlist that quietly refers to a site
    /// that no longer exists is how these guards rot into decoration.
    private func assertExactUse(of literal: String,
                                allowlist: [String: Int],
                                in literals: [SwiftStringLiteral],
                                meaning: String) throws {
        var byFile: [String: [SwiftStringLiteral]] = [:]
        for found in literals where found.text == literal {
            byFile[found.file, default: []].append(found)
        }

        for (file, sites) in byFile.sorted(by: { $0.key < $1.key }) {
            guard let expected = allowlist[file] else {
                Issue.record("""
                    \(meaning)
                    \(sites.count) unallowlisted use(s) of "\(literal)" in \(file):
                    \(sites.map { "  \($0.location)" }.joined(separator: "\n"))
                    """)
                continue
            }
            #expect(sites.count == expected, """
                \(file) has \(sites.count) use(s) of "\(literal)"; the allowlist records \(expected).
                \(sites.map { "  \($0.location)" }.joined(separator: "\n"))
                Adding a line to an allowlist is how someone silently reintroduces a retired
                synonym — update it deliberately, and say why in the commit message.
                """)
        }

        for (file, expected) in allowlist.sorted(by: { $0.key < $1.key }) where byFile[file] == nil {
            Issue.record("""
                Allowlist rot: \(file) is recorded as holding \(expected) use(s) of "\(literal)",
                and holds none. Remove the entry — a stale allowlist is a guard that has stopped
                guarding something.
                """)
        }
    }

    // MARK: Anti-vacuity

    /// "Compared 0 items" and "compared 800 items" must not both be green.
    ///
    /// Per-root floors, not an aggregate floor: NowThis's roots differ by two orders of
    /// magnitude (116 / 1 / 9 / 2 files), and an aggregate floor cannot detect NowThisWidget
    /// vanishing from the walk entirely.
    @Test("The glossary scan actually examined the source tree")
    func scanIsNotVacuous() throws {
        let counts = try LocalizationCatalogFixture.swiftSourceFileCountsByRoot()
        let floors = ["NowThis": 100, "NowThisWidget": 1, "NowThisWatch": 8, "NowThisWatchWidget": 2]

        for (root, floor) in floors.sorted(by: { $0.key < $1.key }) {
            let seen = counts[root] ?? 0
            #expect(seen >= floor, """
                Walked \(seen) Swift file(s) under \(root)/ — expected at least \(floor).
                Either the source root moved, or the walk silently stopped. A scanner over
                zero files reports success, which is the failure this suite exists to prevent.
                """)
        }

        let literals = try LocalizationCatalogFixture.allSourceLiterals()
        #expect(literals.count > 1500, """
            Extracted only \(literals.count) string literals from the source tree. The scanner
            is not seeing the code.
            """)
    }

    // MARK: Scanner self-checks

    /// The scanner is fed known-bad and known-tricky input directly. Everything else in this
    /// suite is only as trustworthy as this test.
    ///
    /// Note these fixtures live in `NowThisTests`, which `project.yml` opts **out** of string
    /// extraction — otherwise the literals below would be extracted into a real catalog and
    /// the glossary guard would report on its own test data.
    @Test("Scanner self-checks")
    func scannerSelfChecks() {
        func literals(_ source: String) -> [String] {
            SwiftSourceScanner.stringLiterals(in: source, file: "self-check").map(\.text)
        }

        #expect(literals(#"Text("Hello")"#) == ["Hello"])

        // Comments are not literals. A line-based regex reports the doc comment here.
        #expect(literals("""
            /// A "Task List" in a doc comment is not a literal.
            let x = "real"
            """) == ["real"])

        // Nested block comments — Swift allows them, and an unbalanced walk would swallow code.
        #expect(literals("""
            /* outer /* inner */ still comment "not a literal" */
            let x = "real"
            """) == ["real"])

        // A `//` inside a literal does not start a comment.
        #expect(literals(#"let u = "https://asc.is/support/""#) == ["https://asc.is/support/"])

        // Interpolation collapses; the literal does not terminate at the inner quote.
        #expect(literals(#"Text("Every \(n) days")"#) == [#"Every \(…) days"#])
        #expect(literals(##"Text("\(a ?? "fallback") tail")"##) == [#"\(…) tail"#])

        // Raw strings: the regex escapes inside must not terminate the literal early.
        #expect(literals(##"let p = #"(?:^|\s)!(high|low)\b"#"##) == [#"(?:^|\s)!(high|low)\b"#])

        // Multiline literals. The scanner captures the raw span between the delimiters — it
        // does NOT reproduce Swift's leading-newline drop or indentation stripping, because
        // the guards search for words and do not care about layout. Pinned so the behaviour
        // is a decision rather than a surprise.
        #expect(literals("""
            let body = \"\"\"
            line "one"
            line two
            \"\"\"
            """) == ["\nline \"one\"\nline two\n"])

        // Escaped quote does not close the literal.
        #expect(literals(#"let q = "say \"hi\"""#) == [#"say \"hi\""#])

        // `#if` is not a raw-string opener.
        #expect(literals("""
            #if DEBUG
            let x = "debug"
            #endif
            """) == ["debug"])

        // Known-bad input the glossary guard must catch.
        let bad = SwiftSourceScanner.stringLiterals(in: #"Text("No Task Lists")"#, file: "bad")
        #expect(bad.contains { $0.text.range(of: "task list", options: .caseInsensitive) != nil })

        let badState = SwiftSourceScanner.stringLiterals(in: #"return "To Do""#, file: "bad")
        #expect(badState.contains { $0.text == "To Do" })

        // Line numbers are 1-based and track the literal's *start*.
        let multi = SwiftSourceScanner.stringLiterals(in: "let a = 1\nlet b = \"x\"\n", file: "f")
        #expect(multi.map(\.line) == [2])
    }
}
