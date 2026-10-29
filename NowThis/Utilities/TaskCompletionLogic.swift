import Foundation

/// Shared completion semantics used by the in-app completion coordinator and
/// the Watch edit path. Recurring tasks advance to the next occurrence instead
/// of completing; the sync push is driven by `isDirty`.
///
/// This is a verbatim extraction of the mutation logic that was previously
/// inlined in `TaskCompletionCoordinator.toggle(_:onStatusChanged:)` — the
/// animation sequencing, intent donation, widget reload, and status-changed
/// callback stay in the coordinator; only the field mutations moved here.
enum TaskCompletionLogic {
    /// Marks a task completed, unless it is recurring — in which case it is
    /// advanced to its next occurrence instead.
    ///
    /// - Returns: `true` when the task was recurring and advanced instead of
    ///   completing; `false` when it was marked completed.
    @discardableResult
    static func markCompleted(_ task: TaskItem, now: Date = Date()) -> Bool {
        // Check for recurring task — advance to next occurrence
        if let rrule = task.recurrenceRule,
           let rule = RecurrenceRule.parse(rrule),
           let currentDue = task.dueDate,
           let nextDue = rule.nextDate(after: currentDue) {
            // Reset to next occurrence instead of completing
            task.dueDate = nextDue
            task.status = .needsAction
            task.completedDate = nil
            task.percentComplete = 0
            if let startDate = task.startDate {
                let offset = nextDue.timeIntervalSince(currentDue)
                task.startDate = startDate.addingTimeInterval(offset)
            }
            task.lastModifiedDate = now
            task.isDirty = true
            return true
        }

        // Non-recurring: mark complete normally
        task.status = .completed
        task.completedDate = now
        task.percentComplete = 100
        task.lastModifiedDate = now
        task.isDirty = true
        return false
    }

    /// Applies an arbitrary status change, the way dragging a card between the
    /// Kanban board's columns does.
    ///
    /// The board used to hand-roll this, and the copy had drifted from the one
    /// above in two ways a user would notice. It advanced a recurring task's due
    /// date without shifting its start date, leaving the next occurrence starting
    /// on the day the last one finished. And nothing downstream learned that a
    /// task had been completed, so its reminders — the hourly nag included — went
    /// on firing; on a local-only Vault account the bulk sweep never runs, so
    /// they fired forever.
    ///
    /// - Returns: `true` when the task ended up genuinely completed, and its
    ///   reminders should therefore be cancelled. A recurring task that advanced
    ///   to its next occurrence returns `false`: it still wants them.
    @discardableResult
    static func apply(_ newStatus: TaskStatus, to task: TaskItem, now: Date = Date()) -> Bool {
        switch newStatus {
        case .completed:
            return !markCompleted(task, now: now)
        case .needsAction:
            markUncompleted(task, now: now)
        case .inProcess:
            task.status = newStatus
            task.completedDate = nil
            // 0 and 100 are the two values that mean "nobody has said" — a task
            // never started, or one being dragged back out of Done. Any figure
            // in between is the user's and is left alone.
            if task.percentComplete == 0 || task.percentComplete == 100 {
                task.percentComplete = 50
            }
            task.lastModifiedDate = now
            task.isDirty = true
        case .cancelled:
            task.status = newStatus
            task.completedDate = nil
            task.percentComplete = 0
            task.lastModifiedDate = now
            task.isDirty = true
        }
        return false
    }

    /// Reverts a task's completion fields to the not-completed state.
    static func markUncompleted(_ task: TaskItem, now: Date = Date()) {
        task.status = .needsAction
        task.completedDate = nil
        task.percentComplete = 0
        task.lastModifiedDate = now
        task.isDirty = true
    }
}
