import Foundation

/// A deliberately small block-YAML reader that flattens `project.yml` into dotted paths.
///
/// **Why this exists rather than a regex.** The prior build-settings guard matches
/// `project.yml` line by line, which cannot tell `settings.base` from a single target's
/// `settings.base`. Moving a setting off the project and onto one target — the exact defect
/// Phase 1a exists to fix, since it is how three of the four shipping targets ended up with no
/// string extraction at all — leaves that guard green. A structural read makes the location of
/// a setting assertable, not just its presence.
///
/// Supports only what `project.yml` actually uses: block mappings, block sequences, `# ` line
/// comments, and double-quoted scalars. No anchors, flow collections, multi-line scalars or
/// multi-document streams — if any of those appear, the parser will produce paths that do not
/// match and the guard goes **red**, which is the safe direction.
enum YAMLLite {

    /// Flattens to `["settings.base.SWIFT_EMIT_LOC_STRINGS": "YES", …]`.
    /// Sequence elements are indexed: `targets.NowThis.dependencies.0.target`.
    static func flatten(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var stack: [(indent: Int, path: String)] = [(-1, "")]
        var seqCounters: [String: Int] = [:]

        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") {
                let before = line[line.startIndex..<hash]
                if before.trimmingCharacters(in: .whitespaces).isEmpty || before.hasSuffix(" ") {
                    line = String(before)
                }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let indent = line.prefix(while: { $0 == " " }).count
            while stack.count > 1 && indent <= stack[stack.count - 1].indent { stack.removeLast() }

            var parentPath = stack[stack.count - 1].path
            var content = trimmed
            var effectiveIndent = indent
            var cameFromSequence = false

            if content == "-" || content.hasPrefix("- ") {
                cameFromSequence = true
                let index = seqCounters[parentPath, default: 0]
                seqCounters[parentPath] = index + 1
                parentPath = parentPath.isEmpty ? "\(index)" : "\(parentPath).\(index)"
                content = content == "-" ? "" : String(content.dropFirst(2))
                effectiveIndent = indent + 2
                if content.trimmingCharacters(in: .whitespaces).isEmpty {
                    stack.append((indent: effectiveIndent - 1, path: parentPath))
                    continue
                }
            }

            if let colon = content.firstIndex(of: ":") {
                let key = String(content[content.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let rawValue = String(content[content.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                let path = parentPath.isEmpty ? key : "\(parentPath).\(key)"

                if rawValue.isEmpty {
                    stack.append((indent: effectiveIndent, path: path))
                } else {
                    out[path] = unquote(rawValue)
                    if cameFromSequence {
                        stack.append((indent: effectiveIndent - 1, path: parentPath))
                    }
                }
            } else if cameFromSequence {
                out[parentPath] = unquote(content)
            }
        }
        return out
    }

    /// Every immediate child key under a dotted path. `children(of: "targets", in: …)`
    /// returns the five target names.
    static func children(of path: String, in flat: [String: String]) -> Set<String> {
        let prefix = path.isEmpty ? "" : path + "."
        var names: Set<String> = []
        for key in flat.keys where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            if let first = rest.split(separator: ".").first { names.insert(String(first)) }
        }
        return names
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
