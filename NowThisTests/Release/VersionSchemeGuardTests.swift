import Foundation
import Testing

/// The rules, lifted out of the assertions so the self-check can feed them planted violations.
///
/// Kept as pure functions over a `String` for that reason alone — nothing here reads the
/// repository, so `theRulesCatchPlantedViolations` can prove the guard has teeth without
/// writing to `project.yml`.
enum VersionSchemeRules {

    /// `yy.mm` for a normal release, `yy.mm.v` for a mid-month fix.
    ///
    /// Two digits of year, then the month **without a leading zero**, then an optional patch
    /// starting at 1. `26.8` is August 2026; `26.8.1` is the first fix inside that month;
    /// `26.10` is October. One canonical spelling per release, because App Store Connect
    /// treats `26.8` and `26.08` as two different version trains and there is no undo.
    static func parse(_ version: String) -> (year: Int, month: Int, patch: Int?)? {
        let parts = version.components(separatedBy: ".")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }

        guard parts[0].count == 2, let year = Int(parts[0]) else { return nil }
        guard parts[1].count == String(Int(parts[1]) ?? -1).count, let month = Int(parts[1]),
              (1...12).contains(month) else { return nil }

        guard parts.count == 3 else { return (year, month, nil) }
        guard parts[2].count == String(Int(parts[2]) ?? -1).count, let patch = Int(parts[2]), patch >= 1 else { return nil }
        return (year, month, patch)
    }

    /// The first release under this scheme. Anything earlier is the old `1.0.x` line arriving
    /// through a path that happens to parse — `26` is not a plausible typo for `1`, but a
    /// two-digit year is a small enough alphabet that a floor costs nothing.
    static let firstYear = 26

    /// Empty when `version` is a well-formed calendar version. One sentence per problem
    /// otherwise, so a failure says which rule was broken rather than restating the regex.
    static func problems(with version: String) -> [String] {
        guard let parsed = parse(version) else {
            return ["\u{201C}\(version)\u{201D} is not yy.mm or yy.mm.v — "
                    + "two digits of year, a month 1–12 with no leading zero, "
                    + "and an optional patch starting at 1."]
        }
        var found: [String] = []
        if parsed.year < firstYear {
            found.append("year \(parsed.year) is before \(firstYear) — calendar versioning starts at 26.7.")
        }
        if let patch = parsed.patch, patch < 1 {
            found.append("patch \(patch) is below 1 — the month release itself is yy.mm, with no .0.")
        }
        return found
    }
}

/// NowThis moved from semantic-looking `1.0.x` to calendar versioning on 2026-07-27.
///
/// The number a release ships under is now derivable from the calendar rather than argued
/// about: the release cut in August 2026 is `26.8`, the one after it is `26.9`, and a fix
/// pushed mid-month is `26.8.1`. That is worth guarding rather than merely documenting,
/// because the failure is silent and permanent — App Store Connect accepts any string in the
/// version field, and a version once used is used forever.
///
/// This guard also ties `RELEASE_NOTES.md` to `project.yml`. Nothing did before: the file's
/// top heading carries a version and a build number that no build step reads, so a heading
/// left over from the previous release passed every check in the repository.
///
/// `NowThis.xcodeproj/` is gitignored, so `project.yml` is the only durable record.
@Suite("Release / version scheme")
struct VersionSchemeGuardTests {

    /// Repository-root documents that state contributor conventions. `README.md` is published;
    /// the other two are working files present only in the development checkout. Each is
    /// checked if present rather than asserting a fixed count, so the guard is meaningful in
    /// the public `nowthis-source` mirror (where it checks README.md) and in a full checkout
    /// (where it checks all three).
    static let contributorBriefs = ["README.md", "GEMINI.md", "CLAUDE.md"]

    private func spec() throws -> [String: String] {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let text = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let flat = YAMLLite.flatten(text)
        #expect(flat.count > 80, "Parsed only \(flat.count) paths out of project.yml — the reader is not reading.")
        return flat
    }

    private func marketingVersion() throws -> String {
        let flat = try spec()
        let value = flat["settings.base.MARKETING_VERSION"]
        #expect(value != nil, "settings.base.MARKETING_VERSION is absent from project.yml.")
        return value ?? ""
    }

    @Test("MARKETING_VERSION is a calendar version")
    func marketingVersionFollowsTheScheme() throws {
        let version = try marketingVersion()
        let problems = VersionSchemeRules.problems(with: version)
        #expect(problems.isEmpty, """
            MARKETING_VERSION \u{201C}\(version)\u{201D}: \(problems.joined(separator: " "))
            NowThis uses yy.mm — the month the release is cut — with yy.mm.v for a mid-month
            fix, on a monthly release cadence. See the Versioning section of README.md.
            """)
    }

    @Test("CURRENT_PROJECT_VERSION is a plain increasing integer")
    func buildNumberIsAnInteger() throws {
        let flat = try spec()
        let raw = flat["settings.base.CURRENT_PROJECT_VERSION"]
        #expect(raw != nil, "settings.base.CURRENT_PROJECT_VERSION is absent from project.yml.")
        let build = raw.flatMap(Int.init)
        #expect(build != nil && build! >= 1, """
            CURRENT_PROJECT_VERSION is \u{201C}\(raw ?? "absent")\u{201D} — expected a whole number.
            The build number stays a single counter across the version change; it does not
            restart at 1 for 26.8, because it is what TestFlight orders builds by.
            """)
    }

    /// The tie that did not exist. `RELEASE_NOTES.md` is the one place a human reads to find
    /// out what a build contains, and its heading was free text.
    ///
    /// Skipped where the file is absent. This suite also runs from the public `nowthis-source`
    /// mirror, which ships the sources but not the release log; a guard that hard-fails on a
    /// file the checkout was never meant to contain reports a defect that is not there.
    @Test("The top of RELEASE_NOTES.md names this exact version and build")
    func releaseNotesHeadingMatchesTheSpec() throws {
        let flat = try spec()
        let version = flat["settings.base.MARKETING_VERSION"] ?? ""
        let build = flat["settings.base.CURRENT_PROJECT_VERSION"] ?? ""

        let root = try LocalizationCatalogFixture.repositoryRoot()
        let notesURL = root.appendingPathComponent("RELEASE_NOTES.md")
        guard FileManager.default.fileExists(atPath: notesURL.path) else { return }
        let notes = try String(contentsOf: notesURL, encoding: .utf8)

        let headings = notes.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        #expect(headings.count >= 2, "Found \(headings.count) `## ` headings in RELEASE_NOTES.md — expected the file's release history.")

        let top = headings.first ?? ""
        let expected = "## v\(version) (Build \(build))"
        #expect(top.hasPrefix(expected), """
            RELEASE_NOTES.md's first release heading is \u{201C}\(top)\u{201D}, expected it to start
            \u{201C}\(expected)\u{201D}. project.yml says \(version) / build \(build). Older
            headings below it keep whatever scheme they shipped under — only the top one is
            checked, because only the top one describes the build being cut.
            """)
    }

    /// The user-facing consequence of the change is that the version number jumps from 1.0.5
    /// to 26.8, which looks like a mistake unless the repository says so where a contributor
    /// actually reads.
    ///
    /// Each brief is checked only if it is present. The contributor-facing briefs are working
    /// files that are not published to the `nowthis-source` mirror, so requiring a fixed count
    /// would fail every public checkout for a reason that has nothing to do with versioning.
    /// The regression this catches — a brief that exists but has drifted from the scheme — is
    /// still caught wherever the brief exists.
    @Test("Any contributor brief present documents the scheme")
    func theSchemeIsWrittenDownForContributors() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        for brief in Self.contributorBriefs {
            let url = root.appendingPathComponent(brief)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("yy.mm"), """
                \(brief) does not mention `yy.mm`. The versioning scheme changed on 2026-07-27
                and every brief that documents conventions has to say so — a contributor who
                reads only one of them will otherwise restore 1.0.6 as the obvious next version.
                """)
        }
    }

    @Test("The rules catch planted violations")
    func theRulesCatchPlantedViolations() {
        let accepted = ["26.7", "26.8", "26.8.1", "26.10", "26.12.14", "99.1"]
        for version in accepted {
            #expect(VersionSchemeRules.problems(with: version).isEmpty, "\(version) should be accepted.")
        }

        let rejected = [
            "1.0.5",    // the old scheme
            "1.0",      // ditto, two components
            "26.08",    // leading-zero month — a second version train for the same month
            "26.8.0",   // .0 is the month release itself, spelled yy.mm
            "26.13",    // not a month
            "26.0",     // not a month
            "2026.8",   // four-digit year
            "26",       // one component
            "26.8.1.1", // four components
            "26.8.x",   // non-numeric
            "v26.8",    // the `v` belongs to the heading, not the field
            "26. 8",    // whitespace
            "",         // empty
            "25.8",     // before the scheme existed
        ]
        for version in rejected {
            #expect(!VersionSchemeRules.problems(with: version).isEmpty, "\(version) should be rejected.")
        }
        #expect(accepted.count + rejected.count == 20, "The self-check examined the wrong number of versions.")
    }
}
