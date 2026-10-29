import Foundation
import Testing

/// The 143 strings nobody looks at.
///
/// Accessibility copy is the largest block of user-facing text in the app that **never appears on
/// a screenshot**. A German screenshot pass, a pseudolocalization run and a back-translation of
/// the visible surface all miss it completely: the string is spoken, once, to a reader who is not
/// looking at the display. So it is exactly the class that ships English after everything else is
/// translated — and it is the class with no width budget, which makes it the *cheapest* to
/// translate well and the easiest to forget.
///
/// ## Why this is not the same test as `ViewCopyGuardTests`
///
/// That file asks a question about **shape**: is this literal localized where it was written? It
/// answers it inside a surface it defines by directory. This file asks the two questions that
/// shape cannot answer:
///
/// - **Coverage.** Is every file that speaks actually inside somebody's surface? The prior
///   accessibility guard shipped green for a whole phase over an allowlist that was missing 27
///   emitting files. An allowlist that "starts opt-in and green" is a scan over an empty set, and
///   green is the direction that hides it.
/// - **Arrival.** Did the string reach the catalog? A correctly-shaped `String(localized:)` whose
///   key was never synced compiles, renders, reads aloud, and is in no catalog — the failure is
///   invisible at the call site and visible only in the file the translator opens.
///
/// It also pins the one accessibility defect that predates localization entirely: an SF Symbol
/// name passed as a label, so VoiceOver announces *"line.3.horizontal.decrease.circle"*.
@Suite("Localization / accessibility copy")
struct AccessibilityCopyGuardTests {

    /// Every SwiftUI modifier that takes spoken copy.
    static let markers = [
        ".accessibilityLabel(", ".accessibilityHint(", ".accessibilityValue(",
        ".accessibilityInputLabels(", ".accessibilityAction(",
    ]

    /// Directories and files some guard in this suite already scans for bare literals.
    ///
    /// Read from the two guards rather than re-declared, so a surface that shrinks there is
    /// caught here rather than quietly narrowing both.
    static var scannedSurfaces: [String] {
        ViewCopyGuardTests.surfaceDirectories
            + ViewCopyGuardTests.surfaceFiles_extra
            + NonViewStringProducerGuardTests.surfaceDirectories
            + NonViewStringProducerGuardTests.surfaceFiles_extra
    }

    /// Files that emit spoken copy and are not yet inside any scanner's surface.
    ///
    /// **Dated 2026-07-26: empty, and asserted empty.** §2c-ii migrated every one of them, and
    /// the count is in the failure message below so "nothing unexamined" is a number rather than
    /// an absence. If a file has to be added here it needs a date and a reason, and the count may
    /// only fall.
    static let notYetMigrated: [String: String] = [:]

    /// Sources compiled into more than one target. An extension resolves against its **own**
    /// `Bundle.main`, so a spoken string in one of these has to be in every one of their catalogs.
    static let sharedSources: [String: [String]] = [
        "NowThis/Models/": ["NowThis/Localizable.xcstrings",
                            "NowThisWidget/Localizable.xcstrings"],
        "NowThis/Intents/CompleteTaskIntent.swift": ["NowThis/Localizable.xcstrings",
                                                     "NowThisWidget/Localizable.xcstrings"],
        "NowThis/Intents/WidgetConfigurationIntent.swift": ["NowThis/Localizable.xcstrings",
                                                            "NowThisWidget/Localizable.xcstrings"],
        "NowThis/Utilities/DueDateFormatter.swift": ["NowThis/Localizable.xcstrings",
                                                     "NowThisWatch/Localizable.xcstrings",
                                                     "NowThisWatchWidget/Localizable.xcstrings"],
        "NowThis/Watch/WatchSmartList.swift": ["NowThis/Localizable.xcstrings",
                                               "NowThisWatch/Localizable.xcstrings",
                                               "NowThisWatchWidget/Localizable.xcstrings"],
    ]

    /// Every catalog a file's strings must reach.
    static func catalogs(for file: String) -> [String] {
        for (prefix, catalogs) in sharedSources where file.hasPrefix(prefix) { return catalogs }
        let root = file.split(separator: "/").first.map(String.init) ?? ""
        return ["\(root)/Localizable.xcstrings"]
    }

    // MARK: - Reading an argument

    /// The English a spoken argument resolves to, when it resolves to anything static.
    ///
    /// Three shapes carry static English and everything else is data:
    ///
    ///   .accessibilityLabel("Add task")                            → ["Add task"]
    ///   .accessibilityLabel(String(localized: …, defaultValue: X)) → [X]
    ///   .accessibilityValue(flag ? "Set" : "Not set")              → ["Set", "Not set"]
    ///   .accessibilityLabel(task.title)                            → []   (user data)
    ///
    /// `defaultValue:` wins when present, because the other literals in that call are the key and
    /// the comment — neither of which is ever spoken, and both of which would produce nonsense
    /// findings if compared against a catalog.
    ///
    /// Anything containing an interpolation is dropped: the catalog stores it as `%@`, and
    /// reconstructing the specifier from the Swift expression means knowing each interpolated
    /// value's *type*, which source text does not carry.
    static func staticEnglish(of argument: SwiftSourceScanner.CallArgument) -> [String] {
        let defaults = literals(labelled: "defaultValue:", in: argument.asWritten)
        if !defaults.isEmpty {
            return defaults.filter { !$0.contains("\\(") }.map(unescaped)
        }

        let shape = strippingArgumentLabel(argument.redacted)
        guard isBareLiteral(shape) || SwiftSourceScanner.isAllLiteralTernary(shape) else { return [] }
        return allLiterals(in: strippingArgumentLabel(argument.asWritten))
            .filter { !$0.contains("\\(") }
            .map(unescaped)
    }

    /// Resolves the escape sequences a Swift literal is written with.
    ///
    /// The catalog stores the **value**, not the source spelling. `TaskDetailView`'s all-day hint
    /// is written `…its row shows \"All day\"` and stored `…its row shows "All day"` — and that
    /// one string was this guard's entire first-run finding, a false positive from comparing a
    /// source spelling against a stored value. Left unfixed it would have taught the next reader
    /// that the catalog was stale.
    static func unescaped(_ literal: String) -> String {
        var out = ""
        var index = literal.startIndex
        while index < literal.endIndex {
            guard literal[index] == "\\", literal.index(after: index) < literal.endIndex else {
                out.append(literal[index])
                index = literal.index(after: index)
                continue
            }
            let next = literal[literal.index(after: index)]
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            case "\"", "'", "\\": out.append(next)
            default: out.append("\\"); out.append(next)
            }
            index = literal.index(index, offsetBy: 2)
        }
        return out
    }

    /// Literal values of a labelled argument — `defaultValue: "Add task"`.
    static func literals(labelled label: String, in text: String) -> [String] {
        var found: [String] = []
        var search = text.startIndex
        while let hit = text.range(of: label, range: search..<text.endIndex) {
            search = hit.upperBound
            guard let open = text[hit.upperBound...].firstIndex(of: "\"") else { continue }
            let after = text.index(after: open)
            guard let close = text[after...].firstIndex(of: "\"") else { continue }
            found.append(String(text[after..<close]))
            search = text.index(after: close)
        }
        return found
    }

    /// Every string literal in an expression, in order.
    static func allLiterals(in text: String) -> [String] {
        var found: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "\"" else { index = text.index(after: index); continue }
            var cursor = text.index(after: index)
            var value = ""
            while cursor < text.endIndex, text[cursor] != "\"" {
                if text[cursor] == "\\", text.index(after: cursor) < text.endIndex {
                    value.append(text[cursor])
                    cursor = text.index(after: cursor)
                }
                value.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex else { break }
            found.append(value)
            index = text.index(after: cursor)
        }
        return found
    }

    /// Drops a leading `label: ` so `named: "Delete"` reads as a bare literal.
    static func strippingArgumentLabel(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return trimmed }
        let label = trimmed[trimmed.startIndex..<colon]
        guard !label.isEmpty,
              label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              label.first?.isLetter == true else { return trimmed }
        return String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isBareLiteral(_ redacted: String) -> Bool {
        let trimmed = redacted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
            return false
        }
        return !trimmed.dropFirst().dropLast().contains("\"")
    }

    /// An SF Symbol name, a reverse-DNS token — anything with no words a reader would recognise.
    static func isSymbolName(_ text: String) -> Bool {
        guard text.contains("."), !text.contains(" ") else { return false }
        return text.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "." }
    }

    // MARK: - Collecting

    struct SpokenString {
        let file: String
        let line: Int
        let marker: String
        let english: String
    }

    static func spokenStrings() throws -> (all: [SpokenString], files: Set<String>,
                                           sites: Int, dynamic: Int) {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var all: [SpokenString] = []
        var files: Set<String> = []
        var sites = 0
        var dynamic = 0

        for file in try LocalizationCatalogFixture.swiftSourceFiles() {
            let url = root.appendingPathComponent(file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw LocalizationFixtureError.fileUnreadable(path: file, underlying: "read failed")
            }
            let arguments = SwiftSourceScanner.firstArguments(
                ofCallsTo: Self.markers, in: source, file: file)
            guard !arguments.isEmpty else { continue }
            files.insert(file)

            for argument in arguments {
                sites += 1
                let english = Self.staticEnglish(of: argument)
                if english.isEmpty { dynamic += 1 }
                for value in english {
                    all.append(SpokenString(file: file, line: argument.line,
                                            marker: argument.marker, english: value))
                }
            }
        }
        return (all, files, sites, dynamic)
    }

    // MARK: - 1. Coverage

    @Test("Every file that speaks is inside a scanner's surface")
    func everySpeakingFileIsScanned() throws {
        let scan = try Self.spokenStrings()
        var unscanned: [String] = []

        for file in scan.files.sorted() {
            let covered = Self.scannedSurfaces.contains {
                $0.hasSuffix("/") ? file.hasPrefix($0) : file == $0
            }
            guard !covered else { continue }
            if Self.notYetMigrated[file] != nil { continue }
            unscanned.append("  \(file)")
        }

        #expect(unscanned.isEmpty, """
            \(unscanned.count) file(s) emit spoken copy and are inside no scanner's surface:
            \(unscanned.joined(separator: "\n"))

            Nothing in this suite reads them. The string can be a bare English literal, it will
            compile, render, read aloud, and appear in no catalog — and every guard will be green,
            because from their point of view the file does not exist.

            Add the directory or file to ViewCopyGuardTests.surfaceDirectories /
            NonViewStringProducerGuardTests.surfaceFiles_extra. Do not add it to `notYetMigrated`
            unless there is a dated reason; that list is at \(Self.notYetMigrated.count) and only
            ever falls.
            """)

        #expect(Self.notYetMigrated.isEmpty, """
            \(Self.notYetMigrated.count) file(s) are still recorded as unmigrated:
            \(Self.notYetMigrated.sorted { $0.key < $1.key }
                .map { "  \($0.key) — \($0.value)" }.joined(separator: "\n"))

            §2c-ii emptied this list. It may only ever fall.
            """)

        // Measured 2026-07-26: 38 files, 143 modifier call sites.
        #expect(scan.files.count >= 34, """
            Only \(scan.files.count) files were found emitting spoken copy; there were 38 when
            this was written. The modifier scan has stopped matching.
            """)
        #expect(scan.sites >= 135, """
            Only \(scan.sites) accessibility modifier sites were found; there were 143 when this
            was written.
            """)
    }

    // MARK: - 2. Arrival

    @Test("Every spoken string reaches the catalogs of every target it is compiled into")
    func everySpokenStringReachesItsCatalogs() throws {
        let scan = try Self.spokenStrings()
        var renderings: [String: Set<String>] = [:]
        var comparisons = 0
        var findings: [String] = []

        for catalog in LocalizationCatalogFixture.catalogs {
            renderings[catalog.path] = try LocalizationCatalogFixture.englishRenderings(in: catalog)
        }

        for spoken in scan.all {
            for path in Self.catalogs(for: spoken.file) {
                guard let present = renderings[path] else {
                    findings.append("  \(spoken.file): \(path) is not in the fixture's catalog list")
                    continue
                }
                comparisons += 1
                guard !present.contains(spoken.english) else { continue }
                findings.append("""
                      \(spoken.file):\(spoken.line)  \(spoken.marker)
                          \u{201C}\(spoken.english)\u{201D} is in no \(path)
                    """)
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) spoken string(s) are in no catalog:
            \(findings.sorted().joined(separator: "\n"))

            VoiceOver will read them in English in all five languages, and nothing on screen will
            look wrong. Either the literal is bare — localize it at the literal — or its key was
            never synced:
              python3 Translations/tools/sync_catalogs.py --apply

            A file compiled into more than one target needs its string in EVERY one of their
            catalogs; an extension resolves against its own Bundle.main.
            """)
        // Measured 2026-07-26: 115 static spoken strings compared, 46 dynamic sites (user data).
        #expect(comparisons >= 105, """
            Only \(comparisons) spoken strings were compared against a catalog; there were 115
            when this was written. Either the static-English extractor has stopped resolving
            arguments, or the spoken copy has become data.
            """)
        #expect(scan.dynamic >= 35, """
            Only \(scan.dynamic) spoken arguments read as dynamic; there were 46 when this was
            written. If that reaches zero the extractor is treating user data as static English
            and is about to demand catalog entries for task titles.
            """)
    }

    // MARK: - 3. The pre-localization defect

    @Test("No VoiceOver string is an SF Symbol name")
    func noSpokenStringIsASymbolName() throws {
        let scan = try Self.spokenStrings()
        var findings: [String] = []

        for spoken in scan.all where Self.isSymbolName(spoken.english) {
            findings.append("  \(spoken.file):\(spoken.line)  \(spoken.marker)  \u{201C}\(spoken.english)\u{201D}")
        }

        #expect(findings.isEmpty, """
            \(findings.count) VoiceOver string(s) are SF Symbol names:
            \(findings.joined(separator: "\n"))

            VoiceOver reads them out character group by character group —
            "line dot 3 dot horizontal dot decrease dot circle" — which is what
            FilterBuilderView did for all twelve of its icons before §2b. This is an accessibility
            defect on the English build, before any translation is involved.
            """)
        #expect(!scan.all.isEmpty, "No spoken strings were collected at all.")
    }

    // MARK: - 4. Self-checks

    @Test("Static-English extraction reads arguments, not their neighbours")
    func extractionSelfChecks() {
        func argument(_ source: String) -> SwiftSourceScanner.CallArgument? {
            SwiftSourceScanner.firstArguments(ofCallsTo: Self.markers, in: source).first
        }

        // A bare literal.
        let bare = argument(#"Image(x).accessibilityLabel("Add task")"#)
        #expect(bare.map { Self.staticEnglish(of: $0) } == ["Add task"])

        // A localized literal: the defaultValue is the spoken text; the key and the comment are
        // never read aloud and must not be compared against a catalog.
        let localized = argument("""
            Image(x).accessibilityLabel(String(localized: "tasks.a11y.addTask",
                                               defaultValue: "Add task",
                                               comment: "VoiceOver label for the toolbar button"))
            """)
        #expect(localized.map { Self.staticEnglish(of: $0) } == ["Add task"])

        // An all-literal ternary is two spoken strings, both of which must arrive.
        let ternary = argument(#"X().accessibilityValue(flag ? "Set" : "Not set")"#)
        #expect(ternary.map { Self.staticEnglish(of: $0) } == ["Set", "Not set"])

        // User data is not copy and must not be demanded of a catalog.
        let data = argument("X().accessibilityLabel(task.title)")
        #expect(data.map { Self.staticEnglish(of: $0) } == [])

        // An already-localized producer is fine — extraction happened at its own literal, which
        // some other file's scan covers. Nothing static to compare here.
        let producer = argument("X().accessibilityLabel(status.displayName)")
        #expect(producer.map { Self.staticEnglish(of: $0) } == [])

        // An interpolation becomes %@ in the catalog and cannot be compared as written.
        let interpolated = argument(##"X().accessibilityLabel("\(n) tasks")"##)
        #expect(interpolated.map { Self.staticEnglish(of: $0) } == [])

        // `named:` is an argument label, not the first word of the spoken string.
        let action = argument(#"X().accessibilityAction(named: "Delete") { }"#)
        #expect(action.map { Self.staticEnglish(of: $0) } == ["Delete"])

        // A quote inside a hint. The source spells it `\"`; the catalog stores `"`. Comparing the
        // two spellings was this guard's whole first-run finding, and it was a false positive.
        let escaped = argument(#"""
            X().accessibilityHint("the row shows \"All day\"")
            """#)
        #expect(escaped.map { Self.staticEnglish(of: $0) } == [#"the row shows "All day""#])
        #expect(Self.unescaped(#"a\nb"#) == "a\nb")
        #expect(Self.unescaped(#"C:\\path"#) == #"C:\path"#)
        #expect(Self.unescaped("nothing to do") == "nothing to do")

        // Symbol classification: the defect, and the strings that must not be mistaken for it.
        #expect(Self.isSymbolName("line.3.horizontal.decrease.circle"))
        #expect(Self.isSymbolName("calendar.badge.plus"))
        #expect(!Self.isSymbolName("Add task"))
        #expect(!Self.isSymbolName("Done."))          // sentence-final period, not a symbol
        #expect(!Self.isSymbolName("Sync now"))
        #expect(!Self.isSymbolName("calendar"))       // one word: could be either, and is copy
    }
}
