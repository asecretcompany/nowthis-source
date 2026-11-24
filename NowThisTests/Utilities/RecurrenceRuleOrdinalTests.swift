import Foundation
import Testing
@testable import NowThis

@Suite("Recurrence ordinals")
struct RecurrenceRuleOrdinalTests {
    @Test func monthlyLastSundayRoundTripsAndAdvances() throws {
        let raw = "FREQ=MONTHLY;BYDAY=-1SU"
        let rule = try #require(RecurrenceRule.parse(raw))
        #expect(rule.toRRULEString() == raw)
        let calendar = Calendar.current
        let due = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 10)))
        let expected = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 29, hour: 10)))
        #expect(rule.nextDate(after: due) == expected)
    }

    @Test(arguments: ["XX", "0MO", "54MO", "-54SU", "MO,"])
    func rejectsMalformedWeekdays(_ value: String) {
        #expect(RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=\(value)") == nil)
    }

    @Test(arguments: ["INTERVAL=0", "INTERVAL=-1", "INTERVAL=no", "COUNT=0", "COUNT=-1", "COUNT=no", "BYMONTH=2", "BYSETPOS=-1"])
    func rejectsMalformedOrUnsupportedClauses(_ clause: String) {
        #expect(RecurrenceRule.parse("FREQ=MONTHLY;\(clause)") == nil)
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, in calendar: Calendar? = nil) throws -> Date {
        try #require((calendar ?? utc).date(from: DateComponents(year: year, month: month, day: day, hour: 10, minute: 15)))
    }

    @Test(arguments: ["FREQ=MONTHLY;BYDAY=2FR,-1MO", "FREQ=MONTHLY;BYDAY=+2FR", "FREQ=YEARLY;BYDAY=53TH", "FREQ=MONTHLY;BYDAY=-53MO"])
    func ordinalRoundTrip(_ raw: String) throws {
        let rule = try #require(RecurrenceRule.parse(raw))
        #expect(rule.toRRULEString() == raw)
        #expect(!rule.isPickerRepresentable)
        #expect(rule.displayText == RecurrenceRule.customDisplayText)
    }

    @Test func multipleCandidatesIncludeRemainderOfCurrentMonth() throws {
        let rule = try #require(RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=2FR,-1MO"))
        let first = try date(2026, 10, 9)
        let second = try date(2026, 10, 26)
        let third = try date(2026, 11, 13)
        #expect(rule.nextDates(after: try date(2026, 10, 1), limit: 3, calendar: utc) == [first, second, third])
    }

    @Test func missingFifthWeekdaySkipsMonthsAndHonorsInterval() throws {
        let rule = try #require(RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=2;BYDAY=5MO"))
        #expect(rule.nextDate(after: try date(2026, 1, 26), calendar: utc) == (try date(2026, 3, 30)))
        let monthly = try #require(RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=5MO"))
        #expect(monthly.nextDate(after: try date(2026, 2, 2), calendar: utc) == (try date(2026, 3, 30)))
    }

    @Test func yearlyOrdinalsAreCountedWithinTheYear() throws {
        let rule = try #require(RecurrenceRule.parse("FREQ=YEARLY;BYDAY=2FR,-1MO"))
        #expect(rule.nextDate(after: try date(2026, 1, 9), calendar: utc) == (try date(2026, 12, 28)))
        #expect(rule.nextDate(after: try date(2026, 12, 28), calendar: utc) == (try date(2027, 1, 8)))
        let last = try #require(RecurrenceRule.parse("FREQ=YEARLY;BYDAY=-53TH"))
        #expect(last.nextDate(after: try date(2025, 12, 25), calendar: utc) == (try date(2026, 1, 1)))
        let fiftyThird = try #require(RecurrenceRule.parse("FREQ=YEARLY;BYDAY=53TH"))
        #expect(fiftyThird.nextDate(after: try date(2026, 1, 1), calendar: utc) == (try date(2026, 12, 31)))
    }

    @Test func ordinalPreservesLocalClockAcrossDST() throws {
        var la = utc
        la.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let rule = try #require(RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=-1SU"))
        let from = try date(2026, 10, 25, in: la)
        #expect(rule.nextDate(after: from, calendar: la) == (try date(2026, 11, 29, in: la)))
    }

    @Test func nonexistentOrdinalWallClockIsSkippedWithoutShiftingLaterMonths() throws {
        var berlin = utc
        berlin.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let rule = try #require(RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=-1SU"))
        let from = try #require(berlin.date(from: DateComponents(year: 2026, month: 2, day: 22, hour: 2, minute: 30)))
        let april = try #require(berlin.date(from: DateComponents(year: 2026, month: 4, day: 26, hour: 2, minute: 30)))
        let may = try #require(berlin.date(from: DateComponents(year: 2026, month: 5, day: 31, hour: 2, minute: 30)))
        // March's last Sunday has no 02:30 local time. RFC 5545 requires it to be
        // ignored rather than normalized to 03:00 or moved to the next day.
        #expect(rule.nextDates(after: from, limit: 2, calendar: berlin) == [april, may])
    }

    @Test func nonexistentYearlyOrdinalWallClockSkipsToNextValidCandidate() throws {
        var berlin = utc
        berlin.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let rule = try #require(RecurrenceRule.parse("FREQ=YEARLY;BYDAY=13SU,-1SU"))
        let from = try #require(berlin.date(from: DateComponents(year: 2026, month: 2, day: 22, hour: 2, minute: 30)))
        let december = try #require(berlin.date(from: DateComponents(year: 2026, month: 12, day: 27, hour: 2, minute: 30)))
        let followingDecember = try #require(berlin.date(from: DateComponents(year: 2027, month: 12, day: 26, hour: 2, minute: 30)))
        // The thirteenth Sunday falls in Berlin's missing hour in both years.
        #expect(rule.nextDates(after: from, limit: 2, calendar: berlin) == [december, followingDecember])
    }

    @Test func repeatedOrdinalWallClockUsesFirstOccurrenceAndKeepsClockTime() throws {
        var berlin = utc
        berlin.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let rule = try #require(RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=-1SU"))
        let from = try #require(berlin.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 2, minute: 30)))
        // The first 02:30 on October 25 is still UTC+2. November is UTC+1.
        let october = try #require(ICalendarParser.parseDate("20261025T003000Z"))
        let november = try #require(ICalendarParser.parseDate("20261129T013000Z"))
        #expect(rule.nextDates(after: from, limit: 2, calendar: berlin) == [october, november])
    }

    @Test func untilIsInclusiveAndMissingOrdinalsExhaust() throws {
        let due = try date(2026, 10, 25)
        let inclusive = try #require(RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=-1SU;UNTIL=20261129T101500Z"))
        #expect(inclusive.nextDate(after: due, calendar: utc) == (try date(2026, 11, 29)))
        let expired = try #require(RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=-1SU;UNTIL=20261129T101459Z"))
        #expect(expired.nextOccurrence(after: due, calendar: utc) == .exhausted)
        let impossible = try #require(RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=53MO"))
        #expect(impossible.nextOccurrence(after: due, calendar: utc) == .exhausted)
    }

    @Test func validLargeCountAndUnsafeIntervalDoNotOverflow() throws {
        let rule = try #require(RecurrenceRule.parse("FREQ=DAILY;COUNT=10001"))
        let due = try date(2026, 10, 25)
        #expect(rule.nextDate(after: due, completionCount: 10000, calendar: utc) != nil)
        #expect(rule.nextDate(after: due, completionCount: 10001, calendar: utc) == nil)
        let enormous = try #require(RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=9223372036854775807;BYDAY=MO"))
        #expect(enormous.nextOccurrence(after: due, calendar: utc) == .unsupported)
        #expect(rule.nextDates(after: due, limit: -1).isEmpty)
        #expect(rule.nextDates(after: due, limit: 0).isEmpty)
    }

    @Test(arguments: ["INTERVAL=", "INTERVAL=1.5", "INTERVAL=+1", "COUNT=", "COUNT=1.5", "COUNT=+1", "COUNT=9223372036854775808", "BYDAY=1MO;BYMONTH=2", "BYDAY=1MO;BYSETPOS=1", "BYDAY=001MO", "BYDAY=--1MO", "UNTIL=garbage", "FREQ=DAILY", "COUNT=2;UNTIL=20270101", "INTERVAL=1;INTERVAL=2"])
    func rejectsMalformedCompounds(_ clauses: String) {
        #expect(RecurrenceRule.parse("FREQ=MONTHLY;\(clauses)") == nil)
    }

    @Test(arguments: ["FREQ=WEEKLY;BYDAY=1MO", "FREQ=DAILY;BYDAY=MO", "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,SU;WKST=MO"])
    func rejectsUnsupportedFrequencyCombinations(_ raw: String) {
        #expect(RecurrenceRule.parse(raw) == nil)
    }

    @Test(arguments: ["FREQ=DAILY;COUNT=3", "FREQ=MONTHLY;BYDAY=2FR", "FREQ=MONTHLY;BYMONTHDAY=3", "FREQ=WEEKLY;INTERVAL=100", "FREQ=DAILY;UNTIL=20270101"])
    func pickerKeepsUnrepresentableRulesReadOnly(_ raw: String) {
        #expect(!RecurrenceRule.isPickerRepresentable(raw))
    }

    @Test func pickerSupportsExistingWeeklyRules() {
        #expect(RecurrenceRule.isPickerRepresentable(nil))
        #expect(RecurrenceRule.isPickerRepresentable("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR"))
    }
}

@Suite("Recurrence calendar boundaries")
struct RecurrenceCalendarBoundaryTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func instant(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    @Test(arguments: ["MO,SU", "SU,MO"])
    func omittedWeekStartUsesMondayRegardlessOfCandidateOrder(_ weekdays: String) throws {
        let rule = try #require(RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2;BYDAY=\(weekdays)"))
        let due = try instant("2026-11-02T09:00:00Z")
        let expected = try [instant("2026-11-08T09:00:00Z"), instant("2026-11-16T09:00:00Z")]
        for (locale, firstWeekday) in [("en_US", 1), ("de_DE", 2), ("ar_SA", 7)] {
            var calendar = utc
            calendar.locale = Locale(identifier: locale)
            calendar.firstWeekday = firstWeekday
            #expect(rule.nextDates(after: due, limit: 2, calendar: calendar) == expected)
        }
    }

    @Test func mondayBasedIntervalCrossesTheCalendarYear() throws {
        let rule = try #require(RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,SU"))
        let due = try instant("2026-12-28T09:00:00Z")
        let expected = try [instant("2027-01-03T09:00:00Z"), instant("2027-01-11T09:00:00Z")]
        #expect(rule.nextDates(after: due, limit: 2, calendar: utc) == expected)
    }

    @Test(arguments: [
        (1, "2026-03-31T09:00:00Z", "2026-05-31T09:00:00Z"),
        (3, "2026-07-31T09:00:00Z", "2026-10-31T09:00:00Z")
    ])
    func monthlySkipsInvalidDatesAndRetainsIntervalPhase(_ interval: Int, _ first: String, _ second: String) throws {
        let rule = try #require(RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=\(interval)"))
        let due = try instant("2026-01-31T09:00:00Z")
        let expected = try [instant(first), instant(second)]
        #expect(rule.nextDates(after: due, limit: 2, calendar: utc) == expected)
    }

    @Test(arguments: [
        (1, "2024-02-29T09:00:00Z", "2028-02-29T09:00:00Z", "2032-02-29T09:00:00Z"),
        (5, "2024-02-29T09:00:00Z", "2044-02-29T09:00:00Z", "2064-02-29T09:00:00Z"),
        (1, "2096-02-29T09:00:00Z", "2104-02-29T09:00:00Z", "2108-02-29T09:00:00Z")
    ])
    func yearlySkipsNonLeapYearsAndRetainsIntervalPhase(_ interval: Int, _ start: String, _ first: String, _ second: String) throws {
        let rule = try #require(RecurrenceRule.parse("FREQ=YEARLY;INTERVAL=\(interval)"))
        let expected = try [instant(first), instant(second)]
        #expect(rule.nextDates(after: try instant(start), limit: 2, calendar: utc) == expected)
    }

    @Test(arguments: [("20260331T085959Z", false), ("20260331T090000Z", true)])
    func untilIsInclusiveAtTheFirstValidCandidate(_ until: String, _ includesNext: Bool) throws {
        let raw = "FREQ=MONTHLY;UNTIL=\(until)"
        let rule = try #require(RecurrenceRule.parse(raw))
        #expect(rule.toRRULEString() == raw)
        let reparsed = try #require(RecurrenceRule.parse(rule.toRRULEString()))
        let due = try instant("2026-01-31T09:00:00Z")
        let next = try instant("2026-03-31T09:00:00Z")
        #expect(reparsed.nextOccurrence(after: due, calendar: utc) == (includesNext ? .date(next) : .exhausted))
        #expect(reparsed.nextOccurrence(after: next, calendar: utc) == .exhausted)
    }

    @Test func monthlySkipsMissingLocalClockAndKeepsTheOriginalTime() throws {
        var losAngeles = utc
        losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let rule = try #require(RecurrenceRule.parse("FREQ=MONTHLY"))
        let timed = try instant("2026-02-08T10:30:00Z") // 02:30 PST
        let expected = try [instant("2026-04-08T09:30:00Z"), instant("2026-05-08T09:30:00Z")]
        #expect(rule.nextDates(after: timed, limit: 2, calendar: losAngeles) == expected)

        let dateOnly = try instant("2026-02-08T00:00:00Z")
        #expect(rule.nextDate(after: dateOnly, calendar: utc) == (try instant("2026-03-08T00:00:00Z")))
    }

    @Test func untilEndsTheSeriesWhenTheLastPeriodHasNoLocalClockCandidate() throws {
        var losAngeles = utc
        losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let rule = try #require(RecurrenceRule.parse("FREQ=MONTHLY;UNTIL=20260331T235959Z"))
        let due = try instant("2026-02-08T10:30:00Z") // 02:30 PST
        #expect(rule.nextOccurrence(after: due, calendar: losAngeles) == .exhausted)
    }

    @Test(arguments: ["MONTHLY", "YEARLY"])
    func unrepresentablePeriodAdvanceRefusesEvaluation(_ frequency: String) throws {
        let rule = try #require(RecurrenceRule.parse("FREQ=\(frequency);INTERVAL=2147483647;UNTIL=20270101T090000Z"))
        let due = try instant("2026-01-31T09:00:00Z")
        #expect(rule.nextOccurrence(after: due, calendar: utc) == .unsupported)
    }

    @Test func leapDaySearchRefusesAnUnencodableYearAndAcceptsAFourDigitYear() throws {
        let due = try #require(ICalendarParser.parseDate("20240229"))
        let outOfRange = try #require(RecurrenceRule.parse("FREQ=YEARLY;INTERVAL=1995"))
        #expect(outOfRange.nextOccurrence(after: due, calendar: utc) == .unsupported)

        let inRange = try #require(RecurrenceRule.parse("FREQ=YEARLY;INTERVAL=7972"))
        let next = try #require(inRange.nextDate(after: due, calendar: utc))
        #expect(ICalendarSerializer.formatDateOnly(next) == "99960229")
        #expect(ICalendarParser.parseDate("99960229") == next)
    }

    @Test func timedCandidateUsesTheUTCYearAndHonorsAnEarlierUntil() throws {
        var pacific = utc
        pacific.timeZone = try #require(TimeZone(secondsFromGMT: -8 * 3600))
        let rule = try #require(RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=2"))
        // Oct 31 at 23:30 local advances to Dec 31 at 23:30 local, Jan 1 in UTC.
        let due = try #require(ICalendarParser.parseDate("99991101T073000Z"))
        #expect(rule.nextOccurrence(after: due, calendar: pacific) == .unsupported)

        let limited = try #require(RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=2;UNTIL=99991231T235959Z"))
        #expect(limited.nextOccurrence(after: due, calendar: pacific) == .exhausted)
        let neighbor = try #require(ICalendarParser.parseDate("99991031T235959Z"))
        let last = try #require(limited.nextDate(after: neighbor, calendar: pacific))
        #expect(ICalendarSerializer.formatDate(last) == "99991231T235959Z")
        #expect(ICalendarParser.parseDate("99991231T235959Z") == last)
    }

    @Test(arguments: [
        ("FREQ=DAILY", "99991231", "99991230"),
        ("FREQ=WEEKLY", "99991231", "99991224"),
        ("FREQ=WEEKLY;BYDAY=FR", "99991231", "99991224"),
        ("FREQ=MONTHLY;BYDAY=-1FR", "99991231", "99991126"),
        ("FREQ=YEARLY;BYDAY=-1FR", "99991231", "99981225")
    ])
    func finalFourDigitYearCandidateIsValidButFollowingOccurrenceIsUnsupported(
        raw: String, lastDay: String, previousDay: String
    ) throws {
        let previous = try #require(ICalendarParser.parseDate(previousDay))
        let last = try #require(ICalendarParser.parseDate(lastDay))
        let rule = try #require(RecurrenceRule.parse(raw))
        #expect(rule.nextOccurrence(after: previous, calendar: utc) == .date(last))
        #expect(rule.nextOccurrence(after: last, calendar: utc) == .unsupported)

        let limited = try #require(RecurrenceRule.parse(raw + ";UNTIL=" + lastDay))
        #expect(limited.nextOccurrence(after: previous, calendar: utc) == .date(last))
        #expect(limited.nextOccurrence(after: last, calendar: utc) == .exhausted)
    }

    @Test func weeklyLocalYearBoundaryUsesTheUTCYear() throws {
        var west = utc
        west.timeZone = try #require(TimeZone(secondsFromGMT: -8 * 3600))
        let rule = try #require(RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=FR"))
        let previous = try #require(ICalendarParser.parseDate("99991225T073000Z"))
        // The next local Friday is still in 9999, but it starts 10000 on the wire.
        #expect(rule.nextOccurrence(after: previous, calendar: west) == .unsupported)

        let limited = try #require(RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=FR;UNTIL=99991231T235959Z"))
        #expect(limited.nextOccurrence(after: previous, calendar: west) == .exhausted)
    }

    @Test func localYear10000CanStillEncodeAsUTCYear9999() throws {
        var pacific = utc
        pacific.timeZone = try #require(TimeZone(secondsFromGMT: 14 * 3600))
        let rule = try #require(RecurrenceRule.parse("FREQ=YEARLY"))
        let due = try #require(ICalendarParser.parseDate("99981231T103000Z"))
        let next = try #require(rule.nextDate(after: due, calendar: pacific))
        #expect(ICalendarSerializer.formatDate(next) == "99991231T103000Z")
    }

    @Test func preCommonEraCandidateCannotRoundTripAsICalendarDate() throws {
        let rule = try #require(RecurrenceRule.parse("FREQ=YEARLY"))
        let earlier = try #require(utc.date(from: DateComponents(era: 0, year: 2, month: 1, day: 1)))
        #expect(rule.nextOccurrence(after: earlier, calendar: utc) == .unsupported)

        let later = try #require(utc.date(from: DateComponents(era: 0, year: 1, month: 1, day: 1)))
        let next = try #require(rule.nextDate(after: later, calendar: utc))
        #expect(ICalendarSerializer.formatDateOnly(next) == "00010101")
        #expect(ICalendarParser.parseDate("00010101") == next)
    }
}
