import Foundation
import Testing

/// **The app ships no English string table.** The built bundle carries `de/es/fr/it/nl.lproj`
/// and no `en.lproj` — English is the development language, so Foundation never looks a key up
/// for it. English text comes from exactly two places:
///
/// - an **English-as-key** entry (`String(localized: "Today")`) — the key *is* the English;
/// - an **explicit key** (`String(localized: "sort.manually", defaultValue: "Manually", …)`) —
///   the English is the `defaultValue` argument, resolved at the call site, not from a table.
///
/// So an explicit key written **without** `defaultValue:` renders as the raw key to every
/// English user: `sort.manually` on screen where "Manually" belongs. It compiles, every other
/// guard stays green, and the catalog looks perfectly healthy — the entry is there, it just has
/// no English in it.
///
/// This was not hypothetical: `focus.allLists` shipped in exactly that state and was caught by
/// reading a sync diff, not by a test. Hence this test.
@Suite("Localization / key style")
struct LocalizationKeyStyleGuardTests {

    /// English-as-key strings that happen to be shaped like a dotted identifier. Each needs a
    /// reason, and each is asserted to still exist so the list cannot rot into decoration.
    ///
    /// The heuristic below cannot separate these structurally — `cloud.example.com` and
    /// `sort.manually` are the same shape — so they are named rather than guessed at.
    static let notActuallyKeys: [String: String] = [
        "cloud.example.com":
            "Sample server address shown as a text-field placeholder in account setup. "
            + "TRANSLATION.md §2 marks sample values do-not-translate.",
    ]

    /// A dotted lowerCamel identifier — the shape this project uses for explicit keys.
    /// English-as-key entries never match: real English contains spaces, or is a single word
    /// with no dot.
    static func looksLikeAnExplicitKey(_ key: String) -> Bool {
        guard !key.isEmpty, !key.contains(" "), key.contains(".") else { return false }
        // "3 Months", "%@ – %@", "e.g. Work" and sentence-final periods must not match.
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.first else { return false }
            return first.isLowercase && part.allSatisfy { $0.isLetter || $0.isNumber }
        }
    }

    @Test("Every explicit key carries its English")
    func everyExplicitKeyHasAnEnglishValue() throws {
        var explicitKeys = 0
        var findings: [String] = []

        for catalog in LocalizationCatalogFixture.catalogs {
            for (key, entry) in try LocalizationCatalogFixture.load(catalog)
            where Self.looksLikeAnExplicitKey(key) && Self.notActuallyKeys[key] == nil {
                explicitKeys += 1
                let english = LocalizationCatalogFixture.englishRendering(ofKey: key, entry: entry)
                if english == key {
                    findings.append("  \(catalog.path)  \(key)")
                }
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) explicit key(s) have no English value, so English users see the key:
            \(findings.joined(separator: "\n"))

            Supply defaultValue: at the call site —
              String(localized: "some.key", defaultValue: "Some Text", comment: "…")
              LocalizedStringResource("some.key", defaultValue: "Some Text", comment: "…")
            — then re-run: python3 Translations/tools/sync_catalogs.py --apply
            """)

        // Anti-vacuity with teeth: Phase 2a alone introduced 43 explicit keys. A regex that
        // stopped matching would otherwise report a clean bill of health over nothing.
        #expect(explicitKeys >= 40, """
            Only \(explicitKeys) explicit keys were recognised across all catalogs; expected at
            least 40. The key-shape test is not matching what the code writes.
            """)
    }

    /// An allowlist entry naming a string that is no longer in any catalog is a guard that has
    /// quietly stopped guarding something.
    /// A key with **no words in it** — `""`, `%@`, `%lld`, `%@%@`, `%lldm`, `%lld/%lld`.
    ///
    /// These are what a bare interpolation extracts to: `Text("\(count)")` produces the key
    /// `%lld`, and *every* bare count badge in the app collapses into that one entry. A
    /// translator opening the catalog sees a format specifier and nothing else — no sentence, no
    /// context, and no way to tell which of fourteen screens it belongs to. The empty key is
    /// worse: one entry shared by every empty string.
    ///
    /// Almost all of them **resolve by deletion rather than translation**, and the replacement is
    /// more correct than the original: `Text(count, format: .number)` applies the locale's digits
    /// and grouping separator, `.percent` puts the sign where the language puts it, and
    /// `Measurement` gets the unit spacing right. `"\(count)"` does none of that *and* creates a
    /// catalog entry nobody can act on.
    static func hasNoTranslatableWords(_ key: String) -> Bool {
        var letters = 0
        var index = key.startIndex
        while index < key.endIndex {
            let character = key[index]
            if character == "%" {
                // Skip the whole specifier, including its length modifiers, so `lld` in `%lld`
                // is not mistaken for a word.
                index = key.index(after: index)
                while index < key.endIndex,
                      key[index].isNumber || key[index] == "$" || key[index] == "#"
                        || key[index] == "@" || "lhqzjt".contains(key[index]) {
                    index = key.index(after: index)
                }
                if index < key.endIndex, "diufgeGEs@%".contains(key[index]) {
                    index = key.index(after: index)
                }
                continue
            }
            if character.isLetter { letters += 1 }
            index = key.index(after: index)
        }
        return letters < 2
    }

    @Test("No catalog key is empty or made only of format specifiers")
    func noDegenerateKeys() throws {
        var examined = 0
        var findings: [String] = []

        for ref in LocalizationCatalogFixture.catalogs {
            for (key, _) in try LocalizationCatalogFixture.load(ref) {
                examined += 1
                if Self.hasNoTranslatableWords(key) {
                    findings.append("  \(ref.path)  \(key.isEmpty ? "<empty key>" : key)")
                }
            }
        }

        #expect(examined >= 600, """
            Only \(examined) keys examined across \(LocalizationCatalogFixture.catalogs.count) \
            catalogs; there were 700 when this was written.
            """)
        #expect(findings.isEmpty, """
            \(findings.count) catalog key(s) contain nothing a translator can act on:
            \(findings.joined(separator: "\n"))

            These come from bare interpolations at render sites, and unrelated sites collapse into
            one entry. Resolve by deletion: `Text(count, format: .number)`, `.percent`,
            `Measurement`, or `Text(verbatim:)` — all of which create no key and are more correct
            than string interpolation, which ignores the locale's digits and separators. Where the
            string does carry a word, give it an explicit key and a comment.
            """)
    }

    @Test("The not-a-key allowlist has not rotted")
    func allowlistEntriesStillExist() throws {
        var present: Set<String> = []
        for catalog in LocalizationCatalogFixture.catalogs {
            present.formUnion(try LocalizationCatalogFixture.load(catalog).keys)
        }
        for (key, reason) in Self.notActuallyKeys {
            #expect(present.contains(key), """
                Allowlist rot: \u{201C}\(key)\u{201D} is no longer in any catalog.
                Recorded reason was: \(reason)
                Remove the entry.
                """)
        }
    }

    @Test("Degenerate-key detection self-checks")
    func degenerateKeySelfChecks() {
        // Degenerate — nothing to translate.
        #expect(Self.hasNoTranslatableWords(""))
        #expect(Self.hasNoTranslatableWords("%@"))
        #expect(Self.hasNoTranslatableWords("%lld"))
        #expect(Self.hasNoTranslatableWords("%@%@"))
        #expect(Self.hasNoTranslatableWords("%lld/%lld"))
        #expect(Self.hasNoTranslatableWords("%lld%%"))
        #expect(Self.hasNoTranslatableWords("%1$@ – %2$@"))

        // Not degenerate — each carries a word a translator must render.
        #expect(!Self.hasNoTranslatableWords("%lld tasks"))
        #expect(!Self.hasNoTranslatableWords("%lldm radius"))
        #expect(!Self.hasNoTranslatableWords("Due %@"))
        #expect(!Self.hasNoTranslatableWords("tasks.row.a11y.subtaskCount"))
        // The `lld` inside a specifier must not be counted as a word — this is the check that
        // separates `%lld` from `%lld tasks`, and getting it wrong silently exempts everything.
        #expect(Self.hasNoTranslatableWords("%lld%lld"))
    }

    @Test("Key-shape self-checks")
    func keyShapeSelfChecks() {
        // Explicit keys.
        #expect(Self.looksLikeAnExplicitKey("sort.manually"))
        #expect(Self.looksLikeAnExplicitKey("filter.comparison.notEquals"))
        #expect(Self.looksLikeAnExplicitKey("watch.smartlist.all"))
        #expect(Self.looksLikeAnExplicitKey("recovery.list.name"))

        // English-as-key entries, which legitimately have no `en` block.
        #expect(!Self.looksLikeAnExplicitKey("Today"))
        #expect(!Self.looksLikeAnExplicitKey("All Tasks"))
        #expect(!Self.looksLikeAnExplicitKey(""))
        #expect(!Self.looksLikeAnExplicitKey("%@"))
        #expect(!Self.looksLikeAnExplicitKey("Tasks must match ALL rules."))
        #expect(!Self.looksLikeAnExplicitKey("e.g. Work"))
        #expect(!Self.looksLikeAnExplicitKey("https://..."))
        #expect(!Self.looksLikeAnExplicitKey("Sync History"))
    }
}
