import Foundation

/// User preferences that control how a new task is defaulted — its due date and
/// whether it gets a reminder — plus the time-of-day all-day reminders fire.
///
/// Backed by `UserDefaults` so both the SwiftUI settings screens and the
/// non-SwiftUI ``NewTaskDefaults`` / ``ReminderScheduler`` read the same values.
/// Per-list overrides live on `TaskList`; these are the global fallbacks.
struct TaskDefaultsPreferences {

    // MARK: - Keys

    static let dueDateRuleKey = "defaultDueDateRule"
    static let reminderEnabledKey = "defaultReminderEnabled"
    static let allDayReminderMinutesKey = "allDayReminderMinutes"
    static let dueTimeMinutesKey = "defaultDueTimeMinutes"

    /// Default all-day reminder time: 9:00 AM, expressed as minutes since local
    /// midnight. Matches the platform convention (Apple Reminders defaults to 9 AM).
    static let defaultAllDayReminderMinutes = 540

    /// Default due time stamped onto a new task's due date when a quick due-date
    /// rule (Today/Tomorrow/Next Week) is applied: 9:00 AM, expressed as minutes
    /// since local midnight. Kept separate from the all-day *reminder* time so the
    /// due time and the reminder fire time can be configured independently.
    static let defaultDueTimeMinutes = 540

    // MARK: - Read

    /// Global default due-date rule for new tasks. Defaults to `.none` so the
    /// app's out-of-the-box behavior (no due date unless specified) is unchanged.
    static var globalDueDateRule: DefaultDueDateRule {
        let raw = UserDefaults.standard.string(forKey: dueDateRuleKey)
        return raw.flatMap(DefaultDueDateRule.init(rawValue:)) ?? .none
    }

    /// Whether new tasks that get a due date also get a default reminder.
    /// Defaults to `false` (reminders stay opt-in — no notification spam).
    static var isDefaultReminderEnabled: Bool {
        UserDefaults.standard.bool(forKey: reminderEnabledKey)
    }

    /// Time-of-day, in minutes since local midnight, that all-day (date-only)
    /// reminders fire. Defaults to 9:00 AM.
    static var allDayReminderMinutes: Int {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: allDayReminderMinutesKey) == nil {
            return defaultAllDayReminderMinutes
        }
        return defaults.integer(forKey: allDayReminderMinutesKey)
    }

    /// Time-of-day, in minutes since local midnight, stamped onto a new task's due
    /// date when a quick due-date rule is applied. Defaults to 9:00 AM. Because the
    /// value is baked into the due date, the resulting task is a real timed task
    /// (not date-only), so its row shows a clock time rather than "All day".
    static var dueTimeMinutes: Int {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: dueTimeMinutesKey) == nil {
            return defaultDueTimeMinutes
        }
        return defaults.integer(forKey: dueTimeMinutesKey)
    }
}
