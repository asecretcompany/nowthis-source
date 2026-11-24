import Foundation

/// The add screen's explicit date and quick presets share one submission boundary.
struct WatchAddDueSelection {
    private(set) var retainedDate: Date?
    private var rule: DefaultDueDateRule = .none

    init(retainedDate: Date? = nil) {
        self.retainedDate = retainedDate
    }

    var selectedPreset: DefaultDueDateRule? { retainedDate == nil ? rule : nil }

    mutating func select(_ preset: DefaultDueDateRule) {
        rule = preset
        retainedDate = nil
    }

    mutating func removeDate() {
        retainedDate = nil
        rule = .none
    }

    func retainedDateForDisplay(calendar: Calendar = .current) -> Date? {
        retainedDate.map { DueDateHelper.localStartOfDay(for: $0, isDateOnly: true, regionCalendar: calendar) }
    }

    func resolvedDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        if let retainedDate { return retainedDate }
        guard let offset = rule.dayOffset,
              let day = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
        return DueDateHelper.dateOnlyValue(for: day, calendar: calendar)
    }
}
