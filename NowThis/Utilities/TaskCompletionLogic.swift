import Foundation

/// Shared completion semantics used by the in-app completion coordinator and
/// the Watch edit path. Recurring tasks advance to the next occurrence instead
/// of completing; the sync push is driven by `isDirty`.
///
/// Unsupported recurrence is rejected before any field changes. Animation,
/// intent donation, saving, and reminder effects remain with the callers.
enum TaskCompletionLogic {
    enum Completion {
        case finished
        case advance(due: Date, start: Date?)
    }

    enum CompletionError: LocalizedError, CustomLocalizedStringResourceConvertible {
        case unsupportedRecurrence

        var localizedStringResource: LocalizedStringResource {
            "NowThis cannot complete tasks with this repeat rule. The task has not been changed."
        }

        var errorDescription: String? { String(localized: localizedStringResource) }
    }

    /// Marks a task completed, unless it is recurring — in which case it is
    /// advanced to its next occurrence instead.
    ///
    /// - Returns: `true` when the task was recurring and advanced instead of
    ///   completing; `false` when it was marked completed.
    @discardableResult
    static func markCompleted(_ task: TaskItem, now: Date = Date()) throws -> Bool {
        apply(try completion(for: task), to: task, now: now)
    }

    static func completion(for task: TaskItem) throws -> Completion {
        if let raw = task.recurrenceRule, !raw.isEmpty {
            guard let rule = RecurrenceRule.parse(raw), rule.count == nil else {
                // COUNT needs lifetime occurrence history, which this task does
                // not store. Preserve the imported rule and all fields instead
                // of repeatedly advancing with completionCount == 0.
                throw CompletionError.unsupportedRecurrence
            }
            if let currentDue = task.dueDate {
                if let context = task.modelContext {
                    do {
                        let state = try VTODOOpaqueState.load(taskID: task.id, in: context)
                        let modifiers: Set<String> = ["EXDATE", "RDATE", "EXRULE", "RECURRENCE-ID"]
                        if state?.opaqueProperties.contains(where: { modifiers.contains(ICalendarParser.splitProperty($0).name) }) == true {
                            throw CompletionError.unsupportedRecurrence
                        }
                    } catch { throw CompletionError.unsupportedRecurrence }
                }
                // VALUE=DATE is stored at UTC midnight; local-zone arithmetic would
                // treat it as the previous weekday west of UTC and advance the wrong day.
                var calendar = Calendar.current
                if task.isDueDateOnly { calendar.timeZone = TimeZone(secondsFromGMT: 0)! }
                let result = rule.nextOccurrence(after: currentDue, calendar: calendar)
                if result == .unsupported { throw CompletionError.unsupportedRecurrence }
                if case .date(let nextDue) = result {
                    let offset = nextDue.timeIntervalSince(currentDue)
                    return .advance(due: nextDue, start: task.startDate?.addingTimeInterval(offset))
                }
            }
        }
        return .finished
    }

    @discardableResult
    static func apply(_ completion: Completion, to task: TaskItem, now: Date) -> Bool {
        let advanced: Bool
        switch completion {
        case .finished:
            task.status = .completed
            task.completedDate = now
            task.percentComplete = 100
            advanced = false
        case .advance(let due, let start):
            task.dueDate = due
            task.status = .needsAction
            task.completedDate = nil
            task.percentComplete = 0
            if let start { task.startDate = start }
            advanced = true
        }
        task.lastModifiedDate = now
        task.isDirty = true
        return advanced
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
    static func apply(_ newStatus: TaskStatus, to task: TaskItem, now: Date = Date()) throws -> Bool {
        if newStatus == .completed { return try !markCompleted(task, now: now) }
        applyNoncompletion(newStatus, to: task, now: now)
        return false
    }

    static func applyNoncompletion(_ newStatus: TaskStatus, to task: TaskItem, now: Date) {
        switch newStatus {
        case .completed:
            return
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
