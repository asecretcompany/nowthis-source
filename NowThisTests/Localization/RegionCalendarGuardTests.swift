import Foundation
import Testing
@testable import NowThis

/// **Localization changes the calendar, not just the words.**
///
/// Settings → General → Language & Region lets any user pick a *region calendar* — Japanese,
/// Buddhist, Hebrew, Islamic — independently of language. `Calendar.current` is that calendar.
/// Its day boundaries agree with the Gregorian one; its **year numbering does not**. 2026 CE is
/// Reiwa 8 and Buddhist Era 2569.
///
/// `DueDateHelper` stores date-only (`VALUE=DATE`) due dates as midnight UTC and converts between
/// that and the user's local day by pulling `[.year, .month, .day]` out of one calendar and
/// pushing them into another. Extract Gregorian, reconstruct in Buddhist, and the year 2026 is
/// read as BE 2026 — 543 years off. Nothing here involves a `DateFormatter`, so the
/// `en_US_POSIX` guard sees none of it, and no catalog guard can: there is no string.
///
/// The rule these tests pin: **component extraction and component reconstruction must use the
/// same calendar identity.** Anything crossing the UTC/local boundary uses
/// `Calendar(identifier: .gregorian)` on both sides, and takes only the *time zone* from the
/// user's region.
@Suite("Localization / region calendar independence")
struct RegionCalendarGuardTests {

    /// The four selectable region calendars whose era or year numbering differs from Gregorian.
    /// Each is a real option in iOS Settings, not a hypothetical.
    static func regionCalendars() -> [(name: String, calendar: Calendar)] {
        let identifiers: [(String, Calendar.Identifier)] = [
            ("gregorian", .gregorian),
            ("buddhist", .buddhist),
            ("japanese", .japanese),
            ("hebrew", .hebrew),
            ("islamicUmmAlQura", .islamicUmmAlQura),
        ]
        return identifiers.map { name, identifier in
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            return (name, calendar)
        }
    }

    /// Midnight UTC on 24 July 2026 — the shape every date-only due date is stored in.
    static var storedDateOnlyValue: Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: 2026, month: 7, day: 24))!
    }

    // MARK: - The one that reaches the server

    @Test("An all-day due date serializes to the same DATE value under every region calendar")
    func dateOnlyValueDoesNotCarryTheRegionEra() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let localNoon = pacific.date(from: DateComponents(year: 2026, month: 7, day: 24, hour: 12))!

        var findings: [String] = []
        var examined = 0

        for (name, calendar) in Self.regionCalendars() {
            examined += 1
            let value = DueDateHelper.dateOnlyValue(for: localNoon, calendar: calendar)
            let serialized = ICalendarSerializer.formatDateOnly(value)
            if serialized != "20260724" {
                findings.append("  \(name): DUE;VALUE=DATE:\(serialized)")
            }
        }

        #expect(examined == 5, "only \(examined) region calendars examined")
        #expect(findings.isEmpty, """
            \(findings.count) region calendar(s) write a corrupted DATE value to the server:
            \(findings.joined(separator: "\n"))

            This is the danger this whole project is about, realised with dates rather than
            strings: the value goes over CalDAV and every other device reading the calendar gets
            it. Extraction and reconstruction must use the same calendar identity — take the time
            zone from the user's region, never the era.
            """)
    }

    // MARK: - The ones that make tasks disappear

    @Test("`isOnDay` matches the same day under every region calendar")
    func isOnDayDoesNotDependOnTheRegionCalendar() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let july24Local = pacific.date(from: DateComponents(year: 2026, month: 7, day: 24, hour: 9))!

        var findings: [String] = []
        var examined = 0

        for (name, calendar) in Self.regionCalendars() {
            examined += 1
            let matched = DueDateHelper.isOnDay(Self.storedDateOnlyValue, isDateOnly: true,
                                                sameAs: july24Local, regionCalendar: calendar)
            if !matched { findings.append("  \(name): the task does not fall on its own day") }
        }

        #expect(examined == 5, "only \(examined) region calendars examined")
        #expect(findings.isEmpty, """
            \(findings.count) region calendar(s) fail to match a date-only task to its own day:
            \(findings.joined(separator: "\n"))

            `isOnDay` drives Today, Upcoming, the month grid, the week grid and the day detail
            list. When it returns false for every day, every all-day task vanishes from the app
            with no error anywhere.
            """)
    }

    @Test("`effectiveDeadline` and `localStartOfDay` land on the same instant under every region calendar")
    func deadlineDoesNotDependOnTheRegionCalendar() {
        var findings: [String] = []
        var examined = 0

        let gregorian = Self.regionCalendars().first { $0.name == "gregorian" }!.calendar
        let baselineDeadline = DueDateHelper.effectiveDeadline(
            for: Self.storedDateOnlyValue, isDateOnly: true, regionCalendar: gregorian)
        let baselineStart = DueDateHelper.localStartOfDay(
            for: Self.storedDateOnlyValue, isDateOnly: true, regionCalendar: gregorian)

        for (name, calendar) in Self.regionCalendars() where name != "gregorian" {
            examined += 1
            let deadline = DueDateHelper.effectiveDeadline(
                for: Self.storedDateOnlyValue, isDateOnly: true, regionCalendar: calendar)
            let start = DueDateHelper.localStartOfDay(
                for: Self.storedDateOnlyValue, isDateOnly: true, regionCalendar: calendar)
            if deadline != baselineDeadline {
                findings.append("  \(name): effectiveDeadline \(deadline) != \(baselineDeadline)")
            }
            if start != baselineStart {
                findings.append("  \(name): localStartOfDay \(start) != \(baselineStart)")
            }
        }

        #expect(examined == 4, "only \(examined) non-Gregorian region calendars examined")
        #expect(findings.isEmpty, """
            \(findings.count) disagreement(s) between region calendars:
            \(findings.joined(separator: "\n"))

            `effectiveDeadline` decides overdue and drives the app badge; `localStartOfDay` is the
            anchor for all-day reminder fire times. A reader whose region calendar is not Gregorian
            would get both at the wrong instant — by centuries, not hours.
            """)
    }

    // MARK: - The grid that was already wrong in en-GB

    /// The month grid's header row and its day cells must agree on which column a date sits in.
    ///
    /// Asserted as the **invariant** rather than as "the symbols are rotated": the two are
    /// computed by different code and the bug was that they disagreed. This checks the thing that
    /// matters — that the header above a date is that date's own weekday name.
    @Test("The month grid's weekday headers line up with its day cells in every region")
    @MainActor
    func weekdayHeadersMatchTheDayGrid() {
        var findings: [String] = []
        var examined = 0

        // en-GB is in the list deliberately: `firstWeekday == 2` there too, so this was wrong for
        // English readers before a single word was translated.
        for identifier in ["en_US", "en_GB", "de_DE", "es_ES", "fr_FR", "it_IT", "nl_NL"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: identifier)
            calendar.timeZone = TimeZone(identifier: "UTC")!

            let headers = CalendarMonthView.weekdayHeaderSymbols(for: calendar)
            guard headers.count == 7 else {
                findings.append("  \(identifier): \(headers.count) headers, expected 7")
                continue
            }

            // Walk a whole month so a rotation that happens to work for one weekday cannot pass.
            let firstOfMonth = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
            let leading = CalendarMonthView.leadingEmptyCells(before: firstOfMonth,
                                                              calendar: calendar)
            for dayOffset in 0..<31 {
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: firstOfMonth)
                else { continue }
                examined += 1
                let column = (leading + dayOffset) % 7
                let weekday = calendar.component(.weekday, from: date)
                let expected = calendar.veryShortWeekdaySymbols[weekday - 1]
                if headers[column] != expected {
                    findings.append("""
                          \(identifier): \(calendar.component(.day, from: date)) July sits in \
                        column \(column) under "\(headers[column])" but is a "\(expected)"
                        """)
                    break
                }
            }
        }

        #expect(examined >= 200, "only \(examined) day/column pairs checked across 7 locales")
        #expect(findings.isEmpty, """
            \(findings.count) locale(s) render the month grid under the wrong column headers:
            \(findings.joined(separator: "\n"))

            `veryShortWeekdaySymbols` is Sunday-first in every locale; the grid offsets by
            `firstWeekday`. Rotate the symbols by the same amount.
            """)
    }

    // MARK: - Collation and folding

    @Test("Sorting names uses the reader's collation, not Unicode code points")
    func collationFollowsTheReadersLanguage() {
        // German: Ä sorts with A, so "Ärzte" comes before "Zoo". Code-point order puts U+00C4
        // after every ASCII letter, so it lands last.
        let german = ["Zoo", "Ärzte", "Apfel"]
        let byCodePoint = german.sorted(by: <)
        let localized = german.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        #expect(byCodePoint == ["Apfel", "Zoo", "Ärzte"], """
            Code-point order changed on this OS; the premise of the fix needs re-checking before
            the guard below is trusted. Got \(byCodePoint).
            """)
        #expect(localized == ["Apfel", "Ärzte", "Zoo"], """
            `localizedStandardCompare` did not collate German correctly. Got \(localized).
            """)
        #expect(byCodePoint != localized, "the two orderings must differ, or this proves nothing")
    }

    @Test("Search folds case and diacritics; tag identity folds only case")
    func foldingIsForgivingInSearchAndStrictInIdentity() {
        // Search: a German reader types without the umlaut, a French reader without the accent.
        #expect("Grüße kaufen".localizedStandardContains("grusse"))
        #expect("Café besuchen".localizedStandardContains("cafe"))
        #expect(!"Grüße kaufen".lowercased().contains("grusse"),
                "`lowercased()` must NOT match — that is why the search was changed")

        // Identity: case folds, accents do not. Merging "café" into "cafe" would silently retag
        // the user's data and rewrite CATEGORIES on the server.
        #expect("Work".localizedCaseInsensitiveCompare("work") == .orderedSame)
        #expect("café".localizedCaseInsensitiveCompare("CAFÉ") == .orderedSame)
        #expect("café".localizedCaseInsensitiveCompare("cafe") != .orderedSame,
                "accent-different tags must stay different")
    }

    /// Every remaining `lowercased()` in the repository must be operating on a protocol token,
    /// not on something a person reads. Each exception names what it is.
    static let lowercasedIsProtocol: [String: String] = [
        "NowThis/Sync/CalDAVClient.swift": "HTTP header names and DAV element names.",
        "NowThis/Sync/CalDAVReportValues.swift": "URL scheme and host protocol identity; never user text.",
        "NowThis/Utilities/ServerURLValidator.swift": "URL scheme comparison.",
        "NowThis/Models/SavedFilter.swift": "The stored string \"true\"/\"false\" of a boolean rule.",
        "NowThis/Utilities/NaturalLanguageParser.swift":
            "English parser keywords. A locked decision keeps this parser English-only.",
        "NowThis/Models/TaskPriority.swift":
            "`init?(filterToken:)` reads a value written to disk by an earlier build. The legacy "
            + "spellings are frozen English on purpose — they are what those builds wrote — so "
            + "the comparison must stay ASCII and locale-independent. A Turkish reader's `I` must "
            + "not change how their saved filter parses.",
        "NowThis/Utilities/TranslationDisclosure.swift":
            "BCP-47 language subtags (`de`, `zh-Hans`), folded for use as `Set<String>` members "
            + "and compared against `Bundle.main.preferredLocalizations`. These are protocol "
            + "tokens, never user text — and the tokens themselves are ASCII, so `lowercased()` "
            + "is the locale-independent operation here rather than the risky one. The Turkish "
            + "dotless-i case would matter if a subtag contained `I`; none does, and folding via "
            + "a localized comparison would make the acknowledged-language set depend on the very "
            + "locale it is keyed by.",
        "NowThis/Parser/TaskPhotoAttachment.swift":
            "MIME type token from FMTTYPE; its lowercase comparison is protocol normalization.",
        "NowThis/Services/TaskPhotoCache.swift":
            "UUID filenames are filesystem identifiers, not reader text.",
        "NowThis/Sync/NextcloudPhotoClient.swift":
            "UUID filenames plus URL scheme/host and HTTP Link tokens are protocol identity.",
    ]

    // Three entries were written here from memory and removed on the first run:
    // `ICalendarParser`, `DAVXMLParser` and `RecurrenceRule` use `uppercased()`, not
    // `lowercased()`. The rot check below caught all three before this file was committed, which
    // is the entire argument for having one.

    @Test("No user-facing comparison folds case with `lowercased()`")
    func noUserFacingLowercasedComparisons() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var examined = 0
        var findings: [String] = []

        for file in try LocalizationCatalogFixture.swiftSourceFiles() {
            let source = SwiftSourceScanner.strippingComments(
                try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8))
            guard source.contains("lowercased()") else { continue }
            for (index, line) in source.components(separatedBy: "\n").enumerated()
            where line.contains("lowercased()") {
                examined += 1
                if Self.lowercasedIsProtocol[file] != nil { continue }
                findings.append("  \(file):\(index + 1)  \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        #expect(examined >= 10, """
            Only \(examined) `lowercased()` sites found; there were 20 when this was written. A
            scan that finds nothing to check reports success.
            """)
        #expect(findings.isEmpty, """
            \(findings.count) `lowercased()` call(s) outside the protocol allowlist:
            \(findings.joined(separator: "\n"))

            `lowercased()` is not locale-aware and folds no diacritics. For **search** use
            `localizedStandardContains`; for **identity** use `localizedCaseInsensitiveCompare`.
            If the value is a protocol token, add its file to `lowercasedIsProtocol` with a reason.
            """)
    }

    @Test("`lowercasedIsProtocol` entries still name files that use it")
    func lowercasedAllowlistStillApplies() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var stale: [String] = []
        for (file, _) in Self.lowercasedIsProtocol {
            guard let raw = try? String(
                contentsOf: root.appendingPathComponent(file), encoding: .utf8) else {
                stale.append("\(file) — file is gone")
                continue
            }
            if !SwiftSourceScanner.strippingComments(raw).contains("lowercased()") {
                stale.append("\(file) — no `lowercased()` left to excuse")
            }
        }
        #expect(stale.isEmpty, """
            \(stale.count) stale protocol exemption(s):
            \(stale.sorted().map { "  \($0)" }.joined(separator: "\n"))
            """)
    }

    // MARK: - The source rule, so a new site cannot reintroduce it

    /// Sites where `Calendar.current` is *correct*: they use it for a time zone, for day-boundary
    /// arithmetic, or for locale-driven symbols — none of which depend on era numbering.
    static let calendarCurrentIsFine: [String: String] = [
        "NowThis/Utilities/DueDateHelper.swift":
            "Only as the default argument of the `regionCalendar:` parameters, which the "
            + "implementation uses for its time zone and never for its identity.",
    ]

    @Test("`DueDateHelper` never reconstructs components in a calendar it did not extract them from")
    func componentRoundTripsStayWithinOneCalendarIdentity() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let file = "NowThis/Utilities/DueDateHelper.swift"
        let source = SwiftSourceScanner.strippingComments(
            try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8))

        // `date(from:)` reverses `dateComponents(_:from:)`. Both halves of every such pair must
        // run on a **Gregorian** calendar — `utcCalendar` or `localCalendar(in:)`.
        //
        // The receivers are **allowlisted, not blocklisted**, and that is the correction P1
        // forced. The first version named the receivers it disapproved of — `regionCalendar.` and
        // `Calendar.current.` — and P1 restored the defect through a parameter that happens to be
        // called `calendar:`, which matched neither. The behavioural test caught it, so nothing
        // could ship, but the source rule was blind to the exact mutation it exists to prevent.
        // Naming what is *allowed* cannot be defeated by renaming a variable.
        let allowedReceivers = ["utcCalendar", "localCalendar"]
        var examined = 0
        var findings: [String] = []
        let lines = source.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(".dateComponents(") || trimmed.contains(".date(from:") else {
                continue
            }
            examined += 1
            // A wrapped call puts the receiver on the previous line:
            //     let dayComponents = localCalendar(in: regionCalendar)
            //         .dateComponents([.year, .month, .day], from: day)
            let context = index > 0
                ? lines[index - 1].trimmingCharacters(in: .whitespaces) + " " + trimmed
                : trimmed
            let onAGregorianCalendar = allowedReceivers.contains { receiver in
                context.contains("\(receiver).dateComponents")
                    || context.contains("\(receiver).date(from:")
                    || context.contains("\(receiver)(in:")
            }
            if !onAGregorianCalendar {
                findings.append("  \(file):\(index + 1)  \(trimmed)")
            }
        }

        #expect(examined >= 4, """
            Only \(examined) component conversions found in \(file); there were 5 when this was
            written. If they moved, re-point this scan rather than deleting it.
            """)
        #expect(findings.isEmpty, """
            \(findings.count) component conversion(s) use the caller's region calendar:
            \(findings.joined(separator: "\n"))

            Extract and reconstruct with the same identity. Use `localCalendar(in:)` — a Gregorian
            calendar carrying the region's *time zone* — or `utcCalendar`.
            """)
    }
}
