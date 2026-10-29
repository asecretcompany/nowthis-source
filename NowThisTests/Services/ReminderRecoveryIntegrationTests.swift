import Foundation
import SwiftData
import Testing

@testable import NowThis

@Suite("Local reminder recovery", .serialized)
@MainActor
struct ReminderRecoveryIntegrationTests {
    @Test("A later usable server alarm reaches local registration without another sync")
    func importedAlarmRegistersLocally() async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let list = TaskList(id: "alarm-list", serverURL: "/alarms/", name: "Alarms", colorHex: "#007AFF")
        context.insert(list)
        try context.save()
        let remote = CalDAVClient.RemoteTask(href: "/alarms/import-alarm.ics", etag: "v1", icsData: """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:import-alarm
        SUMMARY:Imported reminder
        DUE:20501015T120000Z
        BEGIN:VALARM
        TRIGGER:-PT
        ACTION:DISPLAY
        END:VALARM
        BEGIN:VALARM
        TRIGGER:-PT15M
        ACTION:DISPLAY
        END:VALARM
        END:VTODO
        END:VCALENDAR
        """)
        let parsed = try SyncBodyValidation.parse(remote, using: ICalendarParser.FormatterCache())
        _ = try SyncInboundBatchWriter(container: container, listID: list.id).apply([parsed])

        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(saved.reminderOffset == 900)
        #expect(try !ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
        let store = CoordinatorNotificationStore()
        let outcome = await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: context, store: store, badgesEnabled: false, policy: .background)
        #expect(outcome.status == .confirmed)
        let request = try #require(store.pending["reminder-" + saved.id])
        let expected = try #require(ISO8601DateFormatter().date(from: "2050-10-15T11:45:00Z"))
        #expect(request.fireDate == expected)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    @Test("Detail title and status callbacks save and reconcile without Done, lifecycle, or sync",
          arguments: ["title", "completed", "cancelled"])
    func detailEditsPersistAndReconcileWithoutDone(edit: String) async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "Original detail title")
        task.id = "detail-edit"; task.dueDate = Date().addingTimeInterval(3_600)
        task.reminderOffset = 0; task.isNaggingReminder = true
        context.insert(task)
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        let store = CoordinatorNotificationStore()
        let initial = await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: context, store: store, badgesEnabled: false, policy: .background)
        #expect(initial.status == .confirmed)
        #expect(Set(store.pending.keys) == ["reminder-detail-edit", "nag-detail-edit"])
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)

        // Exercise the actual title/status callback boundary, with no Done action.
        // Other edits in the main context must survive the same transaction.
        task.notes = "A note still being edited"
        switch edit {
        case "title": task.title = "Renamed detail title"
        case "completed": task.status = .completed
        default: task.status = .cancelled
        }
        var reconciliation: Task<ReminderReconciliationOutcome, Never>?
        try TaskDetailView.saveReminderEdit(task, in: context) { requestedContext in
            reconciliation = Task {
                await ReminderScheduler.reconcileScheduledNotifications(
                    modelContext: requestedContext, store: store,
                    badgesEnabled: false, policy: .background)
            }
        }

        let savedContext = ModelContext(container)
        let saved = try #require(try savedContext.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(saved.title == (edit == "title" ? "Renamed detail title" : "Original detail title"))
        #expect(saved.status == (edit == "completed" ? .completed : edit == "cancelled" ? .cancelled : .needsAction))
        #expect(saved.notes == "A note still being edited")
        #expect(try !ReminderSchedulingJournal.capture(in: savedContext).isEmpty)
        let requested = try #require(reconciliation, "The edit callback must request local scheduling itself")
        let outcome = await requested.value
        #expect(outcome.status == .confirmed)
        if edit == "title" {
            #expect(Set(store.pending.keys) == ["reminder-detail-edit", "nag-detail-edit"])
            #expect(store.pending["reminder-detail-edit"]?.title == "Renamed detail title")
            #expect(store.pending["nag-detail-edit"]?.title == "Renamed detail title")
        } else {
            #expect(store.pending.isEmpty)
        }
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    @Test("Rejected detail save retains edits and never requests scheduling")
    func detailEditSaveFailureRetainsEdits() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "Saved")
        context.insert(task)
        try context.save()
        task.title = "Unsaved title"
        task.notes = "Unsaved note"
        let budget = BackgroundRunBudget()
        budget.expire()
        BackgroundRunBudget.$current.withValue(budget) {
            #expect(throws: CancellationError.self) {
                try TaskDetailView.saveReminderEdit(task, in: context) { _ in
                    Issue.record("Scheduling started after a rejected save")
                }
            }
        }
        #expect(task.title == "Unsaved title")
        #expect(task.notes == "Unsaved note")
        #expect(context.hasChanges)
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(saved.title == "Saved")
        #expect(saved.notes.isEmpty)
    }

    @Test("A saved widget completion or deletion wins over an unsaved foreground overlay",
          arguments: [false, true])
    func widgetMutationDuringAddOverridesUnsavedOverlay(deletesTask: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "Widget overlay race")
        task.id = "widget-overlay"; task.dueDate = Date().addingTimeInterval(3_600)
        task.reminderOffset = 0; task.isNaggingReminder = true
        context.insert(task)
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        let capturedTickets = try ReminderSchedulingJournal.capture(in: ModelContext(container))
        task.notes = "Keep this unsaved foreground note"
        #expect(!ReminderTaskOverlay(modelContext: context).upserts.isEmpty)
        let foreign = ReminderScheduler.PendingSnapshot(identifier: "foreign-request",
            fireDate: nil, badge: nil, title: nil)
        let store = CoordinatorNotificationStore(pausesFirstAdd: true, pending: [foreign])
        let run = Task { await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: context, store: store, badgesEnabled: false, policy: .background) }
        await store.waitUntilAddStarted()

        let widget = ModelContext(container)
        widget.autosaveEnabled = false
        let saved = try #require(try widget.fetch(FetchDescriptor<TaskItem>()).first)
        if deletesTask { widget.delete(saved) }
        else { TaskCompletionLogic.markCompleted(saved) }
        try ReminderSchedulingJournal.saveTaskChanges(in: widget)
        let allTickets = try ReminderSchedulingJournal.capture(in: ModelContext(container))
        #expect(!allTickets.subtracting(capturedTickets).isEmpty)
        // Extension cancellation can precede the acknowledgment of the app's old add.
        store.remove(identifiers: ["reminder-widget-overlay", "nag-widget-overlay"])
        store.releaseAdd()

        let outcome = await run.value
        #expect(outcome.status == .superseded)
        #expect(Set(store.pending.keys) == ["foreign-request"])
        #expect(!store.removedIdentifiers.contains("foreign-request"))
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)) == allTickets)
        #expect(task.notes == "Keep this unsaved foreground note")
        #expect(context.hasChanges)
        let freshTasks = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        if deletesTask { #expect(freshTasks.isEmpty) }
        else {
            #expect(freshTasks.first?.status == .completed)
            #expect(freshTasks.first?.notes.isEmpty == true)
        }
    }

    @Test("Without a newer save, reconciliation retains its immutable unsaved overlay and tickets")
    func unchangedSavedStatePreservesUnsavedOverlay() async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "Saved title")
        task.id = "preserved-overlay"; task.dueDate = Date().addingTimeInterval(3_600)
        task.reminderOffset = 0; task.isNaggingReminder = true
        context.insert(task)
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        let tickets = try ReminderSchedulingJournal.capture(in: ModelContext(container))
        task.title = "Captured unsaved title"
        task.notes = "Captured unsaved note"
        let store = CoordinatorNotificationStore(pausesFirstAdd: true)
        let run = Task { await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: context, store: store, badgesEnabled: false, policy: .background) }
        await store.waitUntilAddStarted()
        // An in-flight projection must not read live edits after its immutable capture.
        task.title = "Later unsaved title"
        task.notes = "Later unsaved note"
        store.releaseAdd()
        let outcome = await run.value
        #expect(outcome.status == .superseded)
        #expect(Set(store.pending.keys) == ["reminder-preserved-overlay", "nag-preserved-overlay"])
        #expect(store.pending["reminder-preserved-overlay"]?.title == "Captured unsaved title")
        #expect(store.pending["nag-preserved-overlay"]?.title == "Captured unsaved title")
        #expect(task.title == "Later unsaved title")
        #expect(task.notes == "Later unsaved note")
        #expect(context.hasChanges)
        let fresh = ModelContext(container)
        let saved = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(saved.title == "Saved title")
        #expect(saved.notes.isEmpty)
        #expect(try ReminderSchedulingJournal.capture(in: fresh) == tickets)
    }

    @Test("Deferred recovery retains the store owner after the caller releases it")
    func coalescedRecoveryKeepsItsContainerAlive() async throws {
        weak var owner: ModelContainer?
        func enqueueFromTemporaryStore() throws {
            let container = try DAVSyncScenario.container()
            owner = container
            ReminderScheduler.requestReconcile(modelContext: container.mainContext)
        }
        try enqueueFromTemporaryStore()
        #expect(owner != nil, "ModelContext does not retain its ModelContainer; queued recovery must own it")
        // Cancel the queued callback before its debounce ends, without touching OS requests.
        let cleanup = try DAVSyncScenario.container()
        _ = await ReminderScheduler.reconcileNow(modelContainer: cleanup,
            policy: ReminderReconcilePolicy(allowsPermissionPrompt: false,
                deadline: ContinuousClock().now - .seconds(1)))
    }

    @Test("Saved quick-add work recovers after restart without remote sync", arguments: [AccountMode.vault, .nextcloud])
    func savedQuickAddRepairsAfterRestartWithoutSync(mode: AccountMode) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(SchemaV2.models)
        let configuration = ModelConfiguration(schema: schema,
            url: directory.appendingPathComponent("local.store"), cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            context.autosaveEnabled = false
            let account = ServerAccount(displayName: "Offline", serverBaseURL: "", username: "", mode: mode)
            let list = TaskList(serverURL: "", name: "Inbox", colorHex: "#007AFF")
            list.account = account
            let task = TaskItem(title: "Saved quick add")
            task.id = "created"; task.taskList = list
            task.dueDate = Date().addingTimeInterval(3_600); task.reminderOffset = 0
            context.insert(account); context.insert(list); context.insert(task)
            try ReminderSchedulingJournal.saveTaskChanges(in: context)
        }
        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        #expect(try !ReminderSchedulingJournal.capture(in: reopened.mainContext).isEmpty)
        let store = CoordinatorNotificationStore()
        let outcome = await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: reopened.mainContext, store: store, badgesEnabled: false, policy: .background)
        #expect(outcome.status == .confirmed)
        #expect(store.pending["reminder-created"] != nil)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(reopened)).isEmpty)
    }

    @Test("Badge and all-day preference changes rewrite registered requests with durable work")
    func badgeAndAllDayTimeChangesReplan() async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let task = TaskItem(title: "All-day reminder")
        task.id = "preferences"; task.isDueDateOnly = true; task.reminderOffset = 0
        task.dueDate = DueDateHelper.dateOnlyValue(for: Date().addingTimeInterval(86_400))
        context.insert(task)
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        let store = CoordinatorNotificationStore()
        let first = await ReminderScheduler.reconcileScheduledNotifications(modelContext: context,
            store: store, badgesEnabled: true, allDayReminderMinutes: 600, policy: .background)
        #expect(first.status == .confirmed)
        let prior = try #require(store.pending["reminder-preferences"])
        #expect(prior.badge != nil)
        #expect(Calendar.current.component(.hour, from: try #require(prior.fireDate)) == 10)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
        // Preference-only changes have no pending TaskItem; they still require recovery.
        try ReminderSchedulingJournal.saveTaskChanges(in: context, needsRecovery: true)
        #expect(try !ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
        let next = await ReminderScheduler.reconcileScheduledNotifications(modelContext: context,
            store: store, badgesEnabled: false, allDayReminderMinutes: 720, policy: .background)
        #expect(next.status == .confirmed)
        let updated = try #require(store.pending["reminder-preferences"])
        #expect(updated.badge == nil)
        #expect(Calendar.current.component(.hour, from: try #require(updated.fireDate)) == 12)
        #expect(store.addedIdentifiers.filter { $0 == "reminder-preferences" }.count == 2)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    @Test("Widget completion during an app add converges from saved state")
    func widgetCompletionDuringAppAddConverges() async throws {
        let container = try DAVSyncScenario.container()
        let task = TaskItem(title: "Widget completion")
        task.id = "widget"; task.dueDate = Date().addingTimeInterval(3_600)
        task.reminderOffset = 0; task.isNaggingReminder = true
        container.mainContext.insert(task)
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        let store = CoordinatorNotificationStore(pausesFirstAdd: true)
        let run = Task { await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: container.mainContext, store: store, badgesEnabled: false, policy: .background) }
        await store.waitUntilAddStarted()
        // A separate context represents the extension's independent process save.
        let widget = ModelContext(container)
        let saved = try #require(try widget.fetch(FetchDescriptor<TaskItem>()).first)
        TaskCompletionLogic.markCompleted(saved)
        try ReminderSchedulingJournal.saveTaskChanges(in: widget)
        store.releaseAdd()
        let interrupted = await run.value
        #expect(interrupted.status == .superseded)
        #expect(store.pending["reminder-widget"] == nil)
        #expect(store.pending["nag-widget"] == nil)
        #expect(try !ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }
}
