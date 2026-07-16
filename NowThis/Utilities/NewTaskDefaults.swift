import Foundation

/// Resolves the initial due date and reminder for a newly created task from the
/// current view context and the user's default settings.
///
/// This is the single source of truth shared by the inline add bar and the Quick
/// Add sheet, so a task created anywhere behaves identically. The core
/// ``resolve(smartList:rule:reminderEnabled:now:calendar:)`` is pure and fully
/// injectable; the convenience overload reads per-list and global preferences.
enum NewTaskDefaults {

    /// The initial field values to stamp onto a new `TaskItem`.
    struct Resolved: Equatable {
        var dueDate: Date?
        var isDueDateOnly: Bool
        /// Seconds before the (all-day–anchored) deadline to fire a reminder,
        /// or `nil` for no reminder.
        var reminderOffset: Int?
    }

    /// Resolves defaults from an explicit rule (pure — no `UserDefaults` access).
    ///
    /// - Parameters:
    ///   - smartList: The smart list currently in view, if any. `.today`
    ///     contextually forces a due-today date so the new task stays visible in
    ///     the list it was created in, regardless of the configured rule.
    ///   - rule: The effective default due-date rule (the caller resolves any
    ///     per-list override against the global default first).
    ///   - reminderEnabled: Whether a task that receives a due date also gets a
    ///     default reminder.
    ///   - dueTimeMinutes: The default due time (minutes since local midnight) to
    ///     bake onto the due date. Defaults to the global ``TaskDefaultsPreferences``
    ///     value; injectable for tests.
    ///   - now: The current date (injectable for tests).
    ///   - calendar: The calendar used to derive the local calendar date.
    static func resolve(
        smartList: SmartList?,
        rule: DefaultDueDateRule,
        reminderEnabled: Bool,
        dueTimeMinutes: Int = TaskDefaultsPreferences.dueTimeMinutes,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Resolved {
        // Contextual override: creating a task while viewing Today always yields a
        // due-today task so it remains visible in the view that created it.
        let effectiveRule: DefaultDueDateRule = (smartList == .today) ? .today : rule

        guard let dayOffset = effectiveRule.dayOffset,
              let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: now) else {
            return Resolved(dueDate: nil, isDueDateOnly: false, reminderOffset: nil)
        }

        // Bake the configured default due time onto the target day so the new task
        // is a real *timed* task — its row shows a clock time instead of "All day".
        // Users can switch it back to all-day from the task editor.
        let dueDate = DueDateHelper.timedValue(
            for: targetDay, minutesSinceMidnight: dueTimeMinutes, calendar: calendar
        )
        // Default reminders are opt-in; when enabled offset 0 fires at the due time.
        let reminderOffset: Int? = reminderEnabled ? 0 : nil

        return Resolved(dueDate: dueDate, isDueDateOnly: false, reminderOffset: reminderOffset)
    }

    /// Resolves defaults for a new task in `list`, reading per-list overrides and
    /// falling back to the global ``TaskDefaultsPreferences``.
    static func resolve(
        smartList: SmartList?,
        list: TaskList?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Resolved {
        resolve(
            smartList: smartList,
            rule: effectiveDueDateRule(for: list),
            reminderEnabled: effectiveReminderEnabled(for: list),
            now: now,
            calendar: calendar
        )
    }

    /// The due-date rule that applies to `list`: its override, or the global default.
    static func effectiveDueDateRule(for list: TaskList?) -> DefaultDueDateRule {
        list?.defaultDueDateRule ?? TaskDefaultsPreferences.globalDueDateRule
    }

    /// Whether default reminders apply to new tasks in `list`: its override, or global.
    static func effectiveReminderEnabled(for list: TaskList?) -> Bool {
        list?.defaultReminderEnabledOverride ?? TaskDefaultsPreferences.isDefaultReminderEnabled
    }
}

// MARK: - Per-List Typed Accessors

/// Typed accessors over `TaskList`'s raw string override columns. Kept in the
/// app target (not the `@Model`) so the widget's copy of the model stays free of
/// any dependency on ``DefaultDueDateRule``.
extension TaskList {

    /// Per-list default due-date rule override. `nil` = use the global default.
    var defaultDueDateRule: DefaultDueDateRule? {
        get { defaultDueDateRuleRaw.flatMap(DefaultDueDateRule.init(rawValue:)) }
        set { defaultDueDateRuleRaw = newValue?.rawValue }
    }

    /// Per-list default-reminder override. `nil` = use the global setting;
    /// `true`/`false` = force reminders on/off for new tasks in this list.
    var defaultReminderEnabledOverride: Bool? {
        get {
            switch defaultReminderModeRaw {
            case "on": return true
            case "off": return false
            default: return nil
            }
        }
        set { defaultReminderModeRaw = newValue.map { $0 ? "on" : "off" } }
    }
}
