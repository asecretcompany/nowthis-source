import Foundation
import Testing
@testable import NowThis

// MARK: - The checks, as pure functions

/// What the in-app purchase's own metadata has to satisfy, expressed so it can be run against
/// strings that are not on disk.
///
/// Same reason as ``StoreListingRules``: every rule below walks a real file, and a walk that finds
/// nothing is green. ``StoreProductGuardTests/theRulesCatchPlantedViolations`` is the only evidence
/// in this file that any of them can say no.
enum StoreProductRules {

    /// App Store Connect's limits on an in-app purchase localization.
    ///
    /// **45 characters is the one that surprises people.** The listing's `description` gets 4000;
    /// the *product's* gets 45, which is not enough for a sentence in German and is the reason the
    /// copy here is a phrase rather than prose. Exceeding it is caught at submission, after the
    /// build is uploaded — the same late failure the listing limits cause, on a field nobody
    /// re-reads because it is eleven words long and has not changed in a year.
    static let displayNameLimit = 30
    static let descriptionLimit = 45

    /// Never translated (`TRANSLATION.md` §2), in any of the six product localizations.
    static let productName = "NowThis Supporter"

    /// Every description says where the unlock applies, in the one form that never translates.
    ///
    /// A purchase description that does not scope itself is the complaint, not the feature: "check
    /// off and add tasks" describes something the iPhone app already does for free.
    static let scopeAnchor = "Apple Watch"

    /// Scope the paywall does not promise, by language, matched as case-insensitive stems.
    ///
    /// One entry per language, because one defect. The shipped configuration said the purchase
    /// unlocked *"Apple Watch app and future premium features"* — wrong twice: the Watch app is
    /// free (`pro.watch.body` says so in all six languages), and "future premium features" promises
    /// value that neither the paywall nor the listing commits to. That promise is what a buyer
    /// quotes back in a refund request, and it is per-language, so an English-only check would
    /// watch one sixth of the surface.
    ///
    /// Stems, not words: German inflects (*zukünftige*, *zukünftigen*), Romance languages share
    /// *futur-*.
    static let unpromisedScope: [String: [String]] = [
        "en": ["future"],
        "de": ["zukünftig", "künftig"],
        "es": ["futur"],
        "fr": ["futur", "à venir"],
        "it": ["futur"],
        "nl": ["toekomst"],
    ]

    /// App Store Connect listing locale → StoreKit configuration locale.
    ///
    /// **A third locale vocabulary.** The binary ships `de`, the listing ships `de-DE`, and a
    /// `.storekit` file ships `de_DE`. The transform between the last two is mechanical — hyphen to
    /// underscore — and Italian survives it unharmed, staying bare `it` in both, which is the one
    /// case a hand-maintained mapping table gets wrong.
    static func storeKitLocale(forListing locale: String) -> String {
        locale.replacingOccurrences(of: "-", with: "_")
    }

    static func isNFC(_ text: String) -> Bool {
        Array(text.unicodeScalars) == Array(text.precomposedStringWithCanonicalMapping.unicodeScalars)
    }

    /// Conservative over both normalization forms, as in ``StoreListingRules/conservativeLength(_:)``.
    static func conservativeLength(_ text: String) -> Int {
        max(text.utf16.count, text.precomposedStringWithCanonicalMapping.utf16.count)
    }

    static func promisesUnavailableScope(_ text: String, language: String) -> [String] {
        (unpromisedScope[language] ?? []).filter {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

// MARK: - The guard

/// Guards the in-app purchase's own localized metadata.
///
/// `NowThis/Store/NowThisStore.storekit` is a StoreKit **test** configuration — it never ships and
/// nothing in the binary reads it. That is exactly why it rots: it is also the only checked-in
/// record of what App Store Connect's in-app purchase page is supposed to say, and the plan's own
/// words for this were *"Nothing automated compares them."*
///
/// It had rotted. The single English localization read *"Apple Watch app and future premium
/// features."* while the shipped paywall said the Watch app is free and the purchase adds two named
/// actions. Both cannot be true, and the one a buyer sees before paying was the wrong one.
///
/// This suite cannot check that the copy is *true* — that is a human cross-read against
/// `pro.watch.body`, and it is on the release checklist. What it can do is make the failures that
/// are mechanical impossible: a locale going missing while five translations ship, a field
/// overflowing App Store Connect's 45 characters, the product name being translated, a description
/// that was copied rather than translated, and the specific over-promise that was already live.
@Suite("App Store product")
struct StoreProductGuardTests {

    static let configurationPath = "NowThis/Store/NowThisStore.storekit"

    struct ProductLocalization {
        let locale: String
        let displayName: String
        let description: String
    }

    /// The configuration's single product, or a readable failure. A configuration that cannot be
    /// parsed **throws** — "I could not look" must never become "I looked and found nothing".
    static func product() throws -> (id: String, type: String, localizations: [ProductLocalization]) {
        let url = try LocalizationCatalogFixture.repositoryRoot()
            .appendingPathComponent(configurationPath)
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw LocalizationFixtureError.fileUnreadable(path: configurationPath,
                                                          underlying: String(describing: error))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let products = root["products"] as? [[String: Any]] else {
            throw LocalizationFixtureError.fileUnreadable(path: configurationPath,
                                                          underlying: "no products array")
        }
        guard products.contains(where: { $0["productID"] as? String == AppConstants.proProductID }) else {
            throw LocalizationFixtureError.fileUnreadable(
                path: configurationPath,
                underlying: "the existing lifetime Supporter product is missing")
        }
        let product = products.first { $0["productID"] as? String == AppConstants.proProductID }!
        guard let id = product["productID"] as? String,
              let type = product["type"] as? String,
              let blocks = product["localizations"] as? [[String: Any]] else {
            throw LocalizationFixtureError.fileUnreadable(
                path: configurationPath, underlying: "the product is missing productID/type/localizations")
        }
        let localizations = try blocks.map { block -> ProductLocalization in
            guard let locale = block["locale"] as? String,
                  let displayName = block["displayName"] as? String,
                  let description = block["description"] as? String else {
                throw LocalizationFixtureError.fileUnreadable(
                    path: configurationPath,
                    underlying: "a localization is missing locale/displayName/description")
            }
            return ProductLocalization(locale: locale, displayName: displayName,
                                       description: description)
        }
        return (id, type, localizations)
    }

    /// Listing locale → binary language, for the locales that have a product localization.
    static func expectedLocales() -> [(storeKit: String, language: String)] {
        StoreListingRules.localeMapping
            .sorted { $0.key < $1.key }
            .map { (StoreProductRules.storeKitLocale(forListing: $0.key), $0.value) }
    }

    // MARK: It describes the product the app actually buys

    @Test("The configuration describes the product the app buys")
    func theConfigurationDescribesTheProductTheAppBuys() throws {
        let product = try Self.product()
        #expect(product.id == AppConstants.proProductID, """
            The StoreKit configuration sells \(product.id) and the app buys \
            \(AppConstants.proProductID). Nothing else in this file is worth checking until those \
            agree — the configuration would be describing a product that does not exist.
            """)
        #expect(product.type == "NonConsumable", """
            The lifetime Supporter unlock is a one-time purchase and the copy says so in six languages \
            ("no subscription", "kein Abo", "sin suscripción"). The configuration calls it \
            \(product.type).
            """)
    }

    // MARK: The three locale vocabularies stay in lockstep

    /// Every listing locale has a product localization, and nothing has one it should not.
    ///
    /// The silent half is the missing one. A German buyer with no `de_DE` block sees the English
    /// description on a page whose every other word is German, and no build, upload or review step
    /// mentions it.
    @Test("Every listing locale has a product localization")
    func everyListingLocaleHasAProductLocalization() throws {
        let present = Set(try Self.product().localizations.map(\.locale))
        let expected = Set(Self.expectedLocales().map(\.storeKit))

        #expect(expected.count == StoreListingRules.localeMapping.count, """
            \(expected.count) StoreKit locales derived from \
            \(StoreListingRules.localeMapping.count) listing locales — the transform collapsed two \
            of them onto one name.
            """)
        #expect(present == expected, """
            The product's localizations and the App Store listing's locales have diverged.

              only in the .storekit: \(present.subtracting(expected).sorted())
              only in the listing:   \(expected.subtracting(present).sorted())

            The listing locale becomes the StoreKit one by replacing "-" with "_", and Italian is
            bare `it` in both. Do not "correct" it to it_IT.
            """)
    }

    // MARK: Nothing exceeds App Store Connect's limits

    @Test("No product field exceeds App Store Connect's limits")
    func noProductFieldExceedsAppStoreConnectsLimits() throws {
        let localizations = try Self.product().localizations
        var overruns: [String] = []
        for localization in localizations {
            let name = StoreProductRules.conservativeLength(localization.displayName)
            if name > StoreProductRules.displayNameLimit {
                overruns.append("\(localization.locale)/displayName: \(name) characters, "
                                + "limit \(StoreProductRules.displayNameLimit)")
            }
            let description = StoreProductRules.conservativeLength(localization.description)
            if description > StoreProductRules.descriptionLimit {
                overruns.append("\(localization.locale)/description: \(description) characters, "
                                + "limit \(StoreProductRules.descriptionLimit)")
            }
        }
        #expect(localizations.count == StoreListingRules.localeMapping.count, """
            Measured \(localizations.count) localizations, expected \
            \(StoreListingRules.localeMapping.count).
            """)
        #expect(overruns.isEmpty, """
            App Store Connect rejects the in-app purchase, after the build is uploaded:

              \(overruns.joined(separator: "\n  "))

            The description field is 45 characters. It is a phrase, not a sentence.
            """)
    }

    @Test("Every product string is already NFC")
    func everyProductStringIsAlreadyNFC() throws {
        var decomposed: [String] = []
        var checked = 0
        for localization in try Self.product().localizations {
            checked += 2
            if !StoreProductRules.isNFC(localization.displayName) {
                decomposed.append("\(localization.locale)/displayName is not NFC")
            }
            if !StoreProductRules.isNFC(localization.description) {
                decomposed.append("\(localization.locale)/description is not NFC")
            }
        }
        #expect(checked == StoreListingRules.localeMapping.count * 2,
                "Read \(checked) strings, expected \(StoreListingRules.localeMapping.count * 2).")
        #expect(decomposed.isEmpty, "\(decomposed.joined(separator: "\n  "))")
    }

    // MARK: Translation changed the description and nothing else

    @Test("The product name is never translated")
    func theProductNameIsNeverTranslated() throws {
        var wrong: [String] = []
        var checked = 0
        for localization in try Self.product().localizations {
            checked += 1
            if !localization.displayName.hasPrefix(StoreProductRules.productName) {
                wrong.append("\(localization.locale): \"\(localization.displayName)\"")
            }
        }
        #expect(checked == StoreListingRules.localeMapping.count,
                "Checked \(checked) of \(StoreListingRules.localeMapping.count) localizations.")
        #expect(wrong.isEmpty, """
            "\(StoreProductRules.productName)" is a product name and is never translated \
            (TRANSLATION.md §2). It is also what the paywall, the listing and the watch's locked \
            sheet all call it, in every language:

              \(wrong.joined(separator: "\n  "))
            """)
    }

    /// A description copied from the English passes every length and completeness check here.
    ///
    /// It is the likeliest way this file half-lands: six locale blocks are added at once, five of
    /// them get real copy, and the sixth is left as a placeholder that reads as deliberate.
    @Test("Every description is actually translated")
    func everyDescriptionIsActuallyTranslated() throws {
        let localizations = try Self.product().localizations
        guard let english = localizations.first(where: { $0.locale == "en_US" })?.description else {
            Issue.record("No en_US localization — every comparison below is against nothing.")
            return
        }
        var copied: [String] = []
        var compared = 0
        for localization in localizations where localization.locale != "en_US" {
            compared += 1
            if localization.description == english { copied.append(localization.locale) }
        }
        #expect(compared == StoreListingRules.localeMapping.count - 1,
                "Compared \(compared) of \(StoreListingRules.localeMapping.count - 1) translations.")
        #expect(copied.isEmpty, """
            These locales ship the English description verbatim: \(copied)
            """)
    }

    /// Every description names where the unlock applies, in the one spelling that never translates.
    @Test("Every description says where the unlock applies")
    func everyDescriptionSaysWhereTheUnlockApplies() throws {
        var unscoped: [String] = []
        var checked = 0
        for localization in try Self.product().localizations {
            checked += 1
            if !localization.description.contains(StoreProductRules.scopeAnchor) {
                unscoped.append("\(localization.locale): \"\(localization.description)\"")
            }
        }
        #expect(checked == StoreListingRules.localeMapping.count,
                "Checked \(checked) of \(StoreListingRules.localeMapping.count) descriptions.")
        #expect(unscoped.isEmpty, """
            A description that does not say "\(StoreProductRules.scopeAnchor)" describes something \
            the iPhone app already does for free:

              \(unscoped.joined(separator: "\n  "))
            """)
    }

    /// The over-promise that was already shipping, checked in every language rather than English.
    @Test("No description promises scope the paywall does not")
    func noDescriptionPromisesScopeThePaywallDoesNot() throws {
        let localizations = try Self.product().localizations
        var overPromising: [String] = []
        var checked = 0
        for (storeKit, language) in Self.expectedLocales() {
            guard let localization = localizations.first(where: { $0.locale == storeKit })
            else { continue }
            #expect(StoreProductRules.unpromisedScope[language] != nil,
                    "No unpromisedScope stems for \(language) — that locale is checked against nothing.")
            checked += 1
            let hits = StoreProductRules.promisesUnavailableScope(localization.description,
                                                                  language: language)
            if !hits.isEmpty {
                overPromising.append("\(storeKit): \"\(localization.description)\" — \(hits)")
            }
        }
        #expect(checked == StoreListingRules.localeMapping.count,
                "Checked \(checked) of \(StoreListingRules.localeMapping.count) descriptions.")
        #expect(overPromising.isEmpty, """
            The purchase page promises scope the paywall does not:

              \(overPromising.joined(separator: "\n  "))

            The purchase adds two named actions on Apple Watch. It does not unlock the Watch app,
            which is free, and it does not commit to anything future.
            """)
    }

    // MARK: Self-check

    /// Plant every violation and confirm the rules see it.
    @Test("The rules catch planted violations")
    func theRulesCatchPlantedViolations() {
        // The 45-character limit, either side of it.
        let overLong = "Aufgaben abhaken und hinzufügen auf Apple Watch"
        #expect(StoreProductRules.conservativeLength(overLong) == 47)
        #expect(StoreProductRules.conservativeLength(overLong) > StoreProductRules.descriptionLimit)
        #expect(StoreProductRules.conservativeLength("Auf Apple Watch abhaken und hinzufügen") == 38)

        // Decomposed accents, which `String ==` would call equal to the composed form.
        let nfd = "Cocher et ajouter des ta\u{0302}ches"
        #expect(!StoreProductRules.isNFC(nfd))
        #expect(StoreProductRules.isNFC("Cocher et ajouter des tâches"))

        // The shipped over-promise, in each language it could have been translated into.
        #expect(StoreProductRules.promisesUnavailableScope(
            "Apple Watch app and future premium features.", language: "en") == ["future"])
        // Both German stems fire: "künftig" is a substring of "zukünftige". That is the point of
        // matching stems rather than words, and the reason the assertion names both.
        #expect(StoreProductRules.promisesUnavailableScope(
            "Apple Watch App und zukünftige Premium-Funktionen.", language: "de")
                == ["zukünftig", "künftig"])
        #expect(StoreProductRules.promisesUnavailableScope(
            "Funciones futuras del Apple Watch.", language: "es") == ["futur"])
        #expect(StoreProductRules.promisesUnavailableScope(
            "Fonctions à venir sur Apple Watch.", language: "fr") == ["à venir"])
        #expect(StoreProductRules.promisesUnavailableScope(
            "Funzioni future su Apple Watch.", language: "it") == ["futur"])
        #expect(StoreProductRules.promisesUnavailableScope(
            "Toekomstige functies op Apple Watch.", language: "nl") == ["toekomst"])
        // ...and the shipping copy is clean in all six.
        for (_, language) in Self.expectedLocales() {
            #expect(StoreProductRules.promisesUnavailableScope(
                "Check off and add tasks on Apple Watch", language: language).isEmpty)
        }

        // The locale transform, including the Italian case that a mapping table gets wrong.
        #expect(StoreProductRules.storeKitLocale(forListing: "de-DE") == "de_DE")
        #expect(StoreProductRules.storeKitLocale(forListing: "it") == "it")
        #expect(StoreProductRules.storeKitLocale(forListing: "en-US") == "en_US")

        // Every shipping language has stems, or that language is checked against nothing.
        let covered = Set(StoreProductRules.unpromisedScope.keys)
        #expect(covered == Set(LocalizationCatalogFixture.translationLanguages + ["en"]),
                "unpromisedScope covers \(covered.sorted()) — one language is watched by no stems.")
    }
}
