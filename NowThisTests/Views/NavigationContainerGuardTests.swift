import Foundation
import Testing

/// **One navigation container per screen.**
///
/// `-[UINavigationBar layoutSubviews]` asserts — and aborts the app — when a *visible* bar is
/// asked to lay out while its `topItem` is owned by a different bar and both bars are in a
/// window. UIKit names the cause in the assertion text itself:
///
/// > Layout requested for visible navigation bar, %@, when the top item belongs to a different
/// > navigation bar. topItem = %@, navigation bar = %@, **possibly from a client attempt to nest
/// > wrapped navigation controllers.**
///
/// Three crash reports carry that signature, all iPhone on iOS 18: `1.0.4 (15)` on 18.7,
/// `26.8.1 (12)` on 18.6, and `26.8.1 (13)` on 18.7.8 — the last one *after* the detail-column
/// and hidden-sheet checks below had shipped, which is how the pushed journal editor was found.
/// It has never been seen on iOS 26, where SwiftUI flattens a nested `NavigationStack` into the
/// container above it; on iOS 18 it evidently does not always, and there is no way to tell from a
/// crash log which nesting produced it. So the rule is structural, not a fix aimed at one screen:
/// **the path from a presentation root to the screen it shows carries exactly one navigation
/// container.**
///
/// The paths below are the ones the app got wrong. All were invisible in review because the
/// nesting spans two structs — the container is declared in one file and the nested view is
/// constructed in another, so nothing reads as nested at either site.
@Suite("One navigation container per screen")
struct NavigationContainerGuardTests {

    // MARK: - Surface

    /// A view "owns" a container when its `var body` opens directly on `NavigationStack` or
    /// `NavigationSplitView`. Such a view supplies its own navigation bar, and therefore must be
    /// rendered *as* a screen — never handed to something that supplies one for it.
    static let containerTypes = ["NavigationStack", "NavigationSplitView"]

    /// View name → `file:line` of the container it opens on.
    static func containerOwners() throws -> [String: String] {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var owners: [String: String] = [:]

        for file in try LocalizationCatalogFixture.swiftSourceFiles()
        where file.hasPrefix("NowThis/Views/") {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let lines = SwiftSourceScanner.strippingComments(source)
                .components(separatedBy: .newlines)
            var currentStruct: String?

            for (index, line) in lines.enumerated() {
                if let name = Self.structName(in: line) { currentStruct = name }
                guard let name = currentStruct,
                      line.contains("var body: some View {") else { continue }

                // The first line with anything on it decides. A `Group`, a `switch` or a
                // `GeometryReader` above the container means the view does not open on one.
                for lookahead in lines.dropFirst(index + 1).prefix(6) {
                    let text = lookahead.trimmingCharacters(in: .whitespaces)
                    if text.isEmpty { continue }
                    if Self.containerTypes.contains(where: { text.hasPrefix($0) }) {
                        owners[name] = "\(file):\(index + 2)"
                    }
                    break
                }
            }
        }

        #expect(owners.count >= 10, """
            Found only \(owners.count) views opening on a navigation container. The app has well
            over ten (every sheet is one). A scanner that examines nothing reports success —
            re-anchor the `var body: some View {` / `struct X: View` match rather than lowering
            this floor.
            """)
        return owners
    }

    /// `struct Foo: View {`, with or without an access modifier.
    private static func structName(in line: String) -> String? {
        let pattern = #"struct\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*View\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    /// Every `SomeView(` construction in a slice of source.
    static func constructedViews(in slice: String) -> [String] {
        let pattern = #"\b([A-Z][A-Za-z0-9_]*)\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: slice, range: NSRange(slice.startIndex..., in: slice))
            .compactMap { Range($0.range(at: 1), in: slice).map { String(slice[$0]) } }
    }

    /// The body of the brace-balanced block that `anchor` opens, comments already stripped.
    static func block(after anchor: String, in source: String, file: String) throws -> String {
        let stripped = SwiftSourceScanner.strippingComments(source)
        let parts = stripped.components(separatedBy: anchor)
        #expect(parts.count == 2, """
            Expected exactly one `\(anchor)` in \(file), found \(parts.count - 1). This scan is
            anchored on it — re-anchor the test rather than deleting the assertion.
            """)
        let rest = try #require(parts.last)
        let open = try #require(rest.firstIndex(of: "{"))

        var depth = 0
        var end = open
        for index in rest[open...].indices {
            if rest[index] == "{" { depth += 1 }
            if rest[index] == "}" {
                depth -= 1
                if depth == 0 { end = index; break }
            }
        }
        return String(rest[open...end])
    }

    // MARK: - The split view's detail column

    @Test("The detail column's screens do not bring their own navigation bar")
    func detailColumnScreensDoNotNest() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let path = "NowThis/Views/Root/MainShellView.swift"
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        let column = try Self.block(after: "struct DetailColumn: View", in: source, file: path)

        let owners = try Self.containerOwners()
        let appViews = Set(owners.keys)
        let constructed = Self.constructedViews(in: column)

        // `ContentUnavailableView` and the like are SwiftUI's, not ours; only views this
        // repository declares can be checked, and only those are counted as examined.
        let declared = try Self.declaredViewNames()
        let examined = constructed.filter { declared.contains($0) }
        #expect(examined.count >= 2, """
            Examined \(examined.count) views in `DetailColumn`. It renders at least the journal
            list and the task list, so a smaller number means the slice is wrong, not that the
            column got simpler.
            """)

        let nested = examined.filter { appViews.contains($0) }
        #expect(nested.isEmpty, """
            \(nested.map { "\($0) (\(owners[$0] ?? "?"))" }.joined(separator: ", "))
            open on their own navigation container, and `DetailColumn` hands them to the detail
            column of `MainShellView`'s `NavigationSplitView`, which already supplies one. On a
            compact iPhone that split view collapses into a single navigation controller and the
            detail is pushed onto it — so the inner container's bar and the collapsed bar are in
            the window together, which is the state `-[UINavigationBar layoutSubviews]` asserts on.
            Delete the inner `NavigationStack` and let the split view own the bar: the title and
            toolbar attach to the detail column's bar unchanged.
            """)
    }

    /// Every view type this repository declares, so SwiftUI's own views cannot be miscounted
    /// as examined.
    static func declaredViewNames() throws -> Set<String> {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var names: Set<String> = []
        for file in try LocalizationCatalogFixture.swiftSourceFiles() {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for line in SwiftSourceScanner.strippingComments(source).components(separatedBy: .newlines) {
                if let name = structName(in: line) { names.insert(name) }
            }
        }
        #expect(names.count >= 40, """
            Found only \(names.count) `struct X: View` declarations across the source roots. The
            app has many more; a short list here silently empties every check below it.
            """)
        return names
    }

    // MARK: - The hidden-destination sheet

    @Test("The hidden-destination sheet puts exactly one container on each path")
    func hiddenDestinationSheetDoesNotNest() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let path = "NowThis/Views/Tasks/TaskListView.swift"
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)

        let sheet = try Self.block(after: ".sheet(item: $presentedHiddenTab)", in: source, file: path)
        let destination = try Self.block(
            after: "private func hiddenDestination(for tab: AppTab) -> some View",
            in: source, file: path)

        // The sheet closure calls `hiddenDestination(for:)`; it does not contain its body, so a
        // container counted here is one the closure itself wraps around every branch.
        let wrappedBySheet = Self.containerTypes
            .map { sheet.components(separatedBy: $0).count - 1 }
            .reduce(0, +)

        let owners = try Self.containerOwners()
        var branches: [(name: String, containers: Int)] = []

        for branch in destination.components(separatedBy: "case ").dropFirst() {
            let label = branch.prefix(while: { $0 != ":" })
            // Both pinned tabs are unreachable here and render `EmptyView()` — no screen, no bar.
            if branch.contains("EmptyView()") { continue }
            let declared = Self.containerTypes
                .map { branch.components(separatedBy: $0).count - 1 }
                .reduce(0, +)
            let owned = Self.constructedViews(in: branch).contains { owners.keys.contains($0) } ? 1 : 0
            branches.append((String(label), declared + owned))
        }

        #expect(branches.count == 4, """
            Examined \(branches.count) presentable branches of `hiddenDestination(for:)`, expected
            4 (board, calendar, matrix, smart). A branch that stopped matching is a branch that
            stopped being checked.
            """)

        for branch in branches {
            #expect(wrappedBySheet + branch.containers == 1, """
                The `\(branch.name)` branch reaches the screen through \
                \(wrappedBySheet + branch.containers) navigation containers: \(wrappedBySheet) \
                added by the `.sheet(item: $presentedHiddenTab)` closure and \(branch.containers) \
                on the branch itself. Exactly one is correct. Two nests wrapped navigation
                controllers, which is what `-[UINavigationBar layoutSubviews]` aborts on; zero
                leaves the screen with no bar, and the sheet with no way out.
                """)
        }
    }

    // MARK: - Pushed screens

    @Test("A pushed screen does not bring its own navigation bar")
    func pushedScreensDoNotNest() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var declarations: [String: [Substring]] = [:]
        var pushes: [(site: String, view: String)] = []

        for file in try LocalizationCatalogFixture.swiftSourceFiles() where file.hasPrefix("NowThis/") {
            let source = SwiftSourceScanner.strippingComments(
                try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8))
            for declaration in Self.viewDeclarations(in: source) {
                declarations[declaration.name, default: []].append(declaration.body)
            }
            for destination in Self.pushDestinations(in: source) {
                let line = source[..<destination.startIndex].filter { $0 == "\n" }.count + 1
                for view in Self.constructedViews(in: String(destination)) {
                    pushes.append(("\(file):\(line)", view))
                }
            }
        }

        // Only views this repository declares can be checked, and only those count as examined.
        let examined = pushes.filter { declarations[$0.view] != nil }
        #expect(examined.count >= 8, """
            Examined \(examined.count) pushed screens. The app pushes at least eight — account edit
            and setup from Settings, onboarding's two steps, a journal entry from the journal list
            and from a task, and a task from the Board and from the Calendar — so a smaller number
            means the destination scan stopped matching, not that the app pushes less.
            """)

        let nested = examined.filter { push in
            declarations[push.view, default: []].contains { Self.opensContainer($0) }
        }
        #expect(nested.isEmpty, """
            \(nested.map { "\($0.view), pushed at \($0.site)" }.joined(separator: "; ")) — each
            opens a navigation container of its own, and a push lands on a stack that already
            supplies one. On iOS 18 the pushed container's bar and the host's bar are then in the
            window together, the state `-[UINavigationBar layoutSubviews]` aborts on; iOS 26 merges
            the two, so no current simulator shows it. The body opening on an `if` rather than on
            the container is what hid this from `containerOwners()`. Put the container at the one
            presentation that needs it — the sheet — and let every push attach its title and
            toolbar to the host's bar.
            """)
    }

    /// Every `struct X: View` in comment-stripped `source`, with its brace-balanced body.
    static func viewDeclarations(in source: String) -> [(name: String, body: Substring)] {
        let pattern = #"struct\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*View\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
            .compactMap { match in
                guard let name = Range(match.range(at: 1), in: source),
                      let end = Range(match.range, in: source)?.upperBound,
                      let open = source[end...].firstIndex(of: "{"),
                      let body = balanced(in: source, openingAt: open) else { return nil }
                return (String(source[name]), source[body])
            }
    }

    /// The pushed destinations in comment-stripped `source`: `NavigationLink { … }`'s closure and
    /// `.navigationDestination(…) { … }`'s.
    ///
    /// `NavigationLink(value:) { … }` is deliberately not one. Its closure is the label; the screen
    /// it reaches is built by a `.navigationDestination`, which this finds on its own.
    static func pushDestinations(in source: String) -> [Substring] {
        var closures: [Substring] = []
        for range in source.ranges(of: "NavigationLink") {
            let next = skippingWhitespace(in: source, from: range.upperBound)
            if next < source.endIndex, source[next] == "{",
               let closure = balanced(in: source, openingAt: next) {
                closures.append(source[closure])
            }
        }
        for range in source.ranges(of: ".navigationDestination") {
            let arguments = skippingWhitespace(in: source, from: range.upperBound)
            guard arguments < source.endIndex, source[arguments] == "(",
                  let span = balanced(in: source, openingAt: arguments) else { continue }
            let next = skippingWhitespace(in: source, from: span.upperBound)
            if next < source.endIndex, source[next] == "{",
               let closure = balanced(in: source, openingAt: next) {
                closures.append(source[closure])
            }
        }
        return closures
    }

    /// Whether a view declaration wraps its own content in a navigation container — anywhere, not
    /// only as the first line of `body`, and not inside a `.sheet`, `.fullScreenCover` or
    /// `.popover`, each of which is a presentation of its own and is entitled to one.
    static func opensContainer(_ declaration: Substring) -> Bool {
        var source = String(declaration)
        for modifier in [".sheet", ".fullScreenCover", ".popover"] {
            while let range = source.range(of: modifier) {
                var end = range.upperBound
                let arguments = skippingWhitespace(in: source, from: end)
                if arguments < source.endIndex, source[arguments] == "(",
                   let span = balanced(in: source, openingAt: arguments) {
                    end = span.upperBound
                    let next = skippingWhitespace(in: source, from: end)
                    if next < source.endIndex, source[next] == "{",
                       let closure = balanced(in: source, openingAt: next) {
                        end = closure.upperBound
                    }
                }
                source.removeSubrange(range.lowerBound..<end)
            }
        }
        return source.range(of: #"\b(NavigationStack|NavigationSplitView)\s*[({]"#,
                            options: .regularExpression) != nil
    }

    /// The span from the `(` or `{` at `open` through the bracket that closes it.
    static func balanced(in source: String, openingAt open: String.Index) -> Range<String.Index>? {
        let opener = source[open]
        let closer: Character = opener == "(" ? ")" : "}"
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == opener { depth += 1 }
            if source[index] == closer {
                depth -= 1
                if depth == 0 { return open..<source.index(after: index) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    static func skippingWhitespace(in source: String, from index: String.Index) -> String.Index {
        source[index...].firstIndex { !$0.isWhitespace } ?? source.endIndex
    }
}
