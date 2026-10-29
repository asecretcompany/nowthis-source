import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("TaskCompletionLogic")
@MainActor
struct TaskCompletionLogicTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(SchemaV2.models)
        return try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(isStoredInMemoryOnly: true)
            ]
        )
    }

    private func makeTask(in context: ModelContext, rrule: String? = nil, due: Date? = nil) -> TaskItem {
        let task = TaskItem(title: "t")
        task.dueDate = due
        task.recurrenceRule = rrule
        context.insert(task)
        return task
    }

    @Test func completingNonRecurringTaskMarksCompleted() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let advanced = TaskCompletionLogic.markCompleted(task, now: now)

        #expect(!advanced)
        #expect(task.status == .completed)
        #expect(task.completedDate == now)
        #expect(task.percentComplete == 100)
        #expect(task.lastModifiedDate == now)
        #expect(task.isDirty)
    }

    @Test func completingDailyRecurringTaskAdvancesDueDateInsteadOfCompleting() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let task = makeTask(in: context, rrule: "FREQ=DAILY", due: due)
        // Establish a non-default precondition so the post-call assertions
        // below prove the recurring branch actually resets these fields,
        // rather than merely matching a fresh task's defaults.
        task.percentComplete = 50
        task.completedDate = due.addingTimeInterval(-1_000)
        task.status = .inProcess

        let advanced = TaskCompletionLogic.markCompleted(task, now: due)

        #expect(advanced)
        #expect(task.status == .needsAction)
        #expect(task.completedDate == nil)
        #expect(task.percentComplete == 0)
        let next = try #require(task.dueDate)
        #expect(next == due.addingTimeInterval(86400))
        #expect(task.isDirty)
    }

    @Test func completingRecurringTaskWithStartDateOffsetsStartDateByTheSameInterval() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let start = due.addingTimeInterval(-3600)
        let task = makeTask(in: context, rrule: "FREQ=DAILY", due: due)
        task.startDate = start

        TaskCompletionLogic.markCompleted(task, now: due)

        let nextDue = try #require(task.dueDate)
        let nextStart = try #require(task.startDate)
        #expect(nextDue == due.addingTimeInterval(86400))
        #expect(nextStart == start.addingTimeInterval(86400))
    }

    @Test func uncompletingRevertsCompletionFields() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        TaskCompletionLogic.markCompleted(task, now: now)
        // markCompleted already sets isDirty = true; reset it so the
        // isDirty assertion below actually exercises markUncompleted's
        // own assignment instead of trivially observing the precondition.
        task.isDirty = false

        TaskCompletionLogic.markUncompleted(task, now: now.addingTimeInterval(60))

        #expect(task.status == .needsAction)
        #expect(task.completedDate == nil)
        #expect(task.percentComplete == 0)
        #expect(task.lastModifiedDate == now.addingTimeInterval(60))
        #expect(task.isDirty)
    }

    @Test func completingRecurringTaskWithUnparseableRRuleCompletesNormally() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let task = makeTask(in: context, rrule: "GARBAGE", due: due)
        let now = due

        let advanced = TaskCompletionLogic.markCompleted(task, now: now)

        #expect(!advanced)
        #expect(task.status == .completed)
        #expect(task.percentComplete == 100)
        #expect(task.completedDate == now)
    }

    @Test func completingRecurringTaskWithNilDueDateCompletesNormally() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context, rrule: "FREQ=DAILY", due: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let advanced = TaskCompletionLogic.markCompleted(task, now: now)

        #expect(!advanced)
        #expect(task.status == .completed)
        #expect(task.percentComplete == 100)
        #expect(task.completedDate == now)
    }

    // MARK: - Board drops
    //
    // The Kanban board carried its own copy of these semantics, reached by
    // dragging a card between columns rather than tapping a checkbox. The copy
    // had drifted: it advanced a recurring task's DUE date without shifting
    // DTSTART, so the task came back due next week and starting last week, and
    // it never told `ReminderScheduler` that anything had been completed — so
    // the hourly nag on a dragged-to-Done task went on firing forever. On a
    // local-only Vault account nothing else ever cancels it, because the bulk
    // sweep only runs after a sync.

    @Test func droppingOnDoneCompletesAndAsksForItsRemindersToBeCancelled() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let endsReminders = TaskCompletionLogic.apply(.completed, to: task, now: now)

        #expect(endsReminders)
        #expect(task.status == .completed)
        #expect(task.completedDate == now)
        #expect(task.percentComplete == 100)
        #expect(task.isDirty)
    }

    /// The drift that mattered: dragging a recurring card to Done has to move
    /// the start date with the due date, exactly as the checkbox does.
    @Test func droppingARecurringTaskOnDoneShiftsItsStartDateToo() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let task = makeTask(in: context, rrule: "FREQ=DAILY", due: due)
        task.startDate = due.addingTimeInterval(-3600)

        let endsReminders = TaskCompletionLogic.apply(.completed, to: task, now: due)

        // Advanced, not completed — so its reminders are still wanted.
        #expect(!endsReminders)
        #expect(task.status == .needsAction)
        let advanced = try #require(task.dueDate)
        #expect(advanced > due)
        let start = try #require(task.startDate)
        #expect(start == advanced.addingTimeInterval(-3600))
    }

    @Test func droppingOnToDoRevertsCompletion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context)
        TaskCompletionLogic.markCompleted(task)

        let endsReminders = TaskCompletionLogic.apply(.needsAction, to: task)

        #expect(!endsReminders)
        #expect(task.status == .needsAction)
        #expect(task.completedDate == nil)
        #expect(task.percentComplete == 0)
        #expect(task.isDirty)
    }

    @Test func droppingOnInProgressSeedsAHalfwayPercentage() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(!TaskCompletionLogic.apply(.inProcess, to: task, now: now))
        #expect(task.status == .inProcess)
        #expect(task.percentComplete == 50)
        #expect(task.lastModifiedDate == now)
        #expect(task.isDirty)
    }

    /// A part-done task keeps the figure the user set; only 0 and 100 are
    /// treated as "no answer yet" and seeded.
    @Test func droppingOnInProgressKeepsAPercentageTheUserAlreadySet() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context)
        task.percentComplete = 20

        _ = TaskCompletionLogic.apply(.inProcess, to: task)

        #expect(task.percentComplete == 20)
    }

    @Test func droppingOnCancelledClearsCompletion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context)
        TaskCompletionLogic.markCompleted(task)

        #expect(!TaskCompletionLogic.apply(.cancelled, to: task))
        #expect(task.status == .cancelled)
        #expect(task.completedDate == nil)
        #expect(task.percentComplete == 0)
        #expect(task.isDirty)
    }
}
