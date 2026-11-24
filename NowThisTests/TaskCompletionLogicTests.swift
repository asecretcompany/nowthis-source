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

        let advanced = try TaskCompletionLogic.markCompleted(task, now: now)

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

        let advanced = try TaskCompletionLogic.markCompleted(task, now: due)

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

        try TaskCompletionLogic.markCompleted(task, now: due)

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
        try TaskCompletionLogic.markCompleted(task, now: now)
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

    @Test(arguments: ["GARBAGE", "FREQ=MONTHLY;BYMONTH=2", "FREQ=MONTHLY;BYDAY=XX", "FREQ=DAILY;COUNT=1", "FREQ=DAILY;COUNT=3", "FREQ=DAILY;COUNT=10001"])
    func unsupportedCompletionLeavesEveryFieldUnchanged(_ raw: String) throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let task = makeTask(in: context, rrule: raw, due: due)
        task.startDate = due.addingTimeInterval(-3600)
        task.status = .inProcess
        task.percentComplete = 42
        task.completedDate = due.addingTimeInterval(-100)
        task.lastModifiedDate = due.addingTimeInterval(-200)
        task.isDirty = false
        try context.save()
        #expect(throws: TaskCompletionLogic.CompletionError.self) {
            try TaskCompletionLogic.markCompleted(task, now: due)
        }
        #expect(throws: TaskCompletionLogic.CompletionError.self) {
            try TaskCompletionLogic.apply(.completed, to: task, now: due)
        }
        #expect(task.recurrenceRule == raw)
        #expect(task.dueDate == due)
        #expect(task.startDate == due.addingTimeInterval(-3600))
        #expect(task.status == .inProcess)
        #expect(task.percentComplete == 42)
        #expect(task.completedDate == due.addingTimeInterval(-100))
        #expect(task.lastModifiedDate == due.addingTimeInterval(-200))
        #expect(!task.isDirty)
        #expect(!context.hasChanges)
    }

    @Test func completingRecurringTaskWithNilDueDateCompletesNormally() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context, rrule: "FREQ=DAILY", due: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let advanced = try TaskCompletionLogic.markCompleted(task, now: now)

        #expect(!advanced)
        #expect(task.status == .completed)
        #expect(task.percentComplete == 100)
        #expect(task.completedDate == now)
    }

    @Test func dateOnlyOrdinalCompletionUsesItsStoredGregorianDay() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let due = try #require(ICalendarParser.parseDate("20261025"))
        let task = makeTask(in: context, rrule: "FREQ=MONTHLY;BYDAY=-1SU", due: due)
        task.isDueDateOnly = true
        #expect(try TaskCompletionLogic.markCompleted(task))
        #expect(task.dueDate == ICalendarParser.parseDate("20261129"))
        #expect(task.isDueDateOnly)
    }

    @Test(arguments: ["FREQ=MONTHLY;BYMONTHDAY=15", "GARBAGE", "FREQ=DAILY;COUNT=3"])
    func detailStatusAndSubtaskChangesStopBeforeSideEffects(_ raw: String) throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context, rrule: raw, due: Date())
        task.isDirty = false
        try context.save()
        var saves = 0
        var reconciles = 0
        var cancelled: [String] = []
        #expect(throws: TaskCompletionLogic.CompletionError.self) {
            try TaskDetailView.applyStatusChange(.completed, to: task, in: context,
                save: { saves += 1 }, requestReconcile: { _ in reconciles += 1 },
                cancelReminder: { cancelled.append($0) })
        }
        #expect(saves == 0)
        #expect(reconciles == 0)
        #expect(cancelled.isEmpty)
        #expect(!context.hasChanges)
        #expect(task.status == .needsAction)
        #expect(!task.isDirty)
    }

    @Test func detailOrdinalCompletionAdvancesAndReplansWithoutCancelling() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context, rrule: "FREQ=MONTHLY;BYDAY=-1SU",
                            due: ICalendarParser.parseDate("20261025"))
        task.isDueDateOnly = true
        try context.save()
        var saves = 0
        var reconciles = 0
        var cancelled: [String] = []
        try TaskDetailView.applyStatusChange(.completed, to: task, in: context,
            save: { saves += 1 }, requestReconcile: { _ in reconciles += 1 },
            cancelReminder: { cancelled.append($0) })
        #expect(task.dueDate == ICalendarParser.parseDate("20261129"))
        #expect(task.status == .needsAction)
        #expect(saves == 1)
        #expect(reconciles == 1)
        #expect(cancelled.isEmpty)
    }

    @Test func exhaustedRuleCompletesWhilePreservingRawText() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let raw = "FREQ=DAILY;UNTIL=20200101T000000Z"
        let task = makeTask(in: context, rrule: raw, due: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try !TaskCompletionLogic.markCompleted(task))
        #expect(task.status == .completed)
        #expect(task.recurrenceRule == raw)
    }

    @Test func titleAndCompletionEditsPreserveTheRawPushRule() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let raw = "BYDAY=+2FR,-1MO;FREQ=MONTHLY;INTERVAL=1"
        let task = makeTask(in: context, rrule: raw, due: Date(timeIntervalSince1970: 1_800_000_000))
        task.title = "Changed title"
        #expect(try SyncPushSnapshot.serialize(task, stamp: Date()).contains("RRULE:" + raw + "\r\n"))
        #expect(try TaskCompletionLogic.markCompleted(task))
        #expect(task.recurrenceRule == raw)
        #expect(try SyncPushSnapshot.serialize(task, stamp: Date()).contains("RRULE:" + raw + "\r\n"))
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

        let endsReminders = try TaskCompletionLogic.apply(.completed, to: task, now: now)

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

        let endsReminders = try TaskCompletionLogic.apply(.completed, to: task, now: due)

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
        try TaskCompletionLogic.markCompleted(task)

        let endsReminders = try TaskCompletionLogic.apply(.needsAction, to: task)

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

        #expect(try !TaskCompletionLogic.apply(.inProcess, to: task, now: now))
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

        _ = try TaskCompletionLogic.apply(.inProcess, to: task)

        #expect(task.percentComplete == 20)
    }

    @Test func droppingOnCancelledClearsCompletion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context)
        try TaskCompletionLogic.markCompleted(task)

        #expect(try !TaskCompletionLogic.apply(.cancelled, to: task))
        #expect(task.status == .cancelled)
        #expect(task.completedDate == nil)
        #expect(task.percentComplete == 0)
        #expect(task.isDirty)
    }
    @Test(arguments: ["EXDATE:20261023T120000Z", "RDATE:20261024T120000Z", "EXRULE:FREQ=WEEKLY", "RECURRENCE-ID:20261022T120000Z"])
    func opaqueScheduleModifiersBlockBeforeAnyMutation(line: String) throws {
        let container = try makeContainer()
        let context = container.mainContext
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let task = makeTask(in: context, rrule: "FREQ=DAILY", due: due)
        task.isDirty = false
        task.percentComplete = 50
        task.status = .inProcess
        var state = VTODOOpaqueState.empty
        state.opaqueProperties = [line]
        try state.store(taskID: task.id, in: context)
        try context.save()
        let before = try SyncPushSnapshot.serialize(task, stamp: due)
        #expect(throws: TaskCompletionLogic.CompletionError.self) {
            try TaskCompletionLogic.markCompleted(task, now: due)
        }
        #expect(try SyncPushSnapshot.serialize(task, stamp: due) == before)
        #expect(!task.isDirty)
        #expect(!context.hasChanges)
        task.recurrenceRule = nil
        #expect(try !TaskCompletionLogic.markCompleted(task, now: due))
        #expect(task.status == .completed)
        #expect(try SyncPushSnapshot.serialize(task, stamp: due).contains(line))
    }

    @Test(arguments: ["broken", #"{"version":2}"#])
    func unreadableOpaqueStateBlocksCompletionWithoutMutation(json: String) throws {
        let container = try makeContainer(); let context = container.mainContext
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let task = makeTask(in: context, rrule: "FREQ=DAILY", due: due)
        task.isDirty = false; task.status = .inProcess; task.percentComplete = 50
        let metadata = SyncMetadata(id: VTODOOpaqueState.prefix + task.id, collectionPath: "")
        metadata.syncToken = json; context.insert(metadata); try context.save()
        #expect(throws: TaskCompletionLogic.CompletionError.self) { try TaskCompletionLogic.markCompleted(task, now: due) }
        #expect(task.dueDate == due); #expect(task.status == .inProcess)
        #expect(task.percentComplete == 50); #expect(task.completedDate == nil)
        #expect(!task.isDirty); #expect(!context.hasChanges)
        #expect(metadata.syncToken == json)
    }

}
