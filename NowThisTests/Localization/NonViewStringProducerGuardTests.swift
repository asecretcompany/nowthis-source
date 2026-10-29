import Foundation
import Testing

/// **The invisible half of the app.**
///
/// Everything the localization catalogs can see is a literal that reaches a localizing
/// construct. A literal that is `return`ed as a plain `String` — from a `LocalizedError`, from a
/// notification-body helper, from a Siri dialog builder — never enters a catalog. It compiles, it
/// renders, VoiceOver reads it, Siri speaks it, and it ships English in all five languages with
/// every catalog guard green, because from the catalog's point of view those strings do not exist.
///
/// `LocalizationBundleGuardTests` cannot catch this: it checks that the keys a catalog *has* reach
/// the device. `LocalizationKeyStyleGuardTests` cannot catch it either: it checks the shape of keys
/// that made it in. Only a source scan can see a string that was never offered to the catalog at
/// all.
///
/// This suite covers the **non-view** surface — sync errors, notifications, permissions, and App
/// Intents. The `String`-typed *view copy* surface (`Text(someString)` and friends) is a separate,
/// larger class with a different mechanism and gets its own guard.
@Suite("Localization / non-view String producers")
struct NonViewStringProducerGuardTests {

    // MARK: - The surface

    /// Directories whose files produce user-facing copy as plain `String` values rather than at a
    /// SwiftUI render site. Whole directories rather than a file list, so a new intent or service
    /// is covered the day it lands instead of the day someone remembers this file.
    static let surfaceDirectories = [
        "NowThis/Auth/",
        "NowThis/Calendar/",
        "NowThis/Intents/",
        "NowThis/Keychain/",
        "NowThis/Services/",
    ]

    /// `NowThis/Sync/` as a whole is the engine and the wire format; only its error type talks to
    /// the user.
    ///
    /// The two `Utilities/` files were added in §2d-ii, which is where the hole showed: neither
    /// this guard nor `ViewCopyGuardTests` looked at `NowThis/Utilities/`, so `RecurrenceRule`
    /// could hardcode `"Mon"`…`"Sun"` and `"Every 3 days"`, and `DueDateFormatter` could append
    /// `" · All day"` to a locale-formatted date, entirely unwatched.
    ///
    /// **The whole directory is not listed, and that is a scoping decision with a number behind
    /// it.** Pointing this guard at `NowThis/Utilities/` wholesale reports 78 literals, of which
    /// roughly sixty are RRULE tokens, HTTP headers, `@AppStorage` keys, regex patterns and the
    /// `NaturalLanguageParser` English keywords that a locked decision keeps English. Two more
    /// (`ErrorState.swift`'s `"Error"` and `"OK"`) are *correctly* localized SwiftUI literals that
    /// this guard flags only because it does not know `.alert(`/`Button(` — that file holds a
    /// `ViewModifier` and is already covered by `ViewCopyGuardTests`. Sixty rubber stamps to catch
    /// nothing is the instrument §2c rejected once already; the rest of the directory is Phase 3's
    /// job; the measurement behind that decision is recorded with the guard it produced.
    static let surfaceFiles_extra = [
        "NowThis/Sync/SyncErrors.swift",
        "NowThis/Utilities/RecurrenceRule.swift",
        "NowThis/Utilities/DueDateFormatter.swift",
    ]

    static func surfaceFiles() throws -> [String] {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        for file in surfaceFiles_extra where !FileManager.default.fileExists(
            atPath: root.appendingPathComponent(file).path) {
            throw LocalizationFixtureError.fileUnreadable(path: file, underlying: "moved or deleted")
        }
        let walked = try LocalizationCatalogFixture.swiftSourceFiles()
            .filter { file in surfaceDirectories.contains { file.hasPrefix($0) } }

        // Per-directory floor. An aggregate count cannot notice `NowThis/Auth/` disappearing
        // behind the twenty-odd files in `NowThis/Intents/`.
        for directory in surfaceDirectories {
            let count = walked.filter { $0.hasPrefix(directory) }.count
            guard count >= 2 else {
                throw LocalizationFixtureError.directoryWalkCouldNotStart(path: directory)
            }
        }
        return surfaceFiles_extra + walked
    }

    /// Sources compiled into **two** targets. Xcode extracts a separate key into each target's
    /// catalog, so a key from one of these must land in both or the widget ships English.
    static let sharedWithWidget: Set<String> = [
        "NowThis/Intents/CompleteTaskIntent.swift",
        "NowThis/Intents/WidgetConfigurationIntent.swift",
    ]

    // MARK: - Literal classification

    /// A literal is *copy* if, once interpolations are collapsed, it still contains a run of two
    /// or more letters. This is what lets `"⏰ \(task.title)"` through without an allowlist entry:
    /// there is no word in it to translate. It is deliberately generous — `"Due now"` and
    /// `"total"` both qualify — because a false positive costs one allowlist line and a false
    /// negative ships English to five languages.
    static func isCopy(_ literal: SwiftStringLiteral) -> Bool {
        var run = 0
        for character in literal.text {
            if character.isLetter {
                run += 1
                if run >= 2 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    /// Constructs that hand a literal to the extractor.
    ///
    /// `LocalizedStringResource` appears here bare rather than as a call because a computed
    /// property *typed* `-> LocalizedStringResource` extracts every literal it returns —
    /// `IntentError.localizedStringResource` is the live example, and its two strings are already
    /// in the catalog. Balancing from the marker covers the whole property body.
    ///
    /// The three bare argument labels at the end exist because `String(localized:` is often
    /// written wrapped — `String(\n    localized: "key",` — and a marker containing the paren
    /// cannot match across the newline. Each of those covers only its own line, which is exactly
    /// the line it labels.
    static let localizingMarkers = [
        "String(localized:",
        "LocalizedStringResource",
        "IntentDescription",
        "TypeDisplayRepresentation",
        "@Parameter(",
        "Summary(",
        "DisplayRepresentation(",
        "caseDisplayRepresentations",
        "AppShortcut(",
        "localized:",
        "defaultValue:",
        "comment:",
    ]

    /// Constructs whose strings are never shown to a person.
    static let notUserFacingMarkers = [
        "logger.",
        "Logger(",
        "userInfo",
        "forKey:",
        "setValue(",
        "httpMethod",
        "httpBody",
        "URL(string:",
        "Notification.Name(",
        // The MKCALENDAR request body: an XML document, in a multiline literal, with English
        // element names that are part of the CalDAV schema.
        "mkCalBody",
    ]

    /// A literal that is neither copy-to-translate nor covered by a marker. Every entry states
    /// why, and every entry is checked to still exist — an allowlist nobody prunes is a second
    /// place for bugs to hide.
    struct Exemption: Hashable {
        let file: String
        let text: String
        let reason: String
    }

    static let exemptions: [Exemption] = [
        Exemption(file: "NowThis/Services/ReminderReconciliationCoordinator.swift", text: "hourly",
                  reason: "Internal trigger tag hashed into the scheduling fingerprint; never displayed."),
        Exemption(file: "NowThis/Services/ReminderReconciliationCoordinator.swift", text: "nil",
                  reason: "Internal absent-badge tag hashed into the scheduling fingerprint; never displayed."),
        Exemption(file: "NowThis/Services/ReminderScheduler.swift", text: "system-notification-center",
                  reason: "Internal coordination-domain key sharing one OS mutation queue across model containers."),
        // ---- RFC-5545 wire tokens. `RecurrenceRule` serializes to and parses from RRULE, and
        //      every literal below is a protocol constant. Translating any of them corrupts the
        //      rule on the server for every other device reading the same calendar.
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "DAILY",
                  reason: "RRULE FREQ= value. Wire token, never displayed."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "WEEKLY",
                  reason: "RRULE FREQ= value. Wire token, never displayed."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "MONTHLY",
                  reason: "RRULE FREQ= value. Wire token, never displayed."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "YEARLY",
                  reason: "RRULE FREQ= value. Wire token, never displayed."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "MO",
                  reason: "RRULE BYDAY= value. Wire token, never displayed."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "TU",
                  reason: "RRULE BYDAY= value. Wire token, never displayed."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "WE",
                  reason: "RRULE BYDAY= value. Wire token, never displayed."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "TH",
                  reason: "RRULE BYDAY= value. Wire token, never displayed."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "FR",
                  reason: "RRULE BYDAY= value. Wire token, never displayed."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "SA",
                  reason: "RRULE BYDAY= value. Wire token, never displayed."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "SU",
                  reason: "RRULE BYDAY= value. Wire token, never displayed."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "FREQ",
                  reason: "RRULE property name matched while parsing."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "INTERVAL",
                  reason: "RRULE property name matched while parsing."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "BYDAY",
                  reason: "RRULE property name matched while parsing."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "COUNT",
                  reason: "RRULE property name matched while parsing."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "UNTIL",
                  reason: "RRULE property name matched while parsing."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "FREQ=\\(…)",
                  reason: "RRULE fragment emitted during serialization."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "INTERVAL=\\(…)",
                  reason: "RRULE fragment emitted during serialization."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "BYDAY=\\(…)",
                  reason: "RRULE fragment emitted during serialization."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "COUNT=\\(…)",
                  reason: "RRULE fragment emitted during serialization."),
        Exemption(file: "NowThis/Utilities/RecurrenceRule.swift", text: "UNTIL=\\(…)",
                  reason: "RRULE fragment emitted during serialization."),
        // ---- Time zone identifier, not a place name a reader sees.
        Exemption(file: "NowThis/Utilities/DueDateFormatter.swift", text: "UTC",
                  reason: "IANA time zone identifier. Date-only values are stored as midnight UTC and must be rendered in UTC to keep the stored day."),
        Exemption(file: "NowThis/Calendar/AppleCalendarSyncManager.swift", text: "NowThis",
                  reason: "The EventKit calendar's title. Product name — never translated, and it "
                        + "is also the lookup key used to find the calendar again."),
        Exemption(file: "NowThis/Calendar/AppleCalendarSyncManager.swift", text: "nowthis_calendar_id",
                  reason: "UserDefaults key."),
        Exemption(file: "NowThis/Services/GeofenceManager.swift", text: "geofence-\\(…)-\\(…)",
                  reason: "Notification request identifier."),
        Exemption(file: "NowThis/Services/ReminderScheduler.swift", text: "XCTestConfigurationFilePath",
                  reason: "Environment variable XCTest sets in a process it launched. Read, never displayed."),
        Exemption(file: "NowThis/Calendar/NextcloudCalendarSyncManager.swift", text: "nowthis-calendar",
                  reason: "Path slug in the CalDAV collection URL."),
        Exemption(file: "NowThis/Calendar/NextcloudCalendarSyncManager.swift",
                  text: "/remote.php/dav/calendars/\\(…)/\\(…)/",
                  reason: "Nextcloud's CalDAV URL layout."),
        Exemption(file: "NowThis/Calendar/NextcloudCalendarSyncManager.swift", text: "\\(…)-event",
                  reason: "Derived iCalendar UID."),
        Exemption(file: "NowThis/Calendar/NextcloudCalendarSyncManager.swift", text: "\\(…)\\(…).ics",
                  reason: "Resource path on the server."),
        Exemption(file: "NowThis/Auth/LoginFlowClient.swift", text: "NowThis/1.0 (iOS)",
                  reason: "HTTP User-Agent sent to Nextcloud."),
        Exemption(file: "NowThis/Auth/LoginFlowCoordinator.swift", text: "nowthis-auth",
                  reason: "Custom URL scheme the login callback arrives on."),
        Exemption(file: "NowThis/Keychain/AccountManager.swift", text: "#007AFF",
                  reason: "Default list colour, a hex literal."),
        Exemption(file: "NowThis/Services/TaskPhotoOriginals.swift",
                  text: "Application Support/TaskPhotoOriginals",
                  reason: "Private filesystem directory for locally cached photo originals."),
    ]

    // MARK: - The guard

    @Test("Every word-bearing literal on the non-view surface reaches the catalog")
    func nonViewCopyIsLocalized() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let allowed = Set(Self.exemptions.map { Exemption(file: $0.file, text: $0.text, reason: "") })
        var examined = 0
        var findings: [String] = []

        for file in try Self.surfaceFiles() {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let covered = SwiftSourceScanner.callCoveredLines(
                in: source, markers: Self.localizingMarkers + Self.notUserFacingMarkers)

            for literal in SwiftSourceScanner.stringLiterals(in: source, file: file)
            where Self.isCopy(literal) {
                examined += 1

                if allowed.contains(Exemption(file: file, text: literal.text, reason: "")) { continue }
                if covered.contains(literal.line) { continue }

                findings.append("  \(literal.location)  \(literal.text)")
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) user-facing string(s) are produced as plain Swift `String`s and never
            enter any string catalog. They will ship English in de, es, fr, it and nl:

            \(findings.joined(separator: "\n"))

            Wrap each in `String(localized:defaultValue:comment:)`, or `LocalizedStringResource`
            where the value crosses a target or actor boundary. If a literal is not copy — a
            UserDefaults key, a wire value, a product name — add it to `exemptions` with a reason.
            """)

        // Anti-vacuity. A scanner that examines zero literals reports success.
        #expect(examined >= 150, """
            Examined only \(examined) word-bearing literals across the surface; expected at least
            150. Either the scan stopped early or the surface list has gone stale.
            """)
    }

    @Test("Exemptions have not rotted")
    func exemptionsStillApply() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        for exemption in Self.exemptions {
            let source = try String(contentsOf: root.appendingPathComponent(exemption.file),
                                    encoding: .utf8)
            let present = SwiftSourceScanner.stringLiterals(in: source, file: exemption.file)
                .contains { $0.text == exemption.text }
            #expect(present, """
                Allowlist rot: \(exemption.file) no longer contains the literal "\(exemption.text)".
                Reason on file: \(exemption.reason)
                """)
        }
        #expect(Self.exemptions.count >= 5, "The allowlist emptied out — that is not a pass.")
    }

    // MARK: - Siri dialog

    /// `IntentDialogResult.dialog` was a `String`, laundered into Siri through
    /// `.result(dialog: "\(result.dialog)")`. That interpolation *does* extract — it extracts the
    /// key `"%@"`, one key for all seven intents, and not one Siri sentence reaches a catalog.
    @Test("IntentDialogResult carries a localized resource, not a String")
    func intentDialogIsLocalized() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("NowThis/Intents/IntentDialogResult.swift"),
            encoding: .utf8)

        #expect(source.contains("let dialog: LocalizedStringResource"), """
            IntentDialogResult.dialog is not a LocalizedStringResource. While it is a String, every
            Siri sentence in the app is invisible to the catalogs: `.result(dialog: "\\(dialog)")`
            extracts the single key "%@" and the sentence itself is never offered for translation.
            """)

        let laundered = try Self.surfaceFiles()
            .filter { $0.hasPrefix("NowThis/Intents/") }
            .filter { file in
                guard let text = try? String(contentsOf: root.appendingPathComponent(file),
                                             encoding: .utf8) else { return false }
                // Redacted, so the description of the defect in IntentDialogResult's own doc
                // comment does not read as an instance of it.
                let code = SwiftSourceScanner.redactedForStructure(text)
                return code.contains("dialog: \"")
            }
        #expect(laundered.isEmpty, """
            \(laundered.count) intent(s) still launder the dialog through a string interpolation:
            \(laundered.joined(separator: "\n"))
            Use `IntentDialog(result.dialog)` so the already-localized resource is passed through
            instead of being re-wrapped in a fresh "%@" key.
            """)
    }

    /// A sentence assembled from fragments cannot be translated. `TaskCountIntent` built
    /// *"You have 3 active tasks "* + *"in Work"* / *"total"*; German needs *insgesamt* in a
    /// different position and has no fragment to put it in. Two complete templates, not one
    /// template and a tail.
    @Test("Every Siri dialog template is a complete sentence")
    func siriDialogsAreCompleteSentences() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var examined = 0
        var findings: [String] = []

        for file in try Self.surfaceFiles() where file.hasPrefix("NowThis/Intents/") {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let literals = SwiftSourceScanner.stringLiterals(in: source, file: file)

            // Pair each `intent.dialog.*` key with the `defaultValue:` literal that follows it.
            for (index, literal) in literals.enumerated()
            where literal.text.hasPrefix("intent.dialog.") {
                examined += 1
                guard index + 1 < literals.count else {
                    findings.append("  \(literal.location)  \(literal.text) — no defaultValue follows")
                    continue
                }
                let value = literals[index + 1].text
                let terminator = value.last
                if terminator != "." && terminator != "!" && terminator != "?" {
                    findings.append("  \(literal.location)  \(literal.text) → \"\(value)\"")
                }
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) Siri dialog template(s) are sentence fragments rather than complete
            sentences:

            \(findings.joined(separator: "\n"))

            A fragment forces the translator to guess where it will be spliced, and word order
            differs by language. Write one complete sentence per branch.
            """)

        #expect(examined >= 10, """
            Found only \(examined) `intent.dialog.*` keys; expected at least 10 across the seven
            intents that speak to the user.
            """)
    }

    /// `DisplayRepresentation(title:)` takes a `LocalizedStringResource`, so interpolating a
    /// `String` into it does not merely produce a bad key — every such site in the app collapses
    /// into the *same* key, `"%@"`, and translating it translates all of them at once.
    @Test("DisplayRepresentation never interpolates user data into a catalog key")
    func displayRepresentationsDoNotShareOneKey() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var examined = 0
        var findings: [String] = []

        for file in try LocalizationCatalogFixture.swiftSourceFiles() {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            guard source.contains("DisplayRepresentation(") else { continue }
            let covered = SwiftSourceScanner.callCoveredLines(
                in: source, markers: ["DisplayRepresentation("])

            for literal in SwiftSourceScanner.stringLiterals(in: source, file: file) {
                guard covered.contains(literal.line) else { continue }
                examined += 1
                // A literal that is *nothing but* an interpolation carries no copy — it exists
                // only to satisfy the type, and it mints the shared "%@" key.
                if literal.text == "\\(…)" {
                    findings.append("  \(literal.location)")
                }
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) DisplayRepresentation site(s) interpolate a plain String, minting the
            shared catalog key "%@":

            \(findings.joined(separator: "\n"))

            Where the whole value is user data, `LocalizedStringResource(stringLiteral: value)`
            creates no catalog key at all — which is correct, because a task title is not copy.
            """)

        #expect(examined >= 4, """
            Examined only \(examined) DisplayRepresentation literals; expected at least 4.
            """)
    }

    // MARK: - Extraction actually happened

    /// The end-to-end proof. Every explicit key written into the surface must be a key in the app
    /// catalog — which is only true if the build extracted it and the catalogs were re-synced.
    /// Without this, the whole file above proves only that the *source* looks right.
    @Test("Every explicit key on the surface reached its catalogs")
    func explicitKeysReachedTheCatalogs() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        guard let app = LocalizationCatalogFixture.catalogs
            .first(where: { $0.path == "NowThis/Localizable.xcstrings" }),
              let widget = LocalizationCatalogFixture.catalogs
            .first(where: { $0.path == "NowThisWidget/Localizable.xcstrings" }) else {
            throw LocalizationFixtureError.fileUnreadable(path: "catalog list",
                                                          underlying: "expected catalogs missing")
        }
        let appKeys = Set(try LocalizationCatalogFixture.load(app).keys)
        let widgetKeys = Set(try LocalizationCatalogFixture.load(widget).keys)

        var examined = 0
        var missing: [String] = []

        for file in try Self.surfaceFiles() {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            // Only literals inside a localizing call are keys. `Logger(subsystem: "com.nowthis")`
            // has the shape of one and is not.
            //
            // The bare `localized:` marker is load-bearing and was missing at first: this file's
            // own falsification pass renamed `sync.error.noAccount` in source and the test stayed
            // **green**, because `SyncErrors.swift` writes the call wrapped —
            // `String(\n    localized: "…"` — and `String(localized:` cannot match across the
            // newline. Every key in five of the surface's files was invisible to the one test
            // that proves extraction happened.
            let covered = SwiftSourceScanner.callCoveredLines(
                in: source,
                markers: ["String(localized:", "LocalizedStringResource(", "localized:"])

            for literal in SwiftSourceScanner.stringLiterals(in: source, file: file)
            where covered.contains(literal.line) && Self.isExplicitKey(literal.text) {
                examined += 1
                if !appKeys.contains(literal.text) {
                    missing.append("  \(literal.location)  \(literal.text) — not in \(app.name)")
                }
                if Self.sharedWithWidget.contains(file), !widgetKeys.contains(literal.text) {
                    missing.append("  \(literal.location)  \(literal.text) — not in \(widget.name)")
                }
            }
        }

        #expect(missing.isEmpty, """
            \(missing.count) explicit key(s) written in source never reached a catalog:

            \(missing.joined(separator: "\n"))

            Build, then run `python3 Translations/tools/sync_catalogs.py --apply`. A key that is
            in the source and not in the catalog is a string nobody can translate.
            """)

        // 66 explicit keys were written across this surface in the commit that added the guard.
        // The floor is deliberately close to that number: it is the assertion that caught the
        // wrapped-call blind spot described above, where the count silently sat at 40.
        #expect(examined >= 60, """
            Found only \(examined) explicit keys across the surface; expected at least 60.
            A sudden drop means the scan stopped seeing a file, not that keys were deleted.
            """)
    }

    /// Matches this repo's key convention: dotted, lowercase-initial, no spaces. Distinguishes a
    /// key from the English `defaultValue` that sits beside it.
    static func isExplicitKey(_ text: String) -> Bool {
        guard text.contains("."), !text.contains(" "), !text.contains("\\(") else { return false }
        guard let first = text.first, first.isLowercase else { return false }
        guard !text.hasSuffix(".") else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." }
    }

    // MARK: - Self-checks

    /// The classifier decides what the guard even looks at, so it is tested directly rather than
    /// trusted.
    @Test("Scanner self-checks")
    func selfChecks() {
        func literal(_ text: String) -> SwiftStringLiteral {
            SwiftStringLiteral(file: "<test>", line: 1, text: text, isMultiline: false, poundCount: 0)
        }

        #expect(Self.isCopy(literal("Now overdue")))
        #expect(Self.isCopy(literal("total")))
        #expect(Self.isCopy(literal("in \\(…)")), "A fragment with a word is still copy.")
        #expect(!Self.isCopy(literal("⏰ \\(…)")), "Emoji plus user data has nothing to translate.")
        #expect(!Self.isCopy(literal("%@")))
        #expect(!Self.isCopy(literal(", ")))
        #expect(!Self.isCopy(literal("")))
        #expect(!Self.isCopy(literal("a b c")), "Single letters are not a word.")

        #expect(Self.isExplicitKey("sync.error.noAccount"))
        #expect(Self.isExplicitKey("intent.dialog.taskCount.total"))
        #expect(!Self.isExplicitKey("No account configured for sync."), "English is not a key.")
        #expect(!Self.isExplicitKey("Server error (%lld). Please try again later."))
        #expect(!Self.isExplicitKey("NowThis"), "No dot — not a key.")
        // `com.nowthis` is shape-indistinguishable from a key, which is exactly why the catalog
        // check looks only inside localizing calls rather than at shape alone.
        #expect(Self.isExplicitKey("com.nowthis"))
    }

    /// The coverage scanner decides which literals are even looked at, so its two failure modes —
    /// covering too little (false alarms) and covering too much (silence) — are both pinned.
    @Test("Call-coverage self-checks")
    func callCoverageSelfChecks() {
        let source = """
            let a = String(localized: "k.one",
                           defaultValue: "Due now",
                           comment: "A reminder body.")
            let b = "Not localized at all"
            let c = Logger(subsystem: "com.nowthis", category: "reminders")
            var d: LocalizedStringResource {
                switch self {
                case .x: return "Task not found."
                }
            }
            """
        let covered = SwiftSourceScanner.callCoveredLines(
            in: source, markers: ["String(localized:", "Logger(", "LocalizedStringResource"])

        #expect(covered.contains(1))
        #expect(covered.contains(2), "A wrapped call's defaultValue must be inside the call.")
        #expect(covered.contains(3), "…and so must its comment.")
        #expect(!covered.contains(4), """
            Line 4 is a bare literal one line after a localized one. A fixed-window scanner passes
            it; that is the hole balancing the delimiter exists to close.
            """)
        #expect(covered.contains(5))
        #expect(covered.contains(8), "A property typed -> LocalizedStringResource extracts its returns.")

        // Parentheses inside comments and strings must not be counted.
        let tricky = """
            let a = String(localized: "k.two", defaultValue: "A close paren ) in a string")
            let b = "Still not localized"
            """
        let trickyCovered = SwiftSourceScanner.callCoveredLines(
            in: tricky, markers: ["String(localized:"])
        #expect(trickyCovered.contains(1))
        #expect(!trickyCovered.contains(2), """
            A `)` inside a string literal closed the call early. Redaction is not working.
            """)
    }
}
