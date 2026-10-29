import Foundation

/// One projection per display pass; day lookups do not scan the task collection.
struct CalendarTaskProjection {
    struct Bucket {
        var rows: [TaskGlanceRow] = []
        var highestPriority: TaskPriority?
    }
    private let calendar: Calendar
    private let now: Date
    private var days: [Date: Bucket] = [:]
    var overdueRows: [TaskGlanceRow] = []

    init(rows: [TaskGlanceRow], calendar: Calendar = .current, now: Date = Date()) {
        self.calendar = calendar
        self.now = now
        let interval = PerformanceTrace.begin("CalendarBuckets", count: rows.count)
        defer { PerformanceTrace.end("CalendarBuckets", interval) }
        for row in rows {
            guard let due = row.data.dueDate else { continue }
            let day = DueDateHelper.localStartOfDay(for: due, isDateOnly: row.data.isDueDateOnly,
                                                    regionCalendar: calendar)
            days[day, default: Bucket()].rows.append(row)
            if row.data.priority != .none {
                let current = days[day]?.highestPriority
                days[day]?.highestPriority = current.map { min($0, row.data.priority) } ?? row.data.priority
            }
            if row.data.status != .completed && row.data.status != .cancelled,
               now >= DueDateHelper.effectiveDeadline(for: due, isDateOnly: row.data.isDueDateOnly,
                                                      regionCalendar: calendar) {
                overdueRows.append(row)
            }
        }
    }

    func bucket(on date: Date) -> Bucket {
        days[calendar.startOfDay(for: date)] ?? Bucket()
    }

    func isToday(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: now) }
}
