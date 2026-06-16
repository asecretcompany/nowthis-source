import Testing
import Foundation

@testable import NowThis

// MARK: - ICalendarParser Timezone Tests

@Suite("ICalendarParser Timezone Handling")
struct ICalendarParserTimezoneTests {

    // MARK: - TZID-qualified dates

    @Test("Parse DUE with TZID parameter preserves correct time")
    func parseDueWithTZID() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VTODO
        UID:tz-test-1
        SUMMARY:Meeting prep
        DUE;TZID=America/Los_Angeles:20240615T120000
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo != nil)

        // 2024-06-15 12:00 PDT = 2024-06-15 19:00 UTC (PDT is UTC-7 in summer)
        let calendar = Calendar(identifier: .gregorian)
        let utcComponents = calendar.dateComponents(
            in: TimeZone(identifier: "UTC")!,
            from: todo!.dueDate!
        )
        #expect(utcComponents.year == 2024)
        #expect(utcComponents.month == 6)
        #expect(utcComponents.day == 15)
        #expect(utcComponents.hour == 19)
        #expect(utcComponents.minute == 0)
    }

    @Test("Parse DTSTART with TZID parameter preserves correct time")
    func parseStartWithTZID() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VTODO
        UID:tz-test-2
        SUMMARY:Start test
        DTSTART;TZID=Europe/Berlin:20240115T140000
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo != nil)

        // 2024-01-15 14:00 CET = 2024-01-15 13:00 UTC (CET is UTC+1 in winter)
        let calendar = Calendar(identifier: .gregorian)
        let utcComponents = calendar.dateComponents(
            in: TimeZone(identifier: "UTC")!,
            from: todo!.startDate!
        )
        #expect(utcComponents.year == 2024)
        #expect(utcComponents.month == 1)
        #expect(utcComponents.day == 15)
        #expect(utcComponents.hour == 13)
        #expect(utcComponents.minute == 0)
    }

    // MARK: - Local date-time (no Z, no TZID)

    @Test("Parse local date-time without Z uses device local timezone")
    func parseLocalDateTime() throws {
        // A local date-time without Z or TZID should be interpreted in
        // the device's local timezone, not UTC.
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VTODO
        UID:local-time-test
        SUMMARY:Local time task
        DUE:20240615T120000
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo != nil)

        // The date should represent noon in the current device timezone
        let calendar = Calendar(identifier: .gregorian)
        let localComponents = calendar.dateComponents(
            in: TimeZone.current,
            from: todo!.dueDate!
        )
        #expect(localComponents.hour == 12)
        #expect(localComponents.minute == 0)
        #expect(localComponents.day == 15)
        #expect(localComponents.month == 6)
    }

    // MARK: - DATE-only values

    @Test("Parse DATE-only value represents the correct calendar day")
    func parseDateOnly() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VTODO
        UID:date-only-test
        SUMMARY:Date only task
        DUE;VALUE=DATE:20240615
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo != nil)
        #expect(todo!.isDueDateOnly == true)

        // Per the app-wide convention (see DueDateHelper), a DATE-only value is
        // stored as midnight UTC and represents a whole calendar day. It must be
        // interpreted via DueDateHelper, NOT by reading components in local time
        // (which would shift to the prior day in negative-UTC-offset zones).
        let utcComponents = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!,
            from: todo!.dueDate!
        )
        #expect(utcComponents.year == 2024)
        #expect(utcComponents.month == 6)
        #expect(utcComponents.day == 15)

        // And it resolves to the intended local calendar day via DueDateHelper.
        var localJune15 = DateComponents()
        localJune15.year = 2024
        localJune15.month = 6
        localJune15.day = 15
        let localDay = Calendar.current.date(from: localJune15)!
        #expect(DueDateHelper.isOnDay(todo!.dueDate!, isDateOnly: true, sameAs: localDay))
    }

    // MARK: - UTC dates still work

    @Test("Parse UTC date-time with Z suffix still works correctly")
    func parseUTCDateTimeStillWorks() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VTODO
        UID:utc-test
        SUMMARY:UTC task
        DUE:20240615T190000Z
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo != nil)

        let calendar = Calendar(identifier: .gregorian)
        let utcComponents = calendar.dateComponents(
            in: TimeZone(identifier: "UTC")!,
            from: todo!.dueDate!
        )
        #expect(utcComponents.year == 2024)
        #expect(utcComponents.month == 6)
        #expect(utcComponents.day == 15)
        #expect(utcComponents.hour == 19)
        #expect(utcComponents.minute == 0)
    }

    // MARK: - Edge cases

    @Test("Parse TZID with non-standard casing works")
    func parseTZIDCaseInsensitive() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VTODO
        UID:case-test
        SUMMARY:Case test
        DUE;tzid=America/New_York:20240115T090000
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo != nil)

        // 2024-01-15 09:00 EST = 2024-01-15 14:00 UTC (EST is UTC-5)
        let calendar = Calendar(identifier: .gregorian)
        let utcComponents = calendar.dateComponents(
            in: TimeZone(identifier: "UTC")!,
            from: todo!.dueDate!
        )
        #expect(utcComponents.hour == 14)
    }
}
