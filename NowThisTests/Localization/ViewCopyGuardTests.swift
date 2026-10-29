import Foundation
import Testing

/// Guards the view-copy class: user-facing English that renders, reads correctly under VoiceOver,
/// and never reaches a string catalog.
///
/// ## The mechanism
///
/// Every SwiftUI API that takes copy has **two** overloads: one taking `LocalizedStringKey` and a
/// `@_disfavoredOverload` taking `StringProtocol`. `Text` (`SwiftUICore.swiftinterface:18153`),
/// `Label` (`:1590`), `Toggle` (`:4835`), `Menu`/`Section` (`:6849`), `Picker` (`:13440`),
/// `.navigationTitle` (`:17605`), `.accessibilityLabel` (`:741`), `.accessibilityValue` (`:33`),
/// `.accessibilityHint` (`:2637`).
///
/// A **literal** binds the localizing overload. A **`String`-typed value** binds the disfavored
/// one. The build succeeds, the screen renders, VoiceOver reads it, every catalog guard stays
/// green — and the string ships English in all five languages, because from the catalog's point
/// of view it does not exist.
///
/// So the failure is not "a variable reached `Text`". Passing an already-localized `String` is
/// correct and this file must not flag it. The failure is **a bare literal parked in a `String`
/// before it reaches SwiftUI**:
///
/// - `Text(status.displayName)` where `displayName` returns `String(localized:)` — **fine**,
///   extraction happened at the literal.
/// - `Text(quadrant.title)` where `title` returns a bare `"Do First"` — **broken**.
///
/// Hence: *localize at the literal, never at the render site.* These tests check the literals.
@Suite("View copy reaches the catalogs")
struct ViewCopyGuardTests {

    // MARK: - Surface

    /// Where view copy lives. Scoped deliberately: the wire serializers (`VEventSerializer`,
    /// `CalDAVClient`, `ICalendarSerializer`) are full of `-> String` producers returning
    /// `"BEGIN:VCALENDAR"` and `"&amp;"`, and a scanner that reads them needs an exemption list
    /// longer than the guard. Those files are covered by the wire-boundary guard instead, whose
    /// invariant is the opposite one: they must contain **no** localization API at all.
    static let surfaceDirectories = [
        "NowThis/Views/",
        "NowThisWatch/",
        "NowThisWatchWidget/",
        "NowThisWidget/",
    ]

    /// Individual files outside those directories that still render copy.
    static let surfaceFiles_extra = [
        "NowThis/App/NowThisApp.swift",
        "NowThis/Utilities/ErrorState.swift",
    ]

    /// Markers that mean "this literal was localized where it was written".
    static let localizingMarkers = [
        "String(localized:",
        "localized:",
        "LocalizedStringResource",
        "LocalizedStringKey",
        "defaultValue:",
        "comment:",
    ]

    /// Render-site call prefixes whose first argument is copy.
    static let renderMarkers = [
        "Text(", "Label(", "Toggle(", "Button(", "TextField(", "SecureField(",
        "Section(", "Picker(", "Menu(", "Stepper(", "Link(", "NavigationLink(",
        ".navigationTitle(", ".navigationBarTitle(",
        ".accessibilityLabel(", ".accessibilityHint(", ".accessibilityValue(",
        ".alert(", ".confirmationDialog(", ".help(", ".searchable(", ".tabItem(",
    ]

    static func surfaceFiles() throws -> [String] {
        let all = try LocalizationCatalogFixture.swiftSourceFiles()
        var files = all.filter { path in
            Self.surfaceDirectories.contains { path.hasPrefix($0) }
        }
        files.append(contentsOf: Self.surfaceFiles_extra.filter { all.contains($0) })
        return files.sorted()
    }

    // MARK: - Exemptions

    /// A literal that is not copy, or is copy this phase deliberately defers.
    ///
    /// Every entry is rot-checked by ``exemptionsStillApply``: if the text is no longer present in
    /// the named file the exemption fails, so a stale entry cannot keep silently excusing a line
    /// that has since changed meaning.
    struct Exemption {
        let file: String
        let text: String
        let reason: String
    }

    static let exemptions: [Exemption] = [
        // ---- Not copy: SF Symbol names. These reach `Image(systemName:)`, never a catalog.
        Exemption(file: "NowThis/Views/Tasks/QuickAddView.swift", text: "flag",
                  reason: "SF Symbol name for `Image(systemName:)`, not copy."),
        Exemption(file: "NowThis/Views/Tasks/SidebarView.swift", text: "calendar",
                  reason: "SF Symbol name for `Image(systemName:)`, not copy."),

    ]

    /// A whole `-> String` producer that does not produce copy.
    ///
    /// Kept separate from ``Exemption`` because these are identified by *what the property is for*,
    /// not by one literal's text. `SidebarSelection.encoded` builds `"smart:today"`,
    /// `"list:\(id)"` and three more — exempting each by text would need the rot check to match a
    /// literal that is never written whole (`"smart:\(list.rawValue)"`), and would go stale the
    /// moment a case is added.
    struct ProducerExemption {
        let file: String
        let producer: String
        let reason: String
    }

    static let producerExemptions: [ProducerExemption] = [
        ProducerExemption(
            file: "NowThis/Views/Tasks/SidebarView.swift", producer: "encoded",
            reason: "`SidebarSelection.encoded` is a scene-restoration token compared against persisted `@SceneStorage` values. Localizing it would break state restoration on a language change, and the logic-coupling guard forbids it outright."),
        ProducerExemption(
            file: "NowThis/Views/Root/AppTab.swift", producer: "token",
            reason: "`AppTab.token` is a persistence identifier written to `@AppStorage`/`@SceneStorage` and parsed back by `AppTab.decode(from:)`. Localizing it would break tab-bar order and visibility round-tripping the moment the user's language changes — the same shape as `SidebarSelection.encoded` above."),
        ProducerExemption(
            file: "NowThis/Views/Root/AppTab.swift", producer: "icon",
            reason: "`AppTab.icon` returns an SF Symbol name, consumed by `Image(systemName:)`/`Label`'s image argument, not copy. Localizing an SF Symbol name would resolve to no symbol at all in every non-English locale."),
        ProducerExemption(
            file: "NowThis/Views/Root/MainShellView.swift", producer: "resolveStartupKey",
            reason: "`resolveStartupKey` compares against and returns persisted `@AppStorage`/`@SceneStorage` tokens (`\"smart:...\"`, `\"last\"`) — the same `smart:` prefix `AppTab.token` and `SidebarSelection.encoded` already use for this reason. It never reaches a render site; localizing it would break scene restoration the moment the user's language changes."),
        ProducerExemption(
            file: "NowThis/Views/Root/ContentView.swift", producer: "startupChoiceRow",
            reason: "`startupChoiceRow(for:visible:)` builds a persistence tag (`\"last\"`, `\"smart:...\"`, `\"tab:...\"`) that selects which \"Open App To\" picker row is checked — it is compared against the persisted `@AppStorage(\"startupScreen\")` value, never rendered as copy. Localizing it would stop it matching that stored value, so the user's choice would silently stop being honoured after a language change — the same failure mode as `AppTab.token` and `SidebarSelection.encoded` above."),
    ]

    // MARK: - Copy classification

    /// Whether a literal is user-facing copy.
    ///
    /// Interpolations collapse first, so `"\(count) tasks today"` is copy on the strength of
    /// `tasks today` and `"\(a)-\(b)"` is not copy at all.
    static func looksLikeCopy(_ text: String) -> Bool {
        var collapsed = ""
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\\", text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == "(" {
                depth += 1
                index = text.index(index, offsetBy: 2)
                continue
            }
            if depth > 0 {
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" { depth -= 1 }
            } else {
                collapsed.append(text[index])
            }
            index = text.index(after: index)
        }

        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // An SF Symbol name (`calendar.badge.plus`) or a reverse-DNS-ish token is not copy.
        let symbolish = trimmed.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "." }
        if symbolish, trimmed.contains(".") { return false }

        // A hex colour is not copy.
        if trimmed.hasPrefix("#"), trimmed.dropFirst().allSatisfy(\.isHexDigit) { return false }

        // Needs two adjacent letters somewhere to be a word.
        var previousWasLetter = false
        for character in trimmed {
            if character.isLetter {
                if previousWasLetter { return true }
                previousWasLetter = true
            } else {
                previousWasLetter = false
            }
        }
        return false
    }

    // MARK: - 1. Copy producers

    /// Every `-> String` producer in the view surface must localize its copy literals **at the
    /// literal**, because whatever renders the result binds the disfavored overload.
    ///
    /// This is the test that sees `Quadrant.title` returning a bare `"Do First"`. `Text` renders
    /// it, VoiceOver reads it, and no catalog contains it.
    @Test("Copy-producing properties localize at the literal")
    func copyProducingPropertiesAreLocalized() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let files = try Self.surfaceFiles()
        var findings: [String] = []
        var examinedProducers = 0
        var examinedLiterals = 0

        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let producers = Self.stringProducers(in: source)
            examinedProducers += producers.count
            guard !producers.isEmpty else { continue }

            let covered = SwiftSourceScanner.callCoveredLines(in: source, markers: Self.localizingMarkers)
            let literals = SwiftSourceScanner.stringLiterals(in: source, file: file)

            for producer in producers {
                if Self.isExemptProducer(file: file, producer: producer.name) { continue }
                for literal in literals where producer.lines.contains(literal.line) {
                    guard Self.looksLikeCopy(literal.text) else { continue }
                    examinedLiterals += 1
                    if covered.contains(literal.line) { continue }
                    if Self.isExempt(file: file, text: literal.text) { continue }
                    findings.append(
                        "\(file):\(literal.line)  \(producer.name) → \"\(literal.text)\"")
                }
            }
        }

        // Anti-vacuity. A scanner that examines nothing reports success, and the whole point of
        // this phase is that success was being reported over strings nobody could see.
        //
        // 33 is the count **measured** on 2026-07-26, not a comfortable margin below it. A floor
        // set safely under the real number is precisely the range in which a scanner that has
        // stopped looking still passes — that is how the §2c-i guard reported success over five
        // files it could not see.
        #expect(examinedProducers >= 33, """
            Only \(examinedProducers) `-> String` producers found in the view surface; 33 were \
            present when this guard was written. The declaration matcher has stopped matching — \
            every finding below is unreliable until that is fixed.
            """)
        #expect(examinedLiterals >= 30, """
            Only \(examinedLiterals) copy literals examined inside producers; expected at least 30.
            """)

        #expect(findings.isEmpty, """
            \(findings.count) copy literal(s) sit in a `-> String` producer and never reach a catalog.

            Whatever renders these binds SwiftUI's `@_disfavoredOverload` `StringProtocol` overload,
            so they render, VoiceOver reads them, and they ship English in de/es/fr/it/nl.

            Localize **at the literal**:
                case .doFirst: return String(
                    localized: "matrix.quadrant.doFirst.title",
                    defaultValue: "Do First",
                    comment: "Eisenhower matrix quadrant …")

            \(findings.joined(separator: "\n"))
            """)
    }

    // MARK: - 2. Nil-coalesced English

    /// `Text(x ?? "Calendar")` binds the `StringProtocol` overload for exactly the same reason a
    /// bare variable does — the coalesce produces a `String`, so **neither** side extracts.
    @Test("No render site coalesces to an English literal")
    func nilCoalescedEnglishDoesNotReachRenderSites() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let files = try Self.surfaceFiles()
        var findings: [String] = []
        var examinedSites = 0

        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let arguments = SwiftSourceScanner.firstArguments(
                ofCallsTo: Self.renderMarkers, in: source, file: file)
            examinedSites += arguments.count

            for argument in arguments {
                guard let coalesce = argument.redacted.range(of: "??") else { continue }

                // Only the **fallback** side counts. `infoDictionary?["CFBundleVersion"] as? String
                // ?? "1"` coalesces to a version number, not to copy — but the dictionary *key* on
                // the left is a copy-shaped literal, and reading literals from the whole expression
                // reports that key as the finding. The offset is taken on the redacted text and
                // applied to the written text, which `redactedForStructure` keeps index-aligned.
                let offset = argument.redacted.distance(
                    from: argument.redacted.startIndex, to: coalesce.upperBound)
                guard offset < argument.asWritten.count else { continue }

                // A literal inside `String(localized:…)` on the fallback side is the **fix**. Strip
                // those spans before looking for a bare literal, or this test rejects the very
                // change it exists to demand.
                let fallbackRedacted = SwiftSourceScanner.strippingLocalizingCalls(
                    String(argument.redacted.dropFirst(offset)))
                guard fallbackRedacted.contains("\"") else { continue }

                let fallbackWritten = String(argument.asWritten.dropFirst(offset))
                let literals = SwiftSourceScanner.stringLiterals(in: fallbackWritten, file: file)
                let copy = literals.filter { Self.looksLikeCopy($0.text) }
                guard let offender = copy.first else { continue }
                if Self.isExempt(file: file, text: offender.text) { continue }

                findings.append(
                    "\(file):\(argument.line)  \(argument.marker)…  \(argument.asWritten.trimmed())")
            }
        }

        #expect(examinedSites >= 400, """
            Only \(examinedSites) render sites examined; expected at least 400. The render-marker \
            walk has stopped matching.
            """)

        #expect(findings.isEmpty, """
            \(findings.count) render site(s) fall back to an English literal through `??`.

            `x ?? "Calendar"` is a `String`, so the coalesce binds the disfavored overload and
            **neither** branch is extracted — not the fallback, and not a translated `x`.

            Localize the fallback at its literal and coalesce afterwards:
                Text(selectedList?.name ?? String(localized: "calendar.title.allLists", …))

            \(findings.joined(separator: "\n"))
            """)
    }

    // MARK: - 3. The ternary asymmetry

    /// A mixed literal/variable ternary is the subtlest member of the class: it *looks* like the
    /// all-literal form, which does extract.
    @Test("No render site passes a mixed literal/variable ternary")
    func mixedTernaryCopyDoesNotReachRenderSites() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let files = try Self.surfaceFiles()
        var findings: [String] = []
        var ternariesExamined = 0

        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let arguments = SwiftSourceScanner.firstArguments(
                ofCallsTo: Self.renderMarkers, in: source, file: file)

            for argument in arguments {
                // A branch that is a `String(localized:…)` call is an already-localized `String`,
                // so a ternary of two of those is correct — extraction happened at each literal.
                // Strip those spans first; what remains is the bare-literal question.
                let redacted = SwiftSourceScanner.strippingLocalizingCalls(argument.redacted)
                guard redacted.contains("?"), redacted.contains(":") else { continue }
                guard !redacted.contains("??") else { continue }
                guard redacted.contains("\"") else { continue }
                ternariesExamined += 1

                if SwiftSourceScanner.isAllLiteralTernary(redacted) { continue }
                if Self.isExempt(file: file, text: argument.asWritten.trimmed()) { continue }

                findings.append(
                    "\(file):\(argument.line)  \(argument.marker)…  \(argument.asWritten.trimmed())")
            }
        }

        // Was 20. Phase 6 hoisted `TaskRowView`'s swipe-action title out of its
        // `Label` initialiser into a computed property, so that ternary is no
        // longer at a render site and the true population is 19. Lowered
        // deliberately, with the reason, rather than left to fail — but never
        // lower it just because a run came back short. A shrinking population
        // is the thing this floor exists to make someone look at.
        #expect(ternariesExamined >= 19, """
            Only \(ternariesExamined) ternary render sites examined; expected at least 19. If this \
            floor is not met the classifier is not being exercised and its verdicts mean nothing.
            """)

        #expect(findings.isEmpty, """
            \(findings.count) render site(s) pass a ternary with one literal and one non-literal branch.

            An **all-literal** ternary is compiled as a `LocalizedStringKey` and both branches are
            extracted. **One** non-literal branch demotes the whole expression to `StringProtocol`
            and neither branch reaches a catalog:

                Text(flag ? "Descending" : "Ascending")     ✓ both extracted
                Text(flag ? "No date" : rule.displayName)   ✗ neither extracted

            Localize the literal branch at its literal, so both sides are already-localized
            `String`s by the time the ternary runs.

            \(findings.joined(separator: "\n"))
            """)
    }

    // MARK: - 4. String copy parameters

    /// A `View` that takes copy as a `String` cannot be localized by its call sites' literals.
    /// The type is allowed to stay `String` — several call sites legitimately pass an
    /// already-localized value — but then **every** call site must pass a non-literal.
    ///
    /// This is the check, not the type. `FilterChipView(label: "Completed", …)` is the failure:
    /// the literal binds `String`, so `Text(label)` renders it verbatim.
    @Test("No bare literal is passed into a String copy parameter")
    func stringCopyParametersHaveNoBareLiteralCallSites() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let files = try Self.surfaceFiles()

        // Components that hold copy as a `String`, with the parameter label that carries it.
        // Measured, not assumed: these are the `View`-conforming structs in the surface with a
        // copy-named `String` stored property.
        let copyParameters: [(component: String, label: String)] = [
            ("FilterChipView", "label"),
            ("TokenChip", "label"),
            ("InlineAddBar", "dueRuleLabel"),
            ("WatchListDetailView", "title"),
        ]

        var findings: [String] = []
        var callSitesExamined = 0

        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let redacted = SwiftSourceScanner.redactedForStructure(source)
            let lines = redacted.components(separatedBy: "\n")
            let written = source.components(separatedBy: "\n")

            for (component, label) in copyParameters {
                for (index, line) in lines.enumerated() {
                    // The argument may sit on the constructor's line or on a later one.
                    guard line.contains("\(component)(") || line.contains("\(label):") else { continue }
                    guard let range = line.range(of: "\(label):") else { continue }

                    // Only count it if a `component(` opened at or above this line and has not
                    // closed — otherwise `label:` belongs to some unrelated call.
                    guard Self.isInsideCall(to: component, at: index, lines: lines) else { continue }
                    callSitesExamined += 1

                    let argument = line[range.upperBound...].trimmed()
                    guard argument.hasPrefix("\"") else { continue }

                    findings.append("\(file):\(index + 1)  \(component) ← \(written[index].trimmed())")
                }
            }
        }

        #expect(callSitesExamined >= 8, """
            Only \(callSitesExamined) call sites examined across \(copyParameters.count) components; \
            expected at least 8. The call-site walk has stopped matching, so an all-green result \
            here means nothing.
            """)

        #expect(findings.isEmpty, """
            \(findings.count) call site(s) pass a bare literal into a `String` copy parameter.

            The parameter's type is `String`, so the literal binds `String` and the component's
            `Text(label)` renders it through the disfavored overload. It never reaches a catalog.

            Either localize at this literal:
                FilterChipView(label: String(localized: "filter.chip.completed", …), …)
            or change the parameter to `LocalizedStringKey` if **every** call site passes a literal.

            \(findings.joined(separator: "\n"))
            """)
    }

    // MARK: - 5. Copy sinks

    /// A bare literal assigned to a copy-named `String` property is the same defect one step
    /// earlier: `errorMessage = "Couldn't load NowThis Pro."` renders through `Text(errorMessage)`.
    @Test("No bare literal is assigned to a copy-named String property")
    func copyNamedStringSinksAreLocalized() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let files = try Self.surfaceFiles()
        let sinkNames = ["errorMessage", "saveError", "connectionError", "message", "lastError",
                         "statusMessage", "title", "subtitle", "label", "caption", "footer"]
        var findings: [String] = []
        var assignmentsExamined = 0

        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let redacted = SwiftSourceScanner.redactedForStructure(source)
            let covered = SwiftSourceScanner.callCoveredLines(in: source, markers: Self.localizingMarkers)
            let lines = redacted.components(separatedBy: "\n")
            let literals = SwiftSourceScanner.stringLiterals(in: source, file: file)

            for (index, line) in lines.enumerated() {
                for name in sinkNames {
                    guard let range = line.range(of: "\(name) = ") else { continue }
                    let value = line[range.upperBound...].trimmed()
                    guard value.hasPrefix("\"") else { continue }
                    assignmentsExamined += 1

                    let onThisLine = literals.filter { $0.line == index + 1 && Self.looksLikeCopy($0.text) }
                    guard let literal = onThisLine.first else { continue }
                    if covered.contains(index + 1) { continue }
                    if Self.isExempt(file: file, text: literal.text) { continue }

                    findings.append("\(file):\(index + 1)  \(name) = \"\(literal.text)\"")
                }
            }
        }

        #expect(assignmentsExamined >= 1, """
            No literal assignments to copy-named properties examined at all. Either the sink names \
            are wrong or the walk is broken; in both cases this test is not checking anything.
            """)

        #expect(findings.isEmpty, """
            \(findings.count) bare literal(s) assigned to a copy-named `String` property.

            The property is a `String`, so whatever renders it binds the disfavored overload.
            Localize at the literal:
                errorMessage = String(localized: "pro.error.loadFailed", defaultValue: …, comment: …)

            \(findings.joined(separator: "\n"))
            """)
    }

    // MARK: - 6. Exemption rot

    @Test("Every exemption still describes something present")
    func exemptionsStillApply() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var stale: [String] = []

        for exemption in Self.exemptions {
            let url = root.appendingPathComponent(exemption.file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                stale.append("\(exemption.file) — file is gone; exemption for \"\(exemption.text)\" cannot apply")
                continue
            }
            // Extracted literals, not raw text. `source.contains("\"day\"")` was satisfied by a
            // doc comment that merely *mentions* `"day"`, so an exemption whose literal §2d had
            // deleted still looked live — a rot check that cannot rot.
            let literals = SwiftSourceScanner.stringLiterals(in: source, file: exemption.file)
            if !literals.contains(where: { $0.text == exemption.text }) {
                stale.append("\(exemption.file) — no literal \"\(exemption.text)\" remains")
            }
        }

        for exemption in Self.producerExemptions {
            let url = root.appendingPathComponent(exemption.file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                stale.append("\(exemption.file) — file is gone; producer exemption for `\(exemption.producer)` cannot apply")
                continue
            }
            let producers = Self.stringProducers(in: source)
            if !producers.contains(where: { $0.name == exemption.producer }) {
                stale.append("\(exemption.file) — no `-> String` producer named `\(exemption.producer)` remains")
            }
        }

        #expect(Self.exemptions.count >= 2, """
            Only \(Self.exemptions.count) exemptions declared; expected at least 2. Entries were \
            removed without the corresponding literals being localized, which silently widens \
            what this suite forgives.
            """)
        #expect(Self.producerExemptions.count >= 1, """
            No producer exemptions declared; expected at least 1.
            """)

        #expect(stale.isEmpty, """
            \(stale.count) exemption(s) no longer match anything. An exemption that matches nothing \
            is dead weight that will excuse the next literal to take that name — delete it.

            \(stale.joined(separator: "\n"))
            """)
    }

    // MARK: - 6b. `rawValue` never becomes a label

    /// A `-> String` producer that returns a `.rawValue` is rendering a **stored identifier**.
    ///
    /// Found by pseudolocalization, not by any static check that existed: on the doubled build
    /// every string on the task list doubled except the navigation title, because
    /// `TaskListView.title` returned `smart.rawValue` — the token `@AppStorage` persists and
    /// `SidebarSelection.decode` parses back on launch. All five smart-list screens showed it, so
    /// all five shipped English whatever the catalog said.
    ///
    /// It is invisible to every other guard here because there is **no literal at the site**: the
    /// English lives in the enum's raw values, where it is legitimately English and must stay so.
    /// Localizing `rawValue` to "fix" it would lose the user's sidebar selection on a language
    /// change — which is why `displayName` exists as a separate property, and why this checks the
    /// *shape* rather than looking for a string.
    @Test("No copy-producing property returns a stored `rawValue`")
    func rawValuesDoNotBecomeLabels() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let exemptProducers = Set(Self.producerExemptions.map { "\($0.file)|\($0.producer)" })
        var examined = 0
        var findings: [String] = []

        for file in try Self.surfaceFiles() {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let lines = SwiftSourceScanner.strippingComments(source)
                .components(separatedBy: "\n")

            for producer in Self.stringProducers(in: source) {
                examined += 1
                guard !exemptProducers.contains("\(file)|\(producer.name)") else { continue }
                for line in producer.lines.sorted() where line - 1 < lines.count {
                    let text = lines[line - 1]
                    guard text.contains(".rawValue") else { continue }
                    // A `rawValue` used as a dictionary key, a tag, or a stored comparison is
                    // fine; one that is *returned* from a copy producer is the defect.
                    guard text.trimmingCharacters(in: .whitespaces).hasPrefix("return ")
                            || text.contains(": return ") else { continue }
                    findings.append("  \(file):\(line)  \(text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        #expect(examined >= 33, """
            Only \(examined) `-> String` producers examined; 33 existed when this was written.
            """)
        #expect(findings.isEmpty, """
            \(findings.count) copy-producing propert(ies) return a stored `rawValue`:
            \(findings.joined(separator: "\n"))

            A `rawValue` is what gets persisted and parsed back — `@AppStorage`, scene restoration,
            a saved filter's stored comparison. Rendering it means the screen shows the identifier
            and ships English whatever the catalog holds, and localizing the `rawValue` to fix that
            breaks everything that reads it back. Return the type's `displayName` instead.
            """)
    }

    // MARK: - 7. Self-checks

    /// The asymmetry table from the plan, asserted directly. Without this the classifier could
    /// invert and every verdict above would flip with no test going red.
    @Test("The ternary classifier matches the verified storage table")
    func ternaryClassifierSelfChecks() {
        // Extracts: every branch is a literal.
        #expect(SwiftSourceScanner.isAllLiteralTernary(#"flag ? "Descending" : "Ascending""#))
        #expect(SwiftSourceScanner.isAllLiteralTernary(#"a == .b ? "Show" : "Hide""#))
        #expect(SwiftSourceScanner.isAllLiteralTernary(#"x ? "Show \(name)" : "Hide \(name)""#))
        // Nested all-literal ternary in the else branch.
        #expect(SwiftSourceScanner.isAllLiteralTernary(#"a ? "One" : b ? "Two" : "Three""#))
        // A call in the *condition* does not demote it — only the branches matter.
        #expect(SwiftSourceScanner.isAllLiteralTernary(#"list.isEmpty ? "None" : "Some""#))

        // Does not extract: at least one branch is not a literal.
        #expect(!SwiftSourceScanner.isAllLiteralTernary(#"flag ? "No date" : rule.displayName"#))
        #expect(!SwiftSourceScanner.isAllLiteralTernary(#"flag ? rule.displayName : "No date""#))
        #expect(!SwiftSourceScanner.isAllLiteralTernary(#"a ? "One" : b ? "Two" : other"#))
        // Concatenation is not a literal.
        #expect(!SwiftSourceScanner.isAllLiteralTernary(#"a ? "One " + name : "Two""#))

        // Not ternaries at all.
        #expect(!SwiftSourceScanner.isAllLiteralTernary(#"name ?? "Calendar""#))
        #expect(!SwiftSourceScanner.isAllLiteralTernary(#"list?.name"#))
        #expect(!SwiftSourceScanner.isAllLiteralTernary(#""just a literal""#))
        #expect(!SwiftSourceScanner.isAllLiteralTernary(#"someValue"#))
        // A `?` inside a nested call must not be read as this expression's ternary.
        #expect(!SwiftSourceScanner.isAllLiteralTernary(#"f(a ? "x" : "y")"#))
    }

    /// Stripping localizing calls must remove the whole span and nothing else. Too greedy and a
    /// genuinely bare literal beside a localized one is forgiven; too shy and the fix this suite
    /// demands is reported as the defect it replaced.
    @Test("Localizing-call spans are stripped exactly")
    func strippingLocalizingCallsSelfChecks() {
        // The fixed forms: nothing bare survives.
        #expect(!SwiftSourceScanner.strippingLocalizingCalls(
            #"list?.name ?? String(localized: "k", defaultValue: "All Lists", comment: "c")"#
        ).contains("\""))
        // The wrapped form — `String(localized:` is never contiguous here (L24's blind spot).
        #expect(!SwiftSourceScanner.strippingLocalizingCalls(
            "list?.name ?? String(\n    localized: \"k\",\n    defaultValue: \"All Lists\")"
        ).contains("\""))
        #expect(!SwiftSourceScanner.strippingLocalizingCalls(
            #"LocalizedStringResource("k", defaultValue: "v")"#
        ).contains("\""))

        // The broken forms: the bare literal must still be visible.
        #expect(SwiftSourceScanner.strippingLocalizingCalls(#"list?.name ?? "Calendar""#)
            .contains("\""))
        // A bare literal concatenated onto a localized one is still a defect — a marker appearing
        // *somewhere* in the expression must not excuse the whole expression.
        #expect(SwiftSourceScanner.strippingLocalizingCalls(
            #""Prefix " + String(localized: "k", defaultValue: "v")"#
        ).contains("\""))
        // Two localized branches plus one bare one.
        #expect(SwiftSourceScanner.strippingLocalizingCalls(
            #"a ? String(localized: "k", defaultValue: "v") : "Bare""#
        ).contains("\""))

        // Line count is preserved, so absolute line numbers stay valid for callers.
        let multiline = "a ?? String(\n  localized: \"k\",\n  defaultValue: \"v\")"
        #expect(SwiftSourceScanner.strippingLocalizingCalls(multiline)
            .components(separatedBy: "\n").count == multiline.components(separatedBy: "\n").count)
    }

    @Test("Copy classification separates copy from symbol names")
    func copyClassificationSelfChecks() {
        #expect(Self.looksLikeCopy("Do First"))
        #expect(Self.looksLikeCopy("No tasks today"))
        #expect(Self.looksLikeCopy("\(0) tasks today"))
        #expect(Self.looksLikeCopy("Every"))

        #expect(!Self.looksLikeCopy("calendar.badge.plus"))
        #expect(!Self.looksLikeCopy("arrow.up.circle.fill"))
        #expect(!Self.looksLikeCopy("#007AFF"))
        #expect(!Self.looksLikeCopy(""))
        #expect(!Self.looksLikeCopy(", "))
        #expect(!Self.looksLikeCopy("\\(a)-\\(b)"))
    }

    /// The first-argument walk must find the argument, not the whole call, and must not be fooled
    /// by delimiters inside literals.
    @Test("First-argument extraction is delimiter-safe")
    func firstArgumentSelfChecks() {
        let source = """
            Text("hello")
            Text(task.title)
            Text("a ) b", x: 1)
            Label(option.displayName, systemImage: "flag")
            attributedText(other)
            """
        let found = SwiftSourceScanner.firstArguments(
            ofCallsTo: ["Text(", "Label("], in: source, file: "f.swift")

        #expect(found.count == 4, "expected 4 calls, got \(found.count): \(found.map(\.asWritten))")
        #expect(found.map(\.line) == [1, 2, 3, 4])
        #expect(found[0].asWritten == "\"hello\"")
        #expect(found[1].asWritten == "task.title")
        // The `)` inside the literal must not end the argument.
        #expect(found[2].asWritten == "\"a ) b\"")
        #expect(found[3].asWritten == "option.displayName")
        // `attributedText(` must not match the `Text(` marker.
        #expect(!found.contains { $0.asWritten == "other" })
    }

    // MARK: - Helpers

    /// A `-> String` producer and the lines its body spans.
    struct StringProducer {
        let name: String
        let lines: Set<Int>
    }

    /// Every `var x: String { … }` / `func x(…) -> String { … }` in a file, with its body extent.
    static func stringProducers(in source: String) -> [StringProducer] {
        let redacted = SwiftSourceScanner.redactedForStructure(source)
        let lines = redacted.components(separatedBy: "\n")
        var producers: [StringProducer] = []

        for (index, line) in lines.enumerated() {
            guard let name = declaredStringProducerName(in: line) else { continue }

            var depth = 0
            var started = false
            var cursor = index
            var span: Set<Int> = []
            while cursor < lines.count {
                for character in lines[cursor] {
                    if character == "{" { depth += 1; started = true }
                    else if character == "}" { depth -= 1 }
                }
                span.insert(cursor + 1)
                if started && depth <= 0 { break }
                cursor += 1
            }
            producers.append(StringProducer(name: name, lines: span))
        }
        return producers
    }

    /// The declared name if this line opens a `String`-returning computed property or function.
    private static func declaredStringProducerName(in line: String) -> String? {
        let trimmed = line.trimmed()
        guard trimmed.hasSuffix("{") else { return nil }
        guard trimmed.contains("String") else { return nil }

        // `var name: String {` / `var name: String? {`
        if let varRange = trimmed.range(of: "var ") {
            let rest = trimmed[varRange.upperBound...]
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            let name = rest[rest.startIndex..<colon].trimmed()
            let type = rest[rest.index(after: colon)...].trimmed()
            guard type.hasPrefix("String") else { return nil }
            guard !name.isEmpty, !name.contains(" ") else { return nil }
            return name
        }
        // `func name(…) -> String {`
        if let funcRange = trimmed.range(of: "func "), trimmed.contains("-> String") {
            let rest = trimmed[funcRange.upperBound...]
            guard let paren = rest.firstIndex(of: "(") else { return nil }
            let name = rest[rest.startIndex..<paren].trimmed()
            guard !name.isEmpty, !name.contains(" ") else { return nil }
            return name
        }
        return nil
    }

    /// Whether line `index` sits inside an open call to `component`.
    static func isInsideCall(to component: String, at index: Int, lines: [String]) -> Bool {
        var cursor = index
        var lookback = 0
        while cursor >= 0, lookback < 12 {
            if lines[cursor].contains("\(component)(") { return true }
            // A closing paren at the start of a line ends the previous call.
            if cursor < index, lines[cursor].trimmed().hasPrefix(")") { return false }
            cursor -= 1
            lookback += 1
        }
        return false
    }

    static func isExempt(file: String, text: String) -> Bool {
        exemptions.contains { $0.file == file && (text == $0.text || text.contains($0.text)) }
    }

    static func isExemptProducer(file: String, producer: String) -> Bool {
        producerExemptions.contains { $0.file == file && $0.producer == producer }
    }
}

private extension StringProtocol {
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
