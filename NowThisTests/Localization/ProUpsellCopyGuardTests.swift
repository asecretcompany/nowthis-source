import Foundation
import Testing

@Suite("Supporter purchase copy")
struct ProUpsellCopyGuardTests {

    static let source = "NowThis/Views/Settings/ProUpsellView.swift"

    /// The section's copy, in the order it must render.
    static let copyOrder = ["pro.ios.body", "pro.watch.body", "pro.artwork.body", "pro.legacy.body"]

    @Test func permanentPromisesAreExplicitAndTranslated() throws {
        let catalog = try #require(LocalizationCatalogFixture.catalogs.first { $0.path == "NowThis/Localizable.xcstrings" })
        let strings = try LocalizationCatalogFixture.load(catalog)
        let expected = [
            "pro.ios.body": "All iOS productivity features, including future additions, are included with the app.",
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

    @Test("Purchase disclosures lead with features included in the app")
    func includedFeaturesComeFirst() throws {
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
            The included iOS features come first, followed by Watch features, artwork, and previous purchases.
            """)
    }

}
