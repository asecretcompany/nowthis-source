import Testing
import Foundation

@testable import NowThis

@Suite("New Task Defaults Resolver")
struct NewTaskDefaultsTests {

    private let calendar = Calendar.current
    private var now: Date { Date() }

    /// A fixed default due time (9:00 AM) used by the timed-due-date tests so they
    /// don't depend on the device's stored preference.
    private let nineAM = 9 * 60

    // MARK: - Rule → Due Date

    @Test("None rule yields no due date and no reminder")
    func noneRuleYieldsNothing() {
        let resolved = NewTaskDefaults.resolve(
            smartList: nil, rule: .none, reminderEnabled: false,
            dueTimeMinutes: nineAM, now: now, calendar: calendar
        )
        #expect(resolved.dueDate == nil)
        #expect(resolved.isDueDateOnly == false)
        #expect(resolved.reminderOffset == nil)
    }

    @Test("Today rule yields a timed due date on today at the default due time")
    func todayRuleIsDueTodayAtDefaultTime() {
        let resolved = NewTaskDefaults.resolve(
            smartList: nil, rule: .today, reminderEnabled: false,
            dueTimeMinutes: nineAM, now: now, calendar: calendar
        )
        let due = try! #require(resolved.dueDate)
        // Quick due dates now produce a real time so the row shows a clock time,
        // not "All day".
        #expect(resolved.isDueDateOnly == false)
        #expect(calendar.isDate(due, inSameDayAs: now))
        let comps = calendar.dateComponents([.hour, .minute], from: due)
        #expect(comps.hour == 9)
        #expect(comps.minute == 0)
    }

    @Test("Tomorrow rule yields a timed due date on tomorrow")
    func tomorrowRuleIsDueTomorrow() {
        let resolved = NewTaskDefaults.resolve(
            smartList: nil, rule: .tomorrow, reminderEnabled: false,
            dueTimeMinutes: nineAM, now: now, calendar: calendar
        )
        let due = try! #require(resolved.dueDate)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        #expect(resolved.isDueDateOnly == false)
        #expect(calendar.isDate(due, inSameDayAs: tomorrow))
    }

    @Test("Next week rule yields a timed due date seven days out")
    func nextWeekRuleIsSevenDaysOut() {
        let resolved = NewTaskDefaults.resolve(
            smartList: nil, rule: .nextWeek, reminderEnabled: false,
            dueTimeMinutes: nineAM, now: now, calendar: calendar
        )
        let due = try! #require(resolved.dueDate)
        let sevenDays = calendar.date(byAdding: .day, value: 7, to: now)!
        #expect(resolved.isDueDateOnly == false)
        #expect(calendar.isDate(due, inSameDayAs: sevenDays))
    }

    @Test("Due time honors the configured default due time")
    func dueTimeHonorsConfiguredMinutes() {
        let fivePM = 17 * 60
        let resolved = NewTaskDefaults.resolve(
            smartList: nil, rule: .today, reminderEnabled: false,
            dueTimeMinutes: fivePM, now: now, calendar: calendar
        )
        let due = try! #require(resolved.dueDate)
        let comps = calendar.dateComponents([.hour, .minute], from: due)
        #expect(comps.hour == 17)
        #expect(comps.minute == 0)
    }

    // MARK: - Contextual Override (the disappearing-task fix)

    @Test("Creating in Today forces due-today even when the rule is None")
    func todayContextOverridesNoneRule() {
        let resolved = NewTaskDefaults.resolve(
            smartList: .today, rule: .none, reminderEnabled: false,
            dueTimeMinutes: nineAM, now: now, calendar: calendar
        )
        let due = try! #require(resolved.dueDate, "A task made in Today must get a due date so it stays visible")
        #expect(resolved.isDueDateOnly == false)
        #expect(calendar.isDate(due, inSameDayAs: now))
    }

    @Test("Today context overrides a different configured rule")
    func todayContextOverridesOtherRule() {
        let resolved = NewTaskDefaults.resolve(
            smartList: .today, rule: .nextWeek, reminderEnabled: false,
            dueTimeMinutes: nineAM, now: now, calendar: calendar
        )
        let due = try! #require(resolved.dueDate)
        #expect(calendar.isDate(due, inSameDayAs: now))
    }

    @Test("Non-Today smart lists do not force a date")
    func nonTodaySmartListUsesRule() {
        let resolved = NewTaskDefaults.resolve(
            smartList: .all, rule: .none, reminderEnabled: false,
            dueTimeMinutes: nineAM, now: now, calendar: calendar
        )
        #expect(resolved.dueDate == nil)
    }

    // MARK: - Reminders

    @Test("Reminder enabled with a due date sets a zero offset")
    func reminderEnabledSetsOffsetWhenDue() {
        let resolved = NewTaskDefaults.resolve(
            smartList: nil, rule: .today, reminderEnabled: true,
            dueTimeMinutes: nineAM, now: now, calendar: calendar
        )
        #expect(resolved.reminderOffset == 0)
    }

    @Test("Reminder enabled without a due date sets no reminder")
    func reminderEnabledButNoDueDateHasNoOffset() {
        let resolved = NewTaskDefaults.resolve(
            smartList: nil, rule: .none, reminderEnabled: true,
            dueTimeMinutes: nineAM, now: now, calendar: calendar
        )
        #expect(resolved.reminderOffset == nil)
    }
}

@Suite("Task Defaults Preferences")
struct TaskDefaultsPreferencesTests {

    @Test("Default due time falls back to 9:00 AM when unset")
    func dueTimeMinutesFallsBackToNineAM() {
        UserDefaults.standard.removeObject(forKey: TaskDefaultsPreferences.dueTimeMinutesKey)
        #expect(TaskDefaultsPreferences.defaultDueTimeMinutes == 540)
        #expect(TaskDefaultsPreferences.dueTimeMinutes == 540)
    }
}

@Suite("DueDateHelper Date-Only Construction")
struct DueDateHelperDateOnlyTests {

    @Test("dateOnlyValue round-trips the local calendar day")
    func dateOnlyValueRoundTrips() {
        let today = Date()
        let value = DueDateHelper.dateOnlyValue(for: today)
        #expect(DueDateHelper.isOnDay(value, isDateOnly: true, sameAs: today))
    }

    @Test("localStartOfDay for a date-only value is local midnight of that day")
    func localStartOfDayForDateOnly() {
        let today = Date()
        let value = DueDateHelper.dateOnlyValue(for: today)
        let start = DueDateHelper.localStartOfDay(for: value, isDateOnly: true)

        var localCal = Calendar.current
        localCal.timeZone = .current
        #expect(start == localCal.startOfDay(for: today))
    }

    // MARK: - Timed Construction & All-Day ↔ Timed Conversion (editor toggle)

    @Test("timedValue builds a local datetime at the given minutes on the same day")
    func timedValueBuildsLocalDatetime() {
        let today = Date()
        let value = DueDateHelper.timedValue(for: today, minutesSinceMidnight: 9 * 60)
        let cal = Calendar.current
        #expect(cal.isDate(value, inSameDayAs: today))
        let comps = cal.dateComponents([.hour, .minute], from: value)
        #expect(comps.hour == 9)
        #expect(comps.minute == 0)
    }

    @Test("Toggling a timed due date to all-day preserves the calendar day")
    func timedToAllDayPreservesDay() {
        // A timed value at 5 PM today, converted to a date-only value.
        let timed = DueDateHelper.timedValue(for: Date(), minutesSinceMidnight: 17 * 60)
        let dateOnly = DueDateHelper.dateOnlyValue(for: timed)
        #expect(DueDateHelper.isOnDay(dateOnly, isDateOnly: true, sameAs: timed))
    }

    @Test("Toggling an all-day due date to timed restores a local time on the same day")
    func allDayToTimedRestoresLocalTime() {
        let cal = Calendar.current
        let dateOnly = DueDateHelper.dateOnlyValue(for: Date())
        let localDay = DueDateHelper.localStartOfDay(for: dateOnly, isDateOnly: true)
        let timed = DueDateHelper.timedValue(for: localDay, minutesSinceMidnight: 9 * 60)
        #expect(cal.isDate(timed, inSameDayAs: localDay))
        let comps = cal.dateComponents([.hour, .minute], from: timed)
        #expect(comps.hour == 9)
        #expect(comps.minute == 0)
    }
}
