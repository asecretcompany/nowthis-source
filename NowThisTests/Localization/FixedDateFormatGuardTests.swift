import Foundation
import Testing

/// A `DateFormatter` with a **fixed `dateFormat`** parses and emits a machine format, and must
/// pin `Locale(identifier: "en_US_POSIX")`. Without it the formatter follows the *user's* region
/// calendar, and `yyyy` becomes the Buddhist or Japanese era year.
///
/// This is not theoretical here. `SyncEngine` scans raw ICS for `COMPLETED:` timestamps to decide
/// which completed tasks fall inside the sync window. Under a Buddhist calendar the parse
/// silently fails, every completed task looks undateable, and the window filter stops working —
/// with no error anywhere. Nine other formatters in the repo set the locale correctly; three did
/// not.
///
/// Note what this guard does **not** catch, and why §2f exists separately: nothing here involves
/// a `DateFormatter` at all when `DueDateHelper` mixes calendar identities directly.
@Suite("Localization / fixed date formats")
struct FixedDateFormatGuardTests {

    /// Formatters that deliberately follow the **user's** locale because their output is read by
    /// a person. Each needs a reason, and each is a bug of a different kind — a fixed
    /// `dateFormat` on a display string hardcodes day-month order, which is wrong in de/fr/it/nl.
    /// Empty, and that is the correct state. `TaskListView`'s range headers were the only entry;
    /// §2d-ii replaced them with `Date.FormatStyle`, which has no `dateFormat` at all. A
    /// user-facing formatter should not need an allowlist — it should not have a fixed pattern.
    static let displayFacingAllowlist: [String: String] = [:]

    @Test("Every machine-format DateFormatter pins en_US_POSIX")
    func machineFormattersPinPOSIXLocale() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var examined = 0
        var findings: [String] = []

        for file in try LocalizationCatalogFixture.swiftSourceFiles() {
            let raw = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            // Comments blanked, literals kept — `"en_US_POSIX"` *is* a literal, so the fully
            // redacted form would blank the very token being looked for. A planted unpinned
            // formatter went undetected here because a comment fifteen lines above mentioned
            // `en_US_POSIX` in prose (L40); the same shape as L35, in a different guard.
            let source = SwiftSourceScanner.strippingComments(raw)
            guard source.contains("dateFormat = ") else { continue }
            let lines = source.components(separatedBy: "\n")

            for (index, line) in lines.enumerated() where line.contains("dateFormat = ") {
                examined += 1
                if Self.displayFacingAllowlist[file] != nil { continue }

                // The locale assignment sits within a few lines of the format in every correct
                // site in this repo; ±15 is generous and keeps the scan from needing to know
                // which variable is which.
                let window = lines[max(0, index - 15)...min(lines.count - 1, index + 15)]
                if !window.joined(separator: "\n").contains("en_US_POSIX") {
                    findings.append("  \(file):\(index + 1)  \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) fixed-format DateFormatter(s) do not pin en_US_POSIX:
            \(findings.joined(separator: "\n"))

            Set `formatter.locale = Locale(identifier: "en_US_POSIX")`. Under a non-Gregorian
            region calendar `yyyy` is the era year, so the format silently stops round-tripping.
            If the formatter is genuinely user-facing, it should not have a fixed dateFormat at
            all — use a localized template and add it to displayFacingAllowlist with a reason.
            """)

        // Anti-vacuity, and it has teeth: this number is the count of fixed-format sites in the
        // repo. If a refactor moves them all behind a helper, this goes red and the guard gets
        // re-pointed rather than quietly scanning nothing.
        // 11 as of §2d-ii, down from 14: `TaskListView`'s three display-facing patterns became
        // `Date.FormatStyle` and have no `dateFormat` to find. The remaining eleven are all ICS
        // protocol formatters, and none of them may lose its pattern or its `en_US_POSIX` locale.
        #expect(examined >= 11, """
            Examined only \(examined) fixed-dateFormat sites; expected at least 11.
            Either the scan stopped early or the formatters moved.
            """)

        // Rot check. Existence of the *file* was the old test and it could not rot: §2d-ii
        // removed every fixed pattern from `TaskListView` and the entry would have stayed green
        // forever, excusing the next `dateFormat =` to appear there. The allowlist has to name a
        // file that still has something to excuse.
        for (file, _) in Self.displayFacingAllowlist {
            guard let source = try? String(
                contentsOf: root.appendingPathComponent(file), encoding: .utf8) else {
                Issue.record("Allowlist rot: \(file) no longer exists.")
                continue
            }
            #expect(SwiftSourceScanner.strippingComments(source).contains("dateFormat = "), """
                Allowlist rot: \(file) has no fixed `dateFormat` left to excuse. Delete the entry —
                a live exemption over nothing will silently forgive the next one that lands here.
                """)
        }
    }

    /// `strippingComments` is what stands between this guard and a comment satisfying it. Its
    /// two failure directions are opposite and both fatal: strip too little and prose passes the
    /// check; strip a literal's contents and every correctly pinned formatter looks unpinned.
    @Test("Comment stripping removes prose and preserves literals")
    func commentStrippingSelfChecks() {
        let stripped = SwiftSourceScanner.strippingComments("""
            // must keep the en_US_POSIX locale
            let a = 1
            /* block mentioning en_US_POSIX */
            f.locale = Locale(identifier: "en_US_POSIX")
            let s = "// not a comment, en_US_POSIX inside a literal"
            """)
        let lines = stripped.components(separatedBy: "\n")
        #expect(lines.count == 5, "line numbering must survive stripping")
        #expect(!lines[0].contains("en_US_POSIX"), "a `//` comment must not satisfy the check")
        #expect(!lines[2].contains("en_US_POSIX"), "a `/* */` comment must not satisfy the check")
        #expect(lines[3].contains("en_US_POSIX"), "the real `Locale(identifier:)` must survive")
        #expect(lines[4].contains("en_US_POSIX"), "`//` inside a literal is not a comment")
        #expect(lines[1].contains("let a = 1"), "ordinary code must be untouched")
    }

    /// Demonstrates the failure the guard prevents, so the rule is not folklore.
    @Test("Scanner self-check: the hazard is real")
    func hazardIsReal() throws {
        let iso = "20260701T120000Z"

        func parse(locale: Locale?) -> Date? {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            f.timeZone = TimeZone(identifier: "UTC")
            if let locale { f.locale = locale }
            return f.date(from: iso)
        }

        let posix = parse(locale: Locale(identifier: "en_US_POSIX"))
        #expect(posix != nil, "en_US_POSIX must parse an ICS UTC timestamp.")

        // The same string, the same pattern, a user in Thailand with the Buddhist calendar.
        let buddhist = parse(locale: Locale(identifier: "th_TH@calendar=buddhist"))
        #expect(buddhist != posix, """
            A Buddhist-calendar locale parsed \(iso) to the same instant as en_US_POSIX. If that
            is genuinely true on this OS version the hazard may have changed shape — verify
            before weakening the guard above, because SyncEngine's COMPLETED: window depends on it.
            """)
    }
}
