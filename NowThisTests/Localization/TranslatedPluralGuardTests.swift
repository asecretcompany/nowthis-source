import Foundation
import Testing

/// `PluralRuleGuardTests` checks the **English** side: that every count-bearing
/// key is registered, that its English forms differ, and that they resolve at
/// runtime. All of that stays green while a translation quietly does no
/// pluralising at all.
///
/// Phase 6's blind back-translation found the gap. Italian shipped
/// `intent.dialog.showTasks.truncated` with `one` and `other` both `"%arg"`
/// against a base template reading `"… e altre %#@remaining@."`, so the
/// agreeing word sat outside the substitution and one remaining task made Siri
/// say *"e altre 1"*. Every existing guard was green: the English forms are
/// distinct, the key is registered, and the runtime probe resolves the English.
///
/// This guard watches the translated side. Two identical plural cases mean the
/// substitution does nothing, which is correct only when the noun really is
/// invariant in that language — Italian *attività* and *sottoattività* are the
/// same word in both numbers. So the exemption list records **what is right**,
/// naming the language and the invariant word, rather than listing what was
/// once wrong.
@Suite("Localization / translated plurals")
struct TranslatedPluralGuardTests {

    /// A plural substitution whose cases are legitimately byte-identical,
    /// because every word in them takes the same form after 1 and after n.
    ///
    /// Matched on the **exact** case value rather than on a contained noun.
    /// The first draft of this guard matched a substring and was wrong about
    /// its own subject: the identical forms in these catalogs are mostly not
    /// nouns at all but invariable adverbs, so a noun list exempted nothing
    /// and the guard reported eight correct strings as defects.
    struct InvariantPlural: Hashable {
        let language: String
        /// The case value, verbatim and identical across every category.
        let value: String
        /// Why this one does not need to inflect. Not decoration — an
        /// exemption nobody can justify is an exemption nobody should keep.
        let reason: String
    }

    static let invariantPlurals: Set<InvariantPlural> = [
        .init(language: "it", value: "%arg attività",
              reason: "Italian -tà nouns are invariant: una attività / due attività"),
        .init(language: "es", value: "%arg más",
              reason: "más is an invariable adverb: 1 más / 3 más"),
        .init(language: "fr", value: "%arg de plus",
              reason: "de plus is invariable: 1 de plus / 3 de plus"),
        .init(language: "nl", value: "nog %arg",
              reason: "nog is an invariable adverb: nog 1 / nog 3"),
        .init(language: "de", value: "%arg weitere",
              reason: "weitere carries the same ending after 1 and after n"),
    ]

    static func isExempt(language: String, value: String) -> Bool {
        invariantPlurals.contains { $0.language == language && $0.value == value }
    }

    @Test("No translated plural substitution is inert")
    func noTranslatedPluralIsInert() throws {
        var substitutionsExamined = 0
        var catalogsWalked = 0
        var findings: [String] = []

        for catalog in LocalizationCatalogFixture.catalogs {
            catalogsWalked += 1
            for (key, entry) in try LocalizationCatalogFixture.load(catalog) {
                guard let localizations = entry["localizations"] as? [String: Any] else { continue }
                for language in LocalizationCatalogFixture.translationLanguages {
                    guard let block = localizations[language] as? [String: Any],
                          let substitutions = block["substitutions"] as? [String: Any]
                    else { continue }

                    for (name, body) in substitutions {
                        guard let body = body as? [String: Any],
                              let variations = body["variations"] as? [String: Any],
                              let plural = variations["plural"] as? [String: Any]
                        else { continue }

                        var values: [String: String] = [:]
                        for (category, form) in plural {
                            guard let form = form as? [String: Any],
                                  let unit = form["stringUnit"] as? [String: Any],
                                  let value = unit["value"] as? String
                            else { continue }
                            values[category] = value
                        }
                        guard values.count > 1 else { continue }
                        substitutionsExamined += 1

                        let distinct = Set(values.values)
                        guard distinct.count == 1, let only = distinct.first else { continue }
                        guard !Self.isExempt(language: language, value: only) else { continue }

                        findings.append("""
                              \(catalog.path)  \(key)
                                  [\(language)] substitution \(name): every case is "\(only)"
                                  the plural does nothing — any word that must agree with the
                                  count is sitting outside the substitution
                            """)
                    }
                }
            }
        }

        #expect(catalogsWalked == LocalizationCatalogFixture.catalogs.count,
                "walked \(catalogsWalked) catalogs, expected \(LocalizationCatalogFixture.catalogs.count)")
        #expect(substitutionsExamined >= 50, """
            only \(substitutionsExamined) translated plural substitutions examined; \
            55 existed when this guard was written. A scanner that examines nothing \
            reports success.
            """)
        #expect(findings.isEmpty, """
            \(findings.count) translated plural substitution(s) do no pluralising:

            \(findings.sorted().joined(separator: "\n"))
            """)
    }

    @Test("The exemption list describes forms that are actually in the catalogs")
    func exemptionsStillApply() throws {
        var stillPresent: Set<InvariantPlural> = []
        var valuesScanned = 0

        for catalog in LocalizationCatalogFixture.catalogs {
            for (_, entry) in try LocalizationCatalogFixture.load(catalog) {
                guard let localizations = entry["localizations"] as? [String: Any] else { continue }
                for language in LocalizationCatalogFixture.translationLanguages {
                    guard let block = localizations[language] as? [String: Any],
                          let substitutions = block["substitutions"] as? [String: Any]
                    else { continue }
                    for (_, body) in substitutions {
                        guard let body = body as? [String: Any],
                              let variations = body["variations"] as? [String: Any],
                              let plural = variations["plural"] as? [String: Any] else { continue }
                        for (_, form) in plural {
                            guard let form = form as? [String: Any],
                                  let unit = form["stringUnit"] as? [String: Any],
                                  let value = unit["value"] as? String else { continue }
                            valuesScanned += 1
                            for candidate in Self.invariantPlurals
                            where candidate.language == language && candidate.value == value {
                                stillPresent.insert(candidate)
                            }
                        }
                    }
                }
            }
        }

        #expect(valuesScanned > 0, "scanned no plural values at all — the walk did not start")
        #expect(!Self.invariantPlurals.isEmpty, "the exemption list emptied out — that is not a pass")
        let stale = Self.invariantPlurals.subtracting(stillPresent)
        let staleList = stale.map { "  \($0.language): \($0.value)" }.sorted().joined(separator: "\n")
        #expect(stale.isEmpty, """
            \(stale.count) exemption(s) name a form no catalog uses any more, so they are \
            excusing nothing and would silently excuse the wrong thing later:
            \(staleList)
            """)
    }

    @Test("The exemption check can tell an invariant noun from an inert plural")
    func exemptionHelperSelfCheck() {
        #expect(Self.isExempt(language: "it", value: "%arg attività"))
        #expect(Self.isExempt(language: "es", value: "%arg más"))
        // The real defect this guard exists for: no noun at all, just the count.
        #expect(!Self.isExempt(language: "it", value: "%arg"))
        // Same word, wrong language — Spanish `tarea` does inflect.
        #expect(!Self.isExempt(language: "es", value: "%arg attività"))
        #expect(!Self.isExempt(language: "de", value: "%arg Aufgabe"))
    }
}
