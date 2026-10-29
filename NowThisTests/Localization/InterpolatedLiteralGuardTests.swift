import Foundation
import Testing

/// Guards the defect class where a bare English literal is smuggled into a localized
/// string as an **interpolation argument**.
///
/// ## Why the other guards cannot see it
///
/// `ViewCopyGuardTests` checks that copy reaches SwiftUI through a *literal*, so the
/// localizing overload binds. That check passes here: the outer string genuinely is a
/// literal, it genuinely extracts, and the key genuinely lands in the catalog fully
/// translated. `TaskDetailView.swift` shipped
///
/// ```swift
/// .accessibilityLabel("Location, \(task.locationName ?? "not set")")
/// ```
///
/// which extracts as `Location, %@` — present in the catalog with de `Ort, %@`, es
/// `Ubicación, %@`, fr `Lieu, %@`, it `Luogo, %@`, nl `Locatie, %@`. Every catalog guard
/// is green and the coverage report shows 100%.
///
/// But `%@` is filled at runtime by `task.locationName ?? "not set"`, and `"not set"` is a
/// plain Swift `String` that the compiler never emitted. A German user with no location on
/// a task hears VoiceOver say **"Ort, not set"**, while the screen beside it correctly
/// reads "Keiner" from `location.none`. Found by screenshotting in German and reading the
/// accessibility tree, not by any assertion in this suite.
///
/// The repo has already had to fix this twice — `CalendarDayDetailView` (`completed` /
/// `pending`) and `CalendarWeekView` (`, overdue`) both carry comments describing the same
/// mistake. A class fixed twice and re-broken once is a class that needs a guard.
///
/// ## What counts
///
/// A quoted literal containing prose, appearing **inside** a `\( … )` interpolation. Not
/// flagged: empty strings (`?? ""`), punctuation and separators (`", "`), format
/// specifiers, and anything inside a comment — the two already-fixed sites document the
/// old broken code in prose, and a scanner that reads comments would report them forever.
@Suite("Interpolation arguments are not bare English")
struct InterpolatedLiteralGuardTests {

    /// Where user-facing copy lives. Same surface as the view-copy guard, plus the watch
    /// target, whose strings cross into a second catalog.
    static let surfaceDirectories = [
        "NowThis/Views/",
        "NowThis/Intents/",
        "NowThis/Models/",
        "NowThis/Utilities/",
        "NowThisWatch/",
    ]

    /// A literal is prose if it carries two or more consecutive letters. `", "`, `"%@"`,
    /// `""` and `"—"` are separators and formatting, not copy.
    static func isProse(_ s: String) -> Bool {
        var run = 0
        for ch in s {
            if ch.isLetter {
                run += 1
                if run >= 2 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    struct Hit {
        let file: String
        let line: Int
        let literal: String
    }

    /// Walks Swift source tracking string, comment and interpolation state, and returns
    /// every prose literal found inside an interpolation.
    ///
    /// Hand-rolled rather than regex because the thing being detected is a quote nested
    /// inside a quote — the case regular expressions get wrong.
    static func scan(_ source: String, file: String) -> (hits: [Hit], interpolations: Int) {
        var hits: [Hit] = []
        var interpolations = 0
        var line = 1

        // Depth 0 = ordinary code. Entering `\(` inside a string pushes a level; the
        // literals we care about live at depth >= 1.
        var interpolationDepth = 0
        var parenDepth: [Int] = []
        var inString = false
        var inLineComment = false
        var inBlockComment = false
        var current = ""

        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : "\0"

            if ch == "\n" {
                line += 1
                inLineComment = false
                i += 1
                continue
            }
            if inLineComment { i += 1; continue }
            if inBlockComment {
                if ch == "*" && next == "/" { inBlockComment = false; i += 2; continue }
                i += 1
                continue
            }
            if !inString && ch == "/" && next == "/" { inLineComment = true; i += 2; continue }
            if !inString && ch == "/" && next == "*" { inBlockComment = true; i += 2; continue }

            if inString {
                if ch == "\\" && next == "(" {
                    interpolationDepth += 1
                    interpolations += 1
                    parenDepth.append(0)
                    inString = false
                    current = ""
                    i += 2
                    continue
                }
                if ch == "\\" { i += 2; continue }   // any other escape
                if ch == "\"" {
                    if interpolationDepth > 0 && Self.isProse(current) {
                        hits.append(Hit(file: file, line: line, literal: current))
                    }
                    inString = false
                    current = ""
                    i += 1
                    continue
                }
                current.append(ch)
                i += 1
                continue
            }

            if ch == "\"" { inString = true; current = ""; i += 1; continue }

            if interpolationDepth > 0 {
                if ch == "(" { parenDepth[parenDepth.count - 1] += 1 }
                if ch == ")" {
                    if parenDepth[parenDepth.count - 1] == 0 {
                        interpolationDepth -= 1
                        parenDepth.removeLast()
                        inString = true          // back into the enclosing literal
                        current = ""
                    } else {
                        parenDepth[parenDepth.count - 1] -= 1
                    }
                }
            }
            i += 1
        }
        return (hits, interpolations)
    }

    @Test("No bare English literal is passed as an interpolation argument")
    func noBareLiteralInsideInterpolation() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var filesScanned = 0
        var interpolationsExamined = 0
        var hits: [Hit] = []

        for dir in Self.surfaceDirectories {
            let base = root.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                let result = Self.scan(text, file: rel)
                filesScanned += 1
                interpolationsExamined += result.interpolations
                hits.append(contentsOf: result.hits)
            }
        }

        // Anti-vacuity. A scanner that examined nothing reports success, and this one has
        // three separate ways to examine nothing: a wrong root, a renamed directory, or a
        // state machine that never enters a string. Pin all three with real numbers.
        #expect(filesScanned > 60, "Scanned only \(filesScanned) files — the walker is not walking.")
        #expect(interpolationsExamined > 100,
                "Found only \(interpolationsExamined) interpolations — the state machine is not entering them.")

        let report = hits
            .map { "  \($0.file):\($0.line) — \u{201C}\($0.literal)\u{201D}" }
            .joined(separator: "\n")
        #expect(hits.isEmpty, """
            \(hits.count) bare English literal(s) used as interpolation arguments:

            \(report)

            The enclosing string extracts and translates fine; the placeholder it fills does
            not. This ships English inside an otherwise-translated sentence, and when the
            site is an accessibility label it is invisible to sighted review — VoiceOver
            speaks the English while the screen shows the translation.

            Give the argument its own String(localized:key:defaultValue:comment:), or reuse
            the key the visible label already uses.
            """)
    }

    /// The scanner must find a literal that is genuinely nested, ignore one in a comment,
    /// and ignore separators. Without this, a state machine that silently matched nothing
    /// would make the guard above pass forever.
    @Test("The scanner detects nesting, skips comments, and skips separators")
    func scannerSelfCheck() {
        let sample = #"""
        let a = "Location, \(name ?? "not set")"
        // let b = "Status, \(done ? "completed" : "pending")"
        let c = "\(title), \(count)"
        let d = "\(title)\(flag ? ", " : "")"
        let e = "Due \(formatter.string(from: date))"
        """#
        let result = Self.scan(sample, file: "sample.swift")

        #expect(result.interpolations >= 6,
                "Only \(result.interpolations) interpolations seen in the sample.")
        #expect(result.hits.count == 1,
                "Expected exactly the one live literal, got \(result.hits.map(\.literal))")
        #expect(result.hits.first?.literal == "not set")
    }
}
