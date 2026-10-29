import Foundation
import Testing

/// The regression no other guard in this suite can see: **a string that is never translated at
/// all.**
///
/// Everything else here checks the shape of what exists. Nothing checks for absence. Someone adds
/// a screen in build 21, the literal extracts cleanly, it lands in the catalog with a comment and
/// a well-formed English block, every guard stays green — and it ships English in five languages.
/// The prior staleness guard opens with `guard !present.isEmpty else { continue }`, so it skips
/// exactly this case; it is written to catch a translation made from *stale* English, and a key
/// with no translation at all has no stale English to catch.
///
/// ## What `state` gates, and in which language
///
/// **`new` is dropped in the source language and nowhere else.** That is the whole rule, and it
/// is narrower than the one that stood here.
///
/// Measured 2026-08-13 by falsifying four real keys to unmistakable markers, building with
/// `-derivedDataPath` pinned, and reading the values back out of `NowThis.app`:
///
/// | block           | state          | reaches the bundle                    |
/// |-----------------|----------------|---------------------------------------|
/// | `en` (source)   | `new`          | **no** — the Swift `defaultValue` wins |
/// | `en` (source)   | `needs_review` | yes                                   |
/// | `de`            | `new`          | yes                                   |
/// | `de`            | `needs_review` | yes                                   |
///
/// Phase 2 (issues log L48) established the first row and is correct. What did not hold is the
/// generalisation from it: a **translation** ships at any state, `needs_review` included. In the
/// source language `new` means "extracted, nobody has edited it, the literal is the truth", so
/// omitting it changes nothing; in a translation there is no literal to fall back to.
///
/// The distinction is worth this much text because getting it wrong is expensive in one specific
/// direction. Build 3 arrived with forty translations demoted to `needs_review` by an Xcode
/// rewrite. Read through the old rule that is five languages not shipping, and the response is to
/// send five languages back out for re-translation — the exact waste
/// `Translations/tools/catalog_diff.py` exists to prevent. Read correctly it is a file to revert.
///
/// Every assertion below stands unchanged, on the reason that actually applies to each:
///
/// - A **translation** at `needs_review` or `stale` ships without anybody having signed it off.
///   `stale` is the sharper one — the English moved underneath it, so what ships is a fluent
///   sentence about behaviour the app no longer has.
/// - An **English plural** at `new` genuinely does not ship, and that is the one case where the
///   old wording was right: the plural rules are the one thing the Swift literal cannot express,
///   so falling back to the literal renders "1 tasks" with correct rules sitting unread beside it.
@Suite("Localization / completeness")
struct LocalizationCompletenessGuardTests {

    /// Per-catalog count of keys carrying **no** translation.
    ///
    /// **This number is a ratchet**, and ``fullyTranslatedFloor`` below is its other jaw: nothing
    /// new may go untranslated, and nothing already translated may quietly disappear.
    ///
    /// Closed onto the truth in Phase 8, measured 2026-07-27. Until then these held the
    /// pre-translation numbers — 601 for a catalog with 3 untranslated keys — so the ratchet had
    /// both jaws wide open through all of Phase 5 and 6 and never once could have fired. Six
    /// untranslated strings were added in this very phase and walked straight past it.
    ///
    /// What remains is only the deliberately withheld product names: `Nextcloud`, `NowThis`,
    /// `NowThis Supporter`. Every other key in every catalog carries all five languages. So these
    /// numbers may now only fall, and a new untranslated string turns this red on the next run —
    /// which is the entire point of the file.
    static let untranslatedCeiling: [String: Int] = [
        "NowThis/Localizable.xcstrings": 3,          // Nextcloud, NowThis, NowThis Supporter
        "NowThis/InfoPlist.xcstrings": 0,
        "NowThis/AppShortcuts.xcstrings": 0,
        "NowThisWidget/Localizable.xcstrings": 1,    // NowThis
        "NowThisWidget/InfoPlist.xcstrings": 0,
        "NowThisWatch/Localizable.xcstrings": 1,     // NowThis Supporter
        "NowThisWatchWidget/Localizable.xcstrings": 0,
    ]

    /// Keys carrying all five languages in a shipping state, measured 2026-07-27 in Phase 8.
    /// Raised as each batch lands; it may never fall.
    ///
    /// It sat at **1** from Phase 3 until Phase 8 while the real number climbed to 727 — so the
    /// other jaw of the ratchet was equally decorative: every translation in the project could
    /// have vanished and this would still have passed.
    ///
    /// Raised 729 → 734 on 2026-08-13: the tab bar's five `tab.*` labels (`tab.tasks`,
    /// `tab.board`, `tab.calendar`, `tab.matrix`, `tab.settings`) landed fully translated into
    /// de/es/fr/it/nl. This is a `>=` floor, so gaining keys without raising it would have stayed
    /// silently green — including if all five were later deleted.
    ///
    /// Raised 734 → 740 on 2026-08-14: the Tab Bar layout editor's six English literals (the
    /// section header, footer, and the four hint sentences) landed fully translated into
    /// de/es/fr/it/nl, closing the gap the ceiling had been loosened to admit instead.
    ///
    /// Raised 740 → 741 on 2026-08-14, the same day: pinning the Tasks tab reworded the editor's
    /// footer and its last-tab hint and added a `Tabs` header — a net gain of one key. Found by
    /// counting the catalog, not by a red test: 741 satisfies a floor of 740, which is exactly
    /// the hazard this constant exists to describe, and the second time this one branch hit it.
    ///
    /// **Lowered 741 → 740 on 2026-08-14**, the first fall. `Apple Watch editing` was
    /// deleted: the Pro upsell stopped opening with a feature name several builds ago, and the
    /// key outlived its last call site with all five translations intact. A ratchet that may
    /// never fall would forbid deleting dead copy, so the rule is not "never lower" — it is
    /// **never lower to accommodate a translation that went missing.** The distinction is whether
    /// the English key still exists: here it does not, and `translation_io.group_by_surface` was
    /// already refusing to export because the key matched no surface. `sync_catalogs --prune`
    /// would have proposed the same deletion; `KEEP_UNEXTRACTED` is the list of keys exempt from
    /// it, and this was never on it.
    /// Raised 740 → 741 on 2026-08-14: `Nothing in %@ yet.`, the Board's empty-list description,
    /// landed fully translated into de/es/fr/it/nl. It exists because the page said *"All tasks
    /// in X are completed."* for a list that had never held a task — see V1 in
    /// `docs/superpowers/sync-issues.md`.
    ///
    /// **Lowered 741 → 740 on 2026-08-15**, the second fall, and the same kind as the first:
    /// dead copy, not a missing translation. `This is the last tab you can choose. Add another
    /// to the tab bar before hiding this one.` was the disabled-state hint on the tab bar
    /// editor's hide button. A user asked to hide every chosen tab and be left with Tasks and
    /// Settings, which are pinned; the floor that refused was never a rule, only an artefact of
    /// `AppTab.decodeVisible` reading an empty stored list as "never configured". With the floor
    /// gone the hint can never be spoken, so the English key went with the branch — and note it
    /// is the *only* string that dies: the section footer's "up to three" already admits zero
    /// and was left exactly as it stood, at no translation cost.
    /// **Raised 740 → 743 on 2026-08-31**, the ratchet tightening rather than loosening. Build 7's
    /// trashed-lists notice added four keys — the sheet title, its section header, the
    /// `Deleted %@` row subtitle and the explanatory footer — each translated into all five
    /// languages in the same change, taking the real count to 744. Left at 740 the floor would
    /// have permitted all four to vanish again in silence, which is the one thing it exists to
    /// prevent.
    /// **Raised 743 → 753 on 2026-09-01.** The watch's add screen gained a due-date and a
    /// priority picker, putting `DefaultDueDateRule` and `TaskPriority` into the watch target
    /// and so their ten labels into its catalog. Catalogs do not share keys, so these are ten
    /// genuinely new entries; their translations were copied from the identical English already
    /// carried in `NowThis/Localizable.xcstrings` rather than made afresh, taking the real count
    /// to 754.
    /// **Raised 753 → 757 on 2026-09-22.** Board cards gained Move to Top, Move Up, Move Down
    /// and Move to Bottom, in the context menu and as VoiceOver actions — four keys, each
    /// translated into all five languages in the same change, taking the real count to 758.
    /// **Raised 757 → 763 on 2026-09-23.** Moving a task to another list added six keys — the
    /// context-menu item, the picker's title, its Read-only caption, and the subtask
    /// confirmation's title, message and button — each translated into all five languages in
    /// the same change, taking the real count to 764.
    /// Raised 763 → 764 on 2026-10-09: purchase information changing during a refresh
    /// now has actionable recovery copy translated into all five languages.
    /// Raised 764 → 767 on 2026-10-20: Siri's Add Task asks when the task is due — the
    /// question, its “No Due Date” answer and the Shortcuts switch that turns it off, each
    /// translated into all five languages. Today, Tomorrow and Next Week reuse the
    /// `defaultDueDate.*` keys and add nothing.
    static let fullyTranslatedFloor = 767

    /// Keys the catalogs deliberately withhold from translation, exempt from
    /// ``untranslatedCeiling`` and listed here so the exemption is something somebody reads.
    ///
    /// `shouldTranslate: false` is Xcode's own field for "this entry is not copy", and a
    /// bundle's identity is the case it exists for. `CFBundleDisplayName` and `CFBundleName`
    /// name the *bundle*: "NowThis" is a brand and "NowThisWidget" is a fifteen-character
    /// technical name, neither of which is a sentence anybody translates. Xcode re-extracts
    /// them from `INFOPLIST_KEY_CFBundleDisplayName` and `GENERATE_INFOPLIST_FILE` on every
    /// build, so deleting them from the catalogs buys exactly one clean commit.
    ///
    /// The risk of the mechanism is obvious — a genuinely untranslated string silenced with
    /// one boolean — so this set is asserted *exactly*, not as a ceiling. Adding a key here
    /// means editing this list, which is the same bargain the ceiling itself makes.
    ///
    /// The three product names already inside the ceiling (`Nextcloud`, `NowThis`,
    /// `NowThis Supporter`) are the same kind of decision recorded the older way; moving them here
    /// would let those ceilings fall to 0, and is worth doing when one of them is next touched.
    static let withheldFromTranslation: Set<String> = [
        "NowThis/InfoPlist.xcstrings  CFBundleDisplayName",
        "NowThis/InfoPlist.xcstrings  CFBundleName",
        "NowThisWidget/InfoPlist.xcstrings  CFBundleName",
    ]

    /// The one `stringUnit` state that means a human has signed off on this string.
    ///
    /// For a **translation** this is editorial only — every state reaches the device, so an
    /// unreviewed value ships. For the **source language** `new` really is dropped. See the
    /// suite note for the measurement.
    static let shippingState = "translated"

    // MARK: - Reading an entry

    /// What one catalog entry says about its translations.
    struct TranslationStatus {
        /// Languages with a value of some kind — translated or not.
        let present: Set<String>
        /// `(language, state)` for every value **not** marked `translated`, including the
        /// per-category units inside a plural.
        let notShipping: [(language: String, state: String)]
    }

    /// Reads an entry's translation state, plural shapes included.
    ///
    /// The recursion matters: a plural entry has **no** top-level `stringUnit`, so a reader that
    /// only looks there reports a fully-authored five-language plural as untranslated — and, worse,
    /// reports a plural whose `one` form was left at `new` as fine.
    static func translationStatus(of entry: [String: Any],
                                  languages: [String]) -> TranslationStatus {
        guard let localizations = entry["localizations"] as? [String: Any] else {
            return TranslationStatus(present: [], notShipping: [])
        }

        var present: Set<String> = []
        var notShipping: [(language: String, state: String)] = []

        for language in languages {
            guard let block = localizations[language] as? [String: Any] else { continue }
            var sawAValue = false

            for unit in Self.stringUnits(in: block) {
                sawAValue = true
                let state = (unit["state"] as? String) ?? "<none>"
                if state != Self.shippingState {
                    notShipping.append((language: language, state: state))
                }
            }
            if sawAValue { present.insert(language) }
        }
        return TranslationStatus(present: present, notShipping: notShipping)
    }

    /// Every `stringUnit` reachable from one language block: the top-level one, the whole-string
    /// plural's categories, and each substitution's categories.
    static func stringUnits(in block: [String: Any]) -> [[String: Any]] {
        var units: [[String: Any]] = []
        if let unit = block["stringUnit"] as? [String: Any] { units.append(unit) }

        func collect(_ container: [String: Any]) {
            guard let plural = (container["variations"] as? [String: Any])?["plural"]
                    as? [String: Any] else { return }
            for (_, rawCase) in plural {
                guard let unit = (rawCase as? [String: Any])?["stringUnit"] as? [String: Any]
                else { continue }
                units.append(unit)
            }
        }
        collect(block)
        for (_, rawSubstitution) in (block["substitutions"] as? [String: Any]) ?? [:] {
            guard let substitution = rawSubstitution as? [String: Any] else { continue }
            collect(substitution)
        }
        return units
    }

    // MARK: - 1. All five languages, or none

    @Test("No key is translated into some languages but not others")
    func noKeyIsPartiallyTranslated() throws {
        var keysWithAnyTranslation = 0
        var findings: [String] = []

        for catalog in LocalizationCatalogFixture.catalogs {
            for (key, entry) in try LocalizationCatalogFixture.load(catalog) {
                let status = Self.translationStatus(
                    of: entry, languages: LocalizationCatalogFixture.translationLanguages)
                guard !status.present.isEmpty else { continue }
                keysWithAnyTranslation += 1

                let missing = Set(LocalizationCatalogFixture.translationLanguages)
                    .subtracting(status.present)
                guard !missing.isEmpty else { continue }
                findings.append("""
                      \(catalog.path)  \(key)
                          has: \(status.present.sorted().joined(separator: ", "))
                          missing: \(missing.sorted().joined(separator: ", "))
                    """)
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) key(s) are translated into some languages and not others:
            \(findings.sorted().joined(separator: "\n"))

            A partly-translated key is worse than an untranslated one: it reads as done. The five
            languages ship together — a batch is a surface across all of them, never a language.
            """)
        // Anti-vacuity: at least the Phase 1 seed key must be read. Below this the walk is not
        // reaching any translation and "no partial keys" means "no keys".
        #expect(keysWithAnyTranslation >= 1, """
            No key in any catalog carries a single translation, so this test compared nothing.
            The Phase 1 seed key (`Today`, all five languages) should always be found here.
            """)
    }

    // MARK: - 2. Translations that are not marked as such

    @Test("Every translation is marked translated, not left for review")
    func everyTranslationIsMarkedShipping() throws {
        var unitsExamined = 0
        var findings: [String] = []

        for catalog in LocalizationCatalogFixture.catalogs {
            for (key, entry) in try LocalizationCatalogFixture.load(catalog) {
                let status = Self.translationStatus(
                    of: entry, languages: LocalizationCatalogFixture.translationLanguages)
                unitsExamined += status.present.count
                for problem in status.notShipping {
                    findings.append("  \(catalog.path)  \(key)  [\(problem.language)] \(problem.state)")
                }
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) translated value(s) are in a state nobody has signed off:
            \(findings.sorted().joined(separator: "\n"))

            These ship. Every state compiles — see the suite note — so a `needs_review` is not a
            string waiting safely in a file, it is unreviewed copy already on its way to a
            reader.

            A `needs_review` with an UNCHANGED value is the signature of an Xcode catalog
            rewrite — revert it, do not re-translate it. A `stale` means the English
            moved underneath it and the translation has to be re-done against the new source.
            """)
        #expect(unitsExamined >= 5, """
            \(unitsExamined) translated language blocks were examined. Below 5 not even the Phase 1
            seed key is being read.
            """)
    }

    // MARK: - 3. English plurals must be compiled in

    @Test("Every English plural is marked translated, or its rules never load")
    func everyEnglishPluralIsMarkedShipping() throws {
        var categoriesExamined = 0
        var findings: [String] = []

        for catalog in LocalizationCatalogFixture.catalogs {
            for (key, entry) in try LocalizationCatalogFixture.load(catalog) {
                guard let localizations = entry["localizations"] as? [String: Any],
                      let english = localizations["en"] as? [String: Any] else { continue }
                guard !LocalizationCatalogFixture.pluralSlots(entry).isEmpty else { continue }

                for unit in Self.stringUnits(in: english) {
                    categoriesExamined += 1
                    let state = (unit["state"] as? String) ?? "<none>"
                    guard state != Self.shippingState else { continue }
                    findings.append("  \(catalog.path)  \(key)  [en] \(state)")
                }
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) English plural value(s) are not marked translated:
            \(findings.sorted().joined(separator: "\n"))

            The plural rules are the one thing the Swift literal cannot express — that is the only
            reason they live in the catalog at all. This is the source language, where `new` is
            the one state that really is dropped: the entry is not compiled in, the
            interpolation's own text wins, and the string renders "1 tasks" with correct plural
            rules sitting unread beside it.

            Written by Translations/tools/author_plurals.py, which sets the state deliberately.
            """)
        // Measured 2026-07-26: 61 English units across the 25 plural-varied keys — 50 category
        // units plus the 11 substituted entries' top-level values.
        #expect(categoriesExamined >= 55, """
            Only \(categoriesExamined) English plural values were examined; there were 61 when
            this was written. Either the plural reader has stopped descending into `variations`
            and `substitutions`, or the authored plurals are gone.
            """)
    }

    // MARK: - 4. The ratchet

    @Test("Untranslated keys are within the dated ceiling, and translations never disappear")
    func translationProgressOnlyMovesOneWay() throws {
        var untranslated: [String: Int] = [:]
        var fullyTranslated = 0
        var withheld: Set<String> = []
        var findings: [String] = []
        let allLanguages = Set(LocalizationCatalogFixture.translationLanguages)

        for catalog in LocalizationCatalogFixture.catalogs {
            var count = 0
            for (key, entry) in try LocalizationCatalogFixture.load(catalog) {
                // Not copy, by the catalog's own declaration. Counting it as untranslated
                // asks five people to translate a bundle identifier; ignoring the flag
                // without recording it lets anybody silence a real string with one boolean.
                // So skip it here and assert the whole set below.
                if entry["shouldTranslate"] as? Bool == false {
                    withheld.insert("\(catalog.path)  \(key)")
                    continue
                }
                let status = Self.translationStatus(
                    of: entry, languages: LocalizationCatalogFixture.translationLanguages)
                if status.present.isEmpty { count += 1 }
                if status.present == allLanguages, status.notShipping.isEmpty { fullyTranslated += 1 }
            }
            untranslated[catalog.path] = count

            guard let ceiling = Self.untranslatedCeiling[catalog.path] else {
                findings.append("  \(catalog.path): no ceiling recorded — add one")
                continue
            }
            if count > ceiling {
                findings.append("  \(catalog.path): \(count) untranslated, ceiling \(ceiling)")
            }
        }

        for path in Self.untranslatedCeiling.keys
        where !LocalizationCatalogFixture.catalogs.contains(where: { $0.path == path }) {
            findings.append("  \(path): a ceiling for a catalog that is not in the fixture list")
        }

        #expect(withheld == Self.withheldFromTranslation, """
            The set of keys marked `shouldTranslate: false` is not the recorded one.

            added, and therefore now exempt from the ceiling without anybody agreeing to it:
            \(withheld.subtracting(Self.withheldFromTranslation).sorted().joined(separator: "\n  "))

            recorded but no longer marked in the catalog:
            \(Self.withheldFromTranslation.subtracting(withheld).sorted().joined(separator: "\n  "))

            A key added to the first list is a string that will ship in English to five
            countries with this suite green. Withholding is for names — a brand, a bundle
            identifier — never for a sentence. Update `withheldFromTranslation` only when the
            new entry is one of those, and say which in the commit.
            """)

        #expect(findings.isEmpty, """
            The untranslated ratchet moved the wrong way:
            \(findings.sorted().joined(separator: "\n"))

            If a string was added and not translated, translate it — that is the regression this
            whole file exists for, and it is the one that ships English to five countries with a
            green suite.

            While the catalogs are still English-only the ceiling may be RAISED, deliberately, in
            a commit somebody reads. After Phase 5 batch one it may only fall.
            """)

        #expect(fullyTranslated >= Self.fullyTranslatedFloor, """
            \(fullyTranslated) keys carry all five languages in a shipping state; the recorded
            floor is \(Self.fullyTranslatedFloor). Translations do not go backwards — a batch has
            been reverted, dropped by a catalog rewrite, or demoted to needs_review.
            """)
    }

    // MARK: - 5. No language nobody agreed to ship

    @Test("Only the five shipping languages appear in any catalog")
    func onlyShippingLanguagesAppear() throws {
        let allowed = Set(LocalizationCatalogFixture.translationLanguages + ["en"])
        var entriesExamined = 0
        var found: Set<String> = []
        var findings: [String] = []

        for catalog in LocalizationCatalogFixture.catalogs {
            for (key, entry) in try LocalizationCatalogFixture.load(catalog) {
                entriesExamined += 1
                guard let localizations = entry["localizations"] as? [String: Any] else { continue }
                for language in localizations.keys {
                    found.insert(language)
                    guard !allowed.contains(language) else { continue }
                    findings.append("  \(catalog.path)  \(key)  [\(language)]")
                }
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) localization(s) are in a language this app does not ship:
            \(findings.sorted().joined(separator: "\n"))

            Shipping languages are decided once, in the plan, and `knownRegions` is reset to
            (Base, en) by every `xcodegen generate` — so a language that reaches a catalog by some
            other route reaches no device, and a reader of the catalog cannot tell.
            """)
        #expect(found.contains("en"), "No catalog carries an `en` block at all.")
        #expect(entriesExamined >= 700,
                "Only \(entriesExamined) entries examined; there were 722 when this was written.")
    }

    // MARK: - 6. Self-checks

    @Test("The completeness reader classifies known-bad entries")
    func completenessSelfChecks() {
        let five = ["de", "es", "fr", "it", "nl"]
        func unit(_ state: String, _ value: String) -> [String: Any] {
            ["stringUnit": ["state": state, "value": value]]
        }

        // Nothing at all.
        let bare: [String: Any] = [:]
        #expect(Self.translationStatus(of: bare, languages: five).present.isEmpty)

        // English only — the state every key is in before Phase 5.
        let englishOnly: [String: Any] = ["localizations": ["en": unit("new", "Today")]]
        #expect(Self.translationStatus(of: englishOnly, languages: five).present.isEmpty)

        // German only. This is the partial case, and it must NOT read as "translated".
        let germanOnly: [String: Any] = ["localizations": [
            "en": unit("new", "Today"), "de": unit("translated", "Heute"),
        ]]
        #expect(Self.translationStatus(of: germanOnly, languages: five).present == ["de"])

        // Present but not shipping — a value the reader never sees.
        let review: [String: Any] = ["localizations": ["de": unit("needs_review", "Heute")]]
        let reviewStatus = Self.translationStatus(of: review, languages: five)
        #expect(reviewStatus.present == ["de"])
        #expect(reviewStatus.notShipping.count == 1)
        #expect(reviewStatus.notShipping.first?.state == "needs_review")

        // A plural has NO top-level stringUnit. A reader that looks only there calls this
        // untranslated — which would make the whole ratchet report five-language plurals as
        // missing, in exactly the direction that reads as "more work to do" and hides the bug.
        let plural: [String: Any] = ["localizations": ["de": ["variations": ["plural": [
            "one": unit("translated", "%lld Aufgabe"),
            "other": unit("translated", "%lld Aufgaben"),
        ]]]]]
        let pluralStatus = Self.translationStatus(of: plural, languages: five)
        #expect(pluralStatus.present == ["de"])
        #expect(pluralStatus.notShipping.isEmpty)
        #expect(Self.stringUnits(in: (plural["localizations"] as! [String: Any])["de"]
                                as! [String: Any]).count == 2)

        // One category left at `new` inside an otherwise finished plural — the single most
        // likely way a plural ships half-compiled.
        let halfPlural: [String: Any] = ["localizations": ["de": ["variations": ["plural": [
            "one": unit("new", "%lld Aufgabe"),
            "other": unit("translated", "%lld Aufgaben"),
        ]]]]]
        #expect(Self.translationStatus(of: halfPlural, languages: five).notShipping.count == 1)

        // Substitutions nest one level deeper again.
        let substituted: [String: Any] = ["localizations": ["de": [
            "stringUnit": ["state": "translated", "value": "Du hast %#@n@ in %2$@."],
            "substitutions": ["n": ["argNum": 1, "formatSpecifier": "lld",
                                    "variations": ["plural": [
                                        "one": unit("translated", "%arg Aufgabe"),
                                        "other": unit("needs_review", "%arg Aufgaben"),
                                    ]]]],
        ]]]
        let substitutedStatus = Self.translationStatus(of: substituted, languages: five)
        #expect(substitutedStatus.present == ["de"])
        #expect(substitutedStatus.notShipping.count == 1,
                "A substitution's own plural categories carry their own state and must be read.")
    }
}
