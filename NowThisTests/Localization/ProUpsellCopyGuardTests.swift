import Foundation
import Testing

/// The NowThis Supporter section in Settings is the last screen read before paying, and its **order** is
/// the message. It used to open with a feature name — "Apple Watch editing" — so the section read
/// as a list of what you get. It now opens with the ask: *why* the purchase exists. The feature
/// list still follows, and the no-ads/no-tracking line still closes.
///
/// Nothing else can hold that. `LocalizationCompletenessGuardTests` counts translations and cannot
/// see which line is first; `ViewCopyGuardTests` checks that copy reaches a catalog and not what
/// the copy says; `StoreProductGuardTests` reads the `.storekit` metadata, which is a different
/// artifact two taps away. Re-ordering these three lines, or re-wording the first one, is a silent
/// change to a paid conversion under every other guard in this suite.
@Suite("Supporter purchase copy")
struct ProUpsellCopyGuardTests {

    static let source = "NowThis/Views/Settings/ProUpsellView.swift"

    /// The section's copy, in the order it must render.
    static let copyOrder = ["pro.support.title", "pro.ios.body", "pro.watch.body", "pro.artwork.body", "pro.legacy.body", "pro.support.body"]

    /// Pinned because it is the sentence that was signed off, not because the words are
    /// structurally special. A change here is a decision; a change here by accident is a bug.
    static let ask = "Help support continued development"

    @Test func permanentPromisesAreExplicitAndTranslated() throws {
        let catalog = try #require(LocalizationCatalogFixture.catalogs.first { $0.path == "NowThis/Localizable.xcstrings" })
        let strings = try LocalizationCatalogFixture.load(catalog)
        let expected = [
            "pro.ios.body": "All iOS productivity features, including future additions, are included with the app. Supporter is an optional way to support continued development.",
            "pro.watch.body": "Viewing tasks and using complications on Apple Watch are always free. Supporter adds checking off and adding tasks on Apple Watch, including by voice, plus supporter app icons.",
            "pro.artwork.body": "New supporter artwork arrives each year. Subscribers keep collections earned during paid periods. Lifetime Supporter includes all current and future Supporter features and artwork.",
            "pro.legacy.body": "Pro has been renamed to Supporter. Previous Pro and Apple Watch unlock purchases have automatically become Lifetime Supporter, including all current and future Supporter features and artwork. No subscription or repurchase is needed."
        ]
        for (key, english) in expected {
            let entry = try #require(strings[key])
            #expect(LocalizationCatalogFixture.englishRendering(ofKey: key, entry: entry) == english)
            let locales = try #require(entry["localizations"] as? [String: Any])
            for language in LocalizationCatalogFixture.translationLanguages {
                let unit = try #require((locales[language] as? [String: Any])?["stringUnit"] as? [String: Any])
                #expect(unit["state"] as? String == "translated")
                #expect((unit["value"] as? String)?.isEmpty == false)
                #expect(unit["value"] as? String != english)
            }
        }
        #expect(!(try Self.sourceText()).contains("no subscription"))
    }

    static func sourceText() throws -> String {
        let url = try LocalizationCatalogFixture.repositoryRoot().appendingPathComponent(source)
        do { return try String(contentsOf: url, encoding: .utf8) } catch {
            throw LocalizationFixtureError.fileUnreadable(path: source,
                                                          underlying: String(describing: error))
        }
    }

    // MARK: - Order

    @Test("The section leads with the support ask, then the feature list")
    func theAskComesFirst() throws {
        let lines = try Self.sourceText().split(separator: "\n", omittingEmptySubsequences: false)

        var positions: [(key: String, line: Int)] = []
        for key in Self.copyOrder {
            guard let index = lines.firstIndex(where: { $0.contains("\"\(key)\"") }) else {
                Issue.record("""
                    \(Self.source) no longer references \(key).

                    The support copy lines of the NowThis Supporter section are pinned in order. If one was
                    renamed, rename it here too; if one was deleted, that is a copy decision and
                    this list is where it gets recorded.
                    """)
                continue
            }
            positions.append((key, index + 1))
        }

        // Anti-vacuity: a scan that found none of the copy lines would otherwise report success.
        #expect(positions.count == Self.copyOrder.count,
                "Found \(positions.count) of \(Self.copyOrder.count) pinned copy keys in \(Self.source)")

        let rendered = positions.sorted { $0.line < $1.line }.map(\.key)
        #expect(rendered == Self.copyOrder, """
            The NowThis Supporter section renders its copy in the wrong order.
              expected: \(Self.copyOrder.joined(separator: " → "))
              actual:   \(rendered.joined(separator: " → "))
            The ask leads; the feature list follows it; the no-ads line closes.
            """)
    }

    // MARK: - Wording

    @Test("The support ask says exactly what was signed off")
    func theAskIsTheAgreedSentence() throws {
        let catalog = try #require(
            LocalizationCatalogFixture.catalogs.first { $0.path == "NowThis/Localizable.xcstrings" })
        let entry = try #require(try LocalizationCatalogFixture.load(catalog)["pro.support.title"],
                                 "pro.support.title is not in NowThis/Localizable.xcstrings")

        let english = LocalizationCatalogFixture.englishRendering(ofKey: "pro.support.title", entry: entry)
        #expect(english == Self.ask, """
            The first line of the NowThis Supporter section reads:
              \(english)
            It is pinned to:
              \(Self.ask)
            """)
    }

    @Test("The support ask ships in all five languages")
    func theAskIsTranslatedEverywhere() throws {
        let catalog = try #require(
            LocalizationCatalogFixture.catalogs.first { $0.path == "NowThis/Localizable.xcstrings" })
        let entry = try #require(try LocalizationCatalogFixture.load(catalog)["pro.support.title"],
                                 "pro.support.title is not in NowThis/Localizable.xcstrings")
        let localizations = try #require(entry["localizations"] as? [String: Any])

        var examined = 0
        var findings: [String] = []
        for language in LocalizationCatalogFixture.translationLanguages {
            examined += 1
            guard let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any],
                  let value = unit["value"] as? String, !value.isEmpty else {
                findings.append("  \(language): missing")
                continue
            }
            if (unit["state"] as? String) != "translated" {
                findings.append("  \(language): state is \(unit["state"] as? String ?? "nil"), not translated")
            }
            // The English left in place is the failure mode a completeness count cannot see.
            if value == Self.ask {
                findings.append("  \(language): still the English")
            }
        }

        #expect(examined == LocalizationCatalogFixture.translationLanguages.count,
                "Examined \(examined) languages; expected \(LocalizationCatalogFixture.translationLanguages.count)")
        #expect(findings.isEmpty, """
            pro.support.title is not shipping in every language:
            \(findings.joined(separator: "\n"))
            """)
    }
}
