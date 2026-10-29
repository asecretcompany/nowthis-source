import Foundation

/// The four smart lists the watch surfaces, as pure predicates over `WatchTask`.
/// Lives in `NowThis/Watch/` (compiled into the iOS app, the watch app, and
/// `NowThisTests`) so the rules are unit-tested on iOS. `WatchTodayView`,
/// `WatchListsView`, and `WatchListDetailView` all render
/// `bridge.displayTasks.filter { list.includes($0, now:) }` and never restate
/// the rules. Semantics mirror the iOS `SmartList` cases
/// (`TaskListView.filterForSmartList` / `TaskListFilter.shouldIncludeInToday`).
enum WatchSmartList: String, CaseIterable, Identifiable {
    case today, overdue, upcoming, all

    var id: String { rawValue }

    /// Display only. This file is compiled into three targets, so each of these keys exists
    /// separately in three catalogs and must be translated in all three.
    var title: String {
        switch self {
        case .today:
            return String(localized: "watch.smartlist.today", defaultValue: "Today",
                          comment: "Apple Watch list name: tasks due today. Very tight width budget.")
        case .overdue:
            return String(localized: "watch.smartlist.overdue", defaultValue: "Overdue",
                          comment: "Apple Watch list name: tasks past their due date. Very tight width budget.")
        case .upcoming:
            return String(localized: "watch.smartlist.upcoming", defaultValue: "Upcoming",
                          comment: "Apple Watch list name: tasks due in the next 7 days. Very tight width budget.")
        case .all:
            return String(localized: "watch.smartlist.all", defaultValue: "All",
                          comment: "Apple Watch list name: every active task. Very tight width budget — one short word.")
        }
    }

    /// Whether `task` belongs in this list at `now`. Completed tasks are never
    /// included (there is no `.completed` case here). Date basis matches iOS:
    /// `today`/`overdue` use `DueDateHelper.effectiveDeadline`; `upcoming` uses
    /// the raw `dueDate` against a 7-day window.
    func includes(_ task: WatchTask, now: Date = Date()) -> Bool {
        guard !task.isCompleted else { return false }
        switch self {
        case .all:
            return true
        case .today:
            guard let due = task.dueDate else { return false }
            let endOfToday = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
            return DueDateHelper.effectiveDeadline(for: due, isDateOnly: task.isDueDateOnly) <= endOfToday
        case .overdue:
            guard let due = task.dueDate else { return false }
            return now >= DueDateHelper.effectiveDeadline(for: due, isDateOnly: task.isDueDateOnly)
        case .upcoming:
            guard let due = task.dueDate else { return false }
            return due >= now && due <= now.addingTimeInterval(7 * 86_400)
        }
    }

    func filter(_ tasks: [WatchTask], now: Date = Date()) -> [WatchTask] {
        tasks.filter { includes($0, now: now) }
    }
}
