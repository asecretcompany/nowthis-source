import CryptoKit
import Foundation
import Testing

/// A translation is only correct with respect to the English it was translated from.
///
/// Reword the English and Xcode leaves every translation in place and marks nothing. The German
/// still renders; it is now a translation of a sentence the app no longer says. That failure is
/// invisible in English, invisible in review, and invisible in `git diff` when it arrives inside a
/// catalog rewrite — which is how it arrived here: the English had moved out from under 35
/// translations, every other guard was green, and the change was buried in a 19,700-line diff.
///
/// So every translated key records a digest of the English it was made from, in
/// `Translations/english-hashes.json`, written by `Translations/tools/english_hashes.py --write`.
/// This guard compares that record against the English in the catalogs today.
///
/// ### Two halves, and this one is deliberately the smaller
///
/// Ported as-is, this guard examines **zero** NowThis keys and passes green forever.
/// Its walk skips any entry with no explicit `en` block, and 426 of this repository's 653 keys are
/// English-as-key (`String(localized: "Today")`) — the key *is* the English, so there is no `en`
/// block to read. In the prior project the same skip silently dropped 850 of 1,051 translated keys.
///
/// The plan's fix was to fall back to the catalog key. That is what
/// ``LocalizationCatalogFixture/englishRendering(ofKey:entry:)`` does, and it is right for reading
/// a sentence — but recording `sha256(key)` for a key that *is* its own English produces a row
/// that cannot ever fail to match itself. 426 rows of decoration, and a coverage number that
/// reads like protection.
///
/// The real division of labour, which is what this guard implements:
///
/// - **Explicit key** (`String(localized: "sort.manually", defaultValue: "Manually", …)`) — the
///   English lives in an `en` block, it can be reworded without the key moving, and nothing else
///   would notice. **This guard's job.**
/// - **English-as-key** — rewording the English edits the Swift literal, which *renames the key*.
///   The old key vanishes and `LocalizedLiteralArrivalGuard` fails on a source line asking for a
///   key no catalog has. **That guard's job**, and it has teeth today.
/// - **An `en` block appearing on a key that never had one** — the one way an English-as-key entry
///   can drift. It becomes tracked, it has no record, and the missing-record arm below fires.
///
/// ### What is dormant, stated plainly
///
/// Zero keys are tracked as of this commit, because the only translated key in the tree is
/// English-as-key. The hash-comparison arm therefore examines nothing and a green run is **not**
/// evidence it works — the falsification cases in this file are. It grows teeth automatically as
/// Phase 5 lands translations on explicitly-keyed entries.
///
/// Deliberately **not** here: a `translated > 0` floor. On an English-as-key catalog that is
/// structurally red, so it would be deleted within a week and take the real assertions with it.
/// The accounting identity below is the floor instead, and it holds at every count including zero.
@Suite("Localization / staleness")
struct LocalizationStalenessGuardTests {

    // MARK: - Digest, mirrored from english_hashes.py

    /// The English a translator worked from, in every catalog form, or `nil` when the key is its
    /// own English.
    ///
    /// **Byte-for-byte identical to `english_hashes.py:english_of`.** The two halves hash the same
    /// text or the guard is noise: Python writes the record, Swift checks it. Every detail here is
    /// load-bearing —
    ///
    /// - the single-`stringUnit`-and-no-substitutions shortcut returns the bare value, *not* a
    ///   `template=` prefix;
    /// - `variations` sort before `substitutions`, both by name, cases by name inside;
    /// - parts join with one space;
    /// - a `stringUnit` with no `value` contributes the literal text `None`, because Python's
    ///   `str(None)` does. It is unreachable through Xcode and reproduced anyway: the moment the
    ///   two implementations disagree about an edge case, every digest after it disagrees too.
    static func englishComposition(of entry: [String: Any]) -> String? {
        guard let localizations = entry["localizations"] as? [String: Any],
              let english = localizations["en"] as? [String: Any] else { return nil }

        let unit = english["stringUnit"] as? [String: Any]
        let substitutions = english["substitutions"] as? [String: Any]
        if unit != nil, substitutions == nil {
            return value(of: unit)
        }

        var parts: [String] = []
        if let unit { parts.append("template=" + (value(of: unit) ?? "None")) }

        for (kind, cases) in sortedPairs(english["variations"]) {
            for (name, body) in sortedPairs(cases) {
                parts.append("\(kind).\(name)=" + (value(of: stringUnit(of: body)) ?? "None"))
            }
        }
        for (name, body) in sortedPairs(substitutions) {
            for (kind, cases) in sortedPairs((body as? [String: Any])?["variations"]) {
                for (caseName, inner) in sortedPairs(cases) {
                    parts.append("sub.\(name).\(kind).\(caseName)="
                                 + (value(of: stringUnit(of: inner)) ?? "None"))
                }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// `sorted(dict.items())` — key order only, which is all `english_of` relies on. Plural
    /// categories, variation kinds and substitution names are ASCII, so Swift's `<` and Python's
    /// agree.
    private static func sortedPairs(_ any: Any?) -> [(String, Any)] {
        guard let dictionary = any as? [String: Any] else { return [] }
        return dictionary.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private static func stringUnit(of body: Any) -> [String: Any]? {
        (body as? [String: Any])?["stringUnit"] as? [String: Any]
    }

    private static func value(of unit: [String: Any]?) -> String? {
        unit?["value"] as? String
    }

    /// `hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]`.
    static func digest(_ text: String) -> String {
        let hex = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return String(hex.prefix(16))
    }

    // MARK: - The record

    struct RecordedRow {
        let english: String
        let languages: [String]
    }

    static let hashesPath = "Translations/english-hashes.json"

    /// `catalog path -> key -> row`, as `english_hashes.py --write` leaves it.
    static func recordedRows() throws -> [String: [String: RecordedRow]] {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let url = root.appendingPathComponent(hashesPath)
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw LocalizationFixtureError.fileUnreadable(
                path: hashesPath,
                underlying: "\(error) — run `python3 Translations/tools/english_hashes.py --write`")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalizationFixtureError.fileUnreadable(path: hashesPath,
                                                          underlying: "not a JSON object")
        }
        var out: [String: [String: RecordedRow]] = [:]
        for (catalog, rows) in object {
            guard let rows = rows as? [String: Any] else {
                throw LocalizationFixtureError.fileUnreadable(
                    path: hashesPath, underlying: "\(catalog) does not map to an object")
            }
            var parsed: [String: RecordedRow] = [:]
            for (key, row) in rows {
                guard let row = row as? [String: Any],
                      let english = row["english"] as? String,
                      let languages = row["languages"] as? [String] else {
                    throw LocalizationFixtureError.fileUnreadable(
                        path: hashesPath, underlying: "\(catalog) / \(key) is not {english, languages}")
                }
                parsed[key] = RecordedRow(english: english, languages: languages)
            }
            out[catalog] = parsed
        }
        return out
    }

    /// Non-`en` languages the entry carries a localization block for.
    static func translatedLanguages(of entry: [String: Any]) -> [String] {
        guard let localizations = entry["localizations"] as? [String: Any] else { return [] }
        return localizations.keys.filter { $0 != "en" }.sorted()
    }

    // MARK: - 1. The walk

    @Test("Every translation records the English it was made from",
          .enabled(if: LocalizationCatalogFixture.repositoryFileExists(LocalizationStalenessGuardTests.hashesPath)))
    func everyTranslationRecordsTheEnglishItWasMadeFrom() throws {
        let recorded = try Self.recordedRows()

        var catalogsWalked = 0
        var entriesWalked = 0
        var keysWithAnyTranslation = 0
        var tracked = 0
        var selfDescribing = 0
        var findings: [String] = []

        for catalog in LocalizationCatalogFixture.catalogs {
            catalogsWalked += 1
            let rows = recorded[catalog.path] ?? [:]

            for (key, entry) in try LocalizationCatalogFixture.load(catalog) {
                entriesWalked += 1
                let languages = Self.translatedLanguages(of: entry)
                guard !languages.isEmpty else { continue }
                keysWithAnyTranslation += 1

                guard let english = Self.englishComposition(of: entry) else {
                    selfDescribing += 1
                    continue
                }
                tracked += 1

                guard let row = rows[key] else {
                    findings.append("  \(catalog.path)  \(key)  — translated into "
                                    + "\(languages.joined(separator: ", ")) with no recorded English")
                    continue
                }
                let live = Self.digest(english)
                if row.english != live {
                    findings.append("  \(catalog.path)  \(key)  — the English moved since the "
                                    + "translations were checked\n      recorded \(row.english), "
                                    + "now \(live)\n      now reads: \(english)")
                } else if row.languages != languages {
                    findings.append("  \(catalog.path)  \(key)  — recorded languages "
                                    + "\(row.languages.joined(separator: ", ")) but the catalog "
                                    + "carries \(languages.joined(separator: ", "))")
                }
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) translation(s) no longer match the English they were made from:
            \(findings.sorted().joined(separator: "\n"))

            Re-read those translations against the English as it now reads, fix the ones that no
            longer say it, and only then run:
              python3 Translations/tools/english_hashes.py --write

            `--write` means "these translations have been re-checked against this English".
            Running it to clear this failure without reading them is the one way to make the
            record worse than useless.
            """)

        // The accounting identity, computed in the same walk. This is the anti-vacuity floor and
        // it holds at every count including zero — unlike a `tracked > 0` floor, which on an
        // English-as-key catalog is structurally red and gets deleted rather than fixed.
        #expect(tracked + selfDescribing == keysWithAnyTranslation, """
            \(tracked) tracked + \(selfDescribing) self-describing != \
            \(keysWithAnyTranslation) keys with a translation.

            Every translated key is one or the other. A key that is neither means the walk stopped
            classifying — which is how this guard silently narrows to nothing.
            """)
        #expect(catalogsWalked == LocalizationCatalogFixture.catalogs.count,
                "Walked \(catalogsWalked) of \(LocalizationCatalogFixture.catalogs.count) catalogs.")
        let floor = LocalizationCatalogFixture.catalogs.reduce(0) { $0 + $1.keyFloor }
        #expect(entriesWalked >= floor, """
            Only \(entriesWalked) catalog entries were read; the seven catalogs hold at least \
            \(floor). A guard that reads nothing reports success.
            """)
    }

    // MARK: - 2. Records that outlived their keys

    @Test("Nothing is recorded for a key that no longer has one",
          .enabled(if: LocalizationCatalogFixture.repositoryFileExists(LocalizationStalenessGuardTests.hashesPath)))
    func everyRecordDescribesALiveTrackedKey() throws {
        let recorded = try Self.recordedRows()

        var liveTracked: Set<String> = []
        for catalog in LocalizationCatalogFixture.catalogs {
            for (key, entry) in try LocalizationCatalogFixture.load(catalog) {
                guard !Self.translatedLanguages(of: entry).isEmpty,
                      Self.englishComposition(of: entry) != nil else { continue }
                liveTracked.insert("\(catalog.path)\u{0}\(key)")
            }
        }

        var recordCount = 0
        var stale: [String] = []
        for (catalog, rows) in recorded {
            for key in rows.keys {
                recordCount += 1
                if !liveTracked.contains("\(catalog)\u{0}\(key)") {
                    stale.append("  \(catalog)  \(key)")
                }
            }
        }

        #expect(stale.isEmpty, """
            \(stale.count) recorded row(s) describe a key that is no longer tracked:
            \(stale.sorted().joined(separator: "\n"))

            The key was deleted, its translations were removed, or it was renamed — which is what
            rewording an English-as-key string does. Re-run `english_hashes.py --write` after
            confirming the surviving translations are still right.
            """)
        #expect(recordCount == liveTracked.count, """
            \(recordCount) recorded rows for \(liveTracked.count) tracked keys. The record and the
            catalogs have to describe the same set, or `--write` was not run after the last change.
            """)
    }

    // MARK: - 3. The digest, falsified in-suite

    /// The case the whole design turns on, and the one a naive implementation gets wrong.
    ///
    /// A plural entry's *singular* form is not what `englishRendering` returns — that returns the
    /// `other` form, because it is the general phrasing. Digest the rendering instead of the whole
    /// entry and rewriting "1 task" to "one task" leaves the record matching while five languages
    /// go stale on a form only reachable at exactly one item.
    @Test("Changing only a plural singular changes the digest")
    func theDigestChangesWhenOnlyAPluralSingularChanges() {
        func entry(singular: String) -> [String: Any] {
            ["localizations": ["en": [
                "stringUnit": ["state": "new", "value": "%1$@, %#@taskCount@"],
                "substitutions": ["taskCount": [
                    "argNum": 2, "formatSpecifier": "lld",
                    "variations": ["plural": [
                        "one": ["stringUnit": ["state": "new", "value": singular]],
                        "other": ["stringUnit": ["state": "new", "value": "%arg tasks"]]]]]]]]]
        }

        let before = LocalizationStalenessGuardTests.englishComposition(of: entry(singular: "%arg task"))
        let after = LocalizationStalenessGuardTests.englishComposition(of: entry(singular: "%arg item"))

        #expect(before != nil && after != nil, "The composition returned nil for a plural entry.")
        #expect(Self.digest(before ?? "") != Self.digest(after ?? ""), """
            The digest did not move when the plural singular did. It is being computed from the
            rendered sentence rather than the whole entry, and every singular-only rewording will
            pass unnoticed.
            """)
        // The `other` form still reads the same, so a rendering-based digest would be unchanged —
        // which is exactly what this proves is not happening.
        #expect(before?.contains("%arg tasks") == true && after?.contains("%arg tasks") == true)
    }

    // MARK: - 4. Agreement with the Python half

    /// Two constants, computed by `english_hashes.py` and pasted here. Python writes the record and
    /// Swift checks it, so a difference between the two implementations makes every row a false
    /// finding — or, worse, makes a real one match. Neither half computing these from the other is
    /// the point.
    @Test("The digest agrees with english_hashes.py")
    func theDigestMatchesThePythonTool() {
        #expect(Self.digest("Added \"%1$@\" to %2$@.") == "9d9ca4eb389a2fe8")
        #expect(Self.digest(
            "template=%1$@, %#@taskCount@ sub.taskCount.plural.one=%arg task "
            + "sub.taskCount.plural.other=%arg tasks") == "8baeeaf5bf2b2a95")
    }

    /// Checked separately from the digest so a composition change fails readably instead of as two
    /// hex strings that differ.
    @Test("The composition agrees with english_hashes.py")
    func theCompositionMatchesThePythonTool() {
        let substituted: [String: Any] = ["localizations": ["en": [
            "stringUnit": ["state": "new", "value": "%1$@, %#@taskCount@"],
            "substitutions": ["taskCount": [
                "argNum": 2, "formatSpecifier": "lld",
                "variations": ["plural": [
                    "one": ["stringUnit": ["state": "new", "value": "%arg task"]],
                    "other": ["stringUnit": ["state": "new", "value": "%arg tasks"]]]]]]]]]
        #expect(Self.englishComposition(of: substituted)
                == "template=%1$@, %#@taskCount@ sub.taskCount.plural.one=%arg task "
                   + "sub.taskCount.plural.other=%arg tasks")

        // A plain entry returns the bare value — no `template=` prefix. Getting this wrong changes
        // every ordinary key's digest at once, which reads as "the whole catalog drifted".
        let plain: [String: Any] = ["localizations": ["en": [
            "stringUnit": ["state": "new", "value": "Added \"%1$@\" to %2$@."]]]]
        #expect(Self.englishComposition(of: plain) == "Added \"%1$@\" to %2$@.")

        // English-as-key: no `en` block, nothing to record.
        #expect(Self.englishComposition(of: [:]) == nil)
        #expect(Self.englishComposition(of: ["localizations": ["de": [
            "stringUnit": ["state": "translated", "value": "Heute"]]]]) == nil)

        // Whole-string plural, no substitutions — the `template=` branch with no template.
        let wholePlural: [String: Any] = ["localizations": ["en": [
            "variations": ["plural": [
                "one": ["stringUnit": ["state": "new", "value": "%lld task"]],
                "other": ["stringUnit": ["state": "new", "value": "%lld tasks"]]]]]]]
        #expect(Self.englishComposition(of: wholePlural)
                == "plural.one=%lld task plural.other=%lld tasks")
    }
}
