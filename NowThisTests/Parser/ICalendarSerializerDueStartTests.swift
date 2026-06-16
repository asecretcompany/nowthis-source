import Testing
import Foundation

@testable import NowThis

// MARK: - DUE vs DTSTART Validation Tests

@Suite("ICalendarSerializer DUE-DTSTART Validation")
struct ICalendarSerializerDueStartTests {

    // MARK: - Helpers

    private func makeDate(
        year: Int, month: Int, day: Int,
        hour: Int = 12, minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return components.date!
    }

    // MARK: - Tests

    @Test("DTSTART before DUE is emitted normally")
    func startBeforeDue_emitsBoth() {
        let start = makeDate(year: 2026, month: 6, day: 1)
        let due = makeDate(year: 2026, month: 6, day: 10)

        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Task",
            dueDate: due,
            startDate: start
        )

        #expect(ics.contains("DTSTART:"))
        #expect(ics.contains("DUE:"))
    }

    @Test("DTSTART equal to DUE omits DTSTART to avoid Sabre validation error")
    func startEqualsDue_omitsStart() {
        let sameDate = makeDate(year: 2026, month: 6, day: 9, hour: 14)

        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Task",
            dueDate: sameDate,
            startDate: sameDate
        )

        #expect(ics.contains("DUE:"))
        #expect(!ics.contains("DTSTART:"))
    }

    @Test("DTSTART after DUE omits DTSTART to avoid Sabre validation error")
    func startAfterDue_omitsStart() {
        let start = makeDate(year: 2026, month: 6, day: 15)
        let due = makeDate(year: 2026, month: 6, day: 10)

        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Task",
            dueDate: due,
            startDate: start
        )

        #expect(ics.contains("DUE:"))
        #expect(!ics.contains("DTSTART:"))
    }

    @Test("DUE without DTSTART is unaffected")
    func dueOnly_noStart() {
        let due = makeDate(year: 2026, month: 6, day: 10)

        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Task",
            dueDate: due
        )

        #expect(ics.contains("DUE:"))
        #expect(!ics.contains("DTSTART:"))
    }

    @Test("DTSTART without DUE is unaffected")
    func startOnly_noDue() {
        let start = makeDate(year: 2026, month: 6, day: 1)

        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Task",
            startDate: start
        )

        #expect(!ics.contains("DUE:"))
        #expect(ics.contains("DTSTART:"))
    }

    @Test("Date-only DTSTART equal to date-only DUE omits DTSTART")
    func dateOnlyStartEqualsDue_omitsStart() {
        let sameDate = makeDate(year: 2026, month: 6, day: 9)

        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Task",
            dueDate: sameDate,
            startDate: sameDate,
            isDueDateOnly: true,
            isStartDateOnly: true
        )

        #expect(ics.contains("DUE;VALUE=DATE:"))
        #expect(!ics.contains("DTSTART"))
    }
}
