import Foundation
import Testing

/// Every localized literal in the source, checked against the catalog of **every target that
/// compiles the file it lives in**.
///
/// The other guards in this suite ask whether a string was localized *correctly*. This one asks
/// whether it **arrived**. Those are different failures with the same appearance at the call site:
///
/// ```swift
/// String(localized: "sort.manually", defaultValue: "Manually", comment: "…")
/// ```
///
/// is right whether or not `sort.manually` is in a catalog. If nobody ran `sync_catalogs.py`, or
/// the key was renamed, or the build that produced the `.stringsdata` did not include this
/// target, the call compiles, renders "Manually", passes every shape check — and the translator
/// never sees it. `focus.allLists` shipped in exactly that state and was caught by reading a sync
/// diff by eye.
///
/// ## Why the target map is derived rather than written down
///
/// An app extension resolves strings against its **own** `Bundle.main`, so a file compiled into
/// two targets needs its keys in two catalogs — separately, with plural rules authored twice.
/// The list of which files those are is not stable: `project.yml` gains a
/// `- path: NowThis/Utilities/Something.swift` line and a file silently joins a second target.
///
/// So the map is read out of `project.yml` itself. Adding a shared source to a target's `sources`
/// immediately requires that target's catalog to carry its keys, with no second edit here — which
/// is the only version of this check that cannot rot.
///
/// This subsumes the plan's "two-layer compile-time pattern" for the copy containers it names.
/// `Quadrant` is a **`private enum`** inside `EisenhowerMatrixView.swift` and cannot be named from
/// a test at all, so an enumerate-the-types guard could never have covered it; scanning the source
/// covers it, `SidebarSection`, `DefaultDueDateRule`, `RecurrenceRule.Frequency`, `WatchSmartList`
/// and `TaskPriority` without naming any of them.
@Suite("Localization / localized literals arrive")
struct LocalizedLiteralArrivalGuardTests {

    /// The shipping targets and the catalog each resolves against. `NowThisTests` is deliberately
    /// absent: it is opted out of extraction so this file's own fixtures cannot become keys.
    static let catalogOfTarget = [
        "NowThis": "NowThis/Localizable.xcstrings",
        "NowThisWidget": "NowThisWidget/Localizable.xcstrings",
        "NowThisWatch": "NowThisWatch/Localizable.xcstrings",
        "NowThisWatchWidget": "NowThisWatchWidget/Localizable.xcstrings",
    ]

    // MARK: - The target map, read from project.yml

    /// `target → the source paths it compiles`, straight out of `project.yml`.
    static func sourcePathsByTarget() throws -> [String: [String]] {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let spec = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let flat = YAMLLite.flatten(spec)

        var out: [String: [String]] = [:]
        for target in Self.catalogOfTarget.keys {
            var paths: [String] = []
            var index = 0
            while let path = flat["targets.\(target).sources.\(index).path"] {
                paths.append(path)
                index += 1
            }
            out[target] = paths
        }
        return out
    }

    /// Every target that compiles a repository-relative file.
    static func targets(compiling file: String, sources: [String: [String]]) -> [String] {
        sources.compactMap { target, paths in
            paths.contains { path in
                file == path || file.hasPrefix(path.hasSuffix("/") ? path : path + "/")
            } ? target : nil
        }.sorted()
    }

    // MARK: - Reading the source

    /// One localized literal as written.
    struct LocalizedLiteral: Hashable {
        let file: String
        let line: Int
        /// The catalog key — the first literal after the `localized:` label.
        let key: String
        /// The English the catalog must hold: the `defaultValue:` when there is one, otherwise
        /// the key itself, because English-as-key entries carry no `en` block.
        let english: String
    }

    /// Every `…(localized: …)` call in a file.
    ///
    /// **Anchored on the bare `localized:` label, not on `String(localized:`.** The wrapped form
    ///
    /// ```swift
    /// String(
    ///     localized: "some.key",
    ///     defaultValue: "Some Text")
    /// ```
    ///
    /// never contains `String(localized:` as a contiguous substring, and that blind spot is
    /// exactly what let a renamed key pass the §2c-i guard (issues log L24). The same anchor is
    /// used by `SwiftSourceScanner.strippingLocalizingCalls` for the same reason.
    ///
    /// Reads comment-stripped source with literals intact: a commented-out call must not be
    /// demanded of a catalog, and the literal contents are the whole answer.
    static func localizedLiterals(in source: String, file: String) -> [LocalizedLiteral] {
        let code = Array(SwiftSourceScanner.strippingComments(source))
        var lineOf = Array(repeating: 1, count: code.count + 1)
        var line = 1
        for index in code.indices {
            lineOf[index] = line
            if code[index] == "\n" { line += 1 }
        }
        lineOf[code.count] = line

        let text = String(code)
        var found: [LocalizedLiteral] = []
        var searchFrom = text.startIndex

        while let anchor = text.range(of: "localized:", range: searchFrom..<text.endIndex) {
            searchFrom = anchor.upperBound
            let anchorOffset = text.distance(from: text.startIndex, to: anchor.lowerBound)

            // A label, not a substring of an identifier — `unlocalized:` must not match.
            if anchorOffset > 0 {
                let previous = code[anchorOffset - 1]
                if previous.isLetter || previous.isNumber || previous == "_" { continue }
            }

            guard let span = callSpan(around: anchorOffset, in: code) else { continue }
            let call = String(code[span])
            let after = String(code[(anchorOffset + "localized:".count)...span.upperBound - 1])

            guard let key = firstLiteral(in: after) else { continue }
            let english = literal(labelled: "defaultValue:", in: call) ?? key
            guard !key.contains("\\("), !english.contains("\\(") else { continue }

            found.append(LocalizedLiteral(file: file, line: lineOf[anchorOffset],
                                          key: unescaped(key), english: unescaped(english)))
        }
        return found
    }

    /// The parenthesised call an offset sits inside: walk back to the unmatched `(`, then forward
    /// to its partner.
    static func callSpan(around offset: Int, in code: [Character]) -> ClosedRange<Int>? {
        var depth = 0
        var index = offset
        while index > 0 {
            index -= 1
            if code[index] == ")" { depth += 1; continue }
            if code[index] == "(" {
                if depth == 0 { break }
                depth -= 1
            }
        }
        guard index >= 0, code[index] == "(" else { return nil }
        let open = index

        depth = 0
        index = open
        while index < code.count {
            if code[index] == "(" { depth += 1 }
            else if code[index] == ")" {
                depth -= 1
                if depth == 0 { return open...index }
            }
            index += 1
        }
        return nil
    }

    static func firstLiteral(in text: String) -> String? {
        guard let open = text.firstIndex(of: "\"") else { return nil }
        var value = ""
        var index = text.index(after: open)
        while index < text.endIndex, text[index] != "\"" {
            if text[index] == "\\", text.index(after: index) < text.endIndex {
                value.append(text[index])
                index = text.index(after: index)
            }
            value.append(text[index])
            index = text.index(after: index)
        }
        return index < text.endIndex ? value : nil
    }

    static func literal(labelled label: String, in text: String) -> String? {
        guard let hit = text.range(of: label) else { return nil }
        return firstLiteral(in: String(text[hit.upperBound...]))
    }

    /// Resolves Swift escape sequences. The catalog stores the value, not the source spelling.
    static func unescaped(_ literal: String) -> String {
        AccessibilityCopyGuardTests.unescaped(literal)
    }

    // MARK: - 1. Arrival

    @Test("Every localized literal is in the catalog of every target that compiles it")
    func everyLocalizedLiteralArrives() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let sources = try Self.sourcePathsByTarget()
        // key → English, per catalog. Both halves are checked: the key proves the entry exists,
        // the English proves it is the same string. A renamed key whose defaultValue is unchanged
        // passes an English-only check while its five translations sit orphaned under the old key.
        var renderings: [String: [String: String]] = [:]
        for catalog in LocalizationCatalogFixture.catalogs {
            var byKey: [String: String] = [:]
            for (key, entry) in try LocalizationCatalogFixture.load(catalog) {
                byKey[key] = LocalizationCatalogFixture.englishRendering(ofKey: key, entry: entry)
            }
            renderings[catalog.path] = byKey
        }

        var comparisons = 0
        var literalsFound = 0
        var sharedFiles: Set<String> = []
        var findings: [String] = []

        for file in try LocalizationCatalogFixture.swiftSourceFiles() {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let literals = Self.localizedLiterals(in: source, file: file)
            guard !literals.isEmpty else { continue }

            let owners = Self.targets(compiling: file, sources: sources)
            if owners.count > 1 { sharedFiles.insert(file) }
            if owners.isEmpty {
                findings.append("""
                      \(file) has \(literals.count) localized literal(s) and is in no target's
                      `sources` in project.yml — so it is not compiled, and nothing extracts it.
                    """)
                continue
            }

            for literal in literals {
                literalsFound += 1
                for owner in owners {
                    guard let catalogPath = Self.catalogOfTarget[owner],
                          let present = renderings[catalogPath] else { continue }
                    comparisons += 1
                    guard let stored = present[literal.key] else {
                        findings.append("""
                              \(literal.file):\(literal.line)  \(catalogPath)
                                  no entry for key \u{201C}\(literal.key)\u{201D}
                            """)
                        continue
                    }
                    guard stored != literal.english else { continue }
                    findings.append("""
                          \(literal.file):\(literal.line)  \(catalogPath)  key \u{201C}\(literal.key)\u{201D}
                              source says \u{201C}\(literal.english)\u{201D}
                              catalog says \u{201C}\(stored)\u{201D}
                        """)
                }
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) localized literal(s) never reached a catalog they need to be in:
            \(findings.sorted().joined(separator: "\n"))

            The call is correct; the catalog is stale. Nothing renders wrong and no shape check
            can see it — the string simply is not in the file the translator opens, or it is there
            under a key nothing asks for any more, with its translations orphaned under it.

              python3 Translations/tools/sync_catalogs.py --apply

            If the finding names a catalog you did not expect, the file is compiled into more than
            one target (project.yml `sources`), and each target resolves against its own
            Bundle.main. Plural rules do not propagate between them either.
            """)

        // Measured 2026-07-26: 253 comparisons over 4 targets.
        #expect(comparisons >= 240, """
            Only \(comparisons) literal/catalog comparisons were made; there were 253 when this
            was written. The `localized:` scanner has stopped matching what the code writes.
            """)
        // Measured 2026-07-26: 208 localized literals in 7 shared + 60-odd single-target files.
        #expect(literalsFound >= 195,
                "Only \(literalsFound) localized literals were found in the source tree; there were 208.")
        // If nothing is shared, the target map has collapsed to "one root, one catalog" and the
        // hardest half of this check — the widget and watch duplicates — is silently not running.
        #expect(sharedFiles.count >= 5, """
            Only \(sharedFiles.count) files carrying localized literals compile into more than one
            target; there were 7 when this was written. The project.yml target map has
            collapsed, and the shared-source half of this guard is not being exercised.
            """)
    }

    // MARK: - 2. The map itself

    @Test("The target map read from project.yml describes the real targets")
    func targetMapIsSane() throws {
        let sources = try Self.sourcePathsByTarget()
        #expect(Set(sources.keys) == Set(Self.catalogOfTarget.keys))

        for (target, paths) in sources {
            #expect(!paths.isEmpty, """
                `targets.\(target).sources` read as empty from project.yml. Every file would then
                belong to no target and the arrival check would compare nothing.
                """)
            #expect(paths.contains(target), """
                \(target)'s own directory is not in its `sources`: \(paths).
                """)
        }

        // The three sharing relationships the catalog matrix is built on. Read from the spec, so
        // this fails if a `- path:` line is removed — which is how a widget silently stops
        // compiling a model and its catalog stops needing the keys.
        // TaskPriority joined the watch when its add screen gained a priority picker, and
        // DefaultDueDateRule came with it for the due-date presets. Both carry
        // `String(localized:)` labels, so each target compiling them owes those keys its own
        // translations — which is the relationship this block exists to pin.
        #expect(Self.targets(compiling: "NowThis/Models/TaskPriority.swift", sources: sources)
                == ["NowThis", "NowThisWatch", "NowThisWidget"])
        #expect(Self.targets(compiling: "NowThis/Utilities/DefaultDueDateRule.swift", sources: sources)
                == ["NowThis", "NowThisWatch"])
        #expect(Self.targets(compiling: "NowThis/Watch/WatchSmartList.swift", sources: sources)
                == ["NowThis", "NowThisWatch", "NowThisWatchWidget"])
        #expect(Self.targets(compiling: "NowThis/Utilities/DueDateFormatter.swift", sources: sources)
                == ["NowThis", "NowThisWatch", "NowThisWatchWidget"])
        // …and a file that is genuinely app-only.
        #expect(Self.targets(compiling: "NowThis/Views/Tasks/TaskListView.swift", sources: sources)
                == ["NowThis"])
    }

    // MARK: - 3. Self-checks

    @Test("The localized-literal scanner reads calls, not comments and not near-misses")
    func scannerSelfChecks() {
        func scan(_ source: String) -> [LocalizedLiteral] {
            Self.localizedLiterals(in: source, file: "f.swift")
        }

        // English-as-key: the key IS the English.
        #expect(scan(#"let a = String(localized: "Today")"#).map(\.english) == ["Today"])

        // Explicit key: the English is the defaultValue, never the key or the comment.
        let explicit = scan("""
            let a = String(localized: "sort.manually", defaultValue: "Manually",
                           comment: "Sort option: the order the user dragged rows into")
            """)
        #expect(explicit.map(\.key) == ["sort.manually"])
        #expect(explicit.map(\.english) == ["Manually"])

        // The wrapped form — no contiguous `String(localized:` anywhere in it. This shape is why
        // the anchor is the bare label (L24).
        let wrapped = scan("""
            let a = String(
                localized: "some.key",
                defaultValue: "Some Text",
                comment: "why")
            """)
        #expect(wrapped.map(\.english) == ["Some Text"])

        // A commented-out call must not be demanded of a catalog.
        #expect(scan(#"// let a = String(localized: "gone.key", defaultValue: "Gone")"#).isEmpty)

        // An interpolated default becomes %@ in the catalog and cannot be compared as written.
        #expect(scan(##"""
            let a = String(localized: "k", defaultValue: "\(n) tasks", comment: "c")
            """##).isEmpty)

        // Escapes: the catalog stores the value, not the spelling.
        #expect(scan(#"let a = String(localized: "row shows \"All day\"")"#).map(\.english)
                == [#"row shows "All day""#])

        // A label that merely ends in `localized:` is not this label.
        #expect(scan(#"let a = f(unlocalized: "x")"#).isEmpty)

        // Line numbers survive comment stripping, or every finding points at the wrong place.
        let numbered = scan("""
            // a comment
            /* another
               one */
            let a = String(localized: "Today")
            """)
        #expect(numbered.first?.line == 4)
    }
}
