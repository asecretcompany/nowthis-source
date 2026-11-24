import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - CompleteTaskIntent Recurrence Tests

/// `CompleteTaskIntent` is the completion path for Siri, Shortcuts, and the
/// interactive widget. It hand-rolled its own status mutation and never
/// consulted `recurrenceRule`, so a repeating task completed from any of those
/// three surfaces was marked done instead of advancing to its next occurrence —
/// the opposite of what the in-app checkbox does with the same task.
@Suite("CompleteTaskIntent recurrence")
struct CompleteTaskIntentRecurrenceTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    private func entity(for task: TaskItem) -> TaskEntity {
        TaskEntity(
            id: task.id,
            title: task.title,
            isCompleted: task.status == .completed,
            listName: "Work"
        )
    }

    @Test("Completing a recurring task advances it instead of completing it")
    @MainActor
    func recurringTaskAdvancesRatherThanCompleting() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let due = Date(timeIntervalSince1970: 1_700_000_000)
        let task = TaskItem(title: "Water the plants")
        task.dueDate = due
        task.recurrenceRule = "FREQ=DAILY"
        context.insert(task)
        try context.save()

        let intent = CompleteTaskIntent()
        intent.task = entity(for: task)
        let isNowCompleted = try await intent.performWithContainer(container)

        let expectedDue = Calendar.current.date(byAdding: .day, value: 1, to: due)

        #expect(task.status == .needsAction)
        #expect(task.completedDate == nil)
        #expect(task.percentComplete == 0)
        #expect(task.dueDate == expectedDue)
        #expect(isNowCompleted == false)
        #expect(task.isDirty == true)
        #expect(try !ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    @Test("Siri, Shortcuts and widget completion refuse read-only and soft-deleted tasks",
          arguments: [false, true])
    @MainActor
    func unavailableTaskCannotBeCompleted(softDeleted: Bool) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        list.isReadOnly = !softDeleted
        context.insert(list)
        let task = TaskItem(title: "Keep unchanged")
        task.taskList = list
        task.status = .inProcess
        task.percentComplete = 40
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        task.dueDate = due
        task.isDeletedLocally = softDeleted
        task.isDirty = false
        context.insert(task)
        try context.save()

        let taskID = task.id
        let intent = CompleteTaskIntent(task: entity(for: task))
        await #expect(throws: IntentError.self) {
            try await intent.performWithContainer(container)
        }

        let reader = ModelContext(container)
        let saved = try #require(reader.fetch(
            FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
        #expect(saved.status == .inProcess)
        #expect(saved.percentComplete == 40)
        #expect(saved.dueDate == due)
        #expect(saved.isDeletedLocally == softDeleted)
        #expect(!saved.isDirty)
        #expect(!context.hasChanges)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    enum CompletionRoute: CaseIterable, Sendable {
        case app, intent, watch
    }

    @Test("Completing an imported DATE task skips invalid dates and preserves its VTODO", arguments: CompletionRoute.allCases)
    @MainActor
    func monthlyDateRoundTripsAcrossCompletionRoutes(_ route: CompletionRoute) async throws {
        let original = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VTODO
        UID:month-end-task
        SUMMARY:Review the budget
        DTSTART;VALUE=DATE:20260130
        DUE;VALUE=DATE:20260131
        RRULE:FREQ=MONTHLY;UNTIL=20260531
        END:VTODO
        END:VCALENDAR
        """
        let parsed = try #require(try ICalendarParser.parseSingleVTODO(from: original))
        let container = try makeContainer()
        let context = container.mainContext
        let task = TaskItem(uid: parsed.uid, title: parsed.summary)
        task.startDate = parsed.startDate
        task.isStartDateOnly = parsed.isStartDateOnly
        task.dueDate = parsed.dueDate
        task.isDueDateOnly = parsed.isDueDateOnly
        task.recurrenceRule = parsed.recurrenceRule
        task.status = .inProcess
        task.percentComplete = 40
        task.isDirty = false
        context.insert(task)
        try context.save()
        let uid = task.uid
        let stamp = try #require(ISO8601DateFormatter().date(from: "2026-01-31T12:00:00Z"))
        let intent = CompleteTaskIntent(task: entity(for: task))

        for (start, due) in [("20260330", "20260331"), ("20260530", "20260531")] {
            switch route {
            case .app:
                try TaskDetailView.applyStatusChange(.completed, to: task, in: context,
                    requestReconcile: { _ in }, cancelReminder: { _ in })
            case .intent:
                #expect(try await !intent.performWithContainer(container))
            case .watch:
                let reply = WatchEditTransaction.apply(.complete(uid: uid), operationID: UUID(),
                    container: container, isProUnlocked: true, now: stamp)
                #expect(reply == WatchEditReply.applied)
            }

            let reader = ModelContext(container)
            let saved = try #require(reader.fetch(FetchDescriptor<TaskItem>()).first)
            #expect(saved.status == .needsAction)
            #expect(saved.completedDate == nil)
            #expect(saved.percentComplete == 0)
            #expect(saved.isDirty)
            #expect(try !ReminderSchedulingJournal.capture(in: reader).isEmpty)

            let payload = try SyncPushSnapshot.serialize(saved, stamp: stamp)
            #expect(payload.contains("DUE;VALUE=DATE:\(due)\r\n"))
            #expect(payload.contains("DTSTART;VALUE=DATE:\(start)\r\n"))
            let roundTrip = try #require(try ICalendarParser.parseSingleVTODO(from: payload))
            #expect(roundTrip.isDueDateOnly)
            #expect(roundTrip.isStartDateOnly)
            #expect(roundTrip.dueDate == ICalendarParser.parseDate(due))
            #expect(roundTrip.startDate == ICalendarParser.parseDate(start))
            #expect(roundTrip.recurrenceRule == "FREQ=MONTHLY;UNTIL=20260531")
        }
    }

    @Test("Completion refuses an imported recurrence whose next DATE exceeds the iCalendar year range", arguments: [
        ("FREQ=YEARLY;INTERVAL=1995", "20240228", "20240229"),
        ("FREQ=DAILY", "99991230", "99991231"),
        ("FREQ=WEEKLY", "99991230", "99991231"),
        ("FREQ=WEEKLY;BYDAY=MO", "99991230", "99991231"),
        ("FREQ=MONTHLY;BYDAY=1MO", "99991230", "99991231"),
        ("FREQ=YEARLY;BYDAY=-1FR", "99991230", "99991231")
    ])
    @MainActor
    func unencodableNextDateLeavesSavedTaskAndWireDatesUnchanged(raw: String, start: String, due: String) async throws {
        let original = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VTODO
        UID:wire-year-boundary-task
        SUMMARY:Review the budget
        DTSTART;VALUE=DATE:\(start)
        DUE;VALUE=DATE:\(due)
        RRULE:\(raw)
        END:VTODO
        END:VCALENDAR
        """
        let parsed = try #require(try ICalendarParser.parseSingleVTODO(from: original))
        let stamp = try #require(ICalendarParser.parseDate("20240229T120000Z"))
        let container = try makeContainer()
        let context = container.mainContext
        let task = TaskItem(uid: parsed.uid, title: parsed.summary)
        task.startDate = parsed.startDate
        task.isStartDateOnly = parsed.isStartDateOnly
        task.dueDate = parsed.dueDate
        task.isDueDateOnly = parsed.isDueDateOnly
        task.recurrenceRule = parsed.recurrenceRule
        task.status = .inProcess
        task.percentComplete = 40
        task.lastModifiedDate = stamp
        task.isDirty = false
        context.insert(task)
        try context.save()

        let intent = CompleteTaskIntent(task: entity(for: task))
        await #expect(throws: TaskCompletionLogic.CompletionError.self) {
            try await intent.performWithContainer(container)
        }

        let reader = ModelContext(container)
        let saved = try #require(reader.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(saved.status == .inProcess)
        #expect(saved.percentComplete == 40)
        #expect(saved.completedDate == nil)
        #expect(saved.startDate == parsed.startDate)
        #expect(saved.dueDate == parsed.dueDate)
        #expect(saved.lastModifiedDate == stamp)
        #expect(!saved.isDirty)
        #expect(!context.hasChanges)
        #expect(try ReminderSchedulingJournal.capture(in: reader).isEmpty)

        let payload = try SyncPushSnapshot.serialize(saved, stamp: stamp)
        let lines = payload.components(separatedBy: "\r\n")
        #expect(lines.first { $0.hasPrefix("DUE") } == "DUE;VALUE=DATE:\(due)")
        #expect(lines.first { $0.hasPrefix("DTSTART") } == "DTSTART;VALUE=DATE:\(start)")
        #expect(lines.first { $0.hasPrefix("RRULE") } == "RRULE:\(raw)")
    }

    @Test("Unsupported recurrence blocks intents and widget before saving reminder changes", arguments: ["FREQ=MONTHLY;BYMONTHDAY=15", "FREQ=DAILY;COUNT=3"])
    @MainActor
    func unsupportedRecurrenceLeavesTaskAndReminderJournalUnchanged(_ raw: String) async throws {
        let container = try makeContainer()
        let task = TaskItem(title: "Imported rule")
        task.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        task.recurrenceRule = raw
        task.isDirty = false
        container.mainContext.insert(task)
        try container.mainContext.save()
        let intent = CompleteTaskIntent()
        intent.task = entity(for: task)
        await #expect(throws: TaskCompletionLogic.CompletionError.self) {
            try await intent.performWithContainer(container)
        }
        #expect(task.status == .needsAction)
        #expect(!task.isDirty)
        #expect(!container.mainContext.hasChanges)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    @Test("Completing a non-recurring task still completes it")
    @MainActor
    func nonRecurringTaskStillCompletes() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let task = TaskItem(title: "File the taxes")
        task.dueDate = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(task)
        try context.save()

        let intent = CompleteTaskIntent()
        intent.task = entity(for: task)
        let isNowCompleted = try await intent.performWithContainer(container)

        #expect(task.status == .completed)
        #expect(task.completedDate != nil)
        #expect(task.percentComplete == 100)
        #expect(isNowCompleted == true)
        #expect(try !ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    @Test("Uncompleting a task through the intent is unchanged")
    @MainActor
    func uncompletingIsUnchanged() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let task = TaskItem(title: "Already done")
        task.status = .completed
        task.completedDate = Date(timeIntervalSince1970: 1_700_000_000)
        task.percentComplete = 100
        context.insert(task)
        try context.save()

        let intent = CompleteTaskIntent()
        intent.task = entity(for: task)
        let isNowCompleted = try await intent.performWithContainer(container)

        #expect(task.status == .needsAction)
        #expect(task.completedDate == nil)
        #expect(task.percentComplete == 0)
        #expect(isNowCompleted == false)
        #expect(try !ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }
}
