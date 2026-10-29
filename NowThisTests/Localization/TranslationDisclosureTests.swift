import Foundation
import Testing
@testable import NowThis

/// The disclosure's rule is "once per language", and every interesting bug in it is a case where
/// that collapses back into "once ever" or into "every launch".
@Suite("Translation disclosure fires once per language")
struct TranslationDisclosureTests {

    // MARK: - Region folding

    @Test("A region is not a language")
    func regionsFoldIntoTheirLanguage() {
        #expect(TranslationDisclosure.fold("de-AT") == "de")
        #expect(TranslationDisclosure.fold("de-DE") == "de")
        #expect(TranslationDisclosure.fold("de") == "de")
        #expect(TranslationDisclosure.fold("pt-BR") == "pt")
        #expect(TranslationDisclosure.fold("zh-Hans-CN") == "zh")
        // Bundle and Locale disagree about case and separator often enough to matter.
        #expect(TranslationDisclosure.fold("DE_AT") == "de")
    }

    @Test("Moving between regions of one language does not re-disclose")
    func austrianGermanIsAcknowledgedByGermanGerman() {
        let acknowledged = TranslationDisclosure.acknowledging("de-DE", in: [])

        #expect(!TranslationDisclosure.shouldPresent(
            language: TranslationDisclosure.fold("de-AT"),
            acknowledged: acknowledged,
            hasCompletedOnboarding: true))
    }

    // MARK: - The actual rule

    @Test("Fires the first time a language is seen")
    func firesForAnUnacknowledgedLanguage() {
        #expect(TranslationDisclosure.shouldPresent(
            language: "de", acknowledged: [], hasCompletedOnboarding: true))
    }

    @Test("Does not fire again in the same language")
    func doesNotFireTwiceInOneLanguage() {
        let after = TranslationDisclosure.acknowledging("de", in: [])

        #expect(!TranslationDisclosure.shouldPresent(
            language: "de", acknowledged: after, hasCompletedOnboarding: true))
    }

    /// The whole reason this is a set and not a boolean. A user who dismissed a **German** sheet
    /// has been told nothing about the Italian they are now reading.
    @Test("Fires again after switching to a language never disclosed")
    func firesAgainInANewLanguage() {
        let afterGerman = TranslationDisclosure.acknowledging("de", in: [])

        #expect(TranslationDisclosure.shouldPresent(
            language: "it", acknowledged: afterGerman, hasCompletedOnboarding: true))
        // ...and acknowledging Italian must not forget German.
        let afterBoth = TranslationDisclosure.acknowledging("it", in: afterGerman)
        #expect(afterBoth == ["de", "it"])
    }

    @Test("English is the source language and is never disclosed")
    func englishNeverFires() {
        #expect(!TranslationDisclosure.shouldPresent(
            language: "en", acknowledged: [], hasCompletedOnboarding: true))
    }

    @Test("Nothing is disclosed before onboarding is finished")
    func gatedOnOnboarding() {
        #expect(!TranslationDisclosure.shouldPresent(
            language: "de", acknowledged: [], hasCompletedOnboarding: false))
        // ...and the same state fires once onboarding completes, so the gate is a delay and not
        // a permanent suppression.
        #expect(TranslationDisclosure.shouldPresent(
            language: "de", acknowledged: [], hasCompletedOnboarding: true))
    }

    // MARK: - Storage

    @Test("The acknowledged set round-trips through storage")
    func encodingRoundTrips() {
        let languages: Set<String> = ["de", "it", "nl"]
        let raw = TranslationDisclosure.encode(languages)

        #expect(raw == "de,it,nl", "Encoded sorted so the stored value is stable: \(raw)")
        #expect(TranslationDisclosure.decode(raw) == languages)
    }

    @Test("A malformed stored value cannot invent an acknowledged language")
    func decodingIsDefensive() {
        // A stray separator must not register "" as a language — which would then be compared
        // against a real language and silently do nothing, or worse, match a fold of "".
        #expect(TranslationDisclosure.decode(",,de,,") == ["de"])
        #expect(TranslationDisclosure.decode("") == [])
        #expect(TranslationDisclosure.decode("de-DE,it-IT") == ["de", "it"])
    }

    // MARK: - Anti-vacuity

    /// Every assertion above is about a pure function, so the one way this suite could be
    /// meaningless is if the rule it encodes were unreachable from the app. Pin the two inputs
    /// the app actually supplies.
    @Test("The rule is wired to real inputs")
    func realInputsAreWellFormed() {
        #expect(!TranslationDisclosure.storageKey.isEmpty)
        #expect(TranslationDisclosure.reportURL != nil,
                "The report link must parse — it ships inside five translations.")
        #expect(TranslationDisclosure.reportURL?.scheme == "https",
                "Always written with the scheme, per the localization plan's URL rule.")
        // `currentLanguage` reads Bundle.main, so under the test host it is whatever the run's
        // language is. It must at least be folded and non-empty.
        let current = TranslationDisclosure.currentLanguage
        #expect(!current.isEmpty)
        #expect(current == TranslationDisclosure.fold(current))
    }
}

/// The disclosure's *copy* and its reachability, which are the parts a refactor can quietly
/// destroy without breaking a single assertion about its logic.
///
/// "Pin the wording with a test" is the plan's phrasing. Byte-pinning the English is already the
/// staleness guard's job, so what is pinned here is the substance: that the sheet still says the
/// thing it exists to say, still offers a way to report a problem, and is still reachable after
/// the one time it appears. A disclosure the user can never find again is a formality, and a
/// disclosure that no longer mentions machine translation is not a disclosure.
@Suite("The disclosure still discloses")
struct TranslationDisclosureCopyTests {

    static let keys = [
        "disclosure.translation.title",
        "disclosure.translation.body",
        "disclosure.translation.invitation",
        "disclosure.translation.report",
        "disclosure.translation.report.a11y.hint",
        "disclosure.translation.dismiss",
    ]

    static let catalogPath = "NowThis/Localizable.xcstrings"

    private func entries() throws -> [String: [String: Any]] {
        let ref = LocalizationCatalogFixture.catalogs.first { $0.path == Self.catalogPath }
        return try LocalizationCatalogFixture.load(#require(ref))
    }

    @Test("Every disclosure string is in the catalog and carries a comment")
    func keysExistWithComments() throws {
        let all = try entries()
        var examined = 0

        for key in Self.keys {
            guard let entry = all[key] else {
                Issue.record("\(key) is not in \(Self.catalogPath).")
                continue
            }
            examined += 1
            let comment = (entry["comment"] as? String) ?? ""
            #expect(!comment.isEmpty, """
                \(key) has no comment. Two of these strings are verbs and one is a heading; a
                translator given only the English will get at least one of them wrong. This is
                also the sheet whose whole subject is translation quality.
                """)
        }
        #expect(examined == Self.keys.count,
                "Examined \(examined) of \(Self.keys.count) disclosure keys.")
    }

    @Test("The body still says the translation is machine-made")
    func theDisclosureStillDiscloses() throws {
        let all = try entries()
        let body = LocalizationCatalogFixture.englishRendering(
            ofKey: "disclosure.translation.body", entry: try #require(all["disclosure.translation.body"]))
            .lowercased()

        // Substance, not bytes: reword it freely, but the three claims TRANSLATION.md §9 makes
        // binding must all survive.
        //
        // Note the substrings. A bare `contains("ai")` is a false-positive magnet — "available",
        // "again", "detail", "explain" all contain it — so this matches "by ai" and "ai service".
        // The first draft of this guard tested for "automatic"/"machine", which was written
        // against an earlier English body and silently stopped meaning anything the moment §9's
        // wording landed. It is only a pin if it fails when the claim goes.
        #expect(body.contains("translat"), "The body no longer mentions translation at all: \(body)")

        #expect(body.contains("by ai") || body.contains("ai service"), """
            The body no longer says the translation was made by AI:

              \(body)

            TRANSLATION.md §9 makes this the fact the sheet exists to convey. Softening it into
            "translated automatically" or "carefully localized" makes the disclosure untrue.
            """)

        #expect(body.contains("building the app") || body.contains("development"), """
            The body no longer scopes the AI to *building* the app:

              \(body)

            §9 is explicit that "as part of the development process" is materially different from
            "this app uses AI" — NowThis sends nothing to an AI service at runtime, and a body
            that drops the scoping claims something untrue about the running app.
            """)

        #expect(body.contains("never") || body.contains("nothing"), """
            The body no longer states that the user's own text never reaches an AI service:

              \(body)

            This is the half of §9 that makes the disclosure a privacy statement rather than a
            liability notice, and it is the half a well-meaning rewrite drops first.
            """)
    }

    @Test("There is still a way to report a problem, over https")
    func theReportRouteSurvives() throws {
        let url = try #require(TranslationDisclosure.reportURL)
        #expect(url.scheme == "https", "Support URL must carry its scheme: \(url)")
        #expect(!(url.host ?? "").isEmpty)

        let root = try LocalizationCatalogFixture.repositoryRoot()
        let sheet = try String(
            contentsOf: root.appendingPathComponent("NowThis/Views/Settings/TranslationDisclosureSheet.swift"),
            encoding: .utf8)
        #expect(sheet.contains("TranslationDisclosure.reportURL"),
                "The sheet no longer links to the report URL.")
        #expect(sheet.contains("disclosure.translation.report"),
                "The sheet no longer has a report button.")
    }

    /// The sheet fires once per language. If the Settings entry is ever removed, that one
    /// appearance becomes the only one — and a user who dismissed it has no way back.
    @Test("The explanation stays reachable from Settings")
    func settingsKeepsItReachable() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let settings = try String(
            contentsOf: root.appendingPathComponent("NowThis/Views/Settings/SettingsView.swift"),
            encoding: .utf8)

        #expect(settings.contains("TranslationDisclosureSheet"), """
            SettingsView no longer presents TranslationDisclosureSheet. The sheet appears once per
            language; without the Settings row that is the only time the user can ever read it.
            """)
        #expect(settings.contains("disclosure.translation.title"),
                "The Settings row no longer uses the disclosure's own title key.")
    }

    @Test("Every disclosure string ships in all five languages")
    func fullyTranslated() throws {
        let all = try entries()
        var checked = 0

        for key in Self.keys {
            guard let entry = all[key],
                  let localizations = entry["localizations"] as? [String: Any] else { continue }
            for language in LocalizationCatalogFixture.translationLanguages {
                checked += 1
                let block = localizations[language] as? [String: Any]
                let value = (block?["stringUnit"] as? [String: Any])?["value"] as? String
                #expect(!(value ?? "").isEmpty, """
                    \(key) has no \(language) translation.

                    This sheet tells the user their language was machine-translated. Shipping it
                    in English is the one failure that proves its own point.
                    """)
            }
        }
        #expect(checked == Self.keys.count * LocalizationCatalogFixture.translationLanguages.count,
                "Checked \(checked) key/language pairs.")
    }
}
