import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("View persistence reporting", .serialized)
@MainActor
struct ViewPersistenceTests {
    struct SaveFailure: LocalizedError {
        var errorDescription: String? { "private server path and task title" }
    }

    @Test("Failed journal save reports generic error and gates effects; retry preserves one task and ticket")
    func failureAndRetry() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "Draft")
        let unrelated = TaskItem(title: "Unrelated edit")
        context.insert(task)
        context.insert(unrelated)
        let errors = ErrorState()
        var effects = 0
        if ViewPersistence.saveOrReport(in: context, errorState: errors, save: { throw SaveFailure() }) { effects += 1 }
        #expect(effects == 0)
        #expect(errors.isPresented)
        #expect(errors.currentError == String(localized: "persistence.saveFailed", defaultValue: "Couldn't save your change"))
        #expect(errors.currentError?.contains("private server") == false)
        #expect(task.modelContext === context)
        #expect(unrelated.title == "Unrelated edit")
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).isEmpty)
        #expect(try ReminderSchedulingJournal.capture(in: context).count == 1)
        errors.dismiss()
        task.title = "Corrected draft"
        if ViewPersistence.saveOrReport(in: context, errorState: errors) { effects += 1 }
        #expect(effects == 1)
        #expect(!errors.isPresented)
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<TaskItem>()).count == 2)
        #expect(try ReminderSchedulingJournal.capture(in: read).count == 1)
    }

    @Test("Recovery-only saves retain reminder journal semantics")
    func recoveryWithoutTaskChanges() throws {
        let container = try DAVSyncScenario.container()
        #expect(ViewPersistence.saveOrReport(in: container.mainContext, errorState: ErrorState(), needsRecovery: true))
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).count == 1)
    }
    @Test("A failed recurring completion restores only its own fields before retry")
    func completionRetry() async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "Recurring")
        task.recurrenceRule = "FREQ=DAILY"
        task.dueDate = Date(timeIntervalSince1970: 2_000_000_000)
        context.insert(task)
        try context.save()
        task.title = "Unrelated pending title"
        let originalDue = task.dueDate
        var reloads = 0
        var effects = 0
        var attempts = 0
        var donations = 0
        let coordinator = TaskCompletionCoordinator(animationDelay: 0, onWidgetReload: { reloads += 1 }, onCompletionDonation: { _ in donations += 1 })
        coordinator.toggle(task, save: {
            attempts += 1
            try ReminderSchedulingJournal.saveTaskChanges(in: context, save: { throw SaveFailure() })
        }) { effects += 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(attempts == 1)
        #expect(effects == 0 && reloads == 0 && donations == 0)
        #expect(task.dueDate == originalDue)
        #expect(task.title == "Unrelated pending title")
        coordinator.toggle(task, save: { try ReminderSchedulingJournal.saveTaskChanges(in: context) }) { effects += 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(task.dueDate == originalDue?.addingTimeInterval(86400))
        #expect(effects == 1 && reloads == 1 && donations == 1)
    }

    @Test("Failed deletion preserves the live subtree so confirmation can safely retry")
    func deletionRetry() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let root = TaskItem(title: "Root")
        let child = TaskItem(title: "Child")
        context.insert(root); context.insert(child)
        child.parentTask = root
        try context.save()
        root.title = "Pending title"
        var coordinator = TaskDeletionCoordinator()
        var effects = 0
        let failingDelete: (TaskItem, TaskWriteEligibility.DeletionScope) -> Void = { task, scope in
            if TaskDeletionPersistence.perform(task, in: context, errorState: ErrorState(),
                confirmed: scope, save: { throw SaveFailure() }) != nil { effects += 1 }
        }
        coordinator.request(root, in: context, errorState: ErrorState(), delete: failingDelete)
        coordinator.confirm(in: context, errorState: ErrorState(), delete: failingDelete)
        #expect(effects == 0)
        #expect(!root.isDeletedLocally && !child.isDeletedLocally)
        #expect(root.title == "Pending title")
        let retry: (TaskItem, TaskWriteEligibility.DeletionScope) -> Void = { task, scope in
            if let ids = TaskDeletionPersistence.perform(task, in: context, errorState: ErrorState(), confirmed: scope) {
                #expect(Set(ids) == Set([root.id, child.id]))
                effects += 1
            }
        }
        coordinator.request(root, in: context, errorState: ErrorState(), delete: retry)
        #expect(coordinator.subtaskCount == 1)
        coordinator.confirm(in: context, errorState: ErrorState(), delete: retry)
        #expect(effects == 1)
        #expect(root.isDeletedLocally && child.isDeletedLocally)
    }

    @Test("Task draft retry reuses the insertion and accepts a corrected title")
    func creationRetry() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let draft = TaskCreationDraft()
        let task = try draft.task(title: "First")
        context.insert(task)
        _ = ViewPersistence.saveOrReport(in: context, errorState: ErrorState(), save: { throw SaveFailure() })
        let retry = try draft.task(title: "Corrected")
        context.insert(retry)
        #expect(retry === task)
        #expect(retry.title == "Corrected")
        #expect(ViewPersistence.saveOrReport(in: context, errorState: ErrorState()))
        draft.didSave()
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).count == 1)
        #expect(try draft.task(title: "Next") !== task)
    }

    @Test("Cancelling a failed Quick Add discards only its task and tags, never a main-context draft")
    func cancelOwnedCreation() throws {
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        main.autosaveEnabled = false
        let unrelated = TaskItem(title: "Unrelated pending edit")
        main.insert(unrelated)
        let draft = TaskCreationDraft()
        let context = draft.context(in: container)
        let task = try draft.task(title: "Cancelled addition")
        let tag = NowThis.Tag(name: "Cancelled tag")
        context.insert(tag)
        context.insert(task)
        task.tags = [tag]
        #expect(!draft.saveOwnedChanges(errorState: ErrorState(), save: { throw SaveFailure() }))
        #expect(try main.fetch(FetchDescriptor<TaskItem>()).map(\.title) == ["Unrelated pending edit"])
        draft.discardOwnedChanges()
        #expect(try main.fetch(FetchDescriptor<TaskItem>()).map(\.title) == ["Unrelated pending edit"])
        #expect(main.hasChanges)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<NowThis.Tag>()).isEmpty)
        // A subsequent unrelated save must not accidentally persist the cancelled draft.
        try main.save()
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).map(\.title) == ["Unrelated pending edit"])
        #expect(try ModelContext(container).fetch(FetchDescriptor<NowThis.Tag>()).isEmpty)
    }

    @Test("Quick Add retry reuses one owned insertion without saving an unrelated main-context draft")
    func ownedCreationRetry() throws {
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        main.autosaveEnabled = false
        main.insert(TaskItem(title: "Unrelated pending edit"))
        let draft = TaskCreationDraft()
        let context = draft.context(in: container)
        let task = try draft.task(title: "First")
        context.insert(task)
        #expect(!draft.saveOwnedChanges(errorState: ErrorState(), save: { throw SaveFailure() }))
        #expect(draft.context(in: container) === context)
        let retry = try draft.task(title: "Corrected")
        #expect(retry === task)
        #expect(draft.saveOwnedChanges(errorState: ErrorState()))
        draft.discardOwnedChanges()
        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(saved.map(\.title) == ["Corrected"])
        #expect(main.hasChanges)
    }

    @Test(arguments: [
        ("Buy milk tomorrow", "2026-03-08T00:00:00Z", true),
        ("Buy milk tomorrow at 5pm", "2026-03-09T00:00:00Z", false),
    ])
    func quickAddSavesParsedDateOverPicker(phrase: String, instant: String, isDateOnly: Bool) throws {
        let container = try DAVSyncScenario.container()
        let draft = TaskCreationDraft()
        let context = draft.context(in: container)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let iso = ISO8601DateFormatter()
        let now = try #require(iso.date(from: "2026-03-07T20:00:00Z"))
        let expected = try #require(iso.date(from: instant))
        let parsed = try TaskTextValidation.quickAdd(phrase, now: now, calendar: calendar)
        let task = try draft.task(title: parsed.cleanTitle)
        QuickAddView.applyDueDate(parsed, pickerDate: now, to: task)
        context.insert(task)
        #expect(draft.saveOwnedChanges(errorState: ErrorState()))

        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(saved.title == "Buy milk")
        #expect(saved.dueDate == expected)
        #expect(saved.isDueDateOnly == isDateOnly)
    }

    @Test("Quick Add retries with the current picker date and clears the parsed date-only flag")
    func quickAddRetryUsesCurrentPicker() throws {
        let container = try DAVSyncScenario.container()
        let draft = TaskCreationDraft()
        let context = draft.context(in: container)
        let picker = Date(timeIntervalSince1970: 1_800_000_000)
        let parsed = try TaskTextValidation.quickAdd("Buy milk tomorrow")
        let task = try draft.task(title: parsed.cleanTitle)
        QuickAddView.applyDueDate(parsed, pickerDate: picker, to: task)
        context.insert(task)
        #expect(task.isDueDateOnly)
        #expect(!draft.saveOwnedChanges(errorState: ErrorState(), save: { throw SaveFailure() }))

        let corrected = try TaskTextValidation.quickAdd("Buy milk")
        let retry = try draft.task(title: corrected.cleanTitle)
        QuickAddView.applyDueDate(corrected, pickerDate: picker, to: retry)
        #expect(retry === task)
        #expect(draft.saveOwnedChanges(errorState: ErrorState()))

        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(saved.dueDate == picker)
        #expect(!saved.isDueDateOnly)
    }

    @Test("Calendar Quick Add preserves the selected timed instant across DST and month boundaries", arguments: [
        ("America/Los_Angeles", "2026-03-08T08:00:00Z", 3, 8),
        ("Australia/Sydney", "2026-10-31T13:00:00Z", 11, 1),
    ])
    func calendarQuickAddKeepsTimedDay(zone: String, instant: String, month: Int, day: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let selected = try #require(ISO8601DateFormatter().date(from: instant))
        let container = try DAVSyncScenario.container()
        let draft = TaskCreationDraft()
        let context = draft.context(in: container)
        let task = try QuickAddView.taskForCreation(title: "Calendar entry", tagNames: [], draft: draft, in: context)
        QuickAddView.applyDueDate(.init(), pickerDate: selected, to: task)
        context.insert(task)
        #expect(draft.saveOwnedChanges(errorState: ErrorState()))

        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        let due = try #require(saved.dueDate)
        #expect(!saved.isDueDateOnly)
        #expect(due == selected)
        #expect(calendar.component(.month, from: due) == month)
        #expect(calendar.component(.day, from: due) == day)
        #expect(calendar.component(.hour, from: due) == 0)
    }

    @Test("Calendar Quick Add resolves fresh snapshots when a token or scoped list disappears")
    func calendarQuickAddRechecksDestination() throws {
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        let fallback = TaskList(id: "calendar-fallback", serverURL: "", name: "A Calendar fallback", colorHex: "#007AFF")
        let scoped = TaskList(id: "calendar-scoped", serverURL: "", name: "CalendarScope", colorHex: "#007AFF")
        let token = TaskList(id: "calendar-token", serverURL: "", name: "CalendarToken", colorHex: "#007AFF")
        main.insert(fallback)
        main.insert(scoped)
        main.insert(token)
        try main.save()
        let selected = QuickAddView.CalendarSelection(date: Date(), destination: .init(scoped))
        let parsed = try TaskTextValidation.quickAdd("Calendar entry #CalendarToken")
        let first = QuickAddView.calendarDestination(selection: selected, listName: parsed.listName,
                                                    in: ModelContext(container)).map(QuickAddView.Destination.init)
        #expect(first?.id == "calendar-token")

        main.delete(token)
        scoped.name = "CalendarScope renamed"
        try main.save()
        let second = QuickAddView.calendarDestination(selection: selected, listName: parsed.listName,
                                                     in: ModelContext(container)).map(QuickAddView.Destination.init)
        #expect(second?.id == "calendar-scoped")
        #expect(second?.name == "CalendarScope renamed")
        #expect(first != second)

        main.delete(scoped)
        try main.save()
        let fresh = ModelContext(container)
        #expect(QuickAddView.calendarDestination(selection: selected, listName: parsed.listName,
                                                 in: fresh, useFallbackForMissingScope: false) == nil)
        #expect(QuickAddView.calendarDestination(selection: selected, listName: parsed.listName,
                                                 in: fresh)?.id == "calendar-fallback")
    }

    @Test("A duplicate Calendar list token keeps the explicitly scoped account and saves there",
          arguments: [true, false])
    func calendarQuickAddKeepsExplicitScopeForAmbiguousToken(scopeToSecondAccount: Bool) throws {
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        let accountA = ServerAccount(displayName: "Account A", serverBaseURL: "https://a.invalid", username: "a")
        let accountB = ServerAccount(displayName: "Account B", serverBaseURL: "https://b.invalid", username: "b")
        let workA = TaskList(id: "work-a", serverURL: "/a/work/", name: "Work", colorHex: "#007AFF")
        let workB = TaskList(id: "work-b", serverURL: "/b/work/", name: "Work", colorHex: "#007AFF")
        main.insert(accountA)
        main.insert(accountB)
        main.insert(workA)
        main.insert(workB)
        workA.account = accountA
        workB.account = accountB
        try main.save()

        let scoped = scopeToSecondAccount ? workB : workA
        let selection = QuickAddView.CalendarSelection(date: Date(), destination: .init(scoped))
        let parsed = try TaskTextValidation.quickAdd("Plan review #WORK")
        let preview = QuickAddView.committedCalendarDestination(selection: selection, listName: parsed.listName,
                                                               in: container)
        let draft = TaskCreationDraft()
        let context = draft.context(in: container)
        let destination = try #require(QuickAddView.calendarDestination(selection: selection, listName: parsed.listName,
                                                                        in: context))
        #expect(preview?.display == QuickAddView.Destination(destination))
        let task = try QuickAddView.taskForCreation(title: parsed.cleanTitle, tagNames: [], draft: draft, in: context)
        task.taskList = destination
        QuickAddView.applyDueDate(parsed, pickerDate: selection.date, to: task)
        context.insert(task)
        #expect(draft.saveOwnedChanges(errorState: ErrorState()))

        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(saved.map(\.title) == ["Plan review"])
        #expect(saved.first?.taskList?.id == scoped.id)
    }

    enum CalendarRetryChange: CaseIterable {
        case changeList, changeSettings, clearDate
    }

    @Test("Calendar Quick Add retries against current destination and date without retaining a default reminder",
          arguments: CalendarRetryChange.allCases)
    func calendarQuickAddRetryRecomputesReminder(change: CalendarRetryChange) throws {
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        let fallback = TaskList(id: "reminder-off", serverURL: "", name: "Inbox", colorHex: "#007AFF")
        let scoped = TaskList(id: "reminder-on", serverURL: "", name: "Work", colorHex: "#007AFF")
        fallback.defaultReminderEnabledOverride = false
        scoped.defaultReminderEnabledOverride = true
        main.insert(fallback)
        main.insert(scoped)
        try main.save()

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let selection = QuickAddView.CalendarSelection(date: date, destination: .init(scoped))
        let draft = TaskCreationDraft()
        let context = draft.context(in: container)
        let oldList = try #require(QuickAddView.calendarDestination(selection: selection, listName: nil, in: context))
        let task = try QuickAddView.taskForCreation(title: "Calendar draft", priority: .high, tagNames: [],
                                                   draft: draft, in: context)
        task.taskList = oldList
        task.recurrenceRule = "FREQ=DAILY"
        QuickAddView.applyDueDate(.init(), pickerDate: date, to: task)
        QuickAddView.applyDefaultReminder(to: task, calendarReminderEnabled: true)
        context.insert(task)
        #expect(task.reminderOffset == 0)
        let errors = ErrorState()
        #expect(!draft.saveOwnedChanges(errorState: errors, save: { throw SaveFailure() }))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 0)

        if change == .changeSettings {
            scoped.defaultReminderEnabledOverride = false
            try main.save()
            #expect(oldList.defaultReminderEnabledOverride == true)
        }
        let listName = change == .changeList ? "Inbox" : nil
        let finalDate = change == .clearDate ? nil : date
        let current = try #require(QuickAddView.committedCalendarDestination(selection: selection, listName: listName,
                                                                           in: container))
        let pendingList = try #require(QuickAddView.calendarDestination(selection: selection, listName: listName, in: context))
        #expect(current.display.id == pendingList.id)
        let retry = try QuickAddView.taskForCreation(title: "Calendar draft", priority: .high, tagNames: [],
                                                    draft: draft, in: context)
        #expect(retry === task)
        retry.taskList = pendingList
        QuickAddView.applyDueDate(.init(), pickerDate: finalDate, to: retry)
        QuickAddView.applyDefaultReminder(to: retry, calendarReminderEnabled: current.reminderEnabled)
        #expect(draft.saveOwnedChanges(errorState: errors))

        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(saved.count == 1)
        #expect(saved.first?.taskList?.id == (change == .changeList ? "reminder-off" : "reminder-on"))
        #expect(saved.first?.title == "Calendar draft")
        #expect(saved.first?.dueDate == finalDate)
        #expect(saved.first?.priority == .high)
        #expect(saved.first?.recurrenceRule == "FREQ=DAILY")
        #expect(saved.first?.reminderOffset == nil)
    }

    @Test("Calendar Quick Add can resolve a newly committed list after opening without a destination")
    func calendarQuickAddResolvesListAfterSync() throws {
        let container = try DAVSyncScenario.container()
        let selection = QuickAddView.CalendarSelection(date: Date(), destination: nil)
        #expect(QuickAddView.committedCalendarDestination(selection: selection, listName: nil, in: container) == nil)

        let inbound = ModelContext(container)
        inbound.insert(TaskList(id: "new-list", serverURL: "/lists/new/", name: "New List", colorHex: "#007AFF"))
        try inbound.save()

        let resolved = QuickAddView.committedCalendarDestination(selection: selection, listName: nil, in: container)
        #expect(resolved?.display.id == "new-list")
        #expect(resolved?.display.name == "New List")
    }

    @Test("Quick Add preview shows the date-only civil day and the timed local clock")
    func quickAddPreviewDueDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let iso = ISO8601DateFormatter()
        let midnightUTC = try #require(iso.date(from: "2026-03-08T00:00:00Z"))
        let localNoon = try #require(iso.date(from: "2026-03-08T19:00:00Z"))
        let timedDue = try #require(iso.date(from: "2026-03-09T00:00:00Z"))
        let allDay = NaturalLanguageParser.ParseResult(dueDate: midnightUTC, dueHasTime: false)
        let timed = NaturalLanguageParser.ParseResult(dueDate: timedDue, dueHasTime: true)
        var dayStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()
        dayStyle.timeZone = calendar.timeZone
        var timedStyle = dayStyle.hour().minute()
        timedStyle.timeZone = calendar.timeZone
        let day = try #require(ParsePreviewChips.dueDateLabels(for: allDay, timeZone: calendar.timeZone))
        let clock = try #require(ParsePreviewChips.dueDateLabels(for: timed, timeZone: calendar.timeZone))

        #expect(day.visible.contains(localNoon.formatted(dayStyle)))
        #expect(day.spoken.contains(localNoon.formatted(dayStyle)))
        #expect(clock.visible == timedDue.formatted(timedStyle))
        #expect(clock.spoken == clock.visible)
    }

    @Test(arguments: [false, true])
    func quickAddSavesEachTagIdentityOnce(hasExistingTag: Bool) throws {
        let container = try DAVSyncScenario.container()
        let existing = NowThis.Tag(id: "existing-work", name: "Work")
        if hasExistingTag {
            container.mainContext.insert(existing)
            try container.mainContext.save()
        }
        let draft = TaskCreationDraft()
        let context = draft.context(in: container)
        let parsed = try TaskTextValidation.quickAdd("Buy milk tomorrow @work @Work @work @cafe @café @CAFÉ")
        let task = try QuickAddView.taskForCreation(title: parsed.cleanTitle, tagNames: parsed.tagNames,
                                                   draft: draft, in: context)
        QuickAddView.applyDueDate(parsed, pickerDate: nil, to: task)
        #expect(task.tags.count == 3)
        context.insert(task)
        #expect(draft.saveOwnedChanges(errorState: ErrorState()))

        let read = ModelContext(container)
        let saved = try #require(try read.fetch(FetchDescriptor<TaskItem>()).first)
        let tags = try read.fetch(FetchDescriptor<NowThis.Tag>())
        #expect(saved.title == "Buy milk")
        #expect(saved.isDueDateOnly)
        #expect(tags.count == 3)
        #expect(saved.tags.count == 3)
        #expect(Set(saved.tags.map(\.id)) == Set(tags.map(\.id)))
        #expect(Set(tags.map(\.name)) == [hasExistingTag ? "Work" : "work", "cafe", "café"])
        if hasExistingTag {
            #expect(saved.tags.contains { $0.id == existing.id && $0.name == "Work" })
        }
    }

    @Test func quickAddRetryDropsOnlySupersededDraftTags() throws {
        let container = try DAVSyncScenario.container()
        let existing = NowThis.Tag(name: "Work")
        container.mainContext.insert(existing)
        try container.mainContext.save()
        let draft = TaskCreationDraft()
        let context = draft.context(in: container)
        let initial = try QuickAddView.taskForCreation(title: "Buy milk", tagNames: ["work", "cafe", "café"],
                                                       draft: draft, in: context)
        let cafe = try #require(initial.tags.first { $0.name == "cafe" })
        context.insert(initial)
        #expect(!draft.saveOwnedChanges(errorState: ErrorState(), save: { throw SaveFailure() }))

        let stagedTagIDs = Set(initial.tags.map(\.id))
        #expect(throws: SaveFailure.self) {
            try QuickAddView.taskForCreation(title: "Different title", tagNames: ["new"], draft: draft,
                                             in: context, fetchTags: { _ in throw SaveFailure() })
        }
        #expect(initial.title == "Buy milk")
        #expect(Set(initial.tags.map(\.id)) == stagedTagIDs)

        let retry = try QuickAddView.taskForCreation(title: "Buy oat milk", tagNames: ["CAFE", "home", "Home"],
                                                     draft: draft, in: context)
        #expect(retry === initial)
        context.insert(retry)
        #expect(draft.saveOwnedChanges(errorState: ErrorState()))

        let read = ModelContext(container)
        let saved = try #require(try read.fetch(FetchDescriptor<TaskItem>()).first)
        let tags = try read.fetch(FetchDescriptor<NowThis.Tag>())
        #expect(saved.title == "Buy oat milk")
        #expect(saved.tags.count == 2)
        #expect(Set(saved.tags.map(\.name)) == ["cafe", "home"])
        #expect(Set(tags.map(\.name)) == ["Work", "cafe", "home"])
        #expect(tags.contains { $0.id == existing.id })
        #expect(saved.tags.contains { $0.id == cafe.id })
    }

    @Test func quickAddUnreadableTagsOrInvalidTitleCannotStageRows() throws {
        let container = try DAVSyncScenario.container()
        let existing = NowThis.Tag(name: "Work")
        container.mainContext.insert(existing)
        try container.mainContext.save()
        let draft = TaskCreationDraft()
        let context = draft.context(in: container)
        #expect(throws: SaveFailure.self) {
            try QuickAddView.taskForCreation(title: "Buy milk", tagNames: ["work", "Work"],
                                             draft: draft, in: context, fetchTags: { _ in throw SaveFailure() })
        }
        #expect(!context.hasChanges)

        let invalidDraft = TaskCreationDraft()
        let invalidContext = invalidDraft.context(in: container)
        #expect(throws: TaskTextValidation.Failure.self) {
            try QuickAddView.taskForCreation(title: String(repeating: "x", count: TaskItem.maxTitleLength + 1),
                                             tagNames: ["new"], draft: invalidDraft, in: invalidContext,
                                             fetchTags: { _ in throw SaveFailure() })
        }
        #expect(!invalidContext.hasChanges)
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<TaskItem>()).isEmpty)
        #expect(try read.fetch(FetchDescriptor<NowThis.Tag>()).map(\.id) == [existing.id])
    }

    @Test func quickAddPreviewHasOneChipPerTagIdentity() throws {
        let parsed = try TaskTextValidation.quickAdd("Buy milk @work @Work @work @cafe @café @CAFÉ")
        let preview = ParsePreviewChips(result: parsed)
        #expect(preview.tagNames == ["work", "cafe", "café"])
    }

    @Test("Committed Quick Add survives dismissal and repeated reminder failure without another insertion")
    func ownedCreationSecondaryRecovery() throws {
        let container = try DAVSyncScenario.container()
        let draft = TaskCreationDraft()
        let context = draft.context(in: container)
        let task = try draft.task(title: "Already saved")
        context.insert(task)
        var primarySaves = 0
        #expect(draft.saveOwnedChanges(errorState: ErrorState(), save: {
            primarySaves += 1
            try context.save()
        }))
        let errors = ErrorState()
        var recoveryAttempts = 0
        ViewPersistence.recoverRemindersAfterCommit(errorState: errors) {
            recoveryAttempts += 1
            if recoveryAttempts < 3 { throw SaveFailure() }
        }
        draft.discardOwnedChanges()
        #expect(errors.currentError == recoveryMessage)
        errors.retryAction?()
        #expect(errors.isPresented && errors.currentError == recoveryMessage)
        errors.retryAction?()
        #expect(!errors.isPresented)
        #expect(primarySaves == 1 && recoveryAttempts == 3)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).map(\.title) == ["Already saved"])
        #expect(try draft.task(title: "Next") !== task)
    }

    @Test("Subtask cancellation leaves its committed parent and unrelated drafts untouched; retry saves one same-list child")
    func ownedSubtaskCancellationAndRetry() throws {
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        main.autosaveEnabled = false
        let list = TaskList(serverURL: "https://example.com", name: "Parent list", colorHex: "#123456")
        let parent = TaskItem(title: "Parent")
        main.insert(list)
        main.insert(parent)
        parent.taskList = list
        try main.save()
        parent.descriptionText = "Unrelated unsaved parent note"
        let cancelled = TaskCreationDraft()
        _ = try #require(try cancelled.subtask(title: "Cancelled child", parent: parent, in: container))
        #expect(!cancelled.saveOwnedChanges(errorState: ErrorState(), save: { throw SaveFailure() }))
        #expect(parent.subtasks.isEmpty)
        cancelled.discardOwnedChanges()
        #expect(parent.subtasks.isEmpty)
        #expect(parent.descriptionText == "Unrelated unsaved parent note")
        let draft = TaskCreationDraft()
        let child = try #require(try draft.subtask(title: "First", parent: parent, in: container))
        #expect(!draft.saveOwnedChanges(errorState: ErrorState(), save: { throw SaveFailure() }))
        let retry = try #require(try draft.subtask(title: "Corrected child", parent: parent, in: container))
        #expect(retry === child)
        #expect(draft.saveOwnedChanges(errorState: ErrorState()))
        draft.discardOwnedChanges()
        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        let savedParent = try #require(saved.first { $0.id == parent.id })
        let savedChild = try #require(saved.first { $0.id == child.id })
        #expect(saved.count == 2)
        #expect(savedParent.descriptionText != "Unrelated unsaved parent note")
        #expect(savedParent.subtasks.map(\.id) == [child.id])
        #expect(savedChild.title == "Corrected child")
        #expect(savedChild.parentUID == parent.uid)
        #expect(savedChild.taskList?.id == list.id)
        #expect(main.hasChanges)
    }

    @Test("Subtask creation rejects a parent with pending local deletion")
    func ownedSubtaskRejectsDeletedParent() throws {
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        let parent = TaskItem(title: "Deleting parent")
        main.insert(parent)
        try main.save()
        parent.isDeletedLocally = true
        let draft = TaskCreationDraft()
        #expect(try draft.subtask(title: "Must not add", parent: parent, in: container) == nil)
    }

    @Test("A real read-only store save reports an error without discarding pending edits")
    func readOnlyStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(SchemaV2.models)
        let url = directory.appendingPathComponent("view-save.store")
        let writable = try ModelContainer(for: schema, configurations:
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        writable.mainContext.insert(TaskItem(title: "Original"))
        try writable.mainContext.save()
        let readOnly = try ModelContainer(for: schema, configurations:
            ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none))
        readOnly.mainContext.autosaveEnabled = false
        let task = try #require(try readOnly.mainContext.fetch(FetchDescriptor<TaskItem>()).first)
        task.title = "Draft"
        let errors = ErrorState()
        #expect(!ViewPersistence.saveOrReport(in: readOnly.mainContext, errorState: errors))
        #expect(errors.isPresented)
        #expect(task.title == "Draft")
        #expect(try ModelContext(writable).fetch(FetchDescriptor<TaskItem>()).first?.title == "Original")
        errors.dismiss()
        let scheduled = ReminderScheduler.requestReconcile(modelContext: readOnly.mainContext, onSaveFailure: {
            ViewPersistence.report($0, to: errors)
        })
        #expect(!scheduled)
        #expect(errors.isPresented)
        #expect(task.title == "Draft")
    }

    @Test("A move can retry an isolated failed save and still reports a normal no-op")
    func moveRetry() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let source = TaskList(serverURL: "/source/", name: "Source", colorHex: "#007AFF")
        let destination = TaskList(serverURL: "/destination/", name: "Destination", colorHex: "#007AFF")
        let task = TaskItem(title: "Move")
        context.insert(source); context.insert(destination); context.insert(task)
        task.taskList = source
        task.remoteHref = "/source/task.ics"; task.etag = "source-baseline"
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: "https://fixture.invalid", username: "fixture")
        context.insert(account); source.account = account; destination.account = account
        try SyncResourceFixture.prove(task, in: context)
        try context.save()
        let errors = ErrorState()
        #expect(!MoveDestinations.perform(task, toListID: destination.id, in: context, errorState: errors,
            save: { throw SaveFailure() }))
        #expect(errors.isPresented)
        #expect(task.taskList?.id == source.id)
        #expect(task.pendingMoveFromHref == nil)
        #expect(MoveDestinations.perform(task, toListID: destination.id, in: context,
            errorState: errors))
        let read = ModelContext(container)
        let saved = try #require(try read.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(saved.taskList?.id == destination.id)
        #expect(saved.pendingMoveFromHref == "/source/task.ics")
        #expect(try read.fetch(FetchDescriptor<TaskItem>()).count == 1)
        #expect(!MoveDestinations.perform(task, toListID: destination.id, in: context))
    }

    @Test("Failed uncompletion preserves completion until retry succeeds")
    func uncompletionRetry() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "Done")
        context.insert(task)
        try TaskCompletionLogic.markCompleted(task)
        try context.save()
        let originalCompletedDate = task.completedDate
        var reloads = 0
        var effects = 0
        let errors = ErrorState()
        let coordinator = TaskCompletionCoordinator(onWidgetReload: { reloads += 1 }, onCompletionDonation: { _ in })
        coordinator.toggle(task, save: {
            try ReminderSchedulingJournal.saveTaskChanges(in: context, save: { throw SaveFailure() })
        }, errorState: errors) { effects += 1 }
        #expect(errors.isPresented)
        #expect(task.status == .completed && task.completedDate == originalCompletedDate)
        #expect(reloads == 0 && effects == 0)
        coordinator.toggle(task, save: { try ReminderSchedulingJournal.saveTaskChanges(in: context) }) { effects += 1 }
        #expect(task.status == .needsAction)
        #expect(reloads == 1 && effects == 1)
    }

    @Test("Detail status failure preserves recurrence and gates reminder cancellation and reconcile")
    func detailStatusRetry() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "Task")
        context.insert(task)
        try context.save()
        var cancellations = 0
        var reconciles = 0
        #expect(throws: SaveFailure.self) {
            try TaskDetailView.applyStatusChange(.completed, to: task, in: context,
                save: { throw SaveFailure() }, requestReconcile: { _ in reconciles += 1 },
                cancelReminder: { _ in cancellations += 1 })
        }
        #expect(task.status == .needsAction)
        #expect(cancellations == 0 && reconciles == 0)
        try TaskDetailView.applyStatusChange(.completed, to: task, in: context,
            requestReconcile: { _ in reconciles += 1 }, cancelReminder: { _ in cancellations += 1 })
        #expect(cancellations == 1 && reconciles == 1)
    }

    @Test("Revoked Task Detail due-date toggle leaves no work for a later unrelated save",
          arguments: [false, true])
    func revokedDetailDueDateToggle(commitPrimarySave: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await checkRevokedDetailDueDateToggle(storeURL: directory.appendingPathComponent("local.store"),
            commitPrimarySave: commitPrimarySave)
    }

    private func checkRevokedDetailDueDateToggle(storeURL: URL, commitPrimarySave: Bool) async throws {
        let schema = Schema(SchemaV2.models)
        let configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        context.autosaveEnabled = false

        let account = ServerAccount(displayName: "Permission fixture", serverBaseURL: "https://permissions.invalid",
            username: "fixture", mode: .nextcloud)
        let list = TaskList(serverURL: "/shared/", name: "Shared", colorHex: "#007AFF")
        let task = TaskItem(title: "Imported recurring task")
        let peer = TaskItem(title: "Unrelated draft")
        let due = Date(timeIntervalSince1970: 1_728_000_000)
        let modified = due.addingTimeInterval(-600)
        let rule = "FREQ=DAILY"
        context.insert(account)
        context.insert(list)
        context.insert(task)
        context.insert(peer)
        list.account = account
        task.taskList = list
        task.dueDate = due
        task.isDueDateOnly = true
        task.reminderOffset = 600
        task.recurrenceRule = rule
        task.isDirty = true
        task.lastModifiedDate = modified
        try context.save()
        let listID = list.id
        let taskID = task.id
        let peerID = peer.id
        let listDescriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })
        let taskDescriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })
        let peerDescriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == peerID })
        try #require(!list.isReadOnly)

        let incoming = ModelContext(container)
        let incomingList = try #require(try incoming.fetch(listDescriptor).first)
        incomingList.isReadOnly = true
        try incoming.save()
        let privilegeReader = ModelContext(container)
        let committedList = try #require(try privilegeReader.fetch(listDescriptor).first)
        try #require(committedList.isReadOnly)
        peer.descriptionText = "Still pending"

        let errors = ErrorState()
        var reconcileRequests = 0
        let accepted = TaskDetailView.applyDueDateToggle(false, to: task, in: context,
            errorState: errors,
            requestReconcile: { owner, onSaveFailure in
                reconcileRequests += 1
                do {
                    // Use the scheduler's real transaction without the system notification store.
                    try ReminderSchedulingJournal.saveTaskChanges(in: owner, needsRecovery: true, save: {
                        guard commitPrimarySave else { throw SaveFailure() }
                        try owner.save()
                    })
                    return true
                } catch {
                    onSaveFailure(error)
                    return false
                }
            })

        #expect(!accepted)
        #expect(errors.isPresented)
        #expect(reconcileRequests == 0)
        #expect(task.dueDate == due)
        #expect(task.isDueDateOnly)
        #expect(task.recurrenceRule == rule)
        #expect(task.reminderOffset == 600)
        #expect(task.isDirty && task.lastModifiedDate == modified)
        #expect(peer.descriptionText == "Still pending")
        #expect(!context.changedModelsArray.contains { $0.persistentModelID == task.persistentModelID })
        #expect(try ReminderSchedulingJournal.capture(in: context).isEmpty)
        #expect(try CalendarMirrorState.pending(in: context, taskID: taskID).isEmpty)

        await Task.yield()
        #expect(!context.changedModelsArray.contains { $0.persistentModelID == task.persistentModelID })
        let beforePeerSave = ModelContext(container)
        let storedPeer = try #require(try beforePeerSave.fetch(peerDescriptor).first)
        #expect(storedPeer.descriptionText == nil)
        // Deliberately bypass the journal: this is the unrelated save that could leak a live mutation.
        try context.save()
        let read = ModelContext(container)
        let persistedTask = try #require(try read.fetch(taskDescriptor).first)
        let persistedPeer = try #require(try read.fetch(peerDescriptor).first)
        #expect(persistedTask.dueDate == due)
        #expect(persistedTask.isDueDateOnly)
        #expect(persistedTask.recurrenceRule == rule)
        #expect(persistedTask.reminderOffset == 600)
        #expect(persistedTask.isDirty && persistedTask.lastModifiedDate == modified)
        #expect(persistedPeer.descriptionText == "Still pending")
        #expect(try ReminderSchedulingJournal.capture(in: read).isEmpty)
        #expect(try CalendarMirrorState.pending(in: read, taskID: taskID).isEmpty)
    }

    @Test("Task Detail refuses status and recurrence completion on a read-only list",
          arguments: [false, true])
    func readOnlyDetailStatus(recurring: Bool) throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let list = TaskList(serverURL: "/shared/", name: "Shared", colorHex: "#007AFF")
        let task = TaskItem(title: "Imported task")
        let due = Date(timeIntervalSince1970: 1_728_000_000)
        let modified = due.addingTimeInterval(-600)
        list.isReadOnly = true
        context.insert(list)
        context.insert(task)
        task.taskList = list
        task.dueDate = due
        task.reminderOffset = 600
        task.recurrenceRule = recurring ? "FREQ=DAILY" : nil
        task.lastModifiedDate = modified
        try context.save()
        let taskID = task.id
        var saves = 0
        var reconciles = 0
        var cancellations = 0

        #expect(throws: (any Error).self) {
            try TaskDetailView.applyStatusChange(.completed, to: task, in: context,
                save: { saves += 1; try context.save() },
                requestReconcile: { _ in reconciles += 1 },
                cancelReminder: { _ in cancellations += 1 })
        }
        #expect(saves == 0 && reconciles == 0 && cancellations == 0)
        #expect(!context.hasChanges)
        #expect(task.status == .needsAction)
        #expect(task.dueDate == due && task.reminderOffset == 600)
        #expect(task.completedDate == nil && task.percentComplete == 0)
        #expect(!task.isDirty && task.lastModifiedDate == modified)
        let read = ModelContext(container)
        let stored = try #require(try read.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate {
            $0.id == taskID
        })).first)
        #expect(stored.status == .needsAction && stored.dueDate == due)
        #expect(try ReminderSchedulingJournal.capture(in: read).isEmpty)
        #expect(try CalendarMirrorState.pending(in: read, taskID: taskID).isEmpty)
    }

    @Test("Deletion checks a read-only grandchild behind a writable tombstone before changing any row")
    func deleteRefusesReadOnlyDescendant() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let writable = TaskList(serverURL: "/owned/", name: "Owned", colorHex: "#007AFF")
        let readOnly = TaskList(serverURL: "/shared/", name: "Shared", colorHex: "#007AFF")
        readOnly.isReadOnly = true
        let root = TaskItem(title: "Root")
        let tombstone = TaskItem(title: "Previously removed")
        let grandchild = TaskItem(title: "Read-only child")
        let before = Date(timeIntervalSince1970: 1_728_000_000)
        context.insert(writable)
        context.insert(readOnly)
        for row in [root, tombstone, grandchild] {
            context.insert(row)
            row.lastModifiedDate = before
        }
        root.taskList = writable
        tombstone.taskList = writable
        tombstone.parentTask = root
        tombstone.isDeletedLocally = true
        grandchild.taskList = readOnly
        grandchild.parentTask = tombstone
        try context.save()
        let rootID = root.id
        let tombstoneID = tombstone.id
        let grandchildID = grandchild.id
        let errors = ErrorState()
        var saves = 0

        let deleted = TaskDeletionPersistence.perform(root, in: context, errorState: errors,
            save: { saves += 1; try context.save() })
        #expect(deleted == nil)
        #expect(saves == 0)
        #expect(errors.isPresented)
        #expect(!context.hasChanges)
        #expect(!root.isDeletedLocally && tombstone.isDeletedLocally && !grandchild.isDeletedLocally)
        let read = ModelContext(container)
        let rows = try read.fetch(FetchDescriptor<TaskItem>())
        let storedRoot = try #require(rows.first { $0.id == rootID })
        let storedTombstone = try #require(rows.first { $0.id == tombstoneID })
        let storedGrandchild = try #require(rows.first { $0.id == grandchildID })
        #expect(!storedRoot.isDeletedLocally && storedTombstone.isDeletedLocally && !storedGrandchild.isDeletedLocally)
        #expect(rows.allSatisfy { !$0.isDirty && $0.lastModifiedDate == before })
        #expect(try ReminderSchedulingJournal.capture(in: read).isEmpty)
        #expect(try CalendarMirrorState.pending(in: read).isEmpty)
    }

    @Test("A revoked Detail reminder offset never reaches the task or notification request", arguments: [nil, 900] as [Int?])
    func revokedDetailReminderOffset(offset: Int?) throws {
        try withRevokedReminderFixture(dirty: true) { context, task, peer, revoke in
            try revoke()
            let taskID = task.id
            let errors = ErrorState()
            var permissions = 0
            var reconciles = 0
            peer.title = "Unrelated pending edit"
            let accepted = TaskDetailView.applyReminderOffset(offset, to: task, in: context, errorState: errors,
                requestPermission: { permissions += 1 }, requestReconcile: { writer, onSaveFailure in
                    reconciles += 1
                    return saveReminderFixture(in: writer, onSaveFailure: onSaveFailure)
                })

            #expect(!accepted)
            #expect(errors.isPresented)
            #expect(permissions == 0 && reconciles == 0)
            #expect(task.reminderOffset == 300)
            #expect(!task.isNaggingReminder)
            #expect(!context.changedModelsArray.contains { $0.persistentModelID == task.persistentModelID })
            #expect(try ReminderSchedulingJournal.capture(in: context).isEmpty)
            #expect(try CalendarMirrorState.pending(in: context, taskID: taskID).isEmpty)
            let peerID = peer.id
            let before = ModelContext(context.container)
            let storedPeer = try #require(try before.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == peerID })).first)
            #expect(storedPeer.title == "Peer")
            try context.save()
            let after = ModelContext(context.container)
            let stored = try #require(try after.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
            #expect(stored.reminderOffset == 300)
            #expect(stored.isDirty && stored.lastModifiedDate == Date(timeIntervalSince1970: 1_728_000_000))
        }
    }

    @Test("Hourly nag remains local after revocation and preserves existing outbound flags", arguments: [false, true])
    func readOnlyDetailHourlyNag(dirty: Bool) throws {
        try withRevokedReminderFixture(dirty: dirty) { context, task, _, revoke in
            try revoke()
            let taskID = task.id
            let errors = ErrorState()
            var reconciles = 0
            let saved = TaskDetailView.applyHourlyNag(true, to: task, in: context, errorState: errors,
                requestReconcile: { writer, onSaveFailure in
                    reconciles += 1
                    return saveReminderFixture(in: writer, onSaveFailure: onSaveFailure)
                })
            #expect(saved)
            #expect(!errors.isPresented)
            #expect(reconciles == 1)
            var afterCommit = 0
            var dismissals = 0
            TaskDetailView.applyDone(to: task, textDraft: TaskTextDraft(task), in: context, errorState: errors,
                afterCommit: { afterCommit += 1 }, dismiss: { dismissals += 1 })
            #expect(afterCommit == 0 && dismissals == 1)
            #expect(!errors.isPresented)
            let reader = ModelContext(context.container)
            let stored = try #require(try reader.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
            #expect(stored.isNaggingReminder)
            #expect(stored.reminderOffset == 300)
            #expect(stored.title == "Existing reminder")
            #expect(stored.isDirty == dirty)
            #expect(stored.lastModifiedDate == Date(timeIntervalSince1970: 1_728_000_000))
            #expect(try ReminderSchedulingJournal.capture(in: reader).count == 1)
        }
    }

    @Test("Detail Done retains a revoked text draft and dismisses view-only with no new task commit",
          arguments: [false, true])
    func revokedDetailDone(hasTextDraft: Bool) throws {
        try withRevokedReminderFixture(dirty: true) { context, task, peer, revoke in
            let draft = TaskTextDraft(task)
            if hasTextDraft {
                draft.title = "Updated draft title"
                draft.notes = "Updated draft notes"
            }
            try revoke()
            let taskID = task.id
            let errors = ErrorState()
            peer.title = "Unrelated pending edit"
            var commits = 0
            var dismissals = 0
            TaskDetailView.applyDone(to: task, textDraft: draft, in: context, errorState: errors,
                afterCommit: { commits += 1 }, dismiss: { dismissals += 1 })
            #expect(dismissals == (hasTextDraft ? 0 : 1))
            #expect(errors.isPresented == hasTextDraft)
            #expect(commits == 0)
            #expect(draft.hasChanges == hasTextDraft)
            #expect(draft.title == (hasTextDraft ? "Updated draft title" : "Existing reminder"))
            #expect(draft.notes == (hasTextDraft ? "Updated draft notes" : ""))
            #expect(!context.changedModelsArray.contains { $0.persistentModelID == task.persistentModelID })
            #expect(try ReminderSchedulingJournal.capture(in: context).isEmpty)
            #expect(try CalendarMirrorState.pending(in: context, taskID: taskID).isEmpty)
            let peerID = peer.id
            let before = ModelContext(context.container)
            let storedPeer = try #require(try before.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == peerID })).first)
            #expect(storedPeer.title == "Peer")
            try context.save()
            let after = ModelContext(context.container)
            let stored = try #require(try after.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
            #expect(stored.title == "Existing reminder")
            #expect(stored.descriptionText == nil)
            #expect(stored.isDirty && stored.lastModifiedDate == Date(timeIntervalSince1970: 1_728_000_000))
        }
    }

    @Test("Writable Detail Done commits staged text and publishes once")
    func writableDetailDone() throws {
        try withRevokedReminderFixture(dirty: false) { context, task, _, _ in
            let taskID = task.id
            let draft = TaskTextDraft(task)
            draft.title = "Updated title"
            draft.notes = "Updated notes"
            let errors = ErrorState()
            var effects: [String] = []
            TaskDetailView.applyDone(to: task, textDraft: draft, in: context, errorState: errors,
                afterCommit: { effects.append("publish") }, dismiss: { effects.append("dismiss") })
            #expect(effects == ["publish", "dismiss"])
            #expect(!errors.isPresented && !draft.hasChanges)
            let reader = ModelContext(context.container)
            let stored = try #require(try reader.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
            #expect(stored.title == "Updated title" && stored.descriptionText == "Updated notes")
            #expect(stored.isDirty && stored.reminderOffset == 300)
            #expect(try ReminderSchedulingJournal.capture(in: reader).count == 1)
        }
    }

    @Test("Mounted Repeat refuses a permission change or newer imported custom rule without scheduling",
          arguments: [false, true])
    func detailRepeatChecksCurrentTask(revokePermission: Bool) throws {
        try withRevokedReminderFixture(dirty: false) { context, task, peer, revoke in
            let taskID = task.id
            let original = task.recurrenceRule
            let imported = "FREQ=DAILY;COUNT=7"
            if revokePermission {
                try revoke()
            } else {
                let incoming = ModelContext(context.container)
                let current = try #require(try incoming.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
                current.recurrenceRule = imported
                try incoming.save()
            }
            let errors = ErrorState()
            var requests = 0
            let accepted = TaskDetailView.applyRecurrenceRule("FREQ=WEEKLY", replacing: original,
                committedAtOpen: original, to: task, in: context, errorState: errors, requestReconcile: { _, _ in
                    requests += 1
                    return true
                })
            #expect(!accepted && errors.isPresented)
            #expect(requests == 0)
            peer.title = "Later save"
            try context.save()
            let reader = ModelContext(context.container)
            let stored = try #require(try reader.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
            #expect(stored.recurrenceRule == (revokePermission ? original : imported))
            #expect(stored.dueDate == Date(timeIntervalSince1970: 1_728_003_600))
            #expect(!stored.isDirty && stored.lastModifiedDate == Date(timeIntervalSince1970: 1_728_000_000))
            #expect(try ReminderSchedulingJournal.capture(in: reader).isEmpty)
            #expect(try CalendarMirrorState.pending(in: reader, taskID: taskID).isEmpty)
        }
    }

    private func withRevokedReminderFixture(dirty: Bool,
        check: (ModelContext, TaskItem, TaskItem, () throws -> Void) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(SchemaV2.models)
        let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("local.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        context.autosaveEnabled = false
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: "https://permissions.invalid",
            username: "fixture", mode: .nextcloud)
        let list = TaskList(serverURL: "/shared/", name: "Shared", colorHex: "#007AFF")
        let task = TaskItem(title: "Existing reminder")
        let peer = TaskItem(title: "Peer")
        context.insert(account)
        context.insert(list)
        context.insert(task)
        context.insert(peer)
        list.account = account
        task.taskList = list
        task.dueDate = Date(timeIntervalSince1970: 1_728_003_600)
        task.reminderOffset = 300
        task.isDirty = dirty
        task.lastModifiedDate = Date(timeIntervalSince1970: 1_728_000_000)
        try context.save()
        try #require(!list.isReadOnly)
        let listID = list.id
        let descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })
        try check(context, task, peer) {
            let incoming = ModelContext(container)
            let revoked = try #require(try incoming.fetch(descriptor).first)
            revoked.isReadOnly = true
            try incoming.save()
            try #require(try ModelContext(container).fetch(descriptor).first?.isReadOnly == true)
        }
    }

    private func saveReminderFixture(in context: ModelContext, onSaveFailure: (Error) -> Void) -> Bool {
        do {
            try ReminderSchedulingJournal.saveTaskChanges(in: context, needsRecovery: true)
            return true
        } catch {
            onSaveFailure(error)
            return false
        }
    }

    @Test("Calendar failure uses generic localized copy and keeps details out of the alert")
    func calendarError() {
        let errors = ErrorState()
        ViewPersistence.reportCalendarFailure("private account/path", to: errors)
        #expect(errors.isPresented)
        #expect(errors.currentError == String(localized: "calendar.syncFailed", defaultValue: "Couldn't sync your calendars"))
        #expect(errors.currentError?.contains("private") == false)
    }

    @Test("A hidden deleted row can retry its pending save without repeating deletion or effects")
    func pendingDeletionRetry() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let tag = NowThis.Tag(name: "Delete")
        context.insert(tag)
        try context.save()
        context.delete(tag)
        var attempts = 0
        var effects = 0
        let errors = ErrorState()
        ViewPersistence.savePendingDeletion(in: context, errorState: errors, needsRecovery: true,
            save: {
                attempts += 1
                if attempts < 3 { throw SaveFailure() }
                try context.save()
            }, onSaved: { effects += 1 })
        #expect(errors.isPresented)
        #expect(errors.retryAction != nil)
        #expect(attempts == 1 && effects == 0)
        errors.retryAction?()
        #expect(attempts == 2 && effects == 0)
        #expect(errors.isPresented && errors.retryAction != nil)
        errors.retryAction?()
        #expect(attempts == 3 && effects == 1)
        #expect(!errors.isPresented && errors.retryAction == nil)
        #expect(try ModelContext(container).fetch(FetchDescriptor<NowThis.Tag>()).isEmpty)
    }

    enum CompletionJourney: CaseIterable {
        case recurring, complete, reopen
    }

    private func completionFixture(_ journey: CompletionJourney, in context: ModelContext) throws -> TaskItem {
        let task = TaskItem(title: "Committed change")
        context.insert(task)
        if journey == .recurring {
            task.recurrenceRule = "FREQ=DAILY"
            task.dueDate = Date(timeIntervalSince1970: 2_000_000_000)
        } else if journey == .reopen {
            try TaskCompletionLogic.markCompleted(task)
        }
        try context.save()
        return task
    }

    private var recoveryMessage: String {
        String(localized: "persistence.reminderRecoveryFailed",
            defaultValue: "Your change was saved, but reminders couldn't be updated. Retry to update reminders.")
    }

    @Test("Detail completion recovery retry never repeats the committed change", arguments: CompletionJourney.allCases)
    func committedDetailRecoveryRetry(journey: CompletionJourney) throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = try completionFixture(journey, in: context)
        let originalDue = task.dueDate
        let errors = ErrorState()
        var primarySaves = 0
        var recoveryAttempts = 0
        var cancellations = 0
        var unexpectedError: Error?
        do {
            try TaskDetailView.applyStatusChange(journey == .reopen ? .needsAction : .completed,
                to: task, in: context, save: { primarySaves += 1; try context.save() }, errorState: errors,
                requestReconcile: { context in
                    recoveryAttempts += 1
                    try ReminderSchedulingJournal.saveTaskChanges(in: context, needsRecovery: true, save: {
                        if recoveryAttempts < 3 { throw SaveFailure() }
                        try context.save()
                    })
                }, cancelReminder: { _ in cancellations += 1 })
        } catch { unexpectedError = error }
        #expect(unexpectedError == nil, "a committed change must not be reported as an unsaved change")
        let committedStatus = task.status
        let committedDue = task.dueDate
        #expect(committedStatus == (journey == .complete ? .completed : .needsAction))
        #expect(committedDue == (journey == .recurring ? originalDue?.addingTimeInterval(86400) : originalDue))
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.dueDate == committedDue)
        #expect(errors.currentError == recoveryMessage)
        #expect(errors.retryAction != nil)
        let savedRetry = errors.retryAction
        savedRetry?()
        #expect(recoveryAttempts == 2)
        #expect(errors.isPresented && errors.currentError == recoveryMessage)
        errors.retryAction?()
        #expect(recoveryAttempts == 3)
        #expect(!errors.isPresented)
        savedRetry?()
        #expect(recoveryAttempts == 3, "an already completed recovery callback cannot publish twice")
        #expect(primarySaves == 1)
        #expect(cancellations == (journey == .complete ? 1 : 0))
        #expect(task.status == committedStatus && task.dueDate == committedDue)
    }

    @Test("Row completion publishes once while recovery retries only scheduling", arguments: CompletionJourney.allCases)
    func committedRowRecoveryRetry(journey: CompletionJourney) async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = try completionFixture(journey, in: context)
        let originalDue = task.dueDate
        let errors = ErrorState()
        var primarySaves = 0
        var recoveryAttempts = 0
        var publications = 0
        var widgetReloads = 0
        var donations = 0
        let coordinator = TaskCompletionCoordinator(animationDelay: 0, onWidgetReload: { widgetReloads += 1 }, onCompletionDonation: { _ in donations += 1 })
        coordinator.toggle(task, save: {
            primarySaves += 1
            try ReminderSchedulingJournal.saveTaskChanges(in: context)
        }, errorState: errors, requestReconcile: {
            recoveryAttempts += 1
            try ReminderSchedulingJournal.saveTaskChanges(in: context, needsRecovery: true, save: {
                if recoveryAttempts < 3 { throw SaveFailure() }
                try context.save()
            })
        }) { publications += 1 }
        try await Task.sleep(for: .milliseconds(100))
        let committedStatus = task.status
        let committedDue = task.dueDate
        #expect(committedStatus == (journey == .complete ? .completed : .needsAction))
        #expect(committedDue == (journey == .recurring ? originalDue?.addingTimeInterval(86400) : originalDue))
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.status == committedStatus)
        #expect(primarySaves == 1 && publications == 1 && widgetReloads == 1)
        #expect(donations == (journey == .reopen ? 0 : 1))
        #expect(recoveryAttempts == 1)
        #expect(errors.currentError == recoveryMessage)
        #expect(errors.retryAction != nil)
        let savedRetry = errors.retryAction
        savedRetry?()
        #expect(recoveryAttempts == 2)
        #expect(errors.isPresented)
        errors.retryAction?()
        #expect(recoveryAttempts == 3)
        #expect(!errors.isPresented)
        savedRetry?()
        #expect(recoveryAttempts == 3)
        #expect(primarySaves == 1 && publications == 1 && widgetReloads == 1)
        #expect(donations == (journey == .reopen ? 0 : 1))
        #expect(task.status == committedStatus && task.dueDate == committedDue)
    }

    enum QuickAddCreationRoute: CaseIterable {
        case currentList, configuredDefault, displayedAlphabeticalDefault, fallbackAfterOpening, namedToken, calendar
    }

    @Test("Quick Add keeps a denied draft and its destination for retry",
          arguments: QuickAddCreationRoute.allCases)
    func quickAddCreationPermission(route: QuickAddCreationRoute) throws {
        let restoreDefaults = clearCreationListPreferences()
        defer { restoreDefaults() }
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        main.autosaveEnabled = false
        let target = addCreationList(name: "Alpha", in: main)
        let neighbor = addCreationList(name: "Zulu", in: main)
        let targetID = target.id
        switch route {
        case .configuredDefault:
            TaskDefaultsPreferences.setDefaultListID(targetID)
        case .currentList, .namedToken, .calendar:
            TaskDefaultsPreferences.setDefaultListID(neighbor.id)
        case .displayedAlphabeticalDefault, .fallbackAfterOpening:
            break
        }
        try main.save()
        let configured = UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey)
        let date = Date(timeIntervalSince1970: 1_892_030_400)
        let selected = route == .calendar
            ? QuickAddView.CalendarSelection(date: date, destination: .init(target))
            : nil
        let displayed = selected?.destination
        let defaultList: TaskList? = switch route {
        case .currentList, .configuredDefault, .displayedAlphabeticalDefault: target
        case .fallbackAfterOpening, .namedToken, .calendar: nil
        }
        let entry = route == .namedToken ? "Retain these words #Alpha @newlabel !high"
            : "Retain these words @newlabel !high"
        let parsed = try TaskTextValidation.quickAdd(entry)
        let draft = TaskCreationDraft()
        let owned = draft.context(in: container)
        let retained = try #require(try owned.fetch(FetchDescriptor<TaskList>()).first { $0.id == targetID })
        #expect(!retained.isReadOnly)
        let errors = ErrorState()
        var calendarDestinationChanges: [QuickAddView.Destination?] = []
        var commits: [String] = []
        var primarySaves = 0
        func submit(tag: String = "newlabel", failSave: Bool = false) throws {
            let parse = tag == "newlabel" ? parsed
                : try TaskTextValidation.quickAdd(entry.replacingOccurrences(of: "@newlabel", with: "@" + tag))
            QuickAddView.commitCreation(title: parse.cleanTitle, parseResult: parse, selectedPriority: .low,
                pickerDate: date, recurrenceRule: "FREQ=DAILY", defaultList: defaultList,
                calendarSelection: selected, displayedDestination: displayed, creationDraft: draft,
                modelContext: main, errorState: errors, save: {
                    primarySaves += 1
                    if failSave { throw SaveFailure() }
                    try owned.save()
                },
                reportCalendarDestinationChange: { calendarDestinationChanges.append($0) }
            ) { task, _, donation in
                commits.append(task.id)
                #expect(donation?.id == targetID)
            }
        }

        let pendingID: String?
        let pendingModels: Set<PersistentIdentifier>
        if route == .calendar {
            try submit(tag: "pendinglabel", failSave: true)
            let pending = try #require(owned.insertedModelsArray.compactMap { $0 as? TaskItem }.first)
            pendingID = pending.id
            pendingModels = Set(owned.insertedModelsArray.map(\.persistentModelID))
            #expect(pending.tags.map(\.name) == ["pendinglabel"] && commits.isEmpty)
            errors.dismiss()
        } else {
            pendingID = nil
            pendingModels = []
        }
        try setCreationListPermission(targetID, readOnly: true, in: container)
        let previousSaves = primarySaves
        try submit()
        #expect(errors.isPresented)
        #expect(errors.currentError?.isEmpty == false)
        #expect(commits.isEmpty && primarySaves == previousSaves)
        #expect(calendarDestinationChanges.isEmpty)
        #expect(draft.hasPendingTask == (pendingID != nil))
        #expect(Set(owned.insertedModelsArray.map(\.persistentModelID)) == pendingModels)
        if let pendingID {
            let pending = owned.insertedModelsArray.compactMap { $0 as? TaskItem }.first
            #expect(pending?.id == pendingID && pending?.tags.map(\.name) == ["pendinglabel"])
        }
        #expect(UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey) == configured)
        let denied = ModelContext(container)
        let saved = try denied.fetch(FetchDescriptor<TaskItem>())
        #expect(saved.isEmpty)
        #expect(try denied.fetchCount(FetchDescriptor<NowThis.Tag>()) == 0)
        #expect(try denied.fetchCount(FetchDescriptor<SyncMetadata>()) == 0)
        guard saved.isEmpty else { return }

        try setCreationListPermission(targetID, readOnly: false, in: container)
        errors.dismiss()
        try submit()
        let fresh = ModelContext(container)
        let created = try fresh.fetch(FetchDescriptor<TaskItem>())
        #expect(created.count == 1)
        #expect(commits == created.map(\.id))
        if let pendingID { #expect(created.first?.id == pendingID) }
        #expect(created.first?.taskList?.id == targetID)
        #expect(created.first?.title == "Retain these words")
        #expect(created.first?.priority == .high)
        #expect(created.first?.dueDate == date && created.first?.isDueDateOnly == false)
        #expect(created.first?.recurrenceRule == "FREQ=DAILY")
        #expect(created.first?.tags.map(\.name) == ["newlabel"])
        #expect(try fresh.fetch(FetchDescriptor<NowThis.Tag>()).map(\.name) == ["newlabel"])
        #expect(primarySaves == previousSaves + 1)
        #expect(errors.currentError == nil)
        #expect(UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey) ==
            (route == .fallbackAfterOpening ? targetID : configured))
    }

    enum LocalCreationDestination: CaseIterable {
        case vault, recoveryOnly, readOnlyRecoveryOnly, unbound
    }

    @Test("Ordinary Quick Add keeps Vault, Recovery, and unbound creation rules",
          arguments: LocalCreationDestination.allCases)
    func quickAddLocalCreationPermission(destination: LocalCreationDestination) throws {
        let restoreDefaults = clearCreationListPreferences()
        defer { restoreDefaults() }
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        let list: TaskList?
        if destination == .unbound {
            list = nil
        } else {
            let account = ServerAccount(vaultDisplayName: "Vault")
            main.insert(account)
            let local = TaskList(serverURL: destination == .vault ? "" : TaskList.recoveryListServerURL,
                name: destination == .vault ? "Vault" : "Recovered Tasks", colorHex: "#123456")
            main.insert(local)
            local.account = account
            local.isReadOnly = destination == .readOnlyRecoveryOnly
            list = local
        }
        try main.save()
        let draft = TaskCreationDraft()
        let errors = ErrorState()
        var commits = 0
        QuickAddView.commitCreation(title: "Local draft", parseResult: .init(), selectedPriority: .none,
            pickerDate: nil, recurrenceRule: nil, defaultList: nil, calendarSelection: nil,
            displayedDestination: nil, creationDraft: draft, modelContext: main, errorState: errors,
            reportCalendarDestinationChange: { _ in Issue.record("Unexpected Calendar destination change") }
        ) { _, _, _ in commits += 1 }
        let read = ModelContext(container)
        let tasks = try read.fetch(FetchDescriptor<TaskItem>())
        if destination == .readOnlyRecoveryOnly {
            #expect(commits == 0 && tasks.isEmpty && errors.isPresented)
            #expect(UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey) == nil)
            #expect(try read.fetchCount(FetchDescriptor<SyncMetadata>()) == 0)
        } else {
            #expect(commits == 1 && tasks.count == 1)
            #expect(tasks.first?.taskList?.id == list?.id)
            #expect(tasks.first?.title == "Local draft")
            #expect(UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey) == list?.id)
        }
    }

    @Test("Denied inline creation does not renumber roots or leak into an unrelated save",
          arguments: [false, true], [false, true])
    func inlineCreationPermission(explicit: Bool, priorFailedSave: Bool) throws {
        let restoreDefaults = clearCreationListPreferences()
        defer { restoreDefaults() }
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        main.autosaveEnabled = false
        let target = addCreationList(name: "Alpha", in: main)
        let neighbor = addCreationList(name: "Zulu", in: main)
        let targetID = target.id
        let root = TaskItem(title: "Keep original rank")
        let peer = TaskItem(title: "Peer in another list")
        main.insert(root)
        main.insert(peer)
        root.taskList = target
        root.manualSortOrder = Int.min
        root.isDirty = false
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        root.lastModifiedDate = modified
        peer.taskList = neighbor
        if explicit { TaskDefaultsPreferences.setDefaultListID(neighbor.id) }
        try main.save()
        let configured = UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey)
        let peerTicket = ReminderSchedulingJournal.enqueue(in: main)
        peer.descriptionText = "An unrelated unsaved note"
        let draft = TaskCreationDraft()
        let errors = ErrorState()
        var commits: [String] = []
        var primarySaves = 0
        func submit(failSave: Bool = false) {
            TaskListView.commitInlineCreation(title: "Inline text stays available",
                selectedTaskList: explicit ? target : nil, liveRoots: [root, peer], manualAscending: true,
                dueDateRule: { .tomorrow }, creationDraft: draft, modelContext: main, errorState: errors,
                save: {
                    primarySaves += 1
                    if failSave { throw SaveFailure() }
                    try main.save()
                }
            ) { task in
                commits.append(task.id)
                draft.didSave()
            }
        }
        if priorFailedSave {
            submit(failSave: true)
            #expect(primarySaves == 1 && commits.isEmpty && errors.isPresented)
            if !explicit {
                #expect(UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey) == configured)
                // Keep the retry on the fallback branch after recording premature baseline adoption.
                TaskDefaultsPreferences.setDefaultListID(configured)
            }
            #expect(root.manualSortOrder == Int.min && !root.isDirty && root.lastModifiedDate == modified)
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 2)
            errors.dismiss()
        }
        try setCreationListPermission(targetID, readOnly: true, in: container)
        let previousSaves = primarySaves
        submit()
        #expect(errors.isPresented && errors.currentError?.isEmpty == false)
        #expect(commits.isEmpty && !draft.hasPendingTask && primarySaves == previousSaves)
        #expect(root.manualSortOrder == Int.min && !root.isDirty && root.lastModifiedDate == modified)
        #expect(peer.descriptionText == "An unrelated unsaved note")
        #expect(UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey) == configured)
        let beforePeerSave = ModelContext(container)
        let savedBefore = try beforePeerSave.fetch(FetchDescriptor<TaskItem>())
        #expect(Set(savedBefore.map(\.id)) == [root.id, peer.id])
        #expect(savedBefore.first { $0.id == peer.id }?.descriptionText != "An unrelated unsaved note")
        #expect(try beforePeerSave.fetchCount(FetchDescriptor<SyncMetadata>()) == 0)
        try main.save()
        let afterPeerSave = ModelContext(container)
        let savedAfter = try afterPeerSave.fetch(FetchDescriptor<TaskItem>())
        #expect(Set(savedAfter.map(\.id)) == [root.id, peer.id])
        #expect(savedAfter.first { $0.id == peer.id }?.descriptionText == "An unrelated unsaved note")
        #expect(savedAfter.first { $0.id == root.id }?.manualSortOrder == Int.min)
        let mirrorTickets = try CalendarMirrorState.pending(in: afterPeerSave)
        #expect(try ReminderSchedulingJournal.capture(in: afterPeerSave) == [peerTicket])
        if priorFailedSave {
            #expect(mirrorTickets.allSatisfy { $0.identity.taskID == peer.id })
        } else {
            #expect(mirrorTickets.isEmpty)
        }
        guard savedAfter.count == 2 else { return }

        try setCreationListPermission(targetID, readOnly: false, in: container)
        errors.dismiss()
        submit()
        let created = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
            .first { $0.title == "Inline text stays available" }
        #expect(commits.count == 1 && created?.id == commits.first && primarySaves == previousSaves + 1)
        #expect(created?.taskList?.id == targetID && created?.dueDate != nil)
        #expect(UserDefaults.standard.string(forKey: TaskDefaultsPreferences.defaultListIDKey) ==
            (explicit ? configured : targetID))
    }

    @Test("Subtask denial preserves the owned draft and committed parent for retry")
    func subtaskCreationPermission() throws {
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        main.autosaveEnabled = false
        let target = addCreationList(name: "Parent list", in: main)
        let parent = TaskItem(title: "Existing dirty parent")
        main.insert(parent)
        parent.taskList = target
        parent.isDirty = true
        parent.etag = "unchanged"
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        parent.lastModifiedDate = modified
        try main.save()

        let draft = TaskCreationDraft()
        let owned = draft.context(in: container)
        let pending = try #require(try draft.subtask(title: "Initial child text", parent: parent, in: container))
        let childID = pending.id
        #expect(!draft.saveOwnedChanges(errorState: ErrorState(), save: { throw SaveFailure() }))
        let priorPending = Set(owned.insertedModelsArray.map(\.persistentModelID))
        try setCreationListPermission(target.id, readOnly: true, in: container)
        let errors = ErrorState()
        do {
            if try draft.subtask(title: "Corrected child text", parent: parent, in: container) != nil {
                _ = draft.saveOwnedChanges(errorState: errors)
            }
        } catch { errors.show(error) }
        #expect(errors.isPresented && errors.currentError?.isEmpty == false)
        #expect(draft.hasPendingTask && pending.title == "Initial child text")
        #expect(Set(owned.insertedModelsArray.map(\.persistentModelID)) == priorPending)
        let denied = ModelContext(container)
        let tasks = try denied.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.map(\.id) == [parent.id])
        #expect(tasks.first?.isDirty == true && tasks.first?.etag == "unchanged")
        #expect(tasks.first?.lastModifiedDate == modified && tasks.first?.subtasks.isEmpty == true)
        #expect(try denied.fetchCount(FetchDescriptor<SyncMetadata>()) == 0)
        guard tasks.count == 1 else { return }

        try setCreationListPermission(target.id, readOnly: false, in: container)
        let retry = try #require(try draft.subtask(title: "Corrected child text", parent: parent, in: container))
        #expect(retry.id == childID)
        #expect(draft.saveOwnedChanges(errorState: ErrorState()))
        let fresh = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        let child = try #require(fresh.first { $0.id == childID })
        #expect(fresh.count == 2 && child.title == "Corrected child text")
        #expect(child.taskList?.id == target.id && child.parentTask?.id == parent.id && child.parentUID == parent.uid)
    }

    private func addCreationList(name: String, in context: ModelContext) -> TaskList {
        let account = ServerAccount(displayName: name, serverBaseURL: "https://creation.invalid", username: name)
        let list = TaskList(serverURL: "/creation/", name: name, colorHex: "#123456")
        context.insert(account)
        context.insert(list)
        list.account = account
        return list
    }

    private func setCreationListPermission(_ id: String, readOnly: Bool, in container: ModelContainer) throws {
        let writer = ModelContext(container)
        let descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == id })
        let list = try #require(try writer.fetch(descriptor).first)
        list.isReadOnly = readOnly
        try writer.save()
        let committed = try ModelContext(container).fetch(descriptor).first?.isReadOnly
        try #require(committed == readOnly)
    }

    private func clearCreationListPreferences() -> () -> Void {
        let defaults = UserDefaults.standard
        let keys = [TaskDefaultsPreferences.defaultListIDKey, TaskDefaultsPreferences.legacySiriListIDKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        return {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
    }

}
