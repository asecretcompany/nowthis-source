import Foundation
import Testing

/// Xcode will happily build an app that extracts **zero** strings and say nothing about it.
///
/// Before this guard, `SWIFT_EMIT_LOC_STRINGS` was set on `NowThis` and `NowThisWidget` only.
/// `NowThisWatch` and `NowThisWatchWidget` had no extraction settings at all, so every watch
/// string would have shipped English in all five languages — with a green build, a green test
/// suite, and a catalog that simply did not contain them.
///
/// `NowThis.xcodeproj/` is gitignored, so `project.yml` is the only durable record of any of
/// this. Every assertion here is on the spec, not on generated output.
@Suite("Localization / build settings")
struct LocalizationBuildSettingsGuardTests {

    /// The four settings that make string extraction happen, named exactly.
    ///
    /// Confirmed against the prior project's `project.yml` and its guard's own `settings` array.
    /// An earlier draft of the plan named `LOCALIZED_STRING_SWIFTUI_SUPPORT`, which is not one
    /// of them — a guard written from that text would assert on a setting nobody decided.
    static let extractionSettings = [
        "SWIFT_EMIT_LOC_STRINGS",               // emit .stringsdata from Swift
        "LOCALIZATION_PREFERS_STRING_CATALOGS", // .xcstrings, not .strings
        "LOCALIZED_STRING_CODE_COMMENTS",       // carry `comment:` into the catalogs
        "STRING_CATALOG_GENERATE_SYMBOLS",      // generated symbol accessors
    ]

    /// Targets that ship to a user and therefore must extract.
    static let shippingTargets = ["NowThis", "NowThisWidget", "NowThisWatch", "NowThisWatchWidget"]

    private func spec() throws -> [String: String] {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let text = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let flat = YAMLLite.flatten(text)
        // Anti-vacuity: a parser that silently produced nothing would make every assertion
        // below pass by absence of contradiction... except they assert presence. Still, pin it.
        #expect(flat.count > 80, "Parsed only \(flat.count) paths out of project.yml — the reader is not reading.")
        return flat
    }

    @Test("All four extraction settings are on, at the project level")
    func extractionSettingsAreOnAtProjectLevel() throws {
        let flat = try spec()
        for setting in Self.extractionSettings {
            let value = flat["settings.base.\(setting)"]
            #expect(value.map(Self.isTruthy) == true, """
                settings.base.\(setting) is \(value.map { "\u{201C}\($0)\u{201D}" } ?? "absent") — expected YES.
                All four must be set once, at the project level, so a new target cannot be added
                without extraction. NowThisWatch and NowThisWatchWidget shipped with none of them.
                """)
        }
    }

    /// The assertion a line-by-line matcher cannot make.
    @Test("No shipping target overrides an extraction setting")
    func noShippingTargetOverridesExtraction() throws {
        let flat = try spec()
        for target in Self.shippingTargets {
            for setting in Self.extractionSettings {
                let path = "targets.\(target).settings.base.\(setting)"
                #expect(flat[path] == nil, """
                    \(path) is set to \u{201C}\(flat[path] ?? "")\u{201D}.
                    Extraction settings belong under `settings.base` and nowhere else. A per-target
                    copy is how three of four targets silently diverged, and a flat regex over this
                    file cannot tell the two locations apart — which is why this guard parses it.
                    """)
            }
        }
    }

    /// The one target that must NOT extract.
    ///
    /// `settings.base` reaches `NowThisTests` too. The Phase 3 scanners feed themselves known-bad
    /// input — `""`, `"123"`, `"%@"`, a planted `"To Do"` — and if the test target extracts, those
    /// fixtures become real catalog keys and every guard starts reporting on its own test data.
    @Test("NowThisTests is explicitly opted out of extraction")
    func testTargetIsOptedOut() throws {
        let flat = try spec()
        for setting in Self.extractionSettings {
            let path = "targets.NowThisTests.settings.base.\(setting)"
            let value = flat[path]
            #expect(value.map { !Self.isTruthy($0) } == true, """
                \(path) is \(value.map { "\u{201C}\($0)\u{201D}" } ?? "absent") — expected an explicit NO.
                Inheriting the project-level YES would extract the deliberately malformed fixtures
                in NowThisTests/Localization/ into a catalog, and the guards would then fail on
                strings they wrote themselves.
                """)
        }
    }

    @Test("The development language is declared")
    func developmentLanguageIsDeclared() throws {
        let flat = try spec()
        #expect(flat["options.developmentLanguage"] == "en", """
            options.developmentLanguage is \(flat["options.developmentLanguage"].map { "\u{201C}\($0)\u{201D}" } ?? "absent") — expected "en".
            Without it the source language is inferred, and the inference is not stable across
            Xcode versions.
            """)
    }

    /// A target you cannot run is a target you cannot look at.
    ///
    /// `project.yml` declared exactly one scheme. The watch app builds (it is a dependency of
    /// NowThis), so extraction happens — but pseudolocalization and the German screenshot pass
    /// are the only checks that catch the layout bug class, and both require *running* it.
    @Test("Every shipping target has a scheme")
    func everyShippingTargetHasAScheme() throws {
        let flat = try spec()
        let schemes = YAMLLite.children(of: "schemes", in: flat)
        for target in ["NowThis", "NowThisWatch"] {
            #expect(schemes.contains(target), """
                No `\(target)` scheme in project.yml. Declared schemes: \(schemes.sorted().joined(separator: ", ")).
                Since NowThis.xcodeproj/ is gitignored, every clean checkout reproduces this — there
                are no autocreated schemes to fall back on.
                """)
        }
    }

    /// `CFBundleDevelopmentRegion` in an Info.plist pins that bundle's locale and overrides the
    /// project setting, so the extension resolves English no matter what the catalog holds.
    @Test("No Info.plist pins CFBundleDevelopmentRegion")
    func noInfoPlistPinsDevelopmentRegion() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let plists = [
            "NowThis/Info.plist",
            "NowThisWidget/Info.plist",
            "NowThisWatchWidget/Info.plist",
        ]
        var examined = 0
        for relative in plists {
            let url = root.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path) else {
                Issue.record("\(relative) is missing — a plist that cannot be read must not read as clean.")
                continue
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            examined += 1
            #expect(!text.contains("CFBundleDevelopmentRegion"), """
                \(relative) pins CFBundleDevelopmentRegion. That overrides
                options.developmentLanguage for this bundle and forces English resolution
                regardless of what ships in the catalog.
                """)
        }
        #expect(examined == plists.count, "Examined \(examined) of \(plists.count) Info.plists.")
    }

    // MARK: Helpers and self-checks

    static func isTruthy(_ value: String) -> Bool {
        ["YES", "true", "TRUE", "True", "1"].contains(value)
    }

    /// The repo writes `"YES"` (quoted) while the prior regex accepted only unquoted `true`.
    /// Both spellings are normalised here, and the normalisation is pinned.
    @Test("YAML reader and truthiness self-checks")
    func readerSelfChecks() {
        #expect(Self.isTruthy("YES"))
        #expect(Self.isTruthy("true"))
        #expect(!Self.isTruthy("NO"))
        #expect(!Self.isTruthy("false"))
        #expect(!Self.isTruthy(""))

        let sample = """
            name: Demo
            options:
              developmentLanguage: en
            settings:
              base:
                SWIFT_EMIT_LOC_STRINGS: "YES"   # quoted, as this repo writes it
                OTHER: true
            targets:
              App:
                sources:
                  - path: App
                    excludes:
                      - "**/.DS_Store"
                settings:
                  base:
                    SWIFT_EMIT_LOC_STRINGS: "NO"
                dependencies:
                  - target: Ext
                    embed: true
            schemes:
              App:
                build:
                  targets:
                    App: all
            """
        let flat = YAMLLite.flatten(sample)

        #expect(flat["options.developmentLanguage"] == "en")
        // The whole point: project level and target level are distinguishable.
        #expect(flat["settings.base.SWIFT_EMIT_LOC_STRINGS"] == "YES")
        #expect(flat["targets.App.settings.base.SWIFT_EMIT_LOC_STRINGS"] == "NO")
        #expect(flat["settings.base.OTHER"] == "true")
        // Trailing comments are stripped, quotes removed.
        #expect(flat["settings.base.SWIFT_EMIT_LOC_STRINGS"]?.contains("#") == false)
        // Sequences of mappings are indexed, and a sibling key of a sequence item attaches to it.
        #expect(flat["targets.App.sources.0.path"] == "App")
        #expect(flat["targets.App.sources.0.excludes.0"] == "**/.DS_Store")
        #expect(flat["targets.App.dependencies.0.target"] == "Ext")
        #expect(flat["targets.App.dependencies.0.embed"] == "true")
        #expect(YAMLLite.children(of: "schemes", in: flat) == ["App"])
        #expect(YAMLLite.children(of: "targets", in: flat) == ["App"])
    }
}
