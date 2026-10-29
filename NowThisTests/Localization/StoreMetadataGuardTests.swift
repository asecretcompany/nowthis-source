import Foundation
import Testing
@testable import NowThis

// MARK: - The checks, as pure functions

/// The App Store listing's invariants, expressed so they can be run against text that is not on
/// disk.
///
/// The prior `StoreMetadataGuardTests` ships **no scanner self-check**, and it is the one guard
/// whose failure blocks a cut release: every rule lives inline inside a test that walks the real
/// files, so the only evidence it works is that it is green — which is also what it looks like
/// when the walk finds nothing. Lifting the rules out means `theScannerCatchesPlantedViolations`
/// can feed them a 31-character name and a keywords string with a space after a comma.
enum StoreListingRules {
    static let supportMarkers: [String: [String]] = [
        "en": ["future ios", "productivity", "optional", "monthly", "annual", "lifetime", "tips", "always free", "supporter icons"],
        "de": ["produktivitätsfunktionen", "künftige", "freiwillig", "monatlich", "jährlich", "lebenszeit", "trinkgel", "immer kostenlos", "app-symbole"],
        "es": ["ios", "futuras", "opcional", "mensual", "anual", "de por vida", "propinas", "siempre es gratis", "iconos"],
        "fr": ["ios", "à venir", "facultatif", "au mois", "à l’année", "à vie", "pourboires", "toujours gratuit", "icônes"],
        "it": ["ios", "future", "facoltativo", "mensile", "annuale", "a vita", "mance", "sempre gratis", "icone"],
        "nl": ["ios", "toekomstige", "vrijwillig", "per maand", "per jaar", "voor altijd", "fooien", "altijd gratis", "appiconen"]
    ]

    static func supportCopyFindings(_ text: String, language: String) -> [String] {
        let normalized = text.lowercased()
        let missing = (supportMarkers[language] ?? []).filter { !normalized.contains($0) }
        let stale = ["no subscription", "kein abo", "sin suscripción", "sans abonnement", "senza abbonamento", "zonder abonnement"].filter(normalized.contains)
        return missing + stale
    }

    /// Whether this checkout carries the store listing at all.
    ///
    /// Lives here rather than on `StoreMetadataGuardTests` because a `@Suite` condition that
    /// references a static on the type the macro is expanding is a circular reference, and the
    /// build fails with `Circular reference resolving attached macro 'Suite'`.
    ///
    /// Non-throwing by construction: a suite condition that throws is a suite that fails, which
    /// is the outcome it exists to avoid.
    static var metadataDirectoryExists: Bool {
        guard let root = try? LocalizationCatalogFixture.repositoryRoot() else { return false }
        var isDirectory: ObjCBool = false
        let path = root.appendingPathComponent("fastlane/metadata").path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// App Store Connect locale ← the binary localization it must accompany.
    ///
    /// `it` has no region. That asymmetry is App Store Connect's, not a typo — `it-IT` is not an
    /// App Store Connect locale and "correcting" this line silently unlists Italy.
    static let localeMapping: [String: String] = [
        "en-US": "en",
        "de-DE": "de",
        "es-ES": "es",
        "fr-FR": "fr",
        "it": "it",
        "nl-NL": "nl",
    ]

    /// Field → maximum characters, per App Store Connect.
    static let limits: [String: Int] = [
        "name": 30,
        "subtitle": 30,
        "keywords": 100,
        "promotional_text": 170,
        "description": 4000,
        "release_notes": 4000,
    ]

    /// The English description's own ceiling, well under App Store Connect's 4000.
    ///
    /// Measured, not guessed. A 3,525-character English description translated to de-DE
    /// 3,737 (+6.0%), nl-NL 3,921, it 3,993, fr-FR 3,994, es-ES 3,997 — and four of those five
    /// finished within seven characters of the 4000 cap, meaning they were *edited down to fit*.
    /// Their ratios are ceiling artifacts, so the real expansion is worse than +13.4% and German
    /// at +6.0% with 263 characters of slack is the only uncensored data point.
    ///
    /// NowThis's live 3,949-character description overflowed in **every** locale under those
    /// ratios (de 4,187 … es 4,478). Cutting the English is the only fix that does not amount to
    /// deleting claims from four translations by hand.
    static let englishDescriptionCeiling = 3500

    /// The quick-add example, which must survive translation byte-for-byte.
    ///
    /// `NaturalLanguageParser` matches the literal English words `tomorrow`, `next week`, `at
    /// 5pm` and the priority keywords `high`/`medium`/`med`/`low` after `!`. It is English-only
    /// and stays that way (`TRANSLATION.md` §2). A German listing that helpfully renders this as
    /// *"Zahnarzt anrufen morgen !hoch @gesundheit"* teaches a syntax that parses nothing — and
    /// it reads perfectly, so no length check, completeness check or back-translation sees it.
    static let quickAddExample = "Call dentist tomorrow !high @health"

    /// Characters as App Store Connect might count them, taken conservatively.
    ///
    /// The two plausible readings conflict and nobody has tested which one ASC uses. Swift's
    /// `String.count` is normalization-invariant — `"café"` NFC and NFD both count 4 — so if ASC
    /// counts graphemes, decomposed accents are free; the playbook this was ported from asserts
    /// both that they "count double" and that you should "normalize to NFC before counting".
    /// `.count` also undercounts badly the other way: a three-person family emoji is one grapheme
    /// and eight UTF-16 units.
    ///
    /// So do not pick a side. Count UTF-16 in both forms and take the larger, which is an upper
    /// bound under either reading. `everyListingFileIsAlreadyNFC` then removes the accent
    /// question entirely at authoring time, leaving this measure tight in practice.
    static func conservativeLength(_ text: String) -> Int {
        max(text.utf16.count, text.precomposedStringWithCanonicalMapping.utf16.count)
    }

    /// Compared **scalar by scalar**, not with `==`.
    ///
    /// `String`'s `==` is canonical equivalence, so `text == text.precomposedStringWithCanonicalMapping`
    /// is `true` for decomposed text and this rule silently answered "already NFC" for every input
    /// it exists to reject. `theScannerCatchesPlantedViolations` is the only reason that was
    /// noticed: every file in the repo happens to be NFC, so the check was green on real data
    /// while being incapable of failing.
    static func isNFC(_ text: String) -> Bool {
        Array(text.unicodeScalars) == Array(text.precomposedStringWithCanonicalMapping.unicodeScalars)
    }

    /// A space after a comma in `keywords` is spent from the same 100 characters as a keyword.
    ///
    /// The rule is *no space **after a comma***, not "no spaces": multi-word keywords like
    /// `to do list` are legal, deliberate, and the highest-volume search term this app has.
    static func keywordsWasteWhitespace(_ text: String) -> Bool {
        text.contains(", ")
    }

    /// Keywords listed more than once in the same locale, lowercased.
    ///
    /// The second copy is spent from the same 100 characters and bought nothing — App Store
    /// Connect indexes a term once. It arrives from ordinary editing: prepending a term to the
    /// front of the line without reading to the end of it, which is exactly how `caldav` came to
    /// appear twice in the English list at 109 characters against a limit of 100.
    ///
    /// Invisible to every other check here. A duplicated list is still a plausible pile of
    /// comma-separated terms, still NFC, still free of spaces after commas, and still not the
    /// English list when read from another locale.
    static func duplicatedKeywords(_ text: String) -> [String] {
        var seen: Set<String> = []
        var repeated: [String] = []
        for keyword in text.split(separator: ",").map({
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }) where !keyword.isEmpty {
            if !seen.insert(keyword).inserted, !repeated.contains(keyword) { repeated.append(keyword) }
        }
        return repeated
    }

    /// The AI-translation disclosure each translated description must carry, verbatim.
    ///
    /// `en-US` is deliberately absent: it is the source text, not a translation, and the sentence
    /// would be false there. `TranslationDisclosureTests` makes the same call for the in-app
    /// sheet — "English is the source language and is never disclosed".
    ///
    /// The wording tracks the app's own `disclosure.translation.body` in each language: KI in
    /// German, IA in Spanish, French and Italian, AI in Dutch.
    ///
    /// Pinned rather than pattern-matched. A description is rewritten as one block, and a rule
    /// that only asks for "AI mentioned somewhere" is satisfied by wording that has been softened
    /// into saying nothing.
    static let translationDisclosure: [String: String] = [
        "de-DE": "Aus dem Englischen mit KI übersetzt.",
        "es-ES": "Traducido del inglés con IA.",
        "fr-FR": "Traduit de l'anglais par IA.",
        "it": "Tradotto dall'inglese con IA.",
        "nl-NL": "Vertaald uit het Engels met AI.",
    ]

    /// Every URL in a blob of listing text.
    ///
    /// Finds them by scanning for the literal `http`, which is why every URL in every locale must
    /// be written **with its scheme**. A bare `asc.is/support/` is invisible here, and a guard
    /// that cannot see a URL cannot notice it was translated.
    static func urls(in text: String) -> Set<String> {
        // A URL ends at whitespace or at a bracket/quote wrapping it. Trailing sentence
        // punctuation is prose, not part of the address.
        let terminators: Set<Character> = [
            " ", "\t", "\n", "\r", "\"", "'", "<", ">", "(", ")", "[", "]",
            "«", "»", "„", "“", "”", "‘", "’",
        ]
        var found: Set<String> = []
        var scanner = Substring(text)
        while let range = scanner.range(of: "http", options: [.caseInsensitive]) {
            let token = scanner[range.lowerBound...].prefix { !terminators.contains($0) }
            let cleaned = String(token).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            if cleaned.count > "http".count { found.insert(cleaned) }
            scanner = scanner[range.upperBound...]
        }
        return found
    }
}

// MARK: - The guard

/// Guards the App Store listing text.
///
/// Two systems localize this app and they do not share a vocabulary. The binary ships ISO codes —
/// `de`, `es`, `fr`, `it`, `nl` — while App Store Connect wants `de-DE`, `es-ES`, `fr-FR`, bare
/// `it` and `nl-NL`. Nothing in a build connects them, so it is entirely possible to ship a fully
/// German app whose German listing is in English, and no test, log line or reviewer would mention
/// it. That is not hypothetical here: the live listing declares `languageCodesISO2A: ["EN"]`.
///
/// The character limits are the other half. App Store Connect rejects an upload that exceeds them
/// — after the release is cut and the build is uploaded.
///
/// The files are **not bundle resources**; they are read from the working copy. See
/// `fastlane/metadata/README.md`.
///
/// The whole suite is skipped where `fastlane/metadata` is absent. The store listing is release
/// tooling, not a shipped source, so it is not published to the `nowthis-source` mirror; without
/// this the suite turns every public checkout red over files that checkout was never meant to
/// have. Where the directory exists — the release checkout, the only place a listing can actually
/// be cut — every check below runs unchanged.
@Suite("App Store listing", .enabled(if: StoreListingRules.metadataDirectoryExists))
struct StoreMetadataGuardTests {
    @Test func supportPromisesAndChoicesShipInEveryDescription() throws {
        var examined = 0
        for (locale, language) in StoreListingRules.localeMapping {
            examined += 1
            let text = try Self.field("description", inListing: locale)
            #expect(StoreListingRules.supportCopyFindings(text, language: language).isEmpty,
                    "Missing support promises or stale offer wording in \(locale)")
        }
        #expect(examined == 6)
        #expect(StoreListingRules.supportMarkers.count == 6)
    }

    @Test func supportScannerCatchesAMissingPromiseAndStaleBilling() {
        let valid = StoreListingRules.supportMarkers["en"]!.joined(separator: " ")
        #expect(StoreListingRules.supportCopyFindings(valid, language: "en").isEmpty)
        #expect(StoreListingRules.supportCopyFindings(valid.replacingOccurrences(of: "always free", with: ""), language: "en").contains("always free"))
        #expect(StoreListingRules.supportCopyFindings(valid + " no subscription", language: "en").contains("no subscription"))
    }

    /// Locales whose listing text has not been written yet.
    ///
    /// **A release blocker, recorded rather than hidden.** Every per-file check below iterates the
    /// files that *exist*, so all of them pass with five empty directories — the exact failure
    /// this suite was written to prevent would be green. So the invariant is not "listings exist"
    /// (unenforceable until the copy is written) but "a listing is all six fields or none of
    /// them". Half-done is the state that actually ships damage: a German `name.txt` beside an
    /// English `description.txt` uploads without complaint and looks deliberate.
    ///
    /// Checked against `localeMapping`, **not** against directories on disk. Git does not track
    /// empty directories, so "the folder is there and empty" is not a state a clean checkout can
    /// be in — absent is the only honest representation, and requiring the directory made
    /// the equivalent guard red in every checkout but the one that authored it.
    ///
    /// Removing a locale from this set turns on full field-completeness checking for it
    /// immediately.
    ///
    /// It is empty: all six listings are written. Adding a locale back here is how you start a
    /// seventh translation, not how you excuse a failing check.
    static let listingsNotYetAuthored: Set<String> = []

    static func metadataRoot() throws -> URL {
        try LocalizationCatalogFixture.repositoryRoot().appendingPathComponent("fastlane/metadata")
    }

    // MARK: The two locale sets stay in lockstep

    /// Every language the binary ships must have a listing directory.
    ///
    /// Silent in both directions: a German app with an English listing looks fine in Xcode and
    /// fine in App Store Connect, and is visible only to the German user deciding whether to
    /// download it.
    @Test("Every language the binary ships has a listing directory")
    func everyShippingLanguageHasAListingDirectory() throws {
        let catalogLanguages = try Self.languagesInCatalogs()
        #expect(catalogLanguages == Set(LocalizationCatalogFixture.translationLanguages), """
            The catalogs ship \(catalogLanguages.sorted()) but the fixture declares \
            \(LocalizationCatalogFixture.translationLanguages). An empty or shrunken set here \
            would make every check below vacuous.
            """)

        var missing: [String] = []
        for language in catalogLanguages.sorted() {
            guard let locale = StoreListingRules.localeMapping.first(where: { $0.value == language })?.key
            else {
                missing.append("\(language): ships in the binary but has no App Store Connect locale mapped")
                continue
            }
            if Self.listingsNotYetAuthored.contains(locale) { continue }
            var isDirectory: ObjCBool = false
            let path = try Self.metadataRoot().appendingPathComponent(locale).path
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                missing.append("\(language): no fastlane/metadata/\(locale)/ directory")
            }
        }
        #expect(missing.isEmpty, """
            The binary ships languages the App Store listing does not cover:

              \(missing.joined(separator: "\n  "))
            """)
    }

    /// And nothing in the other direction — a listing locale with no binary behind it advertises
    /// an app that will open in English.
    @Test("No listing locale lacks a binary localization")
    func noListingLocaleLacksABinaryLocalization() throws {
        let catalogLanguages = try Self.languagesInCatalogs()
        var orphans: [String] = []
        for locale in try Self.listingLocales() {
            guard let language = StoreListingRules.localeMapping[locale] else {
                orphans.append("\(locale): not in localeMapping")
                continue
            }
            if language != "en", !catalogLanguages.contains(language) {
                orphans.append("\(locale): listed on the App Store but the app has no \(language) localization")
            }
        }
        #expect(orphans.isEmpty, "\(orphans.joined(separator: "\n  "))")
    }

    // MARK: Nothing exceeds App Store Connect's limits

    @Test("No field exceeds its character limit")
    func noFieldExceedsItsCharacterLimit() throws {
        var overruns: [String] = []
        var checked = 0

        for locale in try Self.listingLocales() {
            for (field, limit) in StoreListingRules.limits {
                guard let text = try Self.optionalField(field, inListing: locale) else { continue }
                checked += 1
                let length = StoreListingRules.conservativeLength(text)
                if length > limit {
                    overruns.append("\(locale)/\(field).txt: \(length) characters, limit \(limit)")
                }
            }
        }

        let expectedReads = try Self.authoredLocales().count * StoreListingRules.limits.count
        #expect(checked == expectedReads,
                "Read \(checked) files, expected \(expectedReads) — six per authored listing.")
        #expect(overruns.isEmpty, """
            App Store Connect will reject the upload, after the release is cut:

              \(overruns.joined(separator: "\n  "))
            """)
    }

    /// Assert the files are already NFC rather than normalizing before counting.
    ///
    /// Whether App Store Connect normalizes is unresolved and only a real upload can settle it.
    /// Catching an NFD-emitting editor at authoring time makes the question moot: if nothing
    /// decomposed ever lands in the repo, it cannot matter which way ASC counts.
    @Test("Every listing file is already NFC")
    func everyListingFileIsAlreadyNFC() throws {
        var decomposed: [String] = []
        var checked = 0
        for locale in try Self.listingLocales() {
            for field in StoreListingRules.limits.keys.sorted() {
                guard let text = try Self.optionalField(field, inListing: locale) else { continue }
                checked += 1
                if !StoreListingRules.isNFC(text) {
                    decomposed.append("\(locale)/\(field).txt is not NFC — an editor emitted decomposed accents")
                }
            }
        }
        #expect(checked > 0, "no listing file was read — the layout moved")
        #expect(decomposed.isEmpty, "\(decomposed.joined(separator: "\n  "))")
    }

    @Test("Keywords waste no characters on whitespace")
    func keywordsWasteNoCharactersOnWhitespace() throws {
        var wasteful: [String] = []
        var checked = 0
        for locale in try Self.listingLocales() {
            guard let keywords = try Self.optionalField("keywords", inListing: locale) else { continue }
            checked += 1
            if StoreListingRules.keywordsWasteWhitespace(keywords) {
                wasteful.append("\(locale): a space after a comma costs a character that could be a keyword")
            }
        }
        let authoredCount = try Self.authoredLocales().count
        #expect(checked == authoredCount, "Read keywords for \(checked) of \(authoredCount) listings.")
        #expect(wasteful.isEmpty, "\(wasteful.joined(separator: "\n  "))")
    }

    /// A keyword listed twice costs its characters twice and is indexed once.
    ///
    /// The character limit alone does not catch this. A duplicate inside a list that still fits
    /// under 100 is silently forfeited search coverage — the characters were available and were
    /// spent on nothing.
    @Test("No keyword is listed twice in the same locale")
    func noKeywordIsListedTwice() throws {
        var duplicated: [String] = []
        var checked = 0
        for locale in try Self.listingLocales() {
            guard let keywords = try Self.optionalField("keywords", inListing: locale) else { continue }
            checked += 1
            let repeats = StoreListingRules.duplicatedKeywords(keywords)
            if !repeats.isEmpty {
                duplicated.append("\(locale): \(repeats.joined(separator: ", ")) listed more than once")
            }
        }
        let authoredCount = try Self.authoredLocales().count
        #expect(checked == authoredCount, "Read keywords for \(checked) of \(authoredCount) listings.")
        #expect(duplicated.isEmpty, """
            A repeated keyword is spent twice from the same 100 characters and indexed once:

              \(duplicated.joined(separator: "\n  "))
            """)
    }

    /// The English is held below App Store Connect's limit, not at it.
    ///
    /// This is the check that has to fail *before* a translator is engaged. Discovering the
    /// overflow afterwards means cutting claims out of five finished translations by hand, each
    /// of which then no longer says what the English says.
    @Test("The English description leaves room for translation")
    func theEnglishDescriptionLeavesTranslationHeadroom() throws {
        let english = try Self.field("description", inListing: "en-US")
        let length = StoreListingRules.conservativeLength(english)

        #expect(length > 1000, "en-US/description.txt is \(length) characters — that is not a listing.")
        #expect(length <= StoreListingRules.englishDescriptionCeiling, """
            en-US/description.txt is \(length) characters, over the \
            \(StoreListingRules.englishDescriptionCeiling) ceiling.

            App Store Connect's limit is 4000 and this is not it. At the measured Spanish
            expansion of +13.4% — itself an underestimate, since that translation was edited down
            to fit — \(length) characters becomes \(Int(Double(length) * 1.134)).
            """)
    }

    // MARK: A listing is complete or unstarted, never half-done

    @Test("Every started listing carries every field")
    func everyStartedListingCarriesEveryField() throws {
        var incomplete: [String] = []
        var authored: [String] = []

        for locale in try Self.listingLocales() {
            let present = try Self.fieldsPresent(inListing: locale)
            if present.isEmpty {
                #expect(Self.listingsNotYetAuthored.contains(locale),
                        "\(locale) has no listing text and is not recorded in listingsNotYetAuthored")
                continue
            }
            authored.append(locale)
            let missing = Set(StoreListingRules.limits.keys).subtracting(present)
            if !missing.isEmpty {
                incomplete.append("\(locale): missing \(missing.sorted().joined(separator: ", "))")
            }
        }

        #expect(!authored.isEmpty, "no listing was read at all — the layout moved")
        #expect(incomplete.isEmpty, """
            A half-written store listing uploads without complaint and looks deliberate — a
            translated name above an English description:

              \(incomplete.joined(separator: "\n  "))

            Write the remaining fields, or delete the partial ones and add the locale back to
            listingsNotYetAuthored.
            """)
    }

    @Test("The unauthored set names real locales that really have no copy")
    func theUnauthoredListingSetIsHonest() throws {
        let unknown = Self.listingsNotYetAuthored.subtracting(Set(StoreListingRules.localeMapping.keys))
        #expect(unknown.isEmpty,
                "listingsNotYetAuthored names locales that are not App Store Connect locales: \(unknown.sorted())")

        var actuallyAuthored: [String] = []
        for locale in Self.listingsNotYetAuthored.sorted() {
            if try !Self.fieldsPresent(inListing: locale).isEmpty { actuallyAuthored.append(locale) }
        }
        #expect(actuallyAuthored.isEmpty, """
            These locales have listing text but are still recorded as unauthored, so their fields
            are not being checked: \(actuallyAuthored)

            Remove them from listingsNotYetAuthored.
            """)
    }

    /// A file that exists but is empty reads as "translated" to every tool and ships a blank field.
    @Test("No listing file is present but empty")
    func noListingFileIsPresentButEmpty() throws {
        var blanks: [String] = []
        var checked = 0
        for locale in try Self.listingLocales() {
            let directory = try Self.metadataRoot().appendingPathComponent(locale)
            for file in try Self.textFiles(in: directory) {
                checked += 1
                let raw = (try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)) ?? ""
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blanks.append("\(locale)/\(file) exists but is empty")
                }
            }
        }
        #expect(checked > 0, "no listing file was read — the layout moved")
        #expect(blanks.isEmpty, "\(blanks.joined(separator: "\n  "))")
    }

    // MARK: Translation changed the prose and nothing else

    /// Every URL in the English listing appears byte-identical in every locale.
    ///
    /// A translator working on prose has no reason to stop at a URL, and `asc.is/support/` →
    /// `asc.is/hilfe/` is a plausible, well-meaning edit that reads correctly and 404s. It is the
    /// only support channel those markets have, so breaking it breaks the one path back.
    @Test("Every locale carries the English URLs unchanged")
    func everyLocaleCarriesTheEnglishURLsUnchanged() throws {
        let englishURLs = try Self.urls(inListing: "en-US")
        #expect(englishURLs.count >= 2,
                "found \(englishURLs.count) URLs in the English listing — support and privacy are both expected")
        #expect(englishURLs.allSatisfy { $0.hasPrefix("https://") },
                "a URL in the English listing has no scheme, which makes this scan blind to it: \(englishURLs.sorted())")

        var damaged: [String] = []
        var compared = 0
        for locale in try Self.authoredLocales() where locale != "en-US" {
            compared += 1
            let localized = try Self.urls(inListing: locale)
            for url in englishURLs.subtracting(localized).sorted() {
                damaged.append("\(locale): \(url) is in the English listing but not this one")
            }
            for url in localized.subtracting(englishURLs).sorted() {
                damaged.append("\(locale): invented a URL that is not in the English listing: \(url)")
            }
        }
        let translatedCount = try Self.authoredLocales().count - 1
        #expect(compared == translatedCount,
                "compared \(compared) of \(translatedCount) translated listings against the English URLs")
        #expect(damaged.isEmpty, """
            A URL changed in translation. It will still read correctly to the person it is aimed
            at, and still 404:

              \(damaged.joined(separator: "\n  "))
            """)
    }

    /// The quick-add example survives translation byte-for-byte.
    ///
    /// The parser is English-only. Translating the example produces a listing that teaches a
    /// syntax doing nothing at all, in copy that reads perfectly — invisible to every length,
    /// completeness and URL check, and to back-translation, which would report it as a faithful
    /// rendering of the English.
    @Test("The quick-add example is never translated")
    func theQuickAddExampleIsNeverTranslated() throws {
        let english = try Self.field("description", inListing: "en-US")
        #expect(english.contains(StoreListingRules.quickAddExample), """
            The English description no longer contains \(StoreListingRules.quickAddExample), so
            this guard now watches nothing. If the example was reworded, update
            StoreListingRules.quickAddExample to match; if it was removed, delete this test.
            """)

        var localized: [String] = []
        var compared = 0
        for locale in try Self.authoredLocales() where locale != "en-US" {
            compared += 1
            let description = try Self.field("description", inListing: locale)
            if !description.contains(StoreListingRules.quickAddExample) {
                localized.append("\(locale): the quick-add example was translated or dropped")
            }
        }
        let translatedCount = try Self.authoredLocales().count - 1
        #expect(compared == translatedCount,
                "compared \(compared) of \(translatedCount) translated descriptions against the English example")
        #expect(localized.isEmpty, """
            NaturalLanguageParser matches the English words only. A translated example teaches a
            syntax that parses nothing:

              \(localized.joined(separator: "\n  "))

            Translate the sentence around the example and leave the quoted example in English.
            """)
    }

    /// Feature names in the listing match what the shipped app calls them.
    ///
    /// The gap nothing else covers. A German listing that promises a *"Übersicht"* while the app's
    /// sidebar says *"Demnächst"* passes every length, completeness, URL and NFC check here, and
    /// back-translation reports it as a faithful rendering of "Upcoming" — because it is. The
    /// listing is only wrong relative to a *third* artifact neither the English nor the
    /// translation contains: the string catalog.
    ///
    /// So the terms are looked up in `NowThis/Localizable.xcstrings` rather than translated
    /// again. Where one English rendering has several catalog entries — "Completed" is both a
    /// status and a Smart List — any of their translations counts.
    @Test("Listing feature names match the shipped app")
    func listingFeatureNamesMatchTheApp() throws {
        let catalog = try #require(
            LocalizationCatalogFixture.catalogs.first { $0.path == "NowThis/Localizable.xcstrings" })
        let entries = try LocalizationCatalogFixture.load(catalog)

        /// English rendering → the listing file that has to quote its translation.
        let quoted: [(term: String, file: String)] = [
            ("Today", "description"),
            ("Upcoming", "description"),
            ("Overdue", "description"),
            ("All Tasks", "description"),
            ("Needs Action", "description"),
            ("In Progress", "description"),
            ("Completed", "description"),
            // The 26.10 notes name these Settings controls. Use their catalog
            // translations so the reader can find the actual support and icon screens.
            ("Support Development", "release_notes"),
            ("App Icon", "release_notes"),
            ("Ask for Due Date", "release_notes"),
        ]

        // The English listing must quote the English, or the table is naming terms this listing
        // does not actually use and every locale below is being checked against nothing.
        for (term, file) in quoted {
            let english = try Self.field(file, inListing: "en-US")
            #expect(english.contains(term), """
                en-US/\(file).txt does not contain "\(term)". Either the listing stopped using \
                that term or the app renamed it — in both cases this table is stale.
                """)
        }

        var wrong: [String] = []
        var checked = 0
        for (locale, language) in StoreListingRules.localeMapping.sorted(by: { $0.key < $1.key })
        where language != "en" {
            for (term, file) in quoted {
                let candidates = Self.translations(of: term, language: language, in: entries)
                guard !candidates.isEmpty else {
                    wrong.append("\(locale): the catalog has no \(language) translation of \"\(term)\"")
                    continue
                }
                checked += 1
                let text = try Self.field(file, inListing: locale)
                if !candidates.contains(where: { text.contains($0) }) {
                    wrong.append(
                        "\(locale)/\(file).txt never says \(candidates.sorted()), "
                        + "which is what the app calls \"\(term)\"")
                }
            }
        }

        let expected = quoted.count * LocalizationCatalogFixture.translationLanguages.count
        #expect(checked == expected, "checked \(checked) of \(expected) term/locale pairs")
        #expect(wrong.isEmpty, """
            The listing calls a feature something the app does not:

              \(wrong.joined(separator: "\n  "))

            Take the term from the string catalog, not from a fresh translation of the English.
            """)
    }

    /// Every translated description says it was translated by AI.
    ///
    /// The app discloses this in Settings, but the description is where somebody decides whether to
    /// install — and unlike the release notes it is not rewritten every release, so a disclosure that
    /// lands here stays. Without it a German reader meets machine-translated marketing copy with
    /// nothing marking it as such.
    @Test("Every translated description discloses the AI translation")
    func everyTranslatedDescriptionDisclosesTheAITranslation() throws {
        #expect(Set(StoreListingRules.translationDisclosure.keys)
                == Set(StoreListingRules.localeMapping.keys).subtracting(["en-US"]), """
            The disclosure table and the shipping locales disagree. A locale missing from the \
            table is a locale this check skips without saying so.
            """)

        var missing: [String] = []
        var checked = 0
        for (locale, sentence) in StoreListingRules.translationDisclosure.sorted(by: { $0.key < $1.key }) {
            guard let description = try Self.optionalField("description", inListing: locale) else {
                missing.append("\(locale): no description.txt")
                continue
            }
            checked += 1
            if !description.contains(sentence) {
                missing.append("\(locale)/description.txt does not say \"\(sentence)\"")
            }
        }

        #expect(checked == StoreListingRules.translationDisclosure.count,
                "read \(checked) of \(StoreListingRules.translationDisclosure.count) translated descriptions")
        #expect(missing.isEmpty, """
            A translated store listing does not say it was machine-translated:

              \(missing.joined(separator: "\n  "))
            """)
    }

    /// And the English description claims nothing, because it is not a translation.
    @Test("The English description does not claim to be translated")
    func theEnglishDescriptionDoesNotClaimToBeTranslated() throws {
        let english = try Self.field("description", inListing: "en-US")
        var planted: [String] = []
        for (locale, sentence) in StoreListingRules.translationDisclosure.sorted(by: { $0.key < $1.key })
        where english.contains(sentence) {
            planted.append("\(locale)'s disclosure — \"\(sentence)\"")
        }
        #expect(planted.isEmpty, """
            en-US/description.txt carries a translation disclosure: \(planted.joined(separator: ", "))

            The English is the source text, not a translation.
            """)
    }

    /// The app name is deliberately not localized — see `fastlane/metadata/README.md`.
    @Test("The app name is identical in every locale")
    func theAppNameIsIdenticalInEveryLocale() throws {
        let english = try Self.field("name", inListing: "en-US")
        #expect(!english.isEmpty, "en-US/name.txt is empty")

        var divergent: [String] = []
        for locale in try Self.authoredLocales() where locale != "en-US" {
            let name = try Self.field("name", inListing: locale)
            if name != english {
                divergent.append("\(locale): \"\(name)\" — en-US is \"\(english)\"")
            }
        }
        #expect(divergent.isEmpty, """
            The app name is not localized on purpose, and changing it in one market is a branding
            decision, not a translation:

              \(divergent.joined(separator: "\n  "))
            """)
    }

    /// A locale whose keywords are the English keywords was never translated.
    ///
    /// Keywords are the field a translation pass most plausibly skips: they are not sentences,
    /// several are already English loanwords, and copying them produces a file that passes every
    /// length and completeness check above while forfeiting search in that market entirely.
    @Test("Translated keywords are not just the English ones")
    func translatedKeywordsAreNotJustTheEnglishOnes() throws {
        let english = try Self.field("keywords", inListing: "en-US")

        var copied: [String] = []
        for locale in try Self.authoredLocales() where locale != "en-US" {
            if try Self.field("keywords", inListing: locale) == english { copied.append(locale) }
        }
        #expect(copied.isEmpty, """
            These locales ship the English keywords verbatim, which passes every other check here
            and forfeits App Store search in that market: \(copied)
            """)
    }

    // MARK: Self-check

    /// Plant every violation and confirm the rules see it.
    ///
    /// The prior guard has no equivalent, and it is the guard whose silent failure blocks a cut
    /// release. Each check above walks real files; if the walk found nothing, every one of them
    /// would be green. These assertions are the only evidence in the file that the rules can say
    /// no at all.
    @Test("The rules catch planted violations")
    func theScannerCatchesPlantedViolations() {
        // A 31-character name — one over.
        let tooLong = "NowThis: Aufgaben für Nextcloud"
        #expect(StoreListingRules.conservativeLength(tooLong) == 31)
        #expect(StoreListingRules.conservativeLength(tooLong) > StoreListingRules.limits["name"]!)
        // ...and the 28-character real one is not flagged.
        #expect(StoreListingRules.conservativeLength("NowThis: Tasks for Nextcloud") == 28)

        // A space after a comma, against a legal multi-word keyword.
        #expect(StoreListingRules.keywordsWasteWhitespace("todo, caldav"))
        #expect(!StoreListingRules.keywordsWasteWhitespace("todo,to do list,caldav"))

        // A term prepended to a list that already contains it, which is how this happens.
        #expect(StoreListingRules.duplicatedKeywords("nextcloud,caldav,todo,caldav") == ["caldav"])
        #expect(StoreListingRules.duplicatedKeywords("todo,to do list,caldav").isEmpty)
        // Casing does not make it a second keyword, and a multi-word keyword is not two keywords.
        #expect(StoreListingRules.duplicatedKeywords("CalDAV,caldav") == ["caldav"])
        #expect(StoreListingRules.duplicatedKeywords("to do list,todo,list").isEmpty)

        // Decomposed accents. Note `nfd == "Aufgaben für Nextcloud"` is *true* — String equality
        // is canonical equivalence — which is exactly how the first version of `isNFC` managed to
        // be green and useless.
        let nfd = "Aufgaben fu\u{0308}r Nextcloud"
        #expect(!StoreListingRules.isNFC(nfd))
        #expect(StoreListingRules.isNFC("Aufgaben für Nextcloud"))
        // The counter is an upper bound over both forms, so a decomposed file can only ever look
        // *longer*: 23 UTF-16 units against the composed form's 22. That is the safe direction
        // under the unresolved question of how App Store Connect counts.
        #expect(StoreListingRules.conservativeLength(nfd) == 23)
        #expect(StoreListingRules.conservativeLength("Aufgaben für Nextcloud") == 22)

        // URL scanning: scheme-qualified is found, bare is not — which is why the README requires
        // the scheme, and why `everyLocaleCarriesTheEnglishURLsUnchanged` asserts it.
        #expect(StoreListingRules.urls(in: "Help: https://asc.is/support/ and more.")
                == ["https://asc.is/support/"])
        #expect(StoreListingRules.urls(in: "Help: asc.is/support/").isEmpty)
        // Trailing sentence punctuation is prose, not address.
        #expect(StoreListingRules.urls(in: "See https://nowthis.app/privacy.")
                == ["https://nowthis.app/privacy"])

        // The Italian asymmetry, which a well-meaning edit "corrects".
        #expect(StoreListingRules.localeMapping["it"] == "it")
        #expect(StoreListingRules.localeMapping["it-IT"] == nil)
        #expect(Set(StoreListingRules.localeMapping.values)
                == Set(LocalizationCatalogFixture.translationLanguages + ["en"]))
    }

    // MARK: Helpers

    static func field(_ name: String, inListing locale: String) throws -> String {
        guard let text = try optionalField(name, inListing: locale) else {
            throw LocalizationFixtureError.fileUnreadable(
                path: "fastlane/metadata/\(locale)/\(name).txt", underlying: "no such file")
        }
        return text
    }

    /// `nil` when the file is absent — which for an unauthored locale is the honest answer, not a
    /// failure. Unreadable-but-present still throws.
    static func optionalField(_ name: String, inListing locale: String) throws -> String? {
        let url = try metadataRoot().appendingPathComponent(locale).appendingPathComponent("\(name).txt")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw LocalizationFixtureError.fileUnreadable(path: url.path,
                                                          underlying: String(describing: error))
        }
    }

    static func urls(inListing locale: String) throws -> Set<String> {
        let directory = try metadataRoot().appendingPathComponent(locale)
        var found: Set<String> = []
        for file in try textFiles(in: directory) {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            found.formUnion(StoreListingRules.urls(in: text))
        }
        return found
    }

    /// Locale directories on disk. A directory that cannot be listed **throws** — "I could not
    /// look" must never become "I looked and found nothing".
    static func listingLocales() throws -> [String] {
        let root = try metadataRoot()
        let contents: [String]
        do { contents = try FileManager.default.contentsOfDirectory(atPath: root.path) } catch {
            throw LocalizationFixtureError.directoryWalkCouldNotStart(path: root.path)
        }
        return contents.filter { name in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path,
                                           isDirectory: &isDirectory)
            return isDirectory.boolValue
        }.sorted()
    }

    /// Locales that actually have copy — the population every per-file count is asserted against.
    static func authoredLocales() throws -> [String] {
        try listingLocales().filter { try !fieldsPresent(inListing: $0).isEmpty }
    }

    static func fieldsPresent(inListing locale: String) throws -> Set<String> {
        let directory = try metadataRoot().appendingPathComponent(locale)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        return Set(try textFiles(in: directory).map { String($0.dropLast(4)) })
    }

    private static func textFiles(in directory: URL) throws -> [String] {
        let contents: [String]
        do { contents = try FileManager.default.contentsOfDirectory(atPath: directory.path) } catch {
            throw LocalizationFixtureError.directoryWalkCouldNotStart(path: directory.path)
        }
        return contents.filter { $0.hasSuffix(".txt") }.sorted()
    }

    /// Every translation a catalog carries for entries whose English rendering is exactly `term`.
    ///
    /// A set, not a single value: two entries can share an English rendering and differ in
    /// translation, and the listing only has to match one of them.
    static func translations(of term: String, language: String,
                             in entries: [String: [String: Any]]) -> Set<String> {
        var found: Set<String> = []
        for (key, entry) in entries
        where LocalizationCatalogFixture.englishRendering(ofKey: key, entry: entry) == term {
            guard let localizations = entry["localizations"] as? [String: Any],
                  let block = localizations[language] as? [String: Any],
                  let unit = block["stringUnit"] as? [String: Any],
                  let value = unit["value"] as? String else { continue }
            found.insert(value)
        }
        return found
    }

    /// Every non-English language present in the catalogs.
    static func languagesInCatalogs() throws -> Set<String> {
        var found: Set<String> = []
        for catalog in LocalizationCatalogFixture.catalogs {
            found.formUnion(try LocalizationCatalogFixture.translatedLanguages(in: catalog))
        }
        return found
    }
}
