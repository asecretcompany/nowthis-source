import Foundation
import Testing

/// **Does a translated catalog actually reach the device?**
///
/// Every other guard in this suite is a static scan of the source tree. All of them can be green
/// while the built product ships English only — and that is not hypothetical. `xcodegen generate`
/// resets `knownRegions` to `(Base, en)` on every run, and XcodeGen 2.45.4 has no way to declare
/// otherwise (a `knownRegions:` key under `options` is accepted and silently ignored; verified
/// against the generated pbxproj). If that reset dropped non-English `.lproj` from the bundle,
/// the entire project would produce five translated catalogs that never reach a phone.
///
/// Three things silently depend on the answer: the AI-disclosure sheet reads
/// `Bundle.main.preferredLocalizations.first`, `ExtractAppIntentsMetadata` builds phrases per
/// available localization, and the App Store product page's Languages field is derived from the
/// binary.
///
/// **Measured, 2026-07-24:** seeding five languages on one key produced
/// `NowThis.app/{de,es,fr,it,nl}.lproj/Localizable.strings` on a build whose `knownRegions` was
/// still `(Base, en)`. Accepting the reset is therefore correct — and now tested rather than
/// assumed. Note there is no `en.lproj`: English is the development language and English-as-key
/// strings resolve from the binary's default table, so the expected count is **five**, not six.
///
/// These tests run inside the app host, so `Bundle.main` **is** the built `NowThis.app` — the
/// real product, not a description of it.
@Suite("Localization / built bundle")
struct LocalizationBundleGuardTests {

    /// The invariant, stated so it grows on its own: **every language a catalog carries must
    /// appear in the bundle that catalog belongs to.** No hardcoded language list, so this
    /// tightens automatically as each Phase 5 batch lands rather than needing an edit.
    @Test("Every language in a catalog reaches its built bundle")
    func everyTranslatedLanguageReachesItsBundle() throws {
        var examined = 0
        var assertions = 0

        for catalog in LocalizationCatalogFixture.catalogs {
            let expected = try LocalizationCatalogFixture.translatedLanguages(in: catalog)
            examined += 1
            guard !expected.isEmpty else { continue }

            let bundleURL = try Self.bundleURL(for: catalog)
            guard let bundle = Bundle(url: bundleURL) else {
                Issue.record("""
                    Could not open the bundle for \(catalog.path) at:
                      \(bundleURL.path)
                    A bundle that cannot be opened must not read as "no missing languages".
                    """)
                continue
            }
            let shipped = Set(bundle.localizations)
            let missing = expected.subtracting(shipped)
            assertions += 1

            #expect(missing.isEmpty, """
                \(catalog.path) carries translations for \(expected.sorted().joined(separator: ", ")),
                but \(bundleURL.lastPathComponent) ships only \(shipped.sorted().joined(separator: ", ")).
                Missing: \(missing.sorted().joined(separator: ", ")).

                The catalog is not reaching the device. Check that the .xcstrings is inside one of
                the four globbed source paths in project.yml — anything elsewhere is dropped
                silently by `xcodegen generate` — and that the target has all four extraction
                settings from settings.base.
                """)
        }

        #expect(examined == LocalizationCatalogFixture.catalogs.count,
                "Examined \(examined) of \(LocalizationCatalogFixture.catalogs.count) catalogs.")
        // Until Phase 5, only one catalog carries translations. Once every catalog does, this
        // floor rises with them; it exists so "0 catalogs had anything to check" cannot pass
        // as evidence that translations ship.
        #expect(assertions >= 1, """
            No catalog carried a single non-English translation, so this guard proved nothing.
            It is a scan over an empty set, which is exactly the failure mode this suite exists
            to prevent.
            """)
    }

    /// Anti-vacuity for the whole suite: the catalogs exist, are parseable, and are not empty.
    @Test("Every catalog exists and clears its key floor")
    func everyCatalogClearsItsFloor() throws {
        for catalog in LocalizationCatalogFixture.catalogs {
            let strings = try LocalizationCatalogFixture.load(catalog)
            #expect(strings.count >= catalog.keyFloor, """
                \(catalog.path) holds \(strings.count) keys; the floor measured at first
                extraction is \(catalog.keyFloor).
                Either strings were deleted, or a build stopped extracting for this target.
                Re-run: python3 Translations/tools/sync_catalogs.py
                """)
        }
    }

    /// The Python tools iterate `xcstrings.py CATALOGS`; the Swift guards iterate
    /// `LocalizationCatalogFixture.catalogs`. Two lists is one list plus a way to disagree.
    @Test("The Swift and Python catalog lists are the same list",
          .enabled(if: LocalizationCatalogFixture.repositoryFileExists("Translations/tools/xcstrings.py")))
    func catalogListsAgree() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let toolURL = root.appendingPathComponent("Translations/tools/xcstrings.py")
        let source = try String(contentsOf: toolURL, encoding: .utf8)

        guard let start = source.range(of: "CATALOGS = ["),
              let end = source.range(of: "]", range: start.upperBound..<source.endIndex) else {
            Issue.record("Could not find the CATALOGS list in Translations/tools/xcstrings.py.")
            return
        }
        let block = String(source[start.upperBound..<end.lowerBound])
        let pythonPaths = Set(SwiftSourceScanner.stringLiterals(in: block, file: "xcstrings.py").map(\.text))
        let swiftPaths = Set(LocalizationCatalogFixture.catalogs.map(\.path))

        #expect(pythonPaths == swiftPaths, """
            The catalog lists disagree.
              only in xcstrings.py: \(pythonPaths.subtracting(swiftPaths).sorted())
              only in the fixture:  \(swiftPaths.subtracting(pythonPaths).sorted())
            A catalog on one list and not the other is written by the tools and never guarded,
            or guarded and never written.
            """)
    }

    /// No catalog outside the four globbed source paths. One placed elsewhere compiles into
    /// nothing and is invisible to both halves.
    @Test("No stray catalogs outside the four source roots")
    func noStrayCatalogs() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let known = Set(LocalizationCatalogFixture.catalogs.map(\.path))
        var found: Set<String> = []

        for sourceRoot in LocalizationCatalogFixture.sourceRoots + ["NowThisTests"] {
            let dir = root.appendingPathComponent(sourceRoot)
            guard let walker = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                throw LocalizationFixtureError.directoryWalkCouldNotStart(path: dir.path)
            }
            for case let url as URL in walker where url.pathExtension == "xcstrings" {
                // The *full* relative path, not `sourceRoot + basename`. A catalog at
                // NowThis/Models/Localizable.xcstrings — the specific trap below — would
                // otherwise record as "NowThis/Localizable.xcstrings" and collide with the
                // real one, making the exact case this test exists for invisible to it.
                let rootPath = root.standardizedFileURL.path + "/"
                let filePath = url.standardizedFileURL.path
                found.insert(filePath.hasPrefix(rootPath)
                             ? String(filePath.dropFirst(rootPath.count))
                             : filePath)
            }
        }

        #expect(found == known, """
            Catalogs on disk do not match the fixture list.
              on disk, unknown: \(found.subtracting(known).sorted())
              listed, missing:  \(known.subtracting(found).sorted())
            A catalog under NowThis/Models/ is the specific trap: that directory is compiled into
            NowThisWidget too, so it would join both targets' resource phases under one name.
            A catalog under NowThisTests/ means the test target started extracting.
            """)
    }

    /// **Can an English speaker resolve English from this bundle at all?**
    ///
    /// Every other check here asks whether the *translations* arrive. None asked whether the
    /// source language does — and it does not arrive by being the source language. A bundle
    /// offers English only if it carries an `en.lproj` or declares `CFBundleDevelopmentRegion`;
    /// with neither, `en` is simply absent from `Bundle.localizations`, and iOS resolves the
    /// reader's *next* preferred language instead.
    ///
    /// **Measured, 2026-08-28**, on the real built product. `NowThisWidget.appex` shipped
    /// `[de, es, fr, it, nl]` with `developmentLocalization == nil`, because the target sets
    /// `GENERATE_INFOPLIST_FILE: "NO"` (so no region is generated, unlike the app and the watch
    /// app, which inherit `"YES"`) and its catalog emits no `en.lproj`. Running the negotiation
    /// iOS runs, `Bundle.preferredLocalizations(from:forPreferences:)`:
    ///
    ///     ["en", "es"] -> ["es"]      a reader with Spanish second got a Spanish widget
    ///     ["en"]       -> ["de"]      a reader with only English got a German one
    ///
    /// `NowThisWatchWidget.appex` sets the same flag and escaped only because its catalog does
    /// emit an `en.lproj`. Either condition alone is enough, which is why this asserts the
    /// outcome — English is reachable — rather than either mechanism that provides it.
    @Test("Every shipping bundle can resolve the development language")
    func everyBundleOffersTheDevelopmentLanguage() throws {
        let source = "en"
        var examined = 0

        // Several catalogs share one bundle; each bundle is asked once.
        var seen: Set<String> = []
        for catalog in LocalizationCatalogFixture.catalogs {
            let bundleURL = try Self.bundleURL(for: catalog)
            guard seen.insert(bundleURL.path).inserted else { continue }

            guard let bundle = Bundle(url: bundleURL) else {
                Issue.record("""
                    Could not open the bundle for \(catalog.path) at:
                      \(bundleURL.path)
                    A bundle that cannot be opened must not read as "English is fine here".
                    """)
                continue
            }
            examined += 1

            let offered = Set(bundle.localizations)
            #expect(offered.contains(source), """
                \(bundleURL.lastPathComponent) does not offer "\(source)". It ships \
                \(offered.sorted().joined(separator: ", ")), and its developmentLocalization is \
                \(bundle.developmentLocalization ?? "nil").

                An English reader resolves \
                \(Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [source])) \
                from this bundle instead of English.

                Give the target a generated Info.plist (drop any GENERATE_INFOPLIST_FILE: "NO",
                so CFBundleDevelopmentRegion is written for it the way it is for NowThis and
                NowThisWatch), or give its catalog explicit English values so an en.lproj is
                emitted. Either one is enough.
                """)
        }

        #expect(examined >= 4, """
            Examined \(examined) bundles. The four shipping bundles — app, widget, watch app and
            watch complication — must each be asked, or this guard proved nothing.
            """)
    }

    // MARK: Helpers

    private static func bundleURL(for catalog: LocalizationCatalogFixture.CatalogRef) throws -> URL {
        let app = Bundle.main.bundleURL
        guard let relative = catalog.bundleRelativePath else { return app }
        return app.appendingPathComponent(relative)
    }
}
