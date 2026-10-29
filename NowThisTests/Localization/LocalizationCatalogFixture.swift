import Foundation

// MARK: - Errors

/// Every failure mode in this file **throws**.
///
/// A walk that cannot start is not a walk with no findings. The guards ported into this suite used
/// `guard let walker = enumerator(…) else { continue }` and `(try? contentsOfDirectory) ?? []`,
/// which turn "I could not look" into "I looked and found nothing" — green, and wrong in the
/// one direction that matters. Nothing here is allowed to do that.
enum LocalizationFixtureError: Error, CustomStringConvertible {
    case repositoryRootNotFound(startingFrom: String)
    case repositoryRootFailsSanityCheck(root: String, reason: String)
    case directoryWalkCouldNotStart(path: String)
    case fileUnreadable(path: String, underlying: String)

    var description: String {
        switch self {
        case .repositoryRootNotFound(let start):
            return """
            Could not find the repository root by walking up from:
              \(start)
            Expected to find a directory containing `project.yml`. If this test has been moved
            outside the repository, or the repository layout changed, fix the walk — do not
            weaken it into returning a guess.
            """
        case .repositoryRootFailsSanityCheck(let root, let reason):
            return """
            Resolved a repository root that does not look like the NowThis repository:
              \(root)
            Reason: \(reason)
            This is the failure mode that makes every scanner in this suite silently examine
            zero files and report success.
            """
        case .directoryWalkCouldNotStart(let path):
            return """
            Could not begin a directory walk at:
              \(path)
            A walk that cannot start is NOT a walk with no findings. This is a hard failure on
            purpose.
            """
        case .fileUnreadable(let path, let underlying):
            return "Could not read \(path): \(underlying)"
        }
    }
}

// MARK: - Swift string literals

/// One string literal found in Swift source.
struct SwiftStringLiteral: Hashable {
    /// Repository-relative path of the file it came from.
    let file: String
    /// 1-based line the literal *starts* on.
    let line: Int
    /// The literal's text, with interpolations collapsed to `\(…)` and escapes left as written.
    let text: String
    /// True for `"""…"""` literals.
    let isMultiline: Bool
    /// Number of `#` delimiters (0 for an ordinary literal).
    let poundCount: Int

    var location: String { "\(file):\(line)" }
}

/// A character scanner that extracts Swift string literals while correctly skipping
/// comments — including nested block comments — and handling multiline (`"""`) and raw
/// (`#"…"#`) literals, both of which this repository actually uses
/// (`CalDAVClient.swift`, `NaturalLanguageParser.swift`).
///
/// A line-based regex was tried first and is wrong here: it reports the contents of
/// `///` doc comments as literals, and it terminates raw regex patterns at the wrong quote.
enum SwiftSourceScanner {

    static func stringLiterals(in source: String, file: String = "<inline>") -> [SwiftStringLiteral] {
        let chars = Array(source)
        var literals: [SwiftStringLiteral] = []
        var i = 0
        var line = 1

        func peek(_ offset: Int) -> Character? {
            let j = i + offset
            return j < chars.count ? chars[j] : nil
        }

        /// Consumes a literal whose opening `"` sits at `i`. Advances `i` past the closing
        /// delimiter. `p` is the number of `#` delimiters already consumed.
        func consumeStringLiteral(poundCount p: Int) -> (text: String, multiline: Bool, startLine: Int) {
            let startLine = line
            var multiline = false
            if peek(1) == "\"" && peek(2) == "\"" {
                multiline = true
                i += 3
            } else {
                i += 1
            }
            var text = ""

            while i < chars.count {
                let c = chars[i]

                if c == "\n" {
                    line += 1
                    if !multiline { break }  // unterminated single-line literal — bail, do not run on
                    text.append(c)
                    i += 1
                    continue
                }

                if c == "\\" {
                    var pounds = 0
                    var k = i + 1
                    while k < chars.count && chars[k] == "#" && pounds < p { pounds += 1; k += 1 }
                    if pounds == p {
                        if k < chars.count && chars[k] == "(" {
                            // Interpolation. Skip the balanced paren region, honouring nested
                            // literals so `"\(a ?? "x")"` does not terminate early.
                            text += "\\(…)"
                            i = k + 1
                            var depth = 1
                            while i < chars.count && depth > 0 {
                                let d = chars[i]
                                if d == "\n" { line += 1; i += 1; continue }
                                if d == "(" { depth += 1; i += 1; continue }
                                if d == ")" { depth -= 1; i += 1; continue }
                                if d == "\"" { _ = consumeStringLiteral(poundCount: 0); continue }
                                if d == "#" {
                                    var q = 0
                                    var m = i
                                    while m < chars.count && chars[m] == "#" { q += 1; m += 1 }
                                    if m < chars.count && chars[m] == "\"" {
                                        i = m
                                        _ = consumeStringLiteral(poundCount: q)
                                        continue
                                    }
                                    i = m
                                    continue
                                }
                                i += 1
                            }
                            continue
                        }
                        if k < chars.count {
                            text.append("\\")
                            text.append(chars[k])
                            i = k + 1
                            continue
                        }
                    }
                    text.append(c)
                    i += 1
                    continue
                }

                if c == "\"" {
                    let needed = multiline ? 3 : 1
                    var quotes = 0
                    var k = i
                    while k < chars.count && chars[k] == "\"" && quotes < needed { quotes += 1; k += 1 }
                    if quotes == needed {
                        var pounds = 0
                        var m = k
                        while m < chars.count && chars[m] == "#" && pounds < p { pounds += 1; m += 1 }
                        if pounds == p {
                            i = m
                            return (text, multiline, startLine)
                        }
                    }
                    text.append(c)
                    i += 1
                    continue
                }

                text.append(c)
                i += 1
            }
            return (text, multiline, startLine)
        }

        while i < chars.count {
            let c = chars[i]

            if c == "\n" { line += 1; i += 1; continue }

            if c == "/", peek(1) == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }

            if c == "/", peek(1) == "*" {
                var depth = 1              // Swift block comments nest
                i += 2
                while i < chars.count && depth > 0 {
                    if chars[i] == "\n" { line += 1; i += 1; continue }
                    if chars[i] == "/", peek(1) == "*" { depth += 1; i += 2; continue }
                    if chars[i] == "*", peek(1) == "/" { depth -= 1; i += 2; continue }
                    i += 1
                }
                continue
            }

            if c == "#" {
                var p = 0
                var k = i
                while k < chars.count && chars[k] == "#" { p += 1; k += 1 }
                if k < chars.count && chars[k] == "\"" {
                    i = k
                    let found = consumeStringLiteral(poundCount: p)
                    literals.append(SwiftStringLiteral(file: file, line: found.startLine,
                                                       text: found.text,
                                                       isMultiline: found.multiline, poundCount: p))
                    continue
                }
                i = k                      // `#if`, `#available`, `#Predicate`, …
                continue
            }

            if c == "\"" {
                let found = consumeStringLiteral(poundCount: 0)
                literals.append(SwiftStringLiteral(file: file, line: found.startLine,
                                                   text: found.text,
                                                   isMultiline: found.multiline, poundCount: 0))
                continue
            }

            i += 1
        }

        return literals
    }

    // MARK: Call coverage

    /// The source with every comment and every string literal's *contents* blanked to spaces,
    /// newlines preserved so line numbers are unchanged.
    ///
    /// Structural questions — where does this call's argument list end? — must not be answered by
    /// counting parentheses that live inside a comment or inside `"a ) b"`. Blanking first makes
    /// the rest of the analysis a plain character walk.
    /// The source with **comments blanked and string literals intact**, newline positions and
    /// therefore line numbers preserved.
    ///
    /// Distinct from ``redactedForStructure(_:)``, which also blanks literal *contents*. A guard
    /// that looks for a token which legitimately appears inside a literal — `"en_US_POSIX"` is the
    /// live case — cannot use the fully redacted form, because the thing it is searching for would
    /// be blanked along with the prose.
    ///
    /// This exists because the same defect was found twice in one session, in two unrelated
    /// guards: an exemption stayed alive on a doc comment that quoted `"day"` (L35), and a planted
    /// unpinned `DateFormatter` went undetected because a comment fifteen lines above mentioned
    /// `en_US_POSIX` (L40). **A check satisfied by prose about the thing it checks for is not a
    /// check.** Search redacted source; never raw.
    static func strippingComments(_ source: String) -> String {
        let chars = Array(source)
        var out = chars
        var i = 0

        func blank(_ j: Int) { if chars[j] != "\n" { out[j] = " " } }

        while i < chars.count {
            let c = chars[i]
            if c == "\n" { i += 1; continue }

            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { blank(i); i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                var depth = 1
                blank(i); blank(i + 1)
                i += 2
                while i < chars.count && depth > 0 {
                    if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                        depth += 1; blank(i); blank(i + 1); i += 2; continue
                    }
                    if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                        depth -= 1; blank(i); blank(i + 1); i += 2; continue
                    }
                    blank(i); i += 1
                }
                continue
            }

            // A string literal: copy it through untouched, delimiters and all, so a token inside
            // it survives. Raw and multiline forms are handled by the shared scanner.
            var pounds = 0
            var k = i
            while k < chars.count && chars[k] == "#" { pounds += 1; k += 1 }
            if k < chars.count, chars[k] == "\"" {
                i = indexAfterLiteral(chars, startingAt: i, poundCount: pounds)
                continue
            }

            i += 1
        }
        return String(out)
    }

    /// Index just past the string literal whose delimiters begin at `start`.
    private static func indexAfterLiteral(_ chars: [Character], startingAt start: Int,
                                          poundCount pounds: Int) -> Int {
        var i = start + pounds
        guard i < chars.count, chars[i] == "\"" else { return start + 1 }
        var multiline = false
        if i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
            multiline = true; i += 3
        } else {
            i += 1
        }
        while i < chars.count {
            if chars[i] == "\\" {
                var p = 0
                var k = i + 1
                while k < chars.count && chars[k] == "#" && p < pounds { p += 1; k += 1 }
                if p == pounds { i = k + 1; continue }
                i += 1
                continue
            }
            if chars[i] == "\n", !multiline { return i }
            if chars[i] == "\"" {
                let needed = multiline ? 3 : 1
                var quotes = 0
                var k = i
                while k < chars.count && chars[k] == "\"" && quotes < needed { quotes += 1; k += 1 }
                if quotes == needed {
                    var p = 0
                    var m = k
                    while m < chars.count && chars[m] == "#" && p < pounds { p += 1; m += 1 }
                    if p == pounds { return m }
                }
            }
            i += 1
        }
        return i
    }

    static func redactedForStructure(_ source: String) -> String {
        let chars = Array(source)
        var out = Array(repeating: Character(" "), count: chars.count)
        var i = 0

        func keep(_ j: Int) { out[j] = chars[j] }

        while i < chars.count {
            let c = chars[i]
            if c == "\n" { keep(i); i += 1; continue }

            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                var depth = 1
                i += 2
                while i < chars.count && depth > 0 {
                    if chars[i] == "\n" { keep(i) }
                    else if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" { depth += 1; i += 1 }
                    else if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" { depth -= 1; i += 1 }
                    i += 1
                }
                continue
            }

            var pounds = 0
            var k = i
            while k < chars.count && chars[k] == "#" { pounds += 1; k += 1 }
            if pounds > 0, k < chars.count, chars[k] == "\"" {
                for j in i..<k { keep(j) }
                i = k
            } else if pounds > 0 {
                for j in i..<k { keep(j) }
                i = k
                continue
            }

            if i < chars.count, chars[i] == "\"" {
                let multiline = i + 2 < chars.count && chars[i + 1] == "\"" && chars[i + 2] == "\""
                let delimiter = multiline ? 3 : 1
                // The quotes themselves survive. Only their *contents* are noise for structural
                // questions; the delimiters are how a caller tells `f(x: "literal")` from
                // `f(x: value)`, which is a distinction some guards are entirely about.
                for j in i..<min(i + delimiter, chars.count) { keep(j) }
                i += delimiter
                while i < chars.count {
                    if chars[i] == "\n" {
                        keep(i)
                        i += 1
                        if multiline { continue }
                        break
                    }
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == "\"" {
                        var quotes = 0
                        var m = i
                        while m < chars.count && chars[m] == "\"" && quotes < delimiter { quotes += 1; m += 1 }
                        if quotes == delimiter {
                            var seen = 0
                            while m < chars.count && chars[m] == "#" && seen < pounds { seen += 1; m += 1 }
                            if seen == pounds {
                                for j in i..<m { keep(j) }
                                i = m
                                break
                            }
                        }
                    }
                    i += 1
                }
                continue
            }

            keep(i)
            i += 1
        }
        return String(out)
    }

    /// Every line belonging to a call to one of `markers`, from the marker itself to the close of
    /// the brace/bracket/paren it opens.
    ///
    /// A fixed ±N-line window was the first attempt and is wrong in both directions: it misses the
    /// tail of a call that wraps over five lines, and it hands a free pass to any bare literal that
    /// happens to sit one line below a localized one. Balancing the delimiter answers the question
    /// that was actually being asked.
    ///
    /// A marker with no delimiter on its own line covers that line only, which is the assignment
    /// form (`static let title: LocalizedStringResource = "Add Task"`).
    static func callCoveredLines(in source: String, markers: [String]) -> Set<Int> {
        let code = Array(redactedForStructure(source))
        var lineOf = Array(repeating: 1, count: code.count + 1)
        var line = 1
        for index in code.indices {
            lineOf[index] = line
            if code[index] == "\n" { line += 1 }
        }
        lineOf[code.count] = line

        var covered: Set<Int> = []
        let text = String(code)

        for marker in markers {
            var searchFrom = text.startIndex
            while let found = text.range(of: marker, range: searchFrom..<text.endIndex) {
                searchFrom = found.upperBound
                let start = text.distance(from: text.startIndex, to: found.lowerBound)
                covered.insert(lineOf[start])

                // **Every** delimiter opened at or after the marker on its own line, not just the
                // first. `static let caseDisplayRepresentations: [K: DisplayRepresentation] = [`
                // opens two: a type annotation that closes on the same line, and the dictionary
                // that holds the four strings this guard exists to see. Taking only the first
                // covers the annotation and reports the dictionary as untranslated.
                var cursor = start
                var openers: [Int] = []
                while cursor < code.count, code[cursor] != "\n" {
                    if code[cursor] == "(" || code[cursor] == "[" || code[cursor] == "{" {
                        openers.append(cursor)
                    }
                    cursor += 1
                }

                for open in openers {
                    let close: Character = code[open] == "(" ? ")" : (code[open] == "[" ? "]" : "}")
                    var depth = 0
                    var index = open
                    while index < code.count {
                        if code[index] == code[open] { depth += 1 }
                        else if code[index] == close {
                            depth -= 1
                            if depth == 0 { break }
                        }
                        index += 1
                    }
                    let endLine = lineOf[min(index, code.count)]
                    for covering in lineOf[start]...max(lineOf[start], endLine) { covered.insert(covering) }
                }
            }
        }
        return covered
    }

    // MARK: Render sites

    /// One call's first argument, as written.
    struct CallArgument: Hashable {
        /// Repository-relative path.
        let file: String
        /// 1-based line the call's marker sits on.
        let line: Int
        /// The marker that matched, e.g. `Text(` or `.accessibilityLabel(`.
        let marker: String
        /// The argument text with comments and literal *contents* blanked, quotes kept. This is
        /// what the classifier reads — it must not be fooled by a `)` inside a literal.
        let redacted: String
        /// The argument exactly as written, for failure messages.
        let asWritten: String
    }

    /// The first argument of every call to any of `markers`.
    ///
    /// A "marker" is a call prefix ending in `(`. Matches preceded by an identifier character are
    /// skipped, so `Text(` does not also match `attributedText(`.
    static func firstArguments(
        ofCallsTo markers: [String],
        in source: String,
        file: String = "<inline>"
    ) -> [CallArgument] {
        let code = Array(redactedForStructure(source))
        var lineOf = Array(repeating: 1, count: code.count + 1)
        var line = 1
        for index in code.indices {
            lineOf[index] = line
            if code[index] == "\n" { line += 1 }
        }
        lineOf[code.count] = line

        let text = String(code)
        let raw = Array(source)
        var found: [CallArgument] = []

        for marker in markers {
            var searchFrom = text.startIndex
            while let hit = text.range(of: marker, range: searchFrom..<text.endIndex) {
                searchFrom = hit.upperBound
                let start = text.distance(from: text.startIndex, to: hit.lowerBound)

                // `Text(` must not match the tail of `attributedText(`. A leading `.` in the
                // marker already anchors the modifier forms.
                if start > 0, !marker.hasPrefix(".") {
                    let previous = code[start - 1]
                    if previous.isLetter || previous.isNumber || previous == "_" { continue }
                }

                let open = start + marker.count - 1
                guard open < code.count, code[open] == "(" else { continue }

                // Walk to the first top-level comma or the closing paren, whichever comes first.
                var depth = 0
                var index = open
                var end: Int?
                while index < code.count {
                    let c = code[index]
                    if c == "(" || c == "[" || c == "{" { depth += 1 }
                    else if c == ")" || c == "]" || c == "}" {
                        depth -= 1
                        if depth == 0 { end = index; break }
                    } else if c == "," && depth == 1 { end = index; break }
                    index += 1
                }
                guard let end, end > open + 1 || end == open + 1 else { continue }

                let lower = open + 1
                found.append(CallArgument(
                    file: file,
                    line: lineOf[start],
                    marker: marker,
                    redacted: String(code[lower..<end]),
                    asWritten: String(raw[lower..<min(end, raw.count)])
                ))
            }
        }
        return found.sorted { ($0.line, $0.marker) < ($1.line, $1.marker) }
    }

    /// The expression with every `String(localized:…)` / `LocalizedStringResource(…)` call blanked
    /// to spaces, delimiters and all.
    ///
    /// Needed because a literal *inside* a localizing call is the fix, not the defect, and the two
    /// are indistinguishable to "does this expression contain a literal?":
    ///
    ///     Text(list?.name ?? "Calendar")                       ← broken
    ///     Text(list?.name ?? String(localized: "…", …))         ← fixed, and contains MORE literals
    ///
    /// A guard that skips the whole expression whenever a localizing marker appears anywhere would
    /// forgive `"Prefix " + String(localized: …)`. Removing the call's exact span instead leaves any
    /// genuinely bare literal still visible.
    ///
    /// Anchors on the bare `localized:` label and walks **backwards** to the enclosing `(`, so the
    /// wrapped form is covered too — `String(\n    localized: "…")` never contains
    /// `String(localized:` as a contiguous substring, which is precisely the blind spot that let a
    /// renamed key pass the §2c-i guard (see L24).
    static func strippingLocalizingCalls(_ redactedExpression: String) -> String {
        var chars = Array(redactedExpression)
        let anchors = ["localized:", "LocalizedStringResource("]

        for anchor in anchors {
            var searchStart = 0
            while true {
                let text = String(chars)
                guard let hit = text.range(
                    of: anchor,
                    range: text.index(text.startIndex, offsetBy: min(searchStart, text.count))..<text.endIndex
                ) else { break }
                let anchorAt = text.distance(from: text.startIndex, to: hit.lowerBound)
                searchStart = anchorAt + 1

                var open: Int?
                if anchor.hasSuffix("(") {
                    // A call anchor (`LocalizedStringResource(`) brings its own opening paren; there
                    // is no enclosing one to walk back to, and looking for one finds the *caller's*
                    // paren or nothing at all.
                    open = anchorAt + anchor.count - 1
                } else {
                    // A label anchor (`localized:`) sits inside the call's parens. Walk back to the
                    // `(` it is directly inside, skipping any balanced groups on the way.
                    var depth = 0
                    var index = anchorAt - 1
                    while index >= 0 {
                        if chars[index] == ")" || chars[index] == "]" { depth += 1 }
                        else if chars[index] == "(" || chars[index] == "[" {
                            if depth == 0 { open = index; break }
                            depth -= 1
                        }
                        index -= 1
                    }
                }
                guard let open, open < chars.count, chars[open] == "(" else { continue }

                // Forward to its match.
                var close = open
                var nesting = 0
                while close < chars.count {
                    if chars[close] == "(" { nesting += 1 }
                    else if chars[close] == ")" {
                        nesting -= 1
                        if nesting == 0 { break }
                    }
                    close += 1
                }
                guard close < chars.count else { continue }

                for position in open...close where chars[position] != "\n" {
                    chars[position] = " "
                }
            }
        }
        return String(chars)
    }

    /// Whether an expression is a ternary whose **every** branch is a string literal.
    ///
    /// This is the asymmetry the whole view-copy class turns on, verified against `Text`'s
    /// storage via `Mirror`:
    ///
    /// | Expression | Storage | Extracted? |
    /// |---|---|---|
    /// | `Text(flag ? "Descending" : "Ascending")` | `LocalizedTextStorage` | yes |
    /// | `Text(flag ? "No date" : rule.displayName)` | `verbatim` | **no** |
    ///
    /// An all-literal ternary is compiled as a `LocalizedStringKey` and both branches are
    /// extracted. One non-literal branch demotes the whole expression to the disfavored
    /// `StringProtocol` overload and **neither** branch reaches a catalog.
    ///
    /// A guard that does not encode this false-positives on every safe ternary in the tree and
    /// still misses the mixed ones. Takes redacted text (quotes kept, contents blanked).
    static func isAllLiteralTernary(_ redactedExpression: String) -> Bool {
        let expression = redactedExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let question = topLevelIndex(of: "?", in: expression) else { return false }

        // `a ?? b` is nil-coalescing, not a ternary, and never extracts.
        let afterQuestion = expression.index(after: question)
        if afterQuestion < expression.endIndex, expression[afterQuestion] == "?" { return false }
        // `x?.y` is optional chaining.
        if afterQuestion < expression.endIndex, expression[afterQuestion] == "." { return false }

        let rest = String(expression[afterQuestion...])
        guard let colon = topLevelIndex(of: ":", in: rest) else { return false }

        let thenBranch = String(rest[rest.startIndex..<colon])
        let elseBranch = String(rest[rest.index(after: colon)...])

        return branchIsLiteral(thenBranch) && branchIsLiteral(elseBranch)
    }

    /// A ternary branch extracts if it is a literal, or is itself an all-literal ternary.
    private static func branchIsLiteral(_ branch: String) -> Bool {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("\"") || trimmed.hasPrefix("#\"") {
            // A literal followed by anything other than more literal is a concatenation
            // (`"a" + name`), which does not extract as a whole.
            return !trimmed.contains("+")
        }
        return isAllLiteralTernary(trimmed)
    }

    /// The index of `needle` at nesting depth zero, skipping anything inside brackets or quotes.
    private static func topLevelIndex(of needle: Character, in expression: String) -> String.Index? {
        var depth = 0
        var inLiteral = false
        var index = expression.startIndex
        while index < expression.endIndex {
            let c = expression[index]
            if c == "\"" { inLiteral.toggle() }
            else if !inLiteral {
                if c == "(" || c == "[" || c == "{" { depth += 1 }
                else if c == ")" || c == "]" || c == "}" { depth -= 1 }
                else if c == needle && depth == 0 { return index }
            }
            index = expression.index(after: index)
        }
        return nil
    }
}

// MARK: - Fixture

/// Shared filesystem fixture for the localization guards.
///
/// Framework-agnostic on purpose — the guards are Swift Testing, but nothing here imports
/// `Testing`, so the same walk can be exercised from a plain helper.
///
/// **One catalog list, referenced by every guard.** The prior `LocalizationCatalogGuardTests`
/// forked the fixture and re-declared its own, and 8 of its 10 tests silently skipped the
/// shared list. Do not add a second list anywhere.
enum LocalizationCatalogFixture {

    // MARK: Repository root

    /// The four globbed source paths from `project.yml`. A catalog placed outside these is
    /// silently dropped on `xcodegen generate`.
    static let sourceRoots = ["NowThis", "NowThisWidget", "NowThisWatch", "NowThisWatchWidget"]

    // MARK: Catalogs

    /// One string catalog and everything the guards need to know about it.
    struct CatalogRef: Hashable {
        /// Repository-relative path. Must match `Translations/tools/xcstrings.py` `CATALOGS`
        /// exactly — asserted, not assumed, so the Python and Swift halves cannot drift.
        let path: String
        /// Where the owning bundle sits relative to the built `NowThis.app`, or `nil` for the
        /// app itself.
        let bundleRelativePath: String?
        /// ~90% of the count measured at first extraction. A floor, not an equality: keys are
        /// expected to grow. It exists so a catalog emptying out cannot pass as "no findings".
        let keyFloor: Int

        var name: String { (path as NSString).lastPathComponent }
    }

    /// **The one catalog list.** The prior `LocalizationCatalogGuardTests` forked the fixture and
    /// re-declared its own, and 8 of its 10 tests then silently skipped the shared list. Every
    /// guard reads this array; nothing declares a second one.
    ///
    /// Counts measured 2026-07-24 at first extraction (build 17):
    /// 429 / 3 / 8 / 31 / 1 / 20 / 4 = **496 keys**.
    static let catalogs: [CatalogRef] = [
        CatalogRef(path: "NowThis/Localizable.xcstrings",
                   bundleRelativePath: nil, keyFloor: 380),
        CatalogRef(path: "NowThis/InfoPlist.xcstrings",
                   bundleRelativePath: nil, keyFloor: 3),
        CatalogRef(path: "NowThis/AppShortcuts.xcstrings",
                   bundleRelativePath: nil, keyFloor: 8),
        CatalogRef(path: "NowThisWidget/Localizable.xcstrings",
                   bundleRelativePath: "PlugIns/NowThisWidget.appex", keyFloor: 27),
        CatalogRef(path: "NowThisWidget/InfoPlist.xcstrings",
                   bundleRelativePath: "PlugIns/NowThisWidget.appex", keyFloor: 1),
        CatalogRef(path: "NowThisWatch/Localizable.xcstrings",
                   bundleRelativePath: "Watch/NowThisWatch.app", keyFloor: 18),
        CatalogRef(path: "NowThisWatchWidget/Localizable.xcstrings",
                   bundleRelativePath: "Watch/NowThisWatch.app/PlugIns/NowThisWatchWidget.appex",
                   keyFloor: 4),
    ]

    /// The five shipping translations. `en` is the source language and is deliberately absent —
    /// most keys are English-as-key and carry no `en` block at all.
    static let translationLanguages = ["de", "es", "fr", "it", "nl"]

    /// A parsed catalog: the `strings` dictionary, keyed by catalog key.
    static func load(_ catalog: CatalogRef) throws -> [String: [String: Any]] {
        let root = try repositoryRoot()
        let url = root.appendingPathComponent(catalog.path)
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw LocalizationFixtureError.fileUnreadable(path: catalog.path,
                                                          underlying: String(describing: error))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = object["strings"] as? [String: [String: Any]] else {
            throw LocalizationFixtureError.fileUnreadable(
                path: catalog.path,
                underlying: "not a string catalog — no top-level `strings` object")
        }
        return strings
    }

    /// The English text a catalog entry renders as.
    ///
    /// Two key styles coexist here by design. An **explicit** key
    /// (`String(localized: "sort.manually", defaultValue: "Manually", comment: …)`) carries its
    /// English in an `en` block. An **English-as-key** entry (`String(localized: "Today")`) has
    /// no `en` block at all — the key *is* the English.
    ///
    /// The prior staleness guard and its `english_hashes.py` both `continue` past the second form,
    /// which on their tree silently skipped 850 of 1,051 translated keys and on this one would
    /// skip every single key. Falling back to the key is the fix, and it lives here so both the
    /// staleness guard and every other consumer share one definition.
    /// A **plural-varied** entry has no `stringUnit` at all — its text lives under
    /// `variations.plural.<category>` — so reading only `stringUnit` returns the key and every
    /// consumer silently stops seeing the words. That is not hypothetical: §2d's first run
    /// dropped this file's count-bearing scan from 29 entries to 17 without a single failure,
    /// because twelve keys had just become invisible to it. A **substituted** entry does keep a
    /// `stringUnit`, but its value reads `"%1$@, %#@taskCount@"` — the counted noun is inside the
    /// substitution, so a glossary or length check over the raw value sees no nouns either.
    /// Both are resolved here rather than at each call site.
    static func englishRendering(ofKey key: String, entry: [String: Any]) -> String {
        guard let localizations = entry["localizations"] as? [String: Any],
              let english = localizations["en"] as? [String: Any] else {
            return key
        }

        var rendering: String
        if let unit = english["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            rendering = value
        } else if let whole = pluralSlots(entry).first(where: { $0.name.isEmpty }) {
            // `other` is the form English uses for everything but exactly one, so it is the one
            // that carries the general phrasing.
            guard let value = whole.forms["other"] ?? whole.forms.sorted(by: { $0.key < $1.key }).first?.value
            else { return key }
            rendering = value
        } else {
            return key
        }

        // Splice each substitution's `other` form back in where its `%#@name@` marker sits, with
        // `%arg` restored to the specifier it stands for, so the result is the sentence a reader
        // would see rather than the catalog's plumbing.
        guard let substitutions = english["substitutions"] as? [String: Any] else { return rendering }
        for slot in pluralSlots(entry) where !slot.name.isEmpty {
            guard let text = slot.forms["other"] ?? slot.forms.sorted(by: { $0.key < $1.key }).first?.value
            else { continue }
            let specifier = ((substitutions[slot.name] as? [String: Any])?["formatSpecifier"] as? String)
                .map { "%\($0)" } ?? "%lld"
            rendering = rendering.replacingOccurrences(
                of: "%#@\(slot.name)@",
                with: text.replacingOccurrences(of: "%arg", with: specifier))
        }
        return rendering
    }

    /// One plural-varied slot inside a catalog entry.
    ///
    /// `name` is `""` for the whole-string form and the substitution's name otherwise —
    /// distinguishing them matters because only one of the two survives a second placeholder.
    struct PluralSlot: Hashable {
        /// Substitution name, or `""` when the whole string varies.
        let name: String
        /// CLDR plural category (`one`, `other`, `zero`, `two`, `few`, `many`) → the text.
        let forms: [String: String]
    }

    /// The plural slots one language block of an entry carries. Empty means "not plural-varied".
    ///
    /// Xcode writes plurals two different ways and a guard that knows only one of them reports
    /// success over the other:
    ///
    /// - `localizations.<lang>.variations.plural` — the **whole string** varies. Legal only when
    ///   the string has exactly one placeholder, because the runtime drives it from the first
    ///   argument.
    /// - `localizations.<lang>.substitutions.<name>.variations.plural` — one argument varies
    ///   inside a sentence that has other placeholders. The top-level value then holds
    ///   `%#@<name>@` where the counted phrase goes.
    ///
    /// Both were verified to resolve at runtime from a hand-authored catalog before §2d chose
    /// between them — the compiled catalog wins
    /// over the Swift `defaultValue`, which is the only reason a plural shape the Swift literal
    /// cannot express can ship at all.
    static func pluralSlots(_ entry: [String: Any], language: String = "en") -> [PluralSlot] {
        guard let localizations = entry["localizations"] as? [String: Any],
              let block = localizations[language] as? [String: Any] else { return [] }

        func forms(of container: [String: Any]) -> [String: String]? {
            guard let variations = container["variations"] as? [String: Any],
                  let plural = variations["plural"] as? [String: Any] else { return nil }
            var out: [String: String] = [:]
            for (category, value) in plural {
                guard let unit = (value as? [String: Any])?["stringUnit"] as? [String: Any],
                      let text = unit["value"] as? String else { continue }
                out[category] = text
            }
            return out.isEmpty ? nil : out
        }

        var slots: [PluralSlot] = []
        if let whole = forms(of: block) {
            slots.append(PluralSlot(name: "", forms: whole))
        }
        if let substitutions = block["substitutions"] as? [String: Any] {
            for (name, container) in substitutions {
                guard let container = container as? [String: Any],
                      let inner = forms(of: container) else { continue }
                slots.append(PluralSlot(name: name, forms: inner))
            }
        }
        return slots.sorted { $0.name < $1.name }
    }

    /// Every English rendering in a catalog, whichever key style produced it.
    static func englishRenderings(in catalog: CatalogRef) throws -> Set<String> {
        var out: Set<String> = []
        for (key, entry) in try load(catalog) {
            out.insert(englishRendering(ofKey: key, entry: entry))
        }
        return out
    }

    /// The language this test process actually resolved to.
    ///
    /// Not a constant: `xcodebuild -testLanguage de` and a simulator whose own Settings are
    /// German both make the app under test return German from `String(localized:)`. A guard
    /// that compares runtime output against English renderings then fails on every row —
    /// which is exactly what `EnumDisplayNameGuardTests` did, 86 times, the first time the
    /// suite was run in German.
    static var activeLanguage: String {
        Bundle.main.preferredLocalizations.first.map { String($0.prefix(2)) } ?? "en"
    }

    /// One key's rendering in the language the tests are running in.
    ///
    /// Read from the catalog rather than resolved through `Bundle.main`: English has no
    /// `en.lproj/Localizable.strings` — the source strings are compiled in as each call's
    /// `defaultValue` — so a runtime lookup by key returns the key itself under `en` while
    /// working fine under `de`. Tests that compared against a `Bundle.main` lookup passed in
    /// German and failed in English, which is the wrong way round for a source language.
    static func rendering(ofKey key: String, inCatalogAt path: String) throws -> String {
        guard let ref = catalogs.first(where: { $0.path == path }),
              let entry = try load(ref)[key] else { return key }
        let language = activeLanguage
        if language != "en",
           let localizations = entry["localizations"] as? [String: Any],
           let block = localizations[language] as? [String: Any],
           let unit = block["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String {
            return value
        }
        return englishRendering(ofKey: key, entry: entry)
    }

    /// Every rendering a catalog produces **in the language the tests are running in**,
    /// falling back per key to English wherever that language has no entry — which is what
    /// the app itself resolves at runtime.
    ///
    /// Under `en` this is exactly `englishRenderings`. Under any other language it is
    /// strictly stronger: it also fails when a display name is not the translated string.
    static func renderings(in catalog: CatalogRef, language: String) throws -> Set<String> {
        guard language != "en" else { return try englishRenderings(in: catalog) }
        var out: Set<String> = []
        for (key, entry) in try load(catalog) {
            if let localizations = entry["localizations"] as? [String: Any],
               let block = localizations[language] as? [String: Any],
               let unit = block["stringUnit"] as? [String: Any],
               let value = unit["value"] as? String {
                out.insert(value)
            } else {
                // No entry in this language — the app falls back to English, so accept it.
                out.insert(englishRendering(ofKey: key, entry: entry))
            }
        }
        return out
    }

    /// Languages that actually carry a `stringUnit` in this catalog, excluding `en`.
    static func translatedLanguages(in catalog: CatalogRef) throws -> Set<String> {
        var found: Set<String> = []
        for (_, entry) in try load(catalog) {
            guard let localizations = entry["localizations"] as? [String: Any] else { continue }
            for (language, _) in localizations where language != "en" {
                found.insert(language)
            }
        }
        return found
    }

    /// Resolved once. `Result` rather than a lazy `throws` accessor because a mutable static
    /// cache is not concurrency-safe under Swift 6, and losing the error is not an option —
    /// a fixture that fails open is the whole problem this file is about.
    private static let resolvedRoot: Result<URL, LocalizationFixtureError> = {
        do { return .success(try resolveRepositoryRoot()) }
        catch let error as LocalizationFixtureError { return .failure(error) }
        catch { return .failure(.repositoryRootNotFound(startingFrom: #filePath)) }
    }()

    /// Resolves the repository root by walking **up** from this file until a directory
    /// containing `project.yml` is found.
    ///
    /// The guards ported into this suite used `#filePath` + exactly two `deletingLastPathComponent()`,
    /// which works only because `YourPodsTests/` is flat. `NowThisTests/` has ten
    /// subdirectories, so a fixed number of deletions resolves "repository root" to
    /// `NowThisTests/` and every scanner then reports zero findings — green, in the bad
    /// direction. Walking up removes the trap instead of documenting it, and makes the
    /// guards' own directory depth irrelevant.
    static func repositoryRoot() throws -> URL {
        try resolvedRoot.get()
    }

    /// Whether a development-only file is present. `Translations/` is translation tooling, not a
    /// shipped source, so it is not published to the `nowthis-source` mirror; a guard that reads
    /// it is enabled on this, and skipped in a public checkout instead of failing there.
    static func repositoryFileExists(_ relativePath: String) -> Bool {
        guard let root = try? repositoryRoot() else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    private static func resolveRepositoryRoot() throws -> URL {
        let start = URL(fileURLWithPath: #filePath)
        var candidate = start.deletingLastPathComponent()
        let fm = FileManager.default

        while candidate.path != "/" {
            if fm.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
                try sanityCheck(candidate)
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        throw LocalizationFixtureError.repositoryRootNotFound(startingFrom: start.path)
    }

    /// Proves the resolved root is the real repository and not `NowThisTests/`, a worktree,
    /// or a build sandbox. Asserted here rather than in one guard, so every guard inherits it.
    private static func sanityCheck(_ root: URL) throws {
        let fm = FileManager.default
        func fail(_ reason: String) -> LocalizationFixtureError {
            .repositoryRootFailsSanityCheck(root: root.path, reason: reason)
        }

        if root.lastPathComponent == "NowThisTests" {
            throw fail("the resolved root is NowThisTests/ — the walk stopped one level too early")
        }
        // `.claude/worktrees/<name>/` is a full checkout with its own project.yml. A guard that
        // resolves into one scans a different revision of the tree and reports on the wrong code.
        if root.path.contains("/.claude/worktrees/") {
            throw fail("the resolved root is inside .claude/worktrees/ — that is a separate checkout")
        }
        guard fm.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            throw fail("no .git at the resolved root")
        }
        guard fm.fileExists(atPath: root.appendingPathComponent("NowThis").path) else {
            throw fail("no NowThis/ directory at the resolved root")
        }
        let spec = root.appendingPathComponent("project.yml")
        let size = ((try? fm.attributesOfItem(atPath: spec.path))?[.size] as? Int) ?? 0
        guard size > 1000 else {
            throw fail("project.yml at the resolved root is \(size) bytes — expected > 1000")
        }
    }

    // MARK: Source walking

    /// Every `.swift` file under the four `project.yml` source roots, repository-relative,
    /// sorted. Worktrees are unreachable from these roots by construction; the `.claude`
    /// filter is belt-and-braces for any future caller that walks from the repository root.
    static func swiftSourceFiles() throws -> [String] {
        let root = try repositoryRoot()
        let fm = FileManager.default
        var results: [String] = []

        for sourceRoot in sourceRoots {
            let dir = root.appendingPathComponent(sourceRoot)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                throw LocalizationFixtureError.directoryWalkCouldNotStart(path: dir.path)
            }
            guard let walker = fm.enumerator(at: dir,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else {
                throw LocalizationFixtureError.directoryWalkCouldNotStart(path: dir.path)
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                if url.path.contains("/.claude/") { continue }
                results.append(relativePath(of: url, from: root))
            }
        }
        return results.sorted()
    }

    /// Every string literal in every Swift source file under the four source roots.
    static func allSourceLiterals() throws -> [SwiftStringLiteral] {
        let root = try repositoryRoot()
        var all: [SwiftStringLiteral] = []
        for file in try swiftSourceFiles() {
            let url = root.appendingPathComponent(file)
            let source: String
            do {
                source = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw LocalizationFixtureError.fileUnreadable(path: file,
                                                              underlying: String(describing: error))
            }
            all += SwiftSourceScanner.stringLiterals(in: source, file: file)
        }
        return all
    }

    /// Per-root file counts, so a floor can be asserted **per root**. NowThis's roots differ
    /// by two orders of magnitude, and an aggregate floor cannot detect NowThisWidget
    /// vanishing entirely.
    static func swiftSourceFileCountsByRoot() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for file in try swiftSourceFiles() {
            let root = file.split(separator: "/").first.map(String.init) ?? "?"
            counts[root, default: 0] += 1
        }
        return counts
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return filePath }
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}
