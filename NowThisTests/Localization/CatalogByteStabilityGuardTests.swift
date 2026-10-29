import Foundation
import Testing

/// Ordered JSON, written back exactly the way Xcode writes a `.xcstrings`.
///
/// `JSONSerialization` cannot be used here for the same reason `json.dump` cannot be used in
/// `Translations/tools/xcstrings.py`: it discards key order, and it renders an empty object as
/// `{}` where Xcode renders an expanded two-line block. Either one rewrites every entry in the
/// file, and a three-string change becomes a whole-file diff with the real change hidden inside
/// it.
///
/// This is the Swift half of that writer. It exists so the byte-stability property is checked in
/// the merge gate, by a test, rather than by a Python script somebody is trusted to run — this
/// repo has no CI, so a check that lives outside the test suite is a check that does not run.
enum XcodeCatalogJSON {

    indirect enum Value {
        case object([(key: String, value: Value)])
        case array([Value])
        case string(String)
        /// Kept as the source spelling. Re-formatting `4` through a `Double` is how a writer
        /// turns an `argNum` into `4.0` and rewrites every substitution in the file.
        case number(String)
        case bool(Bool)
        case null
    }

    struct ParseError: Error, CustomStringConvertible {
        let offset: Int
        let reason: String
        var description: String { "byte \(offset): \(reason)" }
    }

    // MARK: Parsing

    static func parse(_ text: String) throws -> Value {
        var scanner = Scanner(Array(text.unicodeScalars))
        let value = try scanner.value()
        scanner.skipWhitespace()
        guard scanner.atEnd else {
            throw ParseError(offset: scanner.index, reason: "trailing content after the root value")
        }
        return value
    }

    private struct Scanner {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var atEnd: Bool { index >= scalars.count }

        mutating func skipWhitespace() {
            while index < scalars.count,
                  scalars[index] == " " || scalars[index] == "\n"
                    || scalars[index] == "\r" || scalars[index] == "\t" {
                index += 1
            }
        }

        mutating func value() throws -> Value {
            skipWhitespace()
            guard index < scalars.count else {
                throw ParseError(offset: index, reason: "expected a value, found end of input")
            }
            switch scalars[index] {
            case "{": return try object()
            case "[": return try array()
            case "\"": return .string(try string())
            case "t": try literal("true"); return .bool(true)
            case "f": try literal("false"); return .bool(false)
            case "n": try literal("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func literal(_ word: String) throws {
            for scalar in word.unicodeScalars {
                guard index < scalars.count, scalars[index] == scalar else {
                    throw ParseError(offset: index, reason: "expected \(word)")
                }
                index += 1
            }
        }

        mutating func object() throws -> Value {
            index += 1  // {
            var pairs: [(key: String, value: Value)] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "}" { index += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                let key = try string()
                skipWhitespace()
                guard index < scalars.count, scalars[index] == ":" else {
                    throw ParseError(offset: index, reason: "expected ':' after a key")
                }
                index += 1
                pairs.append((key, try value()))
                skipWhitespace()
                guard index < scalars.count else {
                    throw ParseError(offset: index, reason: "unterminated object")
                }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "}" { index += 1; return .object(pairs) }
                throw ParseError(offset: index, reason: "expected ',' or '}'")
            }
        }

        mutating func array() throws -> Value {
            index += 1  // [
            var items: [Value] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "]" { index += 1; return .array(items) }
            while true {
                items.append(try value())
                skipWhitespace()
                guard index < scalars.count else {
                    throw ParseError(offset: index, reason: "unterminated array")
                }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "]" { index += 1; return .array(items) }
                throw ParseError(offset: index, reason: "expected ',' or ']'")
            }
        }

        mutating func string() throws -> String {
            guard index < scalars.count, scalars[index] == "\"" else {
                throw ParseError(offset: index, reason: "expected a string")
            }
            index += 1
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "\"" { index += 1; return String(out) }
                if scalar != "\\" { out.append(scalar); index += 1; continue }
                index += 1
                guard index < scalars.count else {
                    throw ParseError(offset: index, reason: "escape at end of input")
                }
                let escape = scalars[index]
                index += 1
                switch escape {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append(Unicode.Scalar(8))
                case "f": out.append(Unicode.Scalar(12))
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    guard let first = try? hexQuad() else {
                        throw ParseError(offset: index, reason: "bad \\u escape")
                    }
                    // A surrogate pair arrives as two escapes and must be recombined before it
                    // can become a scalar.
                    if first >= 0xD800, first <= 0xDBFF,
                       index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" {
                        index += 2
                        let second = try hexQuad()
                        let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                        guard let scalar = Unicode.Scalar(combined) else {
                            throw ParseError(offset: index, reason: "bad surrogate pair")
                        }
                        out.append(scalar)
                    } else {
                        guard let scalar = Unicode.Scalar(first) else {
                            throw ParseError(offset: index, reason: "bad code point")
                        }
                        out.append(scalar)
                    }
                default:
                    throw ParseError(offset: index, reason: "unknown escape \\\(escape)")
                }
            }
            throw ParseError(offset: index, reason: "unterminated string")
        }

        mutating func hexQuad() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard index < scalars.count,
                      let digit = Character(scalars[index]).hexDigitValue else {
                    throw ParseError(offset: index, reason: "expected four hex digits")
                }
                value = value * 16 + UInt32(digit)
                index += 1
            }
            return value
        }

        mutating func number() throws -> String {
            let start = index
            while index < scalars.count,
                  "-+.eE0123456789".unicodeScalars.contains(scalars[index]) {
                index += 1
            }
            guard index > start else {
                throw ParseError(offset: index, reason: "expected a number")
            }
            return String(String.UnicodeScalarView(scalars[start..<index]))
        }
    }

    // MARK: Writing

    /// The four format details, all load-bearing: two-space indent, `" : "` between key and
    /// value, an empty container expanded across two lines, and non-ASCII written through rather
    /// than escaped. Get one wrong and every entry in the file is rewritten.
    static func dump(_ value: Value, indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        switch value {
        case .object(let pairs):
            if pairs.isEmpty { return "{\n\n\(pad)}" }
            let items = pairs.map { "\(inner)\(quote($0.key)) : \(dump($0.value, indent: indent + 2))" }
            return "{\n" + items.joined(separator: ",\n") + "\n\(pad)}"
        case .array(let items):
            if items.isEmpty { return "[\n\n\(pad)]" }
            let rendered = items.map { "\(inner)\(dump($0, indent: indent + 2))" }
            return "[\n" + rendered.joined(separator: ",\n") + "\n\(pad)]"
        case .string(let text): return quote(text)
        case .number(let raw): return raw
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }

    /// `json.dumps(text, ensure_ascii=False)`. Note what is *not* escaped: `/`, and every scalar
    /// at or above U+0020 — an escaped `é` would rewrite every accented value in five languages.
    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case Unicode.Scalar(8): out += "\\b"
            case Unicode.Scalar(12): out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// The catalogs must be exactly what Xcode would have written, because that is the only thing
/// that keeps a diff readable.
///
/// This is the check `Translations/tools/xcstrings.py verify` performs, moved into the merge
/// gate. It is deliberately *not* a shell-out to that script: a guard whose failure depends on
/// Python being on the path, and on someone remembering to run it, is not a guard.
///
/// It does **not** detect that Xcode edited a catalog — a rewrite is still perfectly formatted.
/// `Translations/tools/catalog_diff.py` is the tool for that, and the two are complements.
@Suite("Catalog byte stability")
struct CatalogByteStabilityGuardTests {

    @Test("Every catalog round-trips through the writer byte-for-byte")
    func everyCatalogIsByteStableUnderTheWriter() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var examined = 0

        for catalog in LocalizationCatalogFixture.catalogs {
            let url = root.appendingPathComponent(catalog.path)
            let text = try String(contentsOf: url, encoding: .utf8)
            examined += 1

            let parsed: XcodeCatalogJSON.Value
            do {
                parsed = try XcodeCatalogJSON.parse(text)
            } catch {
                Issue.record("\(catalog.path) does not parse: \(error)")
                continue
            }

            let rewritten = XcodeCatalogJSON.dump(parsed)
            guard rewritten != text else { continue }

            Issue.record("""
                \(catalog.path) is not byte-stable under the catalog writer.

                Every tool in Translations/tools/ writes through this format. A catalog that \
                does not already match it means the next one-key change rewrites the whole \
                file, and the real change hides inside a diff nobody can read.

                \(firstDifference(between: text, and: rewritten))
                """)
        }

        #expect(examined == 7,
                "Examined \(examined) catalogs, expected 7 — a guard that reads nothing passes.")
    }

    @Test("The writer reproduces the four format details Xcode depends on")
    func writerSelfChecks() throws {
        // An empty object stays expanded. `json.dumps` collapses it to `{}` and rewrites every
        // entry that has one — and most untranslated entries do.
        #expect(XcodeCatalogJSON.dump(.object([("k", .object([]))]))
                == "{\n  \"k\" : {\n\n  }\n}")

        // Key and value are separated by " : ", not ": ".
        #expect(XcodeCatalogJSON.dump(.object([("k", .string("v"))])) == "{\n  \"k\" : \"v\"\n}")

        // Non-ASCII is written through. An escaped é rewrites every accented value in de/es/fr/
        // it/nl at once.
        #expect(XcodeCatalogJSON.quote("café") == "\"café\"")
        #expect(XcodeCatalogJSON.quote("Erledigt — fertig") == "\"Erledigt — fertig\"")

        // A number keeps its source spelling. `argNum` is an integer and must not come back 4.0.
        #expect(XcodeCatalogJSON.dump(.number("4")) == "4")

        // The escapes that do apply.
        #expect(XcodeCatalogJSON.quote("say \"hi\"") == "\"say \\\"hi\\\"\"")
        #expect(XcodeCatalogJSON.quote("a\nb") == "\"a\\nb\"")
        #expect(XcodeCatalogJSON.quote("a/b") == "\"a/b\"", "'/' is not escaped")
    }

    @Test("The parser preserves key order rather than sorting")
    func parserPreservesOrder() throws {
        // Xcode sorts with `localizedStandardCompare`, which is case-insensitive and
        // numeric-aware. Reproducing it exactly is a rabbit hole and we do not try — emitting
        // read order is what keeps a three-string change to three strings.
        let text = "{\n  \"zebra\" : \"1\",\n  \"apple\" : \"2\"\n}"
        #expect(XcodeCatalogJSON.dump(try XcodeCatalogJSON.parse(text)) == text)

        guard case .object(let pairs) = try XcodeCatalogJSON.parse(text) else {
            Issue.record("expected an object")
            return
        }
        #expect(pairs.map(\.key) == ["zebra", "apple"])
    }

    @Test("The parser reads every escape a catalog can contain")
    func parserSelfChecks() throws {
        guard case .string(let quoted) = try XcodeCatalogJSON.parse("\"say \\\"hi\\\"\""),
              case .string(let escaped) = try XcodeCatalogJSON.parse("\"\\u00e9\\n\\t\""),
              case .string(let paired) = try XcodeCatalogJSON.parse("\"\\ud83c\\udf89\"")
        else {
            Issue.record("a catalog escape failed to parse as a string")
            return
        }
        #expect(quoted == "say \"hi\"")
        #expect(escaped == "é\n\t")
        // 🎉 appears in the widget's empty state and arrives as a surrogate pair when a tool
        // other than ours has written the file.
        #expect(paired == "🎉")

        // Round-tripping an escaped scalar deliberately *normalises* it: `\u00e9` is read as é
        // and written back as é. That is the ensure_ascii=False decision, and it is the one
        // case where this guard's failure means "run the writer once", not "revert something".
        #expect(XcodeCatalogJSON.dump(try XcodeCatalogJSON.parse("\"\\u00e9\"")) == "\"é\"")
    }

    /// The first differing line, with context. A byte offset into a 200 KB file names nothing.
    private func firstDifference(between expected: String, and actual: String) -> String {
        let left = expected.components(separatedBy: "\n")
        let right = actual.components(separatedBy: "\n")
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : "<end of file>"
            let b = index < right.count ? right[index] : "<end of file>"
            if a != b {
                return """
                    First difference at line \(index + 1):
                      on disk: \(a)
                      writer:  \(b)
                    """
            }
        }
        return "The files differ in length only: \(expected.count) vs \(actual.count) characters."
    }
}
