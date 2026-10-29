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

    /// The list new tasks go into when the user isn't already viewing one.
    static let defaultListIDKey = "defaultNewTaskListID"

    /// What ``defaultListIDKey`` was called when it only governed Siri. Read once
    /// per install by ``defaultListID`` and copied forward; never written.
    static let legacySiriListIDKey = "defaultSiriListID"

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

    /// The stored default-list ID, or `nil` when the user has never chosen one.
    ///
    /// Migrates ``legacySiriListIDKey`` forward on first read, so a user who set a
    /// Siri list before this preference was widened keeps it.
    ///
    /// Empty strings count as absent on both keys, and that is not defensiveness:
    /// the picker this replaced tagged its "First List" row with `""`, so a user who
    /// deliberately chose the abstract option has an empty string stored rather than
    /// a missing key. A `nil` check alone cannot tell "opted out" from "never set",
    /// and both have to mean "pick one for me".
    static var defaultListID: String? {
        let defaults = UserDefaults.standard
        if let current = defaults.string(forKey: defaultListIDKey), !current.isEmpty {
            return current
        }
        guard let legacy = defaults.string(forKey: legacySiriListIDKey), !legacy.isEmpty else {
            return nil
        }
        defaults.set(legacy, forKey: defaultListIDKey)
        return legacy
    }

    /// Stores the default-list ID. `nil` clears it, returning the app to "adopt one".
    static func setDefaultListID(_ id: String?) {
        let defaults = UserDefaults.standard
        if let id, !id.isEmpty {
            defaults.set(id, forKey: defaultListIDKey)
        } else {
            defaults.removeObject(forKey: defaultListIDKey)
        }
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
