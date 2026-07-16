import Testing
import Foundation

@testable import NowThis

@Suite("ReminderScheduler Fire Date")
struct ReminderSchedulerFireDateTests {

    // MARK: - Date-Only Fire Date Tests

    @Test("Date-only task fire date anchors to the all-day time, not end-of-day")
    func dateOnlyFireDateUsesAllDayTime() {
        // A date-only task stored as midnight UTC for "today"
        let utcMidnight = makeMidnightUTC(daysFromNow: 0)
        let offset = 3600 // 1 hour before the anchor

        let fireDate = ReminderScheduler.computeFireDate(
            dueDate: utcMidnight,
            isDueDateOnly: true,
            reminderOffset: offset
        )

        // The default anchor is 9:00 AM local (540 minutes) on the due day.
        let anchor = DueDateHelper.localStartOfDay(for: utcMidnight, isDateOnly: true)
            .addingTimeInterval(Double(TaskDefaultsPreferences.defaultAllDayReminderMinutes) * 60)
        let expectedFireDate = anchor.addingTimeInterval(-Double(offset))

        #expect(
            abs(fireDate.timeIntervalSince(expectedFireDate)) < 1,
            "Fire date should be the all-day anchor (9 AM local) minus offset"
        )
    }

    @Test("Date-only all-day time is configurable")
    func dateOnlyFireDateHonorsConfiguredTime() {
        let utcMidnight = makeMidnightUTC(daysFromNow: 0)
        let customMinutes = 8 * 60 + 30 // 8:30 AM

        let fireDate = ReminderScheduler.computeFireDate(
            dueDate: utcMidnight,
            isDueDateOnly: true,
            reminderOffset: 0,
            allDayReminderMinutes: customMinutes
        )

        let expected = DueDateHelper.localStartOfDay(for: utcMidnight, isDateOnly: true)
            .addingTimeInterval(Double(customMinutes) * 60)

        #expect(abs(fireDate.timeIntervalSince(expected)) < 1)
    }

    @Test("Day-before offset fires at the all-day time on the previous day")
    func dateOnlyDayBeforeOffset() {
        let utcMidnight = makeMidnightUTC(daysFromNow: 2)
        let dayBefore = 86400 // 1 day before the anchor

        let fireDate = ReminderScheduler.computeFireDate(
            dueDate: utcMidnight,
            isDueDateOnly: true,
            reminderOffset: dayBefore
        )

        let anchor = DueDateHelper.localStartOfDay(for: utcMidnight, isDateOnly: true)
            .addingTimeInterval(Double(TaskDefaultsPreferences.defaultAllDayReminderMinutes) * 60)
        let expected = anchor.addingTimeInterval(-Double(dayBefore))

        #expect(abs(fireDate.timeIntervalSince(expected)) < 1)
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

    @Test("Zero offset fires at the all-day anchor time")
    func zeroOffsetFiresAtAllDayAnchor() {
        let utcMidnight = makeMidnightUTC(daysFromNow: 1) // tomorrow
        let offset = 0

        let fireDate = ReminderScheduler.computeFireDate(
            dueDate: utcMidnight,
            isDueDateOnly: true,
            reminderOffset: offset
        )

        let expectedAnchor = DueDateHelper.localStartOfDay(for: utcMidnight, isDateOnly: true)
            .addingTimeInterval(Double(TaskDefaultsPreferences.defaultAllDayReminderMinutes) * 60)

        #expect(
            abs(fireDate.timeIntervalSince(expectedAnchor)) < 1,
            "Zero offset should fire exactly at the all-day anchor time (9 AM local)"
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
