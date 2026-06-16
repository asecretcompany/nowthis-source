import Testing
import Foundation

@testable import NowThis

@Suite("ReminderScheduler Fire Date")
struct ReminderSchedulerFireDateTests {

    // MARK: - Date-Only Fire Date Tests

    @Test("Date-only task fire date uses end-of-local-day, not midnight UTC")
    func dateOnlyFireDateUsesEffectiveDeadline() {
        // A date-only task stored as midnight UTC for "today"
        let utcMidnight = makeMidnightUTC(daysFromNow: 0)
        let offset = 3600 // 1 hour before

        let fireDate = ReminderScheduler.computeFireDate(
            dueDate: utcMidnight,
            isDueDateOnly: true,
            reminderOffset: offset
        )

        // The effective deadline for a date-only task is end-of-local-day
        // (start of next day in local timezone).
        // Fire date should be effectiveDeadline - offset.
        let expectedEffectiveDeadline = DueDateHelper.effectiveDeadline(
            for: utcMidnight, isDateOnly: true
        )
        let expectedFireDate = expectedEffectiveDeadline.addingTimeInterval(-Double(offset))

        #expect(
            abs(fireDate.timeIntervalSince(expectedFireDate)) < 1,
            "Fire date should be end-of-local-day minus offset, not midnight UTC minus offset"
        )
    }

    @Test("Date+time task fire date uses exact due date")
    func dateTimeFireDateUsesExactDueDate() {
        // A task due at 3:00 PM today (has a specific time)
        var components = Calendar.current.dateComponents(
            [.year, .month, .day], from: Date()
        )
        components.hour = 15
        components.minute = 0
        let dueDate = Calendar.current.date(from: components)!
        let offset = 900 // 15 minutes before

        let fireDate = ReminderScheduler.computeFireDate(
            dueDate: dueDate,
            isDueDateOnly: false,
            reminderOffset: offset
        )

        let expectedFireDate = dueDate.addingTimeInterval(-Double(offset))

        #expect(
            abs(fireDate.timeIntervalSince(expectedFireDate)) < 1,
            "Fire date for date+time task should be dueDate minus offset"
        )
    }

    @Test("Date-only task due today is NOT treated as past")
    func dateOnlyTaskDueTodayIsNotPast() {
        // midnight UTC for today — raw value is in the past for most timezones
        let utcMidnight = makeMidnightUTC(daysFromNow: 0)
        let offset = 0 // at due time

        let fireDate = ReminderScheduler.computeFireDate(
            dueDate: utcMidnight,
            isDueDateOnly: true,
            reminderOffset: offset
        )

        // End-of-local-day should be in the future (unless it's 11:59 PM)
        // The key assertion: fire date should NOT equal midnight UTC
        let wrongFireDate = utcMidnight.addingTimeInterval(-Double(offset))

        // For any timezone behind UTC, the effective deadline (end of local day)
        // is different from midnight UTC
        let effectiveDeadline = DueDateHelper.effectiveDeadline(
            for: utcMidnight, isDateOnly: true
        )

        if effectiveDeadline != utcMidnight {
            #expect(
                fireDate != wrongFireDate,
                "Date-only fire date must differ from raw midnight UTC computation"
            )
        }
    }

    @Test("Zero offset fires at effective deadline")
    func zeroOffsetFiresAtDeadline() {
        let utcMidnight = makeMidnightUTC(daysFromNow: 1) // tomorrow
        let offset = 0

        let fireDate = ReminderScheduler.computeFireDate(
            dueDate: utcMidnight,
            isDueDateOnly: true,
            reminderOffset: offset
        )

        let expectedDeadline = DueDateHelper.effectiveDeadline(
            for: utcMidnight, isDateOnly: true
        )

        #expect(
            abs(fireDate.timeIntervalSince(expectedDeadline)) < 1,
            "Zero offset should fire exactly at the effective deadline"
        )
    }

    // MARK: - Helpers

    /// Creates a midnight UTC date for N days from now.
    private func makeMidnightUTC(daysFromNow: Int) -> Date {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let today = utcCal.startOfDay(for: Date())
        return utcCal.date(byAdding: .day, value: daysFromNow, to: today)!
    }
}
