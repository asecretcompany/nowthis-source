import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("WatchEditApplier")
@MainActor
struct WatchEditApplicationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(SchemaV2.models)
        return try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(isStoredInMemoryOnly: true)
            ]
        )
    }

    @discardableResult
    private func makeTask(
        in context: ModelContext,
        uid: String = UUID().uuidString,
        rrule: String? = nil,
        due: Date? = nil,
        status: TaskStatus = .needsAction,
        isDeletedLocally: Bool = false
    ) -> TaskItem {
        let task = TaskItem(uid: uid, title: "t")
        task.dueDate = due
        task.recurrenceRule = rrule
        task.status = status
        task.isDeletedLocally = isDeletedLocally
        context.insert(task)
        return task
    }

    private func makeList(in context: ModelContext, name: String = "Inbox") -> TaskList {
        let list = TaskList(serverURL: "https://example.com/cal/", name: name, colorHex: "#007AFF")
        context.insert(list)
        return list
    }

    @Test func watchSaveFailureCannotAcknowledgeReminder() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        _ = makeTask(in: context, uid: "failed-save")
        try context.save()
        struct SaveFailure: Error {}
        let result = WatchEditApplier.apply(.complete(uid: "failed-save"), modelContext: context,
            isProUnlocked: true, now: now, save: { throw SaveFailure() })
        #expect(result == .invalid)
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<TaskItem>()).first?.status == .needsAction)
        #expect(try ReminderSchedulingJournal.capture(in: read).isEmpty)
        #expect(try !ReminderSchedulingJournal.capture(in: context).isEmpty)
        context.rollback()
    }

    @Test func completeByUIDMarksCompletedAndDirty() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context, uid: "u1")
        try context.save()

        let outcome = WatchEditApplier.apply(.complete(uid: "u1"), modelContext: context, isProUnlocked: true, now: now)

        #expect(outcome == .applied)
        #expect(task.status == .completed)
        #expect(task.isDirty)
        #expect(try !ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    @Test func completeRecurringAdvancesOccurrence() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context, uid: "u1", rrule: "FREQ=DAILY", due: now)
        try context.save()

        let outcome = WatchEditApplier.apply(.complete(uid: "u1"), modelContext: context, isProUnlocked: true, now: now)

        #expect(outcome == .applied)
        #expect(task.status == .needsAction)
        let due = try #require(task.dueDate)
        #expect(due > now)
    }

    @Test func uncompleteRevertsCompletion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context, uid: "u1", status: .completed)
        task.completedDate = now
        task.percentComplete = 100
        try context.save()

        let outcome = WatchEditApplier.apply(.uncomplete(uid: "u1"), modelContext: context, isProUnlocked: true, now: now)

        #expect(outcome == .applied)
        #expect(task.status == .needsAction)
        #expect(task.isDirty)
        #expect(try !ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    @Test func addParsesNaturalLanguageIntoTask() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        try context.save()

        let outcome = WatchEditApplier.apply(
            .add(rawText: "Buy milk tomorrow at 5pm", listID: list.id,
                 dueDate: nil, priorityRaw: nil),
            modelContext: context,
            isProUnlocked: true,
            now: now
        )

        #expect(outcome == .applied)
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == 1)
        let task = try #require(tasks.first)
        #expect(task.title == "Buy milk")
        #expect(task.dueDate != nil)
        #expect(task.isDueDateOnly == false)
        #expect(task.taskList?.id == list.id)
        #expect(task.isDirty)
        #expect(try !ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
        #expect(task.isLocalOnly)
    }

    @Test func addWithBareDateIsAllDay() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        try context.save()

        let outcome = WatchEditApplier.apply(
            .add(rawText: "Pay rent tomorrow", listID: list.id,
                 dueDate: nil, priorityRaw: nil),
            modelContext: context,
            isProUnlocked: true,
            now: now
        )

        #expect(outcome == .applied)
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let task = try #require(tasks.first)
        #expect(task.isDueDateOnly == true)
    }

    @Test func editsRejectedWhenLocked() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context, uid: "u1")
        try context.save()

        let outcome = WatchEditApplier.apply(.complete(uid: "u1"), modelContext: context, isProUnlocked: false, now: now)

        #expect(outcome == .rejectedLocked)
        #expect(task.status == .needsAction)
        #expect(!task.isDirty)
    }

    @Test func unknownUIDIsDroppedSafely() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try context.save()

        let outcome = WatchEditApplier.apply(.complete(uid: "nope"), modelContext: context, isProUnlocked: true, now: now)

        #expect(outcome == .unknownTask)
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.isEmpty)
    }

    @Test func softDeletedUIDIsDroppedSafely() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = makeTask(in: context, uid: "u1", isDeletedLocally: true)
        try context.save()

        let outcome = WatchEditApplier.apply(.complete(uid: "u1"), modelContext: context, isProUnlocked: true, now: now)

        #expect(outcome == .unknownTask)
        #expect(task.status == .needsAction)
        #expect(task.isDirty == false)
    }

    @Test func emptyRawTextIsInvalid() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // A resolvable list exists, so `.invalid` here can ONLY come from the empty-text
        // guard — not from list resolution failing (that path is covered separately).
        _ = makeList(in: context)
        try context.save()

        let outcome = WatchEditApplier.apply(
            .add(rawText: "   ", listID: nil, dueDate: nil, priorityRaw: nil),
            modelContext: context,
            isProUnlocked: true,
            now: now
        )

        #expect(outcome == .invalid)
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.isEmpty)
    }

    @Test func addWithNoResolvableListIsInvalid() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try context.save()

        let outcome = WatchEditApplier.apply(
            .add(rawText: "Buy milk", listID: nil, dueDate: nil, priorityRaw: nil),
            modelContext: context,
            isProUnlocked: true,
            now: now
        )

        #expect(outcome == .invalid)
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.isEmpty)
    }

    // MARK: - Explicit fields from the watch add screen

    /// The watch resolves a preset ("Tomorrow") to a concrete date before sending, so
    /// a queued edit still means the day the user meant. Preset dates are all-day.
    @Test func addAppliesAnExplicitDueDateAsAllDay() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        try context.save()
        let due = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
            .addingTimeInterval(86_399)

        let outcome = WatchEditApplier.apply(
            .add(rawText: "Buy milk", listID: list.id, dueDate: due, priorityRaw: nil),
            modelContext: context, isProUnlocked: true, now: now
        )

        #expect(outcome == .applied)
        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(task.title == "Buy milk")
        #expect(task.dueDate == due)
        #expect(task.isDueDateOnly == true)
    }

    @Test func addAppliesAnExplicitPriority() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        try context.save()

        let outcome = WatchEditApplier.apply(
            .add(rawText: "Buy milk", listID: list.id, dueDate: nil,
                 priorityRaw: TaskPriority.high.rawValue),
            modelContext: context, isProUnlocked: true, now: now
        )

        #expect(outcome == .applied)
        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(task.priority == .high)
    }

    /// Precedence matches `QuickAddView`: a token the user typed outranks the picker,
    /// so "buy milk tomorrow" means the same thing wherever it is entered.
    @Test func aTypedDateTokenBeatsThePicker() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        try context.save()
        let pickerDate = Date(timeIntervalSince1970: 1_900_000_000)

        WatchEditApplier.apply(
            .add(rawText: "Buy milk tomorrow", listID: list.id,
                 dueDate: pickerDate, priorityRaw: nil),
            modelContext: context, isProUnlocked: true, now: now
        )

        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        let due = try #require(task.dueDate)
        #expect(due != pickerDate, "the typed token should have won")
        #expect(Calendar.current.isDate(due, inSameDayAs: Date().addingTimeInterval(86_400)))
    }

    @Test func aTypedPriorityTokenBeatsThePicker() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        try context.save()

        WatchEditApplier.apply(
            .add(rawText: "Buy milk !low", listID: list.id, dueDate: nil,
                 priorityRaw: TaskPriority.high.rawValue),
            modelContext: context, isProUnlocked: true, now: now
        )

        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(task.priority == .low)
    }

    /// With neither a token nor a picker value the task keeps today's behaviour.
    @Test func addWithNoExplicitFieldsIsUnchanged() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        try context.save()

        WatchEditApplier.apply(
            .add(rawText: "Buy milk", listID: list.id, dueDate: nil, priorityRaw: nil),
            modelContext: context, isProUnlocked: true, now: now
        )

        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(task.dueDate == nil)
        #expect(task.priority == .none)
    }

}
