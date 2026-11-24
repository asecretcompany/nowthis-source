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
        let anchor = expectedClock(on: utcMidnight, minutes: TaskDefaultsPreferences.defaultAllDayReminderMinutes)
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

        let expected = expectedClock(on: utcMidnight, minutes: customMinutes)

        #expect(abs(fireDate.timeIntervalSince(expected)) < 1)
    }

    @Test("Day-before offset fires 24 elapsed hours before the all-day anchor")
    func dateOnlyDayBeforeOffset() {
        let utcMidnight = makeMidnightUTC(daysFromNow: 2)
        let dayBefore = 86400 // 1 day before the anchor

        let fireDate = ReminderScheduler.computeFireDate(
            dueDate: utcMidnight,
            isDueDateOnly: true,
            reminderOffset: dayBefore
        )

        let anchor = expectedClock(on: utcMidnight, minutes: TaskDefaultsPreferences.defaultAllDayReminderMinutes)
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

        let expectedAnchor = expectedClock(on: utcMidnight, minutes: TaskDefaultsPreferences.defaultAllDayReminderMinutes)

        #expect(
            abs(fireDate.timeIntervalSince(expectedAnchor)) < 1,
            "Zero offset should fire exactly at the all-day anchor time (9 AM local)"
        )
    }

    // MARK: - Helpers

    private func expectedClock(on storedDay: Date, minutes: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var components = utc.dateComponents([.year, .month, .day], from: storedDay)
        components.hour = minutes / 60
        components.minute = minutes % 60
        return DueDateHelper.localCalendar().date(from: components)!
    }

    /// Creates a midnight UTC date relative to a fixed ordinary day.
    private func makeMidnightUTC(daysFromNow: Int) -> Date {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let today = utcCal.date(from: DateComponents(year: 2026, month: 11, day: 3))!
        return utcCal.date(byAdding: .day, value: daysFromNow, to: today)!
    }
}


@Suite("Civil Due Time DST Regressions")
struct CivilDueTimeDSTTests {
    static let days: [(String, Int, Int)] = [
        ("America/Los_Angeles", 3, 8), ("America/Los_Angeles", 11, 1),
        ("Europe/Berlin", 3, 29), ("Europe/Berlin", 10, 25),
        ("Australia/Lord_Howe", 4, 5), ("Australia/Lord_Howe", 10, 4),
        ("UTC", 3, 8), ("America/Los_Angeles", 11, 3)
    ]

    @Test("Due times and all-day anchors preserve wall clock across transitions")
    func civilClockMatrix() {
        for (zone, month, day) in Self.days {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            let noon = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
            let storedDay = DueDateHelper.dateOnlyValue(for: noon, calendar: calendar)
            for minutes in [0, 540, 1020, 1439] {
                let expected = calendar.date(from: DateComponents(year: 2026, month: month, day: day,
                                                                 hour: minutes / 60, minute: minutes % 60))!
                #expect(DueDateHelper.timedValue(for: noon, minutesSinceMidnight: minutes, calendar: calendar) == expected,
                        "Due clock: \(zone) \(month)/\(day) \(minutes)")
                let anchor = ReminderScheduler.computeFireDate(dueDate: storedDay, isDueDateOnly: true,
                    reminderOffset: 0, allDayReminderMinutes: minutes, calendar: calendar)
                #expect(anchor == expected, "Reminder clock: \(zone) \(month)/\(day) \(minutes)")
                for identifier in [Calendar.Identifier.buddhist, .japanese, .hebrew, .islamic] {
                    var region = Calendar(identifier: identifier)
                    region.timeZone = calendar.timeZone
                    #expect(DueDateHelper.timedValue(for: noon, minutesSinceMidnight: minutes, calendar: region) == expected)
                    #expect(ReminderScheduler.computeFireDate(dueDate: storedDay, isDueDateOnly: true,
                        reminderOffset: 0, allDayReminderMinutes: minutes, calendar: region) == expected)
                }
                let earlier = ReminderScheduler.computeFireDate(dueDate: storedDay, isDueDateOnly: true,
                    reminderOffset: 86400, allDayReminderMinutes: minutes, calendar: calendar)
                #expect(earlier == expected.addingTimeInterval(-86400))
                #expect(ReminderScheduler.computeFireDate(dueDate: expected, isDueDateOnly: false,
                    reminderOffset: 3600, calendar: calendar) == expected.addingTimeInterval(-3600))
            }
        }
    }

    @Test("Nonexistent civil time advances to next valid time and fold chooses first occurrence")
    func gapAndFoldPolicy() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let spring = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12, second: 45))!
        let fall = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12, second: 45))!
        let formatter = ISO8601DateFormatter()
        let gap = formatter.date(from: "2026-03-08T10:00:00Z")!
        let fold = formatter.date(from: "2026-11-01T08:30:00Z")!
        let secondFold = formatter.date(from: "2026-11-01T09:30:00Z")!
        for occurrence in [fold, secondFold] {
            #expect(ReminderScheduler.computeFireDate(dueDate: occurrence, isDueDateOnly: false,
                reminderOffset: 0, calendar: calendar) == occurrence)
            #expect(ReminderScheduler.computeFireDate(dueDate: occurrence, isDueDateOnly: false,
                reminderOffset: 1800, calendar: calendar) == occurrence.addingTimeInterval(-1800))
        }
        #expect(DueDateHelper.timedValue(for: spring, minutesSinceMidnight: 150, calendar: calendar) == gap)
        #expect(DueDateHelper.timedValue(for: fall, minutesSinceMidnight: 90, calendar: calendar) == fold)
        for (day, minutes, expected) in [(spring, 150, gap), (fall, 90, fold)] {
            #expect(ReminderScheduler.computeFireDate(
                dueDate: DueDateHelper.dateOnlyValue(for: day, calendar: calendar), isDueDateOnly: true,
                reminderOffset: 0, allDayReminderMinutes: minutes, calendar: calendar) == expected)
        }
    }
}
