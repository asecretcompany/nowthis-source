import Foundation

/// How a new task's due date is defaulted at creation time.
///
/// Applied by ``NewTaskDefaults`` and configurable globally
/// (``TaskDefaultsPreferences``) or per-list (`TaskList.defaultDueDateRule`).
/// Resulting due dates are **date-only** (all-day) values — a new task never
/// assumes a due *time* unless the user sets one.
enum DefaultDueDateRule: String, CaseIterable, Identifiable, Sendable {
    /// No due date — matches the app's historical behavior.
    case none
    /// Due today.
    case today
    /// Due tomorrow.
    case tomorrow
    /// Due one week from today.
    case nextWeek

    var id: String { rawValue }

    /// User-facing label for settings pickers.
    var displayName: String {
        switch self {
        case .none:
            return String(localized: "defaultDueDate.none", defaultValue: "None",
                          comment: "New-task default due date: do not set one. Answers 'Default due date: ?'.")
        case .today:
            return String(localized: "defaultDueDate.today", defaultValue: "Today",
                          comment: "New-task default due date: today.")
        case .tomorrow:
            return String(localized: "defaultDueDate.tomorrow", defaultValue: "Tomorrow",
                          comment: "New-task default due date: tomorrow.")
        case .nextWeek:
            return String(localized: "defaultDueDate.nextWeek", defaultValue: "Next Week",
                          comment: "New-task default due date: one week from today.")
        }
    }

    /// Number of days from today this rule targets, or `nil` for `.none`.
    var dayOffset: Int? {
        switch self {
        case .none: return nil
        case .today: return 0
        case .tomorrow: return 1
        case .nextWeek: return 7
        }
    }
}
