import Foundation

/// The display layer of `RecurrenceRule`, kept apart from the parsing and
/// next-occurrence arithmetic in `RecurrenceRule.swift`.
///
/// The split is a build-target boundary, not a style preference. `NowThisWidget`
/// compiles `RecurrenceRule.swift` so `CompleteTaskIntent` can advance a
/// repeating task, and every `String(localized:)` in a file a target compiles
/// mints a key in *that* target's catalog. Leaving these nine keys in the shared
/// file would have put nine strings the widget never renders into
/// `NowThisWidget/Localizable.xcstrings`, each owing five translations.
/// `DueDateHelper.swift`, the other shared utility, carries no copy for the
/// same reason.
extension RecurrenceRule.Frequency {

    /// Display only. `rawValue` is the RFC-5545 `FREQ=` token and must never be localized.
    var displayName: String {
        switch self {
        case .daily:
            return String(localized: "recurrence.frequency.daily", defaultValue: "Daily",
                          comment: "Recurrence frequency: repeats every day. Adjective/adverb answering 'Repeats: ?'.")
        case .weekly:
            return String(localized: "recurrence.frequency.weekly", defaultValue: "Weekly",
                          comment: "Recurrence frequency: repeats every week.")
        case .monthly:
            return String(localized: "recurrence.frequency.monthly", defaultValue: "Monthly",
                          comment: "Recurrence frequency: repeats every month.")
        case .yearly:
            return String(localized: "recurrence.frequency.yearly", defaultValue: "Yearly",
                          comment: "Recurrence frequency: repeats every year.")
        }
    }
}

extension RecurrenceRule {

    /// Human-readable description of the recurrence.
    ///
    /// The counted branch shares the four `recurrence.custom.interval.*` keys with the stepper in
    /// `TaskDetailView` — the same sentence in the same place in the UI, so the same key, and the
    /// plural forms live in the catalog rather than in an `interval == 1` test here.
    func displayText(in calendar: Calendar = .current) -> String {
        var text: String
        if interval == 1 {
            text = frequency.displayName
        } else {
            switch frequency {
            case .daily:
                text = String(localized: "recurrence.custom.interval.daily",
                              defaultValue: "Every \(interval) days",
                              comment: "Label on the stepper that sets how often a task repeats, for a daily rule. The placeholder is the interval in days.")
            case .weekly:
                text = String(localized: "recurrence.custom.interval.weekly",
                              defaultValue: "Every \(interval) weeks",
                              comment: "Label on the stepper that sets how often a task repeats, for a weekly rule. The placeholder is the interval in weeks.")
            case .monthly:
                text = String(localized: "recurrence.custom.interval.monthly",
                              defaultValue: "Every \(interval) months",
                              comment: "Label on the stepper that sets how often a task repeats, for a monthly rule. The placeholder is the interval in months.")
            case .yearly:
                text = String(localized: "recurrence.custom.interval.yearly",
                              defaultValue: "Every \(interval) years",
                              comment: "Label on the stepper that sets how often a task repeats, for a yearly rule. The placeholder is the interval in years.")
            }
        }

        if !byDay.isEmpty && frequency == .weekly {
            let dayNames = byDay.map { $0.shortName(in: calendar) }.joined(separator: ", ")
            text = String(localized: "recurrence.displayText.onDays",
                          defaultValue: "\(text) on \(dayNames)",
                          comment: "Describes a weekly repeat restricted to certain weekdays, e.g. 'Weekly on Mon, Wed'. First placeholder is the already-localized frequency, second is the abbreviated weekday names joined with commas.")
        }

        return text
    }

    /// Convenience for call sites that render in the user's current locale.
    var displayText: String { displayText(in: .current) }
}
