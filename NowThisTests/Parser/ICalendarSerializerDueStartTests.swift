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

    // MARK: - An all-day DUE is the end of its day, not the start of it

    /// The reported loss. An all-day due date is stored as midnight UTC
    /// carrying a calendar date, so an instant comparison put every timed start
    /// on that day *after* the deadline. The PUT dropped `DTSTART`, and because
    /// the next inbound apply takes the remote as the truth, the start date the
    /// user had set was then erased locally too.
    ///
    /// Turning on Due Date and Start Date in the same sitting reaches this: the
    /// due date defaults to today, and if the user makes it All Day, every
    /// start time they can pick is on or after midnight.
    @Test("A timed start on the day an all-day task is due survives")
    func timedStartOnAllDayDueDay_emitsStart() {
        let day = makeDate(year: 2026, month: 6, day: 9, hour: 0)
        let start = makeDate(year: 2026, month: 6, day: 9, hour: 14)

        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Task",
            dueDate: day,
            startDate: start,
            isDueDateOnly: true
        )

        #expect(ics.contains("DUE;VALUE=DATE:"))
        #expect(ics.contains("DTSTART:"), "the task is due at the end of the 9th, so 14:00 is before it")
    }

    /// The rule still has to bite. A start on the *following* day is genuinely
    /// after the deadline and must stay suppressed.
    @Test("A timed start after the day an all-day task is due is still dropped")
    func timedStartAfterAllDayDueDay_omitsStart() {
        let day = makeDate(year: 2026, month: 6, day: 9, hour: 0)
        let start = makeDate(year: 2026, month: 6, day: 10, hour: 9)

        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Task",
            dueDate: day,
            startDate: start,
            isDueDateOnly: true
        )

        #expect(ics.contains("DUE;VALUE=DATE:"))
        #expect(!ics.contains("DTSTART"))
    }

    /// Locks in the behaviour this change relies on rather than introduces: a
    /// timed `DTSTART` beside an all-day `DUE` is a shape the app already sends
    /// whenever the start falls on an earlier day, so extending it to the due
    /// day itself adds no new kind of payload for the server to reject.
    @Test("A timed start before an all-day due is emitted, as it already was")
    func timedStartBeforeAllDayDueDay_emitsStart() {
        let day = makeDate(year: 2026, month: 6, day: 10, hour: 0)
        let start = makeDate(year: 2026, month: 6, day: 9, hour: 14)

        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Task",
            dueDate: day,
            startDate: start,
            isDueDateOnly: true
        )

        #expect(ics.contains("DUE;VALUE=DATE:"))
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
