import Testing
import Foundation

@testable import NowThis

// MARK: - Parser Date-Only Detection Tests

@Suite("Parser Date-Only Detection")
struct ParserDateOnlyTests {

    @Test("DUE with VALUE=DATE sets isDueDateOnly to true")
    func dueDateOnlyFlag() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VTODO
        UID:date-only-test
        SUMMARY:Date Only Task
        DUE;VALUE=DATE:20260528
        END:VTODO
        END:VCALENDAR
        """

        let todos = try ICalendarParser.parseVTODOs(from: ics)
        let todo = try #require(todos.first)

        #expect(todo.isDueDateOnly == true, "DATE-only DUE should set isDueDateOnly")
        #expect(todo.dueDate != nil, "DUE date should still be parsed")
    }

    @Test("DUE with datetime does NOT set isDueDateOnly")
    func dueDateTimeFlag() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VTODO
        UID:datetime-test
        SUMMARY:DateTime Task
        DUE:20260528T140000Z
        END:VTODO
        END:VCALENDAR
        """

        let todos = try ICalendarParser.parseVTODOs(from: ics)
        let todo = try #require(todos.first)

        #expect(todo.isDueDateOnly == false, "DateTime DUE should NOT set isDueDateOnly")
    }

    @Test("DTSTART with VALUE=DATE sets isStartDateOnly")
    func startDateOnlyFlag() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VTODO
        UID:start-date-test
        SUMMARY:Start Date Only
        DTSTART;VALUE=DATE:20260601
        DUE;VALUE=DATE:20260605
        END:VTODO
        END:VCALENDAR
        """

        let todos = try ICalendarParser.parseVTODOs(from: ics)
        let todo = try #require(todos.first)

        #expect(todo.isStartDateOnly == true)
        #expect(todo.isDueDateOnly == true)
    }
}

// MARK: - Serializer Round-Trip Tests

@Suite("Serializer Date-Only Round-Trip")
struct SerializerDateOnlyTests {

    @Test("Date-only task serializes as VALUE=DATE")
    func serializeDateOnly() {
        // Create a date-only due date (midnight UTC for May 28, 2026)
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 28
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        let dueDate = Calendar.current.date(from: components)!

        let ics = ICalendarSerializer.serialize(
            uid: "roundtrip-test",
            summary: "Round Trip",
            dueDate: dueDate,
            isDueDateOnly: true
        )

        #expect(ics.contains("DUE;VALUE=DATE:20260528"), "Date-only should emit VALUE=DATE without time")
        #expect(!ics.contains("DUE:2026"), "Should NOT emit datetime format for date-only")
    }

    @Test("Date+time task serializes with full datetime")
    func serializeDateTime() {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 28
        components.hour = 14
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        let dueDate = Calendar.current.date(from: components)!

        let ics = ICalendarSerializer.serialize(
            uid: "datetime-test",
            summary: "DateTime Task",
            dueDate: dueDate,
            isDueDateOnly: false
        )

        #expect(ics.contains("DUE:20260528T140000Z"), "Date+time should emit full UTC datetime")
        #expect(!ics.contains("VALUE=DATE"), "Should NOT emit VALUE=DATE for date+time")
    }
}

// MARK: - DueDateHelper Tests

@Suite("DueDateHelper")
struct DueDateHelperTests {

    // Helper: create a Date from UTC components
    private func utcDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar.current.date(from: components)!
    }

    @Test("Date-only task due today is NOT overdue")
    func dateOnlyTodayNotOverdue() {
        // A date-only task stored as midnight UTC today
        let todayUTC = utcDate(
            year: Calendar.current.component(.year, from: Date()),
            month: Calendar.current.component(.month, from: Date()),
            day: Calendar.current.component(.day, from: Date())
        )

        // This should NOT be overdue — it's due "today" (all day)
        let result = DueDateHelper.isOverdue(dueDate: todayUTC, isDateOnly: true)
        #expect(result == false, "A date-only task due today should NOT be overdue")
    }

    @Test("Date-only task due yesterday IS overdue")
    func dateOnlyYesterdayIsOverdue() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let yesterdayUTC = utcDate(
            year: Calendar.current.component(.year, from: yesterday),
            month: Calendar.current.component(.month, from: yesterday),
            day: Calendar.current.component(.day, from: yesterday)
        )

        let result = DueDateHelper.isOverdue(dueDate: yesterdayUTC, isDateOnly: true)
        #expect(result == true, "A date-only task due yesterday should be overdue")
    }

    @Test("effectiveDeadline for date-only returns end of local day")
    func effectiveDeadlineDateOnly() {
        // Midnight UTC May 28
        let midnightUTC = utcDate(year: 2026, month: 5, day: 28)

        let deadline = DueDateHelper.effectiveDeadline(for: midnightUTC, isDateOnly: true)

        // The deadline should be the START of May 29 in local time
        // (which equals the END of May 28 — i.e., one second past 23:59:59)
        let localCalendar = Calendar.current
        var may28Components = DateComponents()
        may28Components.year = 2026
        may28Components.month = 5
        may28Components.day = 28
        let startOfMay28 = localCalendar.date(from: may28Components)!
        let startOfMay29 = localCalendar.date(byAdding: .day, value: 1, to: localCalendar.startOfDay(for: startOfMay28))!

        #expect(deadline == startOfMay29, "Deadline should equal start of next day (end of May 28)")
        #expect(deadline > startOfMay28, "Deadline should be after start of May 28")
    }

    @Test("effectiveDeadline for date+time returns the date unchanged")
    func effectiveDeadlineDateTime() {
        let specificTime = utcDate(year: 2026, month: 5, day: 28, hour: 14, minute: 30)

        let deadline = DueDateHelper.effectiveDeadline(for: specificTime, isDateOnly: false)

        #expect(deadline == specificTime, "Date+time deadline should be unchanged")
    }

    @Test("isOnDay matches date-only task to correct local day")
    func isOnDayDateOnly() {
        // Midnight UTC May 28 — this is what a DUE;VALUE=DATE:20260528 produces
        let midnightUTC = utcDate(year: 2026, month: 5, day: 28)

        // The local "May 28" — create it in the local calendar
        var localComponents = DateComponents()
        localComponents.year = 2026
        localComponents.month = 5
        localComponents.day = 28
        let localMay28 = Calendar.current.date(from: localComponents)!

        let result = DueDateHelper.isOnDay(midnightUTC, isDateOnly: true, sameAs: localMay28)
        #expect(result == true, "Date-only task for May 28 UTC should match local May 28")
    }

    @Test("isOnDay does NOT match date-only task to adjacent day")
    func isOnDayDateOnlyWrongDay() {
        let midnightUTC = utcDate(year: 2026, month: 5, day: 28)

        var localComponents = DateComponents()
        localComponents.year = 2026
        localComponents.month = 5
        localComponents.day = 27
        let localMay27 = Calendar.current.date(from: localComponents)!

        let result = DueDateHelper.isOnDay(midnightUTC, isDateOnly: true, sameAs: localMay27)
        #expect(result == false, "Date-only task for May 28 should NOT match May 27")
    }
}
