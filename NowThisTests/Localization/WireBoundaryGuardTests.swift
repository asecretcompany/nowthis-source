import Foundation
import Testing
@testable import NowThis

/// The boundary between text a reader sees and text a **server** reads.
///
/// This is the risk NowThis has and a podcast player does not. A localized string here does not
/// render wrong — it is written into a VTODO, uploaded over CalDAV, and read back by every other
/// device on that account, including devices in other languages. `STATUS:ERLEDIGT` is not a
/// translation defect; it is a corrupt task on someone else's iPad.
///
/// Two shapes, because one rule does not fit both:
///
/// - **A blanket ban** on the files that exist only to talk to the server. They have no reader-
///   facing text at all, so any localization or locale API in them is wrong by construction and
///   needs no case-by-case judgement.
/// - **A per-file record** for the files that legitimately do both. `SyncEngine` and
///   `AccountManager` create task lists whose names a reader sees *and* a server stores.
///   Each names the exact symbols it may localize and why, and a symbol that is no longer
///   there fails the rot check.
///
/// > The plan put `RecurrenceRule.swift` in the blanket-ban set, and Phase 2d-ii made that
/// > impossible by moving nine display strings into the catalog from that file. The widget fix
/// > took the third option: `RecurrenceRule.swift` now parses `FREQ=WEEKLY;BYDAY=MO,FR` and
/// > nothing else, while `RecurrenceRule+DisplayText.swift` renders "Every 2 weeks on Mon, Fri".
/// > Both are recorded — the display half with its nine keys and the reason each is safe, the
/// > wire half with an **empty** record, which says the stronger thing the plan wanted: not one
/// > localized string, and adding one fails here. The split itself was forced by a build target
/// > (`NowThisWidget` compiles the wire half), so the boundary is now load-bearing twice over.
///
/// `TaskStatus`'s four RFC-5545 raw values are pinned by
/// ``EnumDisplayNameGuardTests/persistedRawValuesAreFrozen`` and deliberately not repeated here.
@Suite("Localization / wire boundary")
struct WireBoundaryGuardTests {

    // MARK: - The blanket ban

    /// Files whose entire job is the wire. Each is asserted to exist, so a rename cannot quietly
    /// drop a file out of the ban.
    static let wireCriticalFiles = [
        "NowThis/Parser/ICalendarSerializer.swift",
        "NowThis/Parser/ICalendarParser.swift",
        "NowThis/Parser/DAVXMLParser.swift",
        "NowThis/Sync/VEventSerializer.swift",
        "NowThis/Sync/VJournalSerializer.swift",
        "NowThis/Sync/CalDAVClient.swift",
        "NowThis/Watch/WatchPayloads.swift",
        "NowThis/App/AppConstants.swift",
    ]

    struct BannedToken {
        let token: String
        let why: String
    }

    /// Four ways the reader's locale reaches the wire. The last three are not localization APIs
    /// at all, which is the point — the `en_US_POSIX` guard sees none of them, and neither does
    /// any catalog check.
    static let bannedTokens: [BannedToken] = [
        .init(token: "String(localized:",
              why: "the value would be the reader's language, and it is about to be uploaded"),
        .init(token: "NSLocalizedString(",
              why: "same, in the older spelling"),
        .init(token: "LocalizedStringResource",
              why: "same, deferred — it resolves in whatever language reads it"),
        .init(token: "LocalizedStringKey",
              why: "same, and it also means a SwiftUI view is being built in a serializer"),
        .init(token: "Locale.current",
              why: "number and date formatting on the wire must be invariant; this is how a "
                  + "German decimal comma reaches an ICS property"),
        .init(token: "Calendar.current",
              why: "the region calendar. Extracting components with it and reconstructing with a "
                  + "Gregorian UTC calendar is what wrote DUE;VALUE=DATE:25690724 to a server "
                  + "(Phase 2f) — no DateFormatter is involved, so no formatter guard sees it"),
        .init(token: ".formatted(",
              why: "Foundation's locale-aware formatting. Reads correctly on screen and produces "
                  + "an unparseable ICS value"),
    ]

    struct RecordedException {
        let file: String
        let token: String
        let reason: String
    }

    /// The one place a banned token is allowed inside a wire-critical file.
    static let recordedExceptions: [RecordedException] = [
        .init(file: "NowThis/Sync/VEventSerializer.swift", token: "Calendar.current",
              reason: "`date(byAdding: .minute, value: 30, to: startDate)` for the default event "
                  + "duration. Minute arithmetic is identical under every calendar identity — "
                  + "only era and year numbering differ — and the time zone SHOULD be the "
                  + "reader's, because the event's half-hour is a half-hour where they are. "
                  + "Nothing is extracted or reconstructed here, so §2f's rule does not apply."),
    ]

    // MARK: - The per-file record

    struct LocalizingFile {
        let file: String
        /// Catalog key → why localizing it is safe on this side of the boundary.
        let keys: [String: String]
    }

    /// Files that talk to the wire *and* to the reader, each with the exact set it may localize.
    ///
    /// The `Inbox` / `Tasks` entries record a **decision, not an oversight**: a German device
    /// creates a collection called *Posteingang* on a server an English device also reads.
    /// Identity matching is by `serverURL == href`, never by name, so nothing breaks — but the
    /// name a second device sees is whatever the first device's language produced. That is the
    /// cross-device leak the plan asked to have written down rather than left to happen.
    static let filesThatMayLocalize: [LocalizingFile] = [
        .init(file: "NowThis/Sync/SyncEngine.swift", keys: [
            "Tasks": "Fallback display name for a discovered CalDAV collection that reports no "
                + "display name of its own. Written into TaskList.name and pushed as the "
                + "collection's display name — recorded cross-device leak, see above.",
        ]),
        .init(file: "NowThis/Keychain/AccountManager.swift", keys: [
            "Inbox": "Name of the default list created with a new account. Same leak, same "
                + "reason it is acceptable: identity is the server URL.",
            "Recovered": "Display name of the vault that rescues never-synced tasks when an "
                + "account is removed. The list itself is found by a stable marker, never by "
                + "this name — LocalizationLogicCouplingTests pins that.",
        ]),
        .init(file: "NowThis/Utilities/RecurrenceRule.swift", keys: [:]),
        .init(file: "NowThis/Utilities/RecurrenceRule+DisplayText.swift", keys: [
            "recurrence.frequency.daily": "Display only. `Frequency.rawValue` is the RFC-5545 "
                + "`FREQ=` token and is frozen below.",
            "recurrence.frequency.weekly": "Display only; rawValue frozen below.",
            "recurrence.frequency.monthly": "Display only; rawValue frozen below.",
            "recurrence.frequency.yearly": "Display only; rawValue frozen below.",
            "recurrence.custom.interval.daily": "Plural template for the custom-interval stepper. "
                + "German inflects the unit with the numeral (jeden Tag / alle 2 Tage), so the "
                + "number and the unit cannot be separate strings.",
            "recurrence.custom.interval.weekly": "Same, weeks.",
            "recurrence.custom.interval.monthly": "Same, months.",
            "recurrence.custom.interval.yearly": "Same, years.",
            "recurrence.displayText.onDays": "Joins the frequency phrase to the weekday list. The "
                + "weekday names come from `Calendar.shortWeekdaySymbols`, not from a catalog — "
                + "resolved by deletion in Phase 2d.",
        ]),
    ]

    // MARK: - Scanning

    /// Catalog keys localized in a file: the first string literal of each `String(localized:`
    /// call, plus a sentinel for any other localizing construct.
    ///
    /// Reads **comment-stripped source with literals intact**. Not the raw source — the ban
    /// tokens appear in prose here (`RecurrenceRule`'s own doc comment says *"must never be
    /// localized"*), and a scanner that reads comments finds the words it is looking for in the
    /// sentence explaining why they must not appear. That is not hypothetical: it is issues-log
    /// L35 and L40, twice, in two different guards.
    static func localizedKeys(in source: String) -> [String] {
        let code = SwiftSourceScanner.strippingComments(source)
        var keys: [String] = []
        var search = code.startIndex

        while let call = code.range(of: "String(localized:", range: search..<code.endIndex) {
            search = call.upperBound
            guard let open = code[call.upperBound...].firstIndex(of: "\"") else {
                keys.append("<no literal>")
                continue
            }
            let after = code.index(after: open)
            guard let close = code[after...].firstIndex(of: "\"") else {
                keys.append("<unterminated>")
                continue
            }
            keys.append(String(code[after..<close]))
            search = code.index(after: close)
        }

        for other in ["NSLocalizedString(", "LocalizedStringResource", "LocalizedStringKey"]
        where code.contains(other) {
            keys.append("<\(other)>")
        }
        return keys
    }

    // MARK: - 1. The ban

    @Test("No wire-critical file touches localization or the reader's locale")
    func wireCriticalFilesAreLocaleFree() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var filesExamined = 0
        var tokensChecked = 0
        var findings: [String] = []
        var exceptionsSeen: Set<String> = []

        for file in Self.wireCriticalFiles {
            let url = root.appendingPathComponent(file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                findings.append("  \(file): unreadable — a wire-critical file that cannot be "
                                + "scanned is not a file with no findings")
                continue
            }
            filesExamined += 1
            // Literals blanked as well as comments: an error message or an XML tag could contain
            // one of these tokens as text, and flagging that would teach the next person to
            // shorten the token list.
            let code = SwiftSourceScanner.redactedForStructure(source)
            let lines = code.split(separator: "\n", omittingEmptySubsequences: false)

            for banned in Self.bannedTokens {
                tokensChecked += 1
                for (offset, line) in lines.enumerated() where line.contains(banned.token) {
                    let key = "\(file)|\(banned.token)"
                    if Self.recordedExceptions.contains(where: {
                        $0.file == file && $0.token == banned.token
                    }) {
                        exceptionsSeen.insert(key)
                        continue
                    }
                    findings.append("  \(file):\(offset + 1)  \(banned.token)\n      \(banned.why)")
                }
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) locale-dependent call(s) in files whose only job is the wire:
            \(findings.sorted().joined(separator: "\n"))

            Whatever these produce is uploaded and read back by every other device on the account,
            in whatever language that device is in. This is not a rendering bug — it is a corrupt
            task on someone else's iPad, and no amount of re-translation fixes it after the fact.

            If the call is genuinely safe, add a RecordedException naming the file, the token and
            the reason. Do not shorten the token list.
            """)

        let unusedExceptions = Set(Self.recordedExceptions.map { "\($0.file)|\($0.token)" })
            .subtracting(exceptionsSeen)
        #expect(unusedExceptions.isEmpty, """
            \(unusedExceptions.count) recorded exception(s) no longer describe anything present:
            \(unusedExceptions.sorted().map { "  \($0)" }.joined(separator: "\n"))

            The call has gone. Delete the exception — an exception nobody can trace to a line of
            code is a hole with a paragraph of justification attached.
            """)

        #expect(filesExamined == Self.wireCriticalFiles.count, """
            \(filesExamined) of \(Self.wireCriticalFiles.count) wire-critical files were read. A
            renamed file must fail here, not silently leave the ban.
            """)
        let expectedPairs = Self.wireCriticalFiles.count * Self.bannedTokens.count
        #expect(tokensChecked == expectedPairs,
                "\(tokensChecked) file/token pairs checked; expected \(expectedPairs).")
    }

    // MARK: - 2. The record

    @Test("The files on the wire boundary localize only what is recorded")
    func localizingFilesStayWithinTheirRecord() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var callsExamined = 0
        var findings: [String] = []

        for subject in Self.filesThatMayLocalize {
            let url = root.appendingPathComponent(subject.file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                findings.append("  \(subject.file): unreadable")
                continue
            }
            let found = Self.localizedKeys(in: source)
            callsExamined += found.count

            for key in Set(found) where subject.keys[key] == nil {
                findings.append("  \(subject.file)  \u{201C}\(key)\u{201D} is localized here and "
                                + "is not in the record")
            }
            for (key, reason) in subject.keys where !found.contains(key) {
                findings.append("  \(subject.file)  \u{201C}\(key)\u{201D} is recorded but no "
                                + "longer localized here.\n      Recorded reason: \(reason)")
            }
        }

        #expect(findings.isEmpty, """
            \(findings.count) discrepanc(y/ies) between what these files localize and what is
            recorded:
            \(findings.sorted().joined(separator: "\n"))

            These three files sit on both sides of the boundary. A new localized string in one of
            them is not wrong — it needs a line saying why it is safe, which is the same review a
            human would do and the only thing standing between "display name" and "wire value".
            """)
        // Measured 2026-07-26: 2 in SyncEngine, 2 in AccountManager, 9 in RecurrenceRule.
        // 2026-09-21: the nine moved to RecurrenceRule+DisplayText.swift when the wire half was
        // shared into NowThisWidget. Same nine keys, same total, one file further from the wire.
        #expect(callsExamined >= 13, """
            Only \(callsExamined) localizing calls were found across these files; there were
            13 when this was written. The key extractor has stopped matching.
            """)
    }

    // MARK: - 3. Frozen constants

    @Test("Wire constants are frozen")
    func wireConstantsAreFrozen() {
        // Changing either of these orphans every existing install's data.
        #expect(AppConstants.appGroupID == "group.com.asecretcompany.nowthis")
        #expect(AppConstants.keychainService == "com.asecretcompany.nowthis.caldav")
        #expect(AppConstants.proProductID == "com.asecretcompany.nowthis.pro")

        // RFC-5545 §3.7.3/§3.7.4.
        //
        // Recorded rather than tidied: `AppConstants.prodID` and `iCalVersion` have **zero
        // callers**. All three serializers hardcode their own, and two different PRODIDs ship —
        // `-//NowThis//iOS//EN` from VEventSerializer, `-//NowThis//NowThis iOS//EN` from
        // ICalendarSerializer and VJournalSerializer. PRODID is informational, so this is
        // untidiness rather than a defect, and pinning what actually ships is the job here.
        #expect(AppConstants.prodID == "-//NowThis//iOS//EN")
        #expect(AppConstants.iCalVersion == "2.0")

        // Every notification prefix that can be scheduled must also be swept — the invariant
        // behind the "Repeat Hourly Until Done" fix.
        #expect(NotificationIdentifiers.allPrefixes == ["reminder-", "overdue-", "nag-"])

        // RFC-5545 §3.3.10. These go into `RRULE:` and come back out of every other client.
        #expect(RecurrenceRule.Frequency.allCases.map(\.rawValue)
                == ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"])
        #expect(RecurrenceRule.Weekday.allCases.map(\.rawValue)
                == ["MO", "TU", "WE", "TH", "FR", "SA", "SU"])
    }

    @Test("A recurrence rule round-trips through its wire tokens, not its words")
    func recurrenceRoundTripsThroughWireTokens() throws {
        let rule = RecurrenceRule(frequency: .weekly, interval: 2,
                                  byDay: [.monday, .friday], count: 10, until: nil)
        let wire = rule.toRRULEString()
        #expect(wire == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR;COUNT=10", """
            The generated RRULE is \u{201C}\(wire)\u{201D}. Every token in it is read by other
            CalDAV clients; none of it is text for a reader.
            """)

        let parsed = try #require(RecurrenceRule.parse(wire))
        #expect(parsed.frequency == .weekly)
        #expect(parsed.interval == 2)
        #expect(parsed.byDay.map(\.rawValue) == ["MO", "FR"])
        #expect(parsed.count == 10)

        // The display side is allowed to be anything the reader's language needs, and must not
        // leak back into the wire side.
        #expect(!rule.displayText.contains("FREQ"))
        #expect(!rule.displayText.contains("BYDAY"))
    }

    @Test("A serialized VTODO carries only wire vocabulary")
    func serializedVTODOIsWireVocabulary() {
        let ics = ICalendarSerializer.serialize(
            uid: "wire-guard-1", summary: "Buy milk", status: "COMPLETED",
            categories: ["errands"], recurrenceRule: "FREQ=DAILY")

        for expected in ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//NowThis//NowThis iOS//EN",
                         "BEGIN:VTODO", "UID:wire-guard-1", "SUMMARY:Buy milk",
                         "STATUS:COMPLETED", "RRULE:FREQ=DAILY", "END:VTODO", "END:VCALENDAR"] {
            let present = ics.contains(expected)
            #expect(present, """
                The serialized VTODO does not contain \u{201C}\(expected)\u{201D}.
                Every property name and enumerated value in an ICS file is protocol vocabulary,
                fixed by RFC-5545 and read by every other client on the account.
                """)
        }
    }

    // MARK: - 4. Self-checks

    @Test("The wire scanner reads code, not prose and not string contents")
    func scannerSelfChecks() {
        // A doc comment saying the token must not appear must not itself be a finding. This is
        // the exact shape that made two earlier guards report green on a planted defect and red
        // on their own explanation.
        let prose = """
            /// `rawValue` is the RFC-5545 `FREQ=` token and must never reach String(localized:.
            /// Do not use Calendar.current here.
            let x = 1
            """
        let redacted = SwiftSourceScanner.redactedForStructure(prose)
        #expect(!redacted.contains("String(localized:"))
        #expect(!redacted.contains("Calendar.current"))
        #expect(redacted.contains("let x = 1"))

        // A literal that happens to contain a banned token is not a call.
        let literal = #"let message = "Locale.current is not used here""#
        #expect(!SwiftSourceScanner.redactedForStructure(literal).contains("Locale.current"))

        // …but the call itself survives redaction, quotes and all.
        let call = #"let n = Calendar.current.component(.day, from: d)"#
        #expect(SwiftSourceScanner.redactedForStructure(call).contains("Calendar.current"))

        // Key extraction: comment-stripped, literals intact.
        let source = """
            // String(localized: "commented.out")
            let a = String(localized: "real.key", defaultValue: "Real", comment: "why")
            let b = String(localized: "second.key")
            """
        #expect(Self.localizedKeys(in: source) == ["real.key", "second.key"])

        // Any other localizing construct is reported rather than silently skipped, because it
        // carries no key this scanner can name.
        #expect(Self.localizedKeys(in: "let t: LocalizedStringResource = \"Add\"")
                == ["<LocalizedStringResource>"])
        #expect(Self.localizedKeys(in: "let x = 1").isEmpty)
    }
}
