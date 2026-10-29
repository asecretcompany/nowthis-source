import Foundation

/// The sorted equivalent of `ReminderScheduler.computeBadgeCount`.
///
/// `computeBadgeCount` answers "how many tasks count toward the app icon badge as of `now`?" by
/// walking every active task and doing calendar math on each one. `planNotifications` used to call
/// it once per planned entry — up to 60 times — which made building a plan O(60 × N) instead of
/// O(N): ≈170 ms at 1,650 tasks. Each task that can ever count toward the badge does so from a
/// single fixed instant onward — the earlier of its effective deadline and its reminder's fire
/// date, if it has one — so collecting those instants once, sorting them, and answering
/// `count(asOf:)` by binary search reduces the repeated work to O(N log N) + O(60 log N).
struct BadgeTimeline {

    /// The instant each countable task starts counting toward the badge, sorted ascending.
    private let times: [Date]

    /// Builds the timeline from `tasks`.
    ///
    /// A task contributes a badge time only when it has a `dueDate` and its status is neither
    /// `.completed` nor `.cancelled` — the same guard `computeBadgeCount` applies per task. That
    /// time is `DueDateHelper.effectiveDeadline(for:isDateOnly:)` (when the task becomes overdue),
    /// or the earlier of that and `ReminderScheduler.computeFireDate` when the task also has a
    /// `reminderOffset` (a reminder can fire before the deadline). This mirrors
    /// `computeBadgeCount`'s two checks — overdue, or reminder already fired — exactly: a task
    /// there counts iff `min(effectiveDeadline, fireDate)` has already passed.
    ///
    /// - Parameter allDayReminderMinutes: Forwarded to `computeFireDate` for date-only tasks.
    ///   Callers can pass the value captured for a projection generation; otherwise it reads the
    ///   live preference, matching `computeBadgeCount`'s default.
    init(
        inputs: [ReminderTaskInput],
        allDayReminderMinutes: Int = TaskDefaultsPreferences.allDayReminderMinutes,
        calendar: Calendar = .current
    ) {
        var times: [Date] = []
        times.reserveCapacity(inputs.count)

        for task in inputs {
            guard task.hasActiveStatus, !task.isDeletedLocally,
                  let due = task.dueDate else { continue }

            var badgeTime = DueDateHelper.effectiveDeadline(
                for: due, isDateOnly: task.isDueDateOnly, regionCalendar: calendar)
            if let offset = task.reminderOffset {
                let fireDate = ReminderScheduler.computeFireDate(
                    dueDate: due,
                    isDueDateOnly: task.isDueDateOnly,
                    reminderOffset: offset,
                    allDayReminderMinutes: allDayReminderMinutes,
                    calendar: calendar
                )
                badgeTime = min(badgeTime, fireDate)
            }
            times.append(badgeTime)
        }

        times.sort()
        self.times = times
    }

    /// Compatibility initializer for existing model-based callers and tests.
    init(
        tasks: [TaskItem],
        allDayReminderMinutes: Int = TaskDefaultsPreferences.allDayReminderMinutes,
        calendar: Calendar = .current
    ) {
        self.init(
            inputs: tasks.map(ReminderTaskInput.init(task:)),
            allDayReminderMinutes: allDayReminderMinutes,
            calendar: calendar
        )
    }

    /// The number of badge times at or before `date` — equivalent to
    /// `computeBadgeCount(tasks:now:)` for the tasks this timeline was built from.
    ///
    /// Binary search for the first time after `date`; everything before it is `<= date`.
    func count(asOf date: Date) -> Int {
        var low = 0
        var high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] <= date {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
