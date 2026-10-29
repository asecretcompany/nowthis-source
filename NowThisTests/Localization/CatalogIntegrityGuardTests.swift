import Foundation
import Testing

/// Structural invariants of the seven `.xcstrings` files themselves.
///
/// Everything here is checkable **while the catalogs are still English-only**, which is the whole
/// reason Phase 3 runs before Phase 5: a malformed entry costs one edit today and five
/// re-translations after batch one.
///
/// Two invariants named in the plan's catalog-integrity row live elsewhere and are deliberately
/// not duplicated: **degenerate keys** and **specifier-only keys** are one check, and it is
/// ``LocalizationKeyStyleGuardTests/noDegenerateKeys``. A key made only of format specifiers has
/// no translatable words, so the same predicate decides both — a second copy here would drift.
///
/// ## What each test is defending against
///
/// - **Schema.** Xcode rewrites catalogs on its own initiative. A field
///   nobody wrote is the cheapest possible signal that it happened.
/// - **Comments on explicit keys.** The key-style decision exists so ambiguous, counted and
///   duplicated strings carry a `comment:`. An explicit key with no comment is that decision
///   silently not applied — the translator gets `sort.dueDate` and nothing else.
/// - **Case variants.** Two entries differing only in case reach the translator as two jobs with
///   no way to tell them apart, and can come back with two different words for one concept.
/// - **Positional specifiers.** German and Dutch reorder clauses. `"Added %@ to %@."` cannot be
///   reordered; `"Added %1$@ to %2$@."` can. This is also the form Xcode's rewrite converts *to*,
///   so converting deliberately leaves the rewrite nothing to do.
/// - **Specifier parity.** A translation that drops or adds an argument is a crash, not a typo:
///   `String(format:)` reads a pointer that was never passed.
/// - **Shared keys.** `NowThis/Models/` compiles into NowThisWidget as well, and each target
///   resolves against its **own** bundle. The same key in two catalogs with two different English
///   values means one of the two targets is showing copy nobody reviewed.
@Suite("Localization / catalog integrity")
struct CatalogIntegrityGuardTests {

    // MARK: - Schema vocabulary

    /// Top-level keys a string catalog may carry.
    static let catalogFields: Set<String> = ["sourceLanguage", "strings", "version"]
    /// Keys one entry in `strings` may carry.
    static let entryFields: Set<String> = ["comment", "extractionState", "localizations",
                                           "shouldTranslate"]
    /// Keys one language block may carry.
    ///
    /// `stringSet` is the App Shortcuts one: an `AppShortcut`'s `phrases:` array is many
    /// spoken alternatives for a single intent, and Xcode extracts it as one key — the first
    /// phrase — whose English block holds every phrase. It is a real field Xcode writes into
    /// `NowThis/AppShortcuts.xcstrings` on every build, and it was missing from this list, so
    /// the scan read eight legitimate entries as an Xcode rewrite. Its shape is checked by
    /// ``stringSetFindings(in:label:)`` rather than merely tolerated.
    static let localizationFields: Set<String> = ["stringUnit", "stringSet",
                                                  "variations", "substitutions"]
    /// Keys a `stringUnit` may carry.
    static let stringUnitFields: Set<String> = ["state", "value"]
    /// Keys a `stringSet` may carry. `values`, plural, where a `stringUnit` has `value`.
    static let stringSetFields: Set<String> = ["state", "values"]
    /// Keys a substitution may carry.
    static let substitutionFields: Set<String> = ["argNum", "formatSpecifier", "variations"]
    /// `stringUnit.state` values Xcode writes.
    static let translationStates: Set<String> = ["new", "translated", "needs_review", "stale"]
    /// `extractionState` values Xcode writes.
    static let extractionStates: Set<String> = ["manual", "extracted_with_value", "migrated",
                                                "stale"]
    /// CLDR plural categories. Nothing else is a category, and a typo'd one is simply never
    /// selected at runtime — it does not fail to build and it does not fail to load.
    static let pluralCategories: Set<String> = ["zero", "one", "two", "few", "many", "other"]

    /// Keys that name the bundle they sit in, and are therefore *required* to differ between
    /// catalogs — the one exemption from ``sharedKeysAreIdenticalInEveryCatalog``.
    ///
    /// Kept to names, and only names. Every other key in two catalogs is there because one
    /// source file compiles into two targets, and for those the whole point is that the two
    /// must agree. Adding anything else here would turn that test off for a real string.
    static let perBundleIdentityKeys: Set<String> = ["CFBundleName", "CFBundleDisplayName"]

    // MARK: - Format arguments

    /// One argument slot in a format string.
    ///
    /// `position` is the explicit `n$` when the specifier carries one. A **substitution marker**
    /// (`%#@taskCount@`) always counts as positioned: its argument index is declared in the
    /// entry's `substitutions` block (`argNum`), not in the string.
    struct FormatArgument: Hashable, CustomStringConvertible {
        let position: Int?
        /// `@`, `lld`, `d` … or `#@name@` for a substitution marker.
        let conversion: String

        var description: String {
            conversion.hasPrefix("#@") ? "%\(conversion)"
                : "%\(position.map { "\($0)$" } ?? "")\(conversion)"
        }
    }

    /// Every argument slot in a format string, in source order.
    ///
    /// `%%` is an escaped percent sign and consumes no argument, so it is not one — a scanner
    /// that counts it reports `"100%% done"` as a one-argument string and then fails parity
    /// against a translation that spells it the same way.
    static func formatArguments(in text: String) -> [FormatArgument] {
        var arguments: [FormatArgument] = []
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            guard characters[index] == "%" else { index += 1; continue }
            index += 1
            guard index < characters.count else { break }

            // `%%` — literal percent, no argument.
            if characters[index] == "%" { index += 1; continue }

            // `%#@name@` — substitution marker.
            if characters[index] == "#", index + 1 < characters.count, characters[index + 1] == "@" {
                var cursor = index + 2
                var name = ""
                while cursor < characters.count, characters[cursor] != "@" {
                    name.append(characters[cursor]); cursor += 1
                }
                guard cursor < characters.count else { break }
                arguments.append(FormatArgument(position: nil, conversion: "#@\(name)@"))
                index = cursor + 1
                continue
            }

            // Optional `n$` positional prefix. Only a `$` makes the digits a position; without
            // one they are a field width and the argument is *not* positional.
            var cursor = index
            var digits = ""
            while cursor < characters.count, characters[cursor].isNumber {
                digits.append(characters[cursor]); cursor += 1
            }
            var position: Int?
            if !digits.isEmpty, cursor < characters.count, characters[cursor] == "$" {
                position = Int(digits)
                cursor += 1
            } else {
                cursor = index
            }

            // Flags, width, precision.
            while cursor < characters.count,
                  "-+ #0".contains(characters[cursor]) || characters[cursor].isNumber
                    || characters[cursor] == "." || characters[cursor] == "*" {
                cursor += 1
            }

            // Length modifiers, longest first so `ll` is not read as two `l`s.
            var length = ""
            for modifier in ["hh", "ll", "h", "l", "q", "z", "j", "t", "L"]
            where String(characters[cursor..<min(cursor + modifier.count, characters.count)])
                    == modifier {
                length = modifier
                cursor += modifier.count
                break
            }

            guard cursor < characters.count else { break }
            let conversion = characters[cursor]
            guard "@dioufFeEgGxXcsp".contains(conversion) else { index = cursor; continue }
            arguments.append(FormatArgument(position: position, conversion: length + String(conversion)))
            index = cursor + 1
        }
        return arguments
    }

    // MARK: - Case variants

    /// Case-variant groups whose members are *both* English-as-key entries.
    ///
    /// These are the visible-control label and the VoiceOver label for the same action:
    /// iOS wants "Sync Now" on the button and "Sync now" spoken. That difference is correct and
    /// must survive translation — but it is invisible in the catalog, where the translator sees
    /// two near-identical jobs with no comment on either.
    ///
    /// The rule is therefore not "no case variants" but **at most one bare English-as-key entry
    /// per group**: any further variant must carry an explicit key and a `comment:` saying which
    /// surface it belongs to. That is the key-style decision applied to its own stated trigger —
    /// *anything … duplicated in English*.
    ///
    /// Deliberately empty. `Completed`/`completed` and `High`/`HIGH` already pass under the rule
    /// because their second variant is `kanban.card.a11y.completed` / `widget.priority.short.high`.
    static let caseVariantsWithAReason: [String: String] = [:]

    // MARK: - Positional conversion backlog

    /// A key whose English still uses bare `%@` for two or more arguments.
    struct PendingPositional: Hashable {
        let catalog: String
        let key: String
    }

    /// **Dated 2026-07-26. Three keys, and it cannot reach zero. This list may only ever
    /// get shorter.**
    ///
    /// Ten of the original thirteen were converted immediately before Phase 5 batch one — a
    /// rewrite of the `en` value in the catalog rather than a source edit, because each one is
    /// generated by Swift string *interpolation* inside `defaultValue:`
    /// (`defaultValue: "Added \"\(taskTitle)\" to \(listName)."`) and **there is no way to write
    /// `%1$@` at the call site**. Rewriting the catalog is safe: `sync_catalogs.py` only ever adds
    /// keys and refreshes comments — it never rewrites an existing value. The state stays `new`,
    /// so English still renders from the Swift `defaultValue`; the conversion changes nothing a
    /// user sees and leaves an Xcode catalog rewrite nothing to convert.
    ///
    /// **The three that remain are structurally unconvertible, not deferred.** Each is an
    /// English-as-key entry produced by `LocalizedStringKey` interpolation
    /// (`.accessibilityLabel("\(account.displayName), Nextcloud server \(account.serverBaseURL)")`),
    /// so the English *is* the key — the entry's body is literally `{}`. There is no `en` value to
    /// convert, and a key is the one thing an Xcode catalog rewrite does not touch, so there is
    /// also nothing here for it to convert. The risk this list exists to manage does not apply.
    ///
    /// What does apply is the translations, and they are not covered here: a five-language
    /// reordering of `%@, %@` is silently wrong. ``everyTranslationUsesPositionalSpecifiers``
    /// covers those with **no allowlist at all**, because we author them.
    ///
    /// Both halves are enforced: a member that no longer exists, or that has since been
    /// converted, fails the rot check — so the only way to shrink the list is to fix a key.
    static let pendingPositionalConversion: Set<PendingPositional> = [
        .init(catalog: "NowThis/Localizable.xcstrings", key: "%@, Nextcloud server %@"),
        .init(catalog: "NowThis/Localizable.xcstrings", key: "%@, due %@"),
        .init(catalog: "NowThis/Localizable.xcstrings", key: "Sort by %@, %@"),
    ]

    // MARK: - 1. Schema

    @Test("Every catalog is shaped the way Xcode writes one")
    func everyCatalogIsWellFormed() throws {
        var entriesExamined = 0
        var findings: [String] = []
        let root = try LocalizationCatalogFixture.repositoryRoot()

        for catalog in LocalizationCatalogFixture.catalogs {
            let url = root.appendingPathComponent(catalog.path)
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                findings.append("  \(catalog.path): not a JSON object")
                continue
            }

            for field in object.keys where !Self.catalogFields.contains(field) {
                findings.append("  \(catalog.path): unknown top-level field \u{201C}\(field)\u{201D}")
            }
            if object["sourceLanguage"] as? String != "en" {
                findings.append("""
                      \(catalog.path): sourceLanguage is \
                    \(String(describing: object["sourceLanguage"])), expected \u{201C}en\u{201D}
                    """)
            }
            if object["version"] as? String != "1.0" {
                findings.append("  \(catalog.path): version is \(String(describing: object["version"]))")
            }

            for (key, entry) in try LocalizationCatalogFixture.load(catalog) {
                entriesExamined += 1
                let label = "\(catalog.path)  \(key.isEmpty ? "<empty key>" : key)"

                for field in entry.keys where !Self.entryFields.contains(field) {
                    findings.append("  \(label): unknown entry field \u{201C}\(field)\u{201D}")
                }
                if let state = entry["extractionState"] as? String,
                   !Self.extractionStates.contains(state) {
                    findings.append("  \(label): unknown extractionState \u{201C}\(state)\u{201D}")
                }

                let localizations = (entry["localizations"] as? [String: Any]) ?? [:]
                for (language, rawBlock) in localizations {
                    guard let block = rawBlock as? [String: Any] else {
                        findings.append("  \(label) [\(language)]: localization is not an object")
                        continue
                    }
                    for field in block.keys where !Self.localizationFields.contains(field) {
                        findings.append("  \(label) [\(language)]: unknown field \u{201C}\(field)\u{201D}")
                    }
                    if block.isEmpty {
                        findings.append("  \(label) [\(language)]: empty localization block")
                    }
                    findings += Self.stringUnitFindings(in: block, label: "\(label) [\(language)]")
                    findings += Self.stringSetFindings(in: block, label: "\(label) [\(language)]")

                    for (name, rawSubstitution) in (block["substitutions"] as? [String: Any]) ?? [:] {
                        guard let substitution = rawSubstitution as? [String: Any] else {
                            findings.append("  \(label) [\(language)]: substitution \(name) is not an object")
                            continue
                        }
                        for field in substitution.keys where !Self.substitutionFields.contains(field) {
                            findings.append("""
                                  \(label) [\(language)] %#@\(name)@: unknown field \u{201C}\(field)\u{201D}
                                """)
                        }
                        if substitution["argNum"] as? Int == nil {
                            findings.append("  \(label) [\(language)] %#@\(name)@: no argNum")
                        }
                        if substitution["formatSpecifier"] as? String == nil {
                            findings.append("  \(label) [\(language)] %#@\(name)@: no formatSpecifier")
                        }
                        findings += Self.pluralFindings(in: substitution,
                                                        label: "\(label) [\(language)] %#@\(name)@")
                    }
                    findings += Self.pluralFindings(in: block, label: "\(label) [\(language)]")
                }
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) catalog schema violation(s):
            \(findings.sorted().joined(separator: "\n"))

            An entry nobody wrote by hand is the signature of an Xcode catalog rewrite.
            Compare semantically with
            `python3 Translations/tools/catalog_diff.py`, never with `git diff`, and revert rather
            than re-author.
            """)
        // Measured 2026-07-26: 722 entries across the seven catalogs.
        #expect(entriesExamined >= 700, """
            Only \(entriesExamined) entries examined; there were 722 when this was written. A
            schema scan that stops finding entries reports a clean bill of health over nothing.
            """)
    }

    private static func stringUnitFindings(in block: [String: Any], label: String) -> [String] {
        guard let unit = block["stringUnit"] as? [String: Any] else { return [] }
        var findings: [String] = []
        for field in unit.keys where !Self.stringUnitFields.contains(field) {
            findings.append("  \(label): unknown stringUnit field \u{201C}\(field)\u{201D}")
        }
        if let state = unit["state"] as? String, !Self.translationStates.contains(state) {
            findings.append("  \(label): unknown state \u{201C}\(state)\u{201D}")
        }
        if unit["value"] as? String == nil {
            findings.append("  \(label): stringUnit has no string value")
        }
        return findings
    }

    /// One language block's `stringSet`, checked the way ``stringUnitFindings(in:label:)``
    /// checks a `stringUnit`.
    ///
    /// Held to the same standard rather than waved through: an empty `values`, or one holding
    /// something that is not a string, is a Siri phrase list that silently loses a phrase —
    /// the shortcut still builds, still installs, and simply stops answering to one of the
    /// things the user was told to say.
    private static func stringSetFindings(in block: [String: Any], label: String) -> [String] {
        guard let set = block["stringSet"] as? [String: Any] else { return [] }
        var findings: [String] = []
        for field in set.keys where !Self.stringSetFields.contains(field) {
            findings.append("  \(label): unknown stringSet field \u{201C}\(field)\u{201D}")
        }
        if let state = set["state"] as? String, !Self.translationStates.contains(state) {
            findings.append("  \(label): unknown stringSet state \u{201C}\(state)\u{201D}")
        }
        guard let values = set["values"] as? [Any] else {
            findings.append("  \(label): stringSet has no values array")
            return findings
        }
        if values.isEmpty {
            findings.append("  \(label): stringSet values are empty")
        }
        for value in values where (value as? String)?.isEmpty ?? true {
            findings.append("  \(label): stringSet holds a value that is not a non-empty string")
        }
        return findings
    }

    private static func pluralFindings(in container: [String: Any], label: String) -> [String] {
        guard let variations = container["variations"] as? [String: Any] else { return [] }
        var findings: [String] = []
        for (dimension, rawCases) in variations {
            guard dimension == "plural" || dimension == "device" else {
                findings.append("  \(label): unknown variation dimension \u{201C}\(dimension)\u{201D}")
                continue
            }
            guard let cases = rawCases as? [String: Any] else {
                findings.append("  \(label): \(dimension) variations are not an object")
                continue
            }
            guard dimension == "plural" else { continue }
            if cases["other"] == nil {
                findings.append("""
                      \(label): plural variations with no \u{201C}other\u{201D} form. Every CLDR \
                    language uses `other`; without it the string has no fallback at all.
                    """)
            }
            for (category, rawCase) in cases {
                if !Self.pluralCategories.contains(category) {
                    findings.append("  \(label): \u{201C}\(category)\u{201D} is not a CLDR plural category")
                }
                guard let block = rawCase as? [String: Any] else {
                    findings.append("  \(label) .\(category): not an object")
                    continue
                }
                findings += Self.stringUnitFindings(in: block, label: "\(label) .\(category)")
            }
        }
        return findings
    }

    // MARK: - 2. Comments

    @Test("Every explicit key carries a translator comment")
    func everyExplicitKeyCarriesAComment() throws {
        var explicitKeys = 0
        var findings: [String] = []

        for catalog in LocalizationCatalogFixture.catalogs {
            for (key, entry) in try LocalizationCatalogFixture.load(catalog)
            where LocalizationKeyStyleGuardTests.looksLikeAnExplicitKey(key)
                && LocalizationKeyStyleGuardTests.notActuallyKeys[key] == nil {
                explicitKeys += 1
                let comment = (entry["comment"] as? String) ?? ""
                if comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    findings.append("  \(catalog.path)  \(key)")
                }
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) explicit key(s) reach the translator with no comment:
            \(findings.joined(separator: "\n"))

            A key is explicit precisely because the English alone is ambiguous, counted, or
            duplicated — that is the whole reason it was not left as English-as-key. Supply
            comment: at the call site (the compiler carries it into the catalog; hand-splicing it
            here is lost on the next extraction), then:
              python3 Translations/tools/sync_catalogs.py --apply
            """)
        // Measured 2026-07-26: 269 explicit keys.
        #expect(explicitKeys >= 240, """
            Only \(explicitKeys) explicit keys were recognised; there were 269 when this was
            written. The key-shape predicate has stopped matching what the code writes.
            """)
    }

    // MARK: - 3. Case variants

    @Test("No two bare keys differ only in case")
    func noUndocumentedCaseVariants() throws {
        var entriesExamined = 0
        var groupsWithVariants = 0
        var findings: [String] = []

        for catalog in LocalizationCatalogFixture.catalogs {
            var groups: [String: [(key: String, rendering: String)]] = [:]
            for (key, entry) in try LocalizationCatalogFixture.load(catalog) {
                entriesExamined += 1
                let rendering = LocalizationCatalogFixture.englishRendering(ofKey: key, entry: entry)
                groups[rendering.lowercased(), default: []].append((key, rendering))
            }

            for (_, members) in groups {
                guard Set(members.map(\.rendering)).count > 1 else { continue }
                groupsWithVariants += 1
                let bare = members
                    .filter { !LocalizationKeyStyleGuardTests.looksLikeAnExplicitKey($0.key) }
                    .map(\.rendering)
                    .sorted()
                guard bare.count > 1 else { continue }
                if Self.caseVariantsWithAReason[bare.joined(separator: " / ")] != nil { continue }
                findings.append("  \(catalog.path)  " + bare.map { "\u{201C}\($0)\u{201D}" }
                    .joined(separator: "  vs  "))
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) case-variant group(s) reach the translator as two anonymous jobs:
            \(findings.sorted().joined(separator: "\n"))

            These are usually a visible control label and its VoiceOver label — "Sync Now" on the
            button, "Sync now" spoken — and the difference is correct. But nothing in the catalog
            says so, and two entries reading the same word can come back with two different
            translations of one concept.

            Give the second variant an explicit key and a comment naming its surface, exactly as
            kanban.card.a11y.completed and widget.priority.short.high already do:
              .accessibilityLabel(String(localized: "tasks.a11y.addTask",
                                         defaultValue: "Add task",
                                         comment: "VoiceOver label for …"))
            """)
        #expect(entriesExamined >= 700,
                "Only \(entriesExamined) entries examined; there were 722 when this was written.")
        // Measured 2026-07-26: 16 groups hold more than one casing. If that reaches zero the
        // grouping is broken, not the catalog — nothing in this repo removes all of them.
        #expect(groupsWithVariants >= 12, """
            Only \(groupsWithVariants) case-variant groups were found; there were 16 when this was
            written, all of them legitimate control-vs-VoiceOver pairs. A scan that finds none is
            not grouping.
            """)
    }

    // MARK: - 4. Positional specifiers

    @Test("Every multi-argument key uses positional specifiers")
    func everyMultiArgumentKeyUsesPositionalSpecifiers() throws {
        var multiArgumentKeys = 0
        var findings: [String] = []
        var stillPending: Set<PendingPositional> = []

        for catalog in LocalizationCatalogFixture.catalogs {
            for (key, entry) in try LocalizationCatalogFixture.load(catalog) {
                let english = Self.rawEnglish(ofKey: key, entry: entry)
                let arguments = Self.formatArguments(in: english)
                guard arguments.count > 1 else { continue }
                multiArgumentKeys += 1

                let unpositioned = arguments.filter {
                    $0.position == nil && !$0.conversion.hasPrefix("#@")
                }
                guard !unpositioned.isEmpty else { continue }

                let pending = PendingPositional(catalog: catalog.path, key: key)
                if Self.pendingPositionalConversion.contains(pending) {
                    stillPending.insert(pending)
                    continue
                }
                findings.append("  \(catalog.path)  \(key)\n      \(english)")
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) multi-argument key(s) use bare specifiers:
            \(findings.sorted().joined(separator: "\n"))

            German and Dutch move the clauses. A translator cannot reorder %@ %@ — the arguments
            are consumed in source order — so the sentence has to be bent around the English word
            order or it is simply wrong. %1$@ %2$@ can be reordered freely.

            These are also exactly what an Xcode catalog rewrite converts, silently, inside a
            20,000-line diff. Converting them deliberately leaves it nothing to do.

            The value comes from Swift interpolation in defaultValue:, so it cannot be written
            positionally at the call site — rewrite the `en` value in the catalog. That is safe:
            sync_catalogs.py only adds keys and refreshes comments.
            """)

        let vanished = Self.pendingPositionalConversion.subtracting(stillPending)
        #expect(vanished.isEmpty, """
            \(vanished.count) entr(y/ies) in `pendingPositionalConversion` no longer describe a
            key that needs converting:
            \(vanished.map { "  \($0.catalog)  \($0.key)" }.sorted().joined(separator: "\n"))

            Either the key is gone or it has been converted. Delete the line — the list is
            allowed to shrink and nothing else. Leaving it here is how a backlog turns into
            decoration.
            """)
        // Measured 2026-07-26: 24 keys take more than one argument.
        #expect(multiArgumentKeys >= 20, """
            Only \(multiArgumentKeys) multi-argument keys were found; there were 24 when this was
            written. The format-argument scanner has stopped parsing.
            """)
    }

    /// Every **translated** value that takes two or more arguments must position them.
    ///
    /// The English half of this rule carries a three-key allowlist. This half carries none, and
    /// it is not an oversight: those three keys are English-as-key
    /// (`.accessibilityLabel("\(title), due \(date)")`), so their English cannot be positioned and
    /// their translations are the only place the ordering can be stated at all. German moves the
    /// clause. Dutch moves the clause. A translator who writes `%@` twice gets the arguments in
    /// **source** order regardless of where the words went, and the sentence still renders — with
    /// the date where the title belongs.
    ///
    /// Mixing a positional translation with a non-positional source string is legal and works
    /// — verified against a hand-authored catalog — which is exactly why nothing else
    /// catches this: there is no build error, no runtime warning, and no visible defect in
    /// English. The specifier-parity guard below does not catch it either — it compares the
    /// *multiset* of conversions, so `%@ %@` and `%2$@ %1$@` are identical to it by design.
    @Test("Every multi-argument translation uses positional specifiers")
    func everyTranslationUsesPositionalSpecifiers() throws {
        var valuesExamined = 0
        var multiArgumentValues = 0
        var findings: [String] = []

        for catalog in LocalizationCatalogFixture.catalogs {
            for (key, entry) in try LocalizationCatalogFixture.load(catalog) {
                for language in LocalizationCatalogFixture.translationLanguages {
                    for (slot, value) in Self.translatedValues(ofLanguage: language, entry: entry) {
                        valuesExamined += 1
                        let arguments = Self.formatArguments(in: value)
                        guard arguments.count > 1 else { continue }
                        multiArgumentValues += 1

                        let unpositioned = arguments.filter {
                            $0.position == nil && !$0.conversion.hasPrefix("#@")
                        }
                        guard !unpositioned.isEmpty else { continue }
                        findings.append("  \(catalog.path)  \(key)  [\(language)\(slot)]\n"
                                        + "      \(value)")
                    }
                }
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) translated value(s) take more than one argument without positioning:
            \(findings.sorted().joined(separator: "\n"))

            Write %1$@ / %2$@ / %2$lld. Bare specifiers bind in source order, so a translation
            that moves the clauses puts the wrong argument in the slot and renders cleanly while
            doing it. There is no allowlist here — we author these.
            """)
        // A floor, not the assertion. It exists so an empty catalog cannot report success; the
        // real assertion is `findings.isEmpty` above, and it is meaningless if nothing was read.
        // Measured 2026-07-26 after Phase 5: 3,765 translated values, 120 of them multi-argument.
        // ~90% of each, so the numbers can grow without touching this and cannot quietly collapse.
        #expect(valuesExamined >= 3_300, """
            Only \(valuesExamined) translated value(s) were read across \
            \(LocalizationCatalogFixture.catalogs.count) catalogs and \
            \(LocalizationCatalogFixture.translationLanguages.count) languages; there were 3,765 \
            when Phase 5 landed. Either the translations are gone or the walk stopped descending \
            into them — a scanner that examines nothing reports success.
            """)
        #expect(multiArgumentValues >= 100, """
            Only \(multiArgumentValues) translated value(s) take more than one argument; there \
            were 120 when Phase 5 landed. The whole check applies to those and to nothing else, \
            so if the format-argument scanner stops parsing, `findings` empties out and every \
            reordering defect passes.
            """)
    }

    /// Every stored value in one language block, labelled by where it sits.
    ///
    /// Reading only `stringUnit` is the trap this exists to avoid: a plural-varied entry has no
    /// `stringUnit` at all and a substituted one keeps its arguments *inside* the substitution,
    /// so a specifier check that reads the top level alone silently stops seeing the counted
    /// clause — which is the clause most likely to be reordered.
    static func translatedValues(ofLanguage language: String,
                                 entry: [String: Any]) -> [(slot: String, value: String)] {
        guard let localizations = entry["localizations"] as? [String: Any],
              let block = localizations[language] as? [String: Any] else { return [] }

        var out: [(slot: String, value: String)] = []
        if let unit = block["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            out.append((slot: "", value: value))
        }
        for slot in LocalizationCatalogFixture.pluralSlots(entry, language: language) {
            for (category, text) in slot.forms.sorted(by: { $0.key < $1.key }) {
                let name = slot.name.isEmpty ? category : "\(slot.name).\(category)"
                out.append((slot: " \(name)", value: text))
            }
        }
        return out
    }

    // MARK: - 5. Specifier parity

    @Test("Every translation takes the same arguments as its English")
    func everyTranslationCarriesTheSameFormatArguments() throws {
        var comparisons = 0
        var findings: [String] = []

        for catalog in LocalizationCatalogFixture.catalogs {
            for (key, entry) in try LocalizationCatalogFixture.load(catalog) {
                let english = Self.rawEnglish(ofKey: key, entry: entry)
                let expected = Self.argumentShape(of: english)

                for language in LocalizationCatalogFixture.translationLanguages {
                    let translated = Self.rawValue(ofLanguage: language, entry: entry)
                    guard let translated else { continue }
                    comparisons += 1
                    let actual = Self.argumentShape(of: translated)
                    guard actual != expected else { continue }
                    findings.append("""
                          \(catalog.path)  \(key)  [\(language)]
                              en: \(english)
                          \(language.padding(toLength: 6, withPad: " ", startingAt: 0)): \(translated)
                        """)
                }
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) translation(s) do not take the same arguments as their English:
            \(findings.sorted().joined(separator: "\n"))

            This is a crash, not a typo. String(format:) walks the argument list by specifier, so
            an extra %@ reads a pointer that was never passed and a missing one shifts every
            argument after it. Fix the translation; never "fix" it by changing the English.
            """)
        // One key (`Today`) carries all five languages until Phase 5 lands. That seed exists so
        // this comparison and the bundle guard are not scans over an empty set.
        #expect(comparisons >= 5, """
            \(comparisons) translated values were compared against their English. Below 5 not even
            the Phase 1 seed key is being read, and this test is proving nothing.
            """)
    }

    /// The multiset of arguments a format string takes, position-insensitive.
    ///
    /// Compared as a **sorted list of conversions**, not as the parsed argument list: reordering
    /// `%1$@ %2$@` into `%2$@ %1$@` is the entire point of positional specifiers and must not
    /// read as a mismatch.
    static func argumentShape(of text: String) -> [String] {
        formatArguments(in: text).map(\.conversion).sorted()
    }

    /// One language block's text **as the catalog stores it**, with `%#@name@` markers left
    /// standing.
    ///
    /// Deliberately *not* ``LocalizationCatalogFixture/englishRendering(ofKey:entry:)``. That
    /// helper splices each substitution's `other` form in where its marker sits, which is right
    /// for reading the sentence and wrong for reading its arguments: the splice writes the
    /// substitution's bare `formatSpecifier` and drops the `argNum` that positions it. Every one
    /// of the eleven substituted keys then looks unpositional, and the first run of
    /// ``everyMultiArgumentKeyUsesPositionalSpecifiers`` reported exactly that — eleven findings
    /// that were all already correct.
    static func rawValue(ofLanguage language: String, entry: [String: Any]) -> String? {
        guard let localizations = entry["localizations"] as? [String: Any],
              let block = localizations[language] as? [String: Any] else { return nil }
        if let unit = block["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            return value
        }
        let slots = LocalizationCatalogFixture.pluralSlots(entry, language: language)
        guard let whole = slots.first(where: { $0.name.isEmpty }) else { return nil }
        return whole.forms["other"] ?? whole.forms.sorted { $0.key < $1.key }.first?.value
    }

    /// The English a catalog entry stores, or the key when the entry is English-as-key.
    static func rawEnglish(ofKey key: String, entry: [String: Any]) -> String {
        rawValue(ofLanguage: "en", entry: entry) ?? key
    }

    // MARK: - 6. Shared keys

    @Test("A key in two catalogs says the same thing in both")
    func sharedKeysAreIdenticalInEveryCatalog() throws {
        var english: [String: [String: String]] = [:]      // key -> catalog -> rendering
        var shapes: [String: [String: String]] = [:]       // key -> catalog -> plural shape

        for catalog in LocalizationCatalogFixture.catalogs {
            for (key, entry) in try LocalizationCatalogFixture.load(catalog) {
                english[key, default: [:]][catalog.path] =
                    LocalizationCatalogFixture.englishRendering(ofKey: key, entry: entry)
                shapes[key, default: [:]][catalog.path] = Self.pluralShape(of: entry)
            }
        }

        var sharedKeys = 0
        var perBundle = 0
        var findings: [String] = []
        for (key, byCatalog) in english where byCatalog.count > 1 {
            sharedKeys += 1
            // A bundle-identity key is not a shared string. This test's whole premise is that
            // a key in two catalogs came from one piece of source compiled into two targets,
            // so the two targets had better agree. `CFBundleName` is the opposite: it names
            // the bundle it sits in, and the app and its widget are required to disagree —
            // "NowThis" against "NowThisWidget". Comparing them reported the app being
            // correctly named as a defect.
            if Self.perBundleIdentityKeys.contains(key) {
                perBundle += 1
                continue
            }
            if Set(byCatalog.values).count > 1 {
                findings.append("  \(key): " + byCatalog.sorted { $0.key < $1.key }
                    .map { "\($0.key) = \u{201C}\($0.value)\u{201D}" }.joined(separator: "  ·  "))
            }
            let shape = shapes[key] ?? [:]
            if Set(shape.values).count > 1 {
                findings.append("  \(key): plural shapes differ — " + shape.sorted { $0.key < $1.key }
                    .map { "\($0.key) = \($0.value.isEmpty ? "not plural" : $0.value)" }
                    .joined(separator: "  ·  "))
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) key(s) mean different things in different catalogs:
            \(findings.sorted().joined(separator: "\n"))

            An app extension resolves strings against its OWN Bundle.main, so a type under
            NowThis/Models/ — compiled into NowThisWidget as well — needs its key in both
            catalogs, with the same English and the same plural rules. Plural rules in particular
            do not propagate: authoring "one/other" in the app catalog leaves the widget rendering
            "1 tasks".
            """)
        // Both identity keys appear in the app catalog and the widget's. If this ever counts
        // more than two, the exemption above has been widened past names and is now switching
        // this test off for a string that two targets really do have to agree on.
        #expect(perBundle == 2, """
            \(perBundle) shared key(s) were exempted as bundle identity, not 2. The exemption
            covers \(Self.perBundleIdentityKeys.sorted().joined(separator: ", ")) and must not
            grow to cover copy.
            """)
        // Measured 2026-07-26: 61 keys appear in more than one catalog.
        #expect(sharedKeys >= 55, """
            Only \(sharedKeys) keys were found in more than one catalog; there were 61 when this
            was written. Shared-source extraction has stopped producing duplicates, which would
            mean a target stopped extracting.
            """)
    }

    /// A stable description of an entry's English plural shape: the slot names and the CLDR
    /// categories each carries. Empty for a non-plural entry.
    static func pluralShape(of entry: [String: Any]) -> String {
        LocalizationCatalogFixture.pluralSlots(entry)
            .map { "\($0.name.isEmpty ? "<whole>" : $0.name)[\($0.forms.keys.sorted().joined(separator: ","))]" }
            .sorted()
            .joined(separator: "+")
    }

    // MARK: - 7. Self-checks

    @Test("The format-argument scanner reads what it claims to")
    func formatArgumentSelfChecks() {
        func conversions(_ text: String) -> [String] {
            Self.formatArguments(in: text).map(\.description)
        }

        #expect(conversions("no arguments here").isEmpty)
        #expect(conversions("%@") == ["%@"])
        #expect(conversions("%lld") == ["%lld"])
        #expect(conversions("%1$@ then %2$@") == ["%1$@", "%2$@"])
        #expect(conversions("Added \"%@\" to %@.") == ["%@", "%@"])
        #expect(conversions("%1$@, %#@taskCount@") == ["%1$@", "%#@taskCount@"])
        #expect(conversions("Subtask level %lld, %@") == ["%lld", "%@"])

        // `%%` is an escaped percent and consumes no argument. Counting it turns "100%% done"
        // into a one-argument string and then fails parity against a translation spelling it
        // exactly the same way.
        #expect(conversions("100%% done").isEmpty)
        #expect(conversions("%lld%% of %@") == ["%lld", "%@"])

        // A width is not a position. `%2f` takes one unpositioned float; reading the 2 as an
        // argument index would let a genuinely unpositional string pass this file's central test.
        #expect(Self.formatArguments(in: "%2f").first?.position == nil)
        #expect(Self.formatArguments(in: "%2$f").first?.position == 2)

        // Length modifiers, longest first — `ll` must not read as two `l`s.
        #expect(conversions("%lld and %ld and %d") == ["%lld", "%ld", "%d"])

        // Parity is position-insensitive: reordering is what positional specifiers are *for*.
        #expect(Self.argumentShape(of: "%1$@ to %2$@") == Self.argumentShape(of: "%2$@ von %1$@"))
        #expect(Self.argumentShape(of: "%@ %@") != Self.argumentShape(of: "%@"))
        #expect(Self.argumentShape(of: "%lld") != Self.argumentShape(of: "%@"))
    }

    /// The distinction between a stored value and a rendered one, asserted directly rather than
    /// left to the floors.
    ///
    /// A floor catches a collapse, not a class going missing — reading the *rendered* English
    /// here made all eleven substituted keys look unpositional at once, and the count-based
    /// assertion below happily stayed green through it.
    @Test("Reading raw catalog values keeps substitution markers standing")
    func rawValueSelfChecks() {
        let substituted: [String: Any] = [
            "localizations": ["en": [
                "stringUnit": ["state": "translated", "value": "You have %#@taskCount@ in %2$@."],
                "substitutions": ["taskCount": [
                    "argNum": 1, "formatSpecifier": "lld",
                    "variations": ["plural": [
                        "one": ["stringUnit": ["state": "translated", "value": "%arg task"]],
                        "other": ["stringUnit": ["state": "translated", "value": "%arg tasks"]],
                    ]],
                ]],
            ]],
        ]

        let raw = Self.rawEnglish(ofKey: "k", entry: substituted)
        #expect(raw == "You have %#@taskCount@ in %2$@.")
        #expect(Self.formatArguments(in: raw).allSatisfy {
            $0.position != nil || $0.conversion.hasPrefix("#@")
        }, "A substituted key carries its argument index in `argNum`, so its marker counts as positioned.")

        // The rendered form is a different string on purpose, and using it here is the mistake
        // this check exists to prevent: the splice writes `%lld` and loses the argNum.
        let rendered = LocalizationCatalogFixture.englishRendering(ofKey: "k", entry: substituted)
        #expect(rendered == "You have %lld tasks in %2$@.")
        #expect(Self.formatArguments(in: rendered).contains { $0.position == nil })

        // English-as-key entries have no `en` block at all; the key is the English.
        #expect(Self.rawEnglish(ofKey: "Today", entry: [:]) == "Today")
        #expect(Self.rawValue(ofLanguage: "de", entry: [:]) == nil)

        // A whole-string plural has no stringUnit; `other` is the general phrasing.
        let plural: [String: Any] = ["localizations": ["en": ["variations": ["plural": [
            "one": ["stringUnit": ["state": "translated", "value": "%lld task"]],
            "other": ["stringUnit": ["state": "translated", "value": "%lld tasks"]],
        ]]]]]
        #expect(Self.rawEnglish(ofKey: "k", entry: plural) == "%lld tasks")
    }

    @Test("The schema scanner rejects known-bad entries")
    func schemaSelfChecks() {
        // Known-bad input, fed directly rather than planted in a catalog — the test target is
        // opted out of extraction precisely so these fixtures cannot become real catalog keys.
        let badState: [String: Any] = ["stringUnit": ["state": "reviewed", "value": "x"]]
        #expect(Self.stringUnitFindings(in: badState, label: "L").count == 1)

        let missingValue: [String: Any] = ["stringUnit": ["state": "translated"]]
        #expect(Self.stringUnitFindings(in: missingValue, label: "L").count == 1)

        let good: [String: Any] = ["stringUnit": ["state": "translated", "value": "x"]]
        #expect(Self.stringUnitFindings(in: good, label: "L").isEmpty)

        // `stringSet` is held to the same standard as `stringUnit`, or adding it to
        // `localizationFields` would have widened the schema rather than described it.
        let goodSet: [String: Any] = ["stringSet": ["state": "new", "values": ["a", "b"]]]
        #expect(Self.stringSetFindings(in: goodSet, label: "L").isEmpty)
        #expect(Self.stringSetFindings(in: good, label: "L").isEmpty)   // no stringSet at all

        let singularValue: [String: Any] = ["stringSet": ["state": "new", "value": "a"]]
        // Two findings: `value` is not a stringSet field, and `values` is missing.
        #expect(Self.stringSetFindings(in: singularValue, label: "L").count == 2)

        let emptySet: [String: Any] = ["stringSet": ["state": "new", "values": []]]
        #expect(Self.stringSetFindings(in: emptySet, label: "L").count == 1)

        let blankPhrase: [String: Any] = ["stringSet": ["state": "new", "values": ["a", ""]]]
        #expect(Self.stringSetFindings(in: blankPhrase, label: "L").count == 1)

        let badSetState: [String: Any] = ["stringSet": ["state": "extracted", "values": ["a"]]]
        #expect(Self.stringSetFindings(in: badSetState, label: "L").count == 1)

        let typoCategory: [String: Any] = ["variations": ["plural": [
            "one": ["stringUnit": ["state": "translated", "value": "1 task"]],
            "others": ["stringUnit": ["state": "translated", "value": "%lld tasks"]],
        ]]]
        // Two findings: `others` is not a category, and there is now no `other` form at all.
        #expect(Self.pluralFindings(in: typoCategory, label: "L").count == 2)

        let wellFormed: [String: Any] = ["variations": ["plural": [
            "one": ["stringUnit": ["state": "translated", "value": "1 task"]],
            "other": ["stringUnit": ["state": "translated", "value": "%lld tasks"]],
        ]]]
        #expect(Self.pluralFindings(in: wellFormed, label: "L").isEmpty)

        // A plural shape is compared across catalogs, so it has to distinguish these.
        let entry: [String: Any] = ["localizations": ["en": wellFormed]]
        #expect(Self.pluralShape(of: entry) == "<whole>[one,other]")
        #expect(Self.pluralShape(of: ["localizations": ["en": good]]).isEmpty)
    }
}
