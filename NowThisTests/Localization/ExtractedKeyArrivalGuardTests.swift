import Foundation
import Testing

/// Every key **the compiler extracted**, checked against the catalog it must land in.
///
/// `LocalizedLiteralArrivalGuardTests` asks the same question of the source text, and answers it
/// for the `localized:` forms — `String(localized:)`, `LocalizedStringResource(...)`, and the
/// wrapped spellings of both. That is where the question was first asked, and it caught a real
/// escape. But it is anchored on the `localized:` argument label, and most of this app's copy
/// never writes one:
///
/// ```swift
/// Text("Nothing in \(list.name) yet.")
/// ```
///
/// is a localized literal. `Text` takes `LocalizedStringKey`, the compiler extracts it into
/// `.stringsdata`, and it needs a catalog entry in five languages exactly like every other
/// string. It contains no `localized:`, so the source scanner cannot see it — and neither can
/// anything else here. `Nothing in %@ yet.` was added, compiled, rendered, and the whole suite
/// stayed green with the key in no catalog at all. Same for `Label`, `Button`, `Toggle`,
/// `Section`, `Picker`, `.navigationTitle` and every `.accessibility*` modifier.
///
/// So this guard does not read the source. It reads what the build produced, which is the only
/// account of what was extracted that cannot disagree with the compiler:
///
///     DerivedData/<proj>/Build/Intermediates.noindex/**/<Target>.build/Objects-normal/*.stringsdata
///
/// ## Finding the build without guessing
///
/// `sync_catalogs.py` used to glob `DerivedData/NowThis-*` and take the newest by mtime, which
/// asks "who built last anywhere on this machine?" — four checkouts here, and the answer changed
/// whenever anyone else built. This has no such problem and must never grow one: a test runs
/// *inside* the build it is asking about, so it walks up from its own bundle to the enclosing
/// `Build` directory. There is nothing to match and nothing to choose.
///
/// ## What it does not assert
///
/// Only that extracted keys **arrive**. Whether they are translated is
/// ``LocalizationCompletenessGuardTests``; whether the shape is right is the plural and
/// substitution guards. And it asserts nothing about keys in a catalog that the build did not
/// extract — an incremental build legitimately produces a partial picture, and `--prune` in
/// `sync_catalogs.py` is where that direction is handled, deliberately behind a flag.
@Suite("Localization / extracted keys arrive")
struct ExtractedKeyArrivalGuardTests {

    /// `(build target, .stringsdata table) → catalog`. Mirrors `TARGET_CATALOGS` in
    /// `Translations/tools/sync_catalogs.py`. `InfoPlist` is absent from both because no
    /// `.stringsdata` carries an `InfoPlist` table — those keys are read from `Info.plist`.
    static let catalogOfTable: [String: [String: String]] = [
        "NowThis": ["Localizable": "NowThis/Localizable.xcstrings",
                    "AppShortcuts": "NowThis/AppShortcuts.xcstrings"],
        "NowThisWidget": ["Localizable": "NowThisWidget/Localizable.xcstrings"],
        "NowThisWatch": ["Localizable": "NowThisWatch/Localizable.xcstrings"],
        "NowThisWatchWidget": ["Localizable": "NowThisWatchWidget/Localizable.xcstrings"],
    ]

    /// The target that always builds when this test does, so "examined nothing" is a failure
    /// rather than a pass. The watch targets are not part of the `NowThis` scheme and are
    /// checked only when a build of them happens to be present.
    static let alwaysBuilt = "NowThis"

    // MARK: - Locating this build

    /// The `Build` directory of the DerivedData tree that produced this test run.
    ///
    /// **Not** derived from `Bundle.main`. On a simulator destination the app is installed into
    /// the device's own container — `.../CoreSimulator/Devices/<id>/data/Containers/...` — which
    /// has no `Build` component to walk up to and says nothing about where it was compiled.
    ///
    /// `__XCODE_BUILT_PRODUCTS_DIR_PATHS` is set by the test runner to the products directory of
    /// *this* build. It is the exact answer rather than a search, which is the whole point: the
    /// bug that motivated this file's sibling in `sync_catalogs.py` was a search over four
    /// checkouts resolved by mtime.
    ///
    /// It is a private Xcode variable and could be renamed by a future toolchain. That is why its
    /// absence throws: a guard that cannot find the build it is asking about must fail, never
    /// quietly examine nothing.
    static func buildDirectory() throws -> URL {
        let key = "__XCODE_BUILT_PRODUCTS_DIR_PATHS"
        guard let raw = ProcessInfo.processInfo.environment[key],
              let first = raw.components(separatedBy: ":").first,
              !first.isEmpty
        else {
            throw LocalizationFixtureError.repositoryRootNotFound(startingFrom: key)
        }

        var url = URL(fileURLWithPath: first)
        while url.pathComponents.count > 1 {
            if url.lastPathComponent == "Build" {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        throw LocalizationFixtureError.repositoryRootNotFound(startingFrom: first)
    }

    /// The build target owning a `.../<Target>.build/Objects-normal/<arch>` path.
    ///
    /// Matching on `"/<Target>.build/"` appearing anywhere is wrong: intermediates nest as
    /// `<Project>.build/<Config>-<sdk>/<Target>.build/...`, so every watch and widget path
    /// contains `/NowThis.build/` too and their strings would be attributed to the app. The
    /// target is the `.build` component immediately above `Objects-normal`, and nothing else.
    static func target(ofObjectsNormal path: URL) -> String? {
        let parts = path.pathComponents
        guard let index = parts.firstIndex(of: "Objects-normal"), index > 0 else { return nil }
        let owner = parts[index - 1]
        guard owner.hasSuffix(".build") else { return nil }
        return String(owner.dropLast(".build".count))
    }

    /// `target → table → keys`, taking the freshest `.stringsdata` per producer.
    ///
    /// A target is built once per SDK *and* per architecture, and old trees are never pruned, so
    /// reading the union resurrects keys deleted from the source hours ago — which here would
    /// fail the build over a string that no longer exists. Keyed on `(file name, source)` rather
    /// than `source` alone, because two extraction products can name the same source file:
    /// `ExtractedAppShortcutsMetadata.stringsdata` and `NowThisShortcuts.stringsdata` both name
    /// `NowThisShortcuts.swift`, and collapsing them drops every `shortTitle` key.
    static func extractedKeys() throws -> [String: [String: Set<String>]] {
        let intermediates = try buildDirectory().appendingPathComponent("Intermediates.noindex")
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: intermediates,
                                              includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [:] }

        struct Producer: Hashable {
            let target: String
            let fileName: String
            let source: String
        }
        var freshest: [Producer: (Date, [String: Any])] = [:]

        for case let file as URL in walker where file.pathExtension == "stringsdata" {
            guard let target = target(ofObjectsNormal: file) else { continue }
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let producer = Producer(target: target,
                                    fileName: file.lastPathComponent,
                                    source: (json["source"] as? String) ?? file.path)
            if let existing = freshest[producer], existing.0 >= stamp { continue }
            freshest[producer] = (stamp, json)
        }

        var out: [String: [String: Set<String>]] = [:]
        for (producer, entry) in freshest {
            guard let tables = entry.1["tables"] as? [String: Any] else { continue }
            for (table, rows) in tables {
                guard let rows = rows as? [[String: Any]] else { continue }
                for row in rows {
                    guard let key = row["key"] as? String, !key.isEmpty else { continue }
                    out[producer.target, default: [:]][table, default: []].insert(key)
                }
            }
        }
        return out
    }

    // MARK: - The assertion

    @Test("Every key this build extracted is in the catalog it resolves against")
    func everyExtractedKeyIsInItsCatalog() throws {
        let extracted = try Self.extractedKeys()

        #expect(extracted[Self.alwaysBuilt] != nil, """
            No .stringsdata was found for \(Self.alwaysBuilt) under this build. That is the shape \
            of a guard examining nothing and reporting success, so it fails instead.
            """)

        var missing: [String] = []
        var examined = 0
        var checkedTargets: [String] = []

        for (target, tables) in extracted.sorted(by: { $0.key < $1.key }) {
            guard let catalogs = Self.catalogOfTable[target] else { continue }
            checkedTargets.append(target)
            for (table, keys) in tables.sorted(by: { $0.key < $1.key }) {
                guard let path = catalogs[table] else { continue }
                guard let ref = LocalizationCatalogFixture.catalogs.first(where: { $0.path == path })
                else {
                    missing.append("\(path) is not in LocalizationCatalogFixture.catalogs")
                    continue
                }
                let entries = try LocalizationCatalogFixture.load(ref)
                for key in keys.sorted() {
                    examined += 1
                    if entries[key] == nil {
                        missing.append("\(path) has no entry for \"\(key)\" (extracted from \(target))")
                    }
                }
            }
        }

        #expect(examined > 300, """
            examined only \(examined) extracted keys across \(checkedTargets.joined(separator: ", ")). \
            The app alone has hundreds, so a number this small means the walk found almost nothing \
            and the check below is close to vacuous.
            """)

        #expect(missing.isEmpty, """
            Keys the compiler extracted that no catalog carries:

              \(missing.joined(separator: "\n  "))

            The string compiles and renders in English, VoiceOver reads it, every other guard \
            stays green — and it ships untranslated in all five languages. Run
            `python3 Translations/tools/sync_catalogs.py --apply` to add them, then translate.
            """)
    }

    /// The extractor's own self-check. Nothing above can tell a correct walk from one that
    /// silently matched nothing, and `target(ofObjectsNormal:)` is the part most likely to go
    /// quietly wrong.
    @Test("The target attribution reads the component above Objects-normal, not any .build")
    func targetAttributionSelfChecks() {
        func target(_ path: String) -> String? {
            ExtractedKeyArrivalGuardTests.target(ofObjectsNormal: URL(fileURLWithPath: path))
        }

        // The nesting that makes a `contains` match wrong: NowThis.build encloses the widget's.
        #expect(target("/d/NowThis.build/Debug-iphonesimulator/NowThisWidget.build/Objects-normal/arm64")
                == "NowThisWidget")
        #expect(target("/d/NowThis.build/Debug-iphonesimulator/NowThis.build/Objects-normal/arm64")
                == "NowThis")
        #expect(target("/d/NowThis.build/Debug/Objects-normal/arm64") == nil,
                "a component that is not a .build owns nothing")
        #expect(target("/d/NowThis.build/Debug-iphonesimulator") == nil,
                "no Objects-normal, no attribution")
    }
}
