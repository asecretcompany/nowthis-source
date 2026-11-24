import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import NowThis

@MainActor
struct LocationDraftTests {
    @Test("Discarding a changed or cleared draft leaves the saved location intact after another edit saves",
          arguments: [false, true])
    func cancelDoesNotLeakLocation(clear: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "First task")
        task.locationName = "Original station"
        task.latitude = 48.0
        task.longitude = -122.0
        task.geofenceRadius = 150
        let unrelated = TaskItem(title: "Second task")
        context.insert(task)
        context.insert(unrelated)
        try context.save()

        let monitor = TestGeofenceMonitoring()
        let manager = GeofenceManager(locationManager: monitor, debounce: .zero)
        manager.configure(container: container)
        await manager.pendingWork?.value
        let originalRegion = try #require(monitor.region(id: task.id))
        do {
            var draft = try #require(LocationDraft.open(task: task, in: context))
            if clear {
                draft.clear()
                #expect(!draft.hasLocation)
            } else {
                draft.select(name: "Replacement station", latitude: 47.0, longitude: -121.0)
                draft.radius = 250
                #expect(draft.name == "Replacement station")
                #expect(draft.coordinate?.latitude == 47.0)
            }
        }

        unrelated.title = "Updated second task"
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        await manager.pendingWork?.value

        let reader = ModelContext(container)
        let saved = try persistedTask(task.id, in: reader)
        #expect(saved.locationName == "Original station")
        #expect(saved.latitude == 48.0)
        #expect(saved.longitude == -122.0)
        #expect(saved.geofenceRadius == 150)
        #expect(try persistedTask(unrelated.id, in: reader).title == "Updated second task")
        #expect(monitor.region(id: task.id) === originalRegion)
        #expect(monitor.startRequests.count == 1)
        #expect(monitor.stopRequests.isEmpty)
    }

    @Test("Failed location save restores the previous values and monitor, then one retry reconciles",
          arguments: [false, true])
    func saveAndRetry(clear: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "First task")
        let other = TaskItem(title: "Second task")
        let modified = Date(timeIntervalSinceReferenceDate: 50_000)
        task.locationName = "Original station"
        task.latitude = 48.0
        task.longitude = -122.0
        task.geofenceRadius = 150
        task.lastModifiedDate = modified
        context.insert(task)
        context.insert(other)
        try context.save()
        task.locationName = "Original station (saved)"
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        let originalReader = ModelContext(container)
        let earlierTickets = try CalendarMirrorState.pending(in: originalReader, taskID: task.id)
        let earlierReminders = try ReminderSchedulingJournal.capture(in: originalReader)
        #expect(earlierTickets.count == 1)
        #expect(earlierReminders.count == 1)

        let monitor = TestGeofenceMonitoring()
        let manager = GeofenceManager(locationManager: monitor, debounce: .zero)
        manager.configure(container: container)
        await manager.pendingWork?.value
        let originalRegion = try #require(monitor.region(id: task.id))

        var draft = try #require(LocationDraft.open(task: task, in: context))
        if clear {
            draft.clear()
        } else {
            draft.select(name: "Replacement station", latitude: 47.0, longitude: -121.0)
            draft.radius = 250
        }
        other.title = "Unrelated pending edit"
        let errorState = ErrorState()
        var locationSaves = 0
        struct SaveFailure: Error {}
        #expect(!draft.save(to: task, in: context, errorState: errorState, save: { throw SaveFailure() },
                            onLocationSaved: { locationSaves += 1 }))
        #expect(errorState.isPresented)
        #expect(manager.pendingWork == nil)
        #expect(locationSaves == 0)
        #expect(task.locationName == "Original station (saved)")
        #expect(task.latitude == 48.0)
        #expect(task.longitude == -122.0)
        #expect(task.geofenceRadius == 150)
        #expect(!task.isDirty)
        #expect(task.lastModifiedDate == modified)
        await Task.yield()
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        await manager.pendingWork?.value
        let firstReader = ModelContext(container)
        #expect(try persistedTask(task.id, in: firstReader).locationName == "Original station (saved)")
        #expect(try persistedTask(other.id, in: firstReader).title == "Unrelated pending edit")
        let remainingTickets = try CalendarMirrorState.pending(in: firstReader, taskID: task.id)
        #expect(remainingTickets.map(\.id) == earlierTickets.map(\.id))
        #expect(remainingTickets == earlierTickets)
        #expect(try CalendarMirrorState.pending(in: firstReader, taskID: other.id).count == 1)
        let remainingReminders = try ReminderSchedulingJournal.capture(in: firstReader)
        #expect(remainingReminders.isSuperset(of: earlierReminders))
        #expect(remainingReminders.subtracting(earlierReminders).count == 1)
        #expect(monitor.region(id: task.id) === originalRegion)

        var displayed: LocationDraft.Fields?
        #expect(draft.save(to: task, in: context, onSave: { displayed = $0 },
                           onLocationSaved: { locationSaves += 1 }))
        await manager.pendingWork?.value
        let reader = ModelContext(container)
        let saved = try persistedTask(task.id, in: reader)
        #expect(saved.locationName == (clear ? nil : "Replacement station"))
        #expect(saved.latitude == (clear ? nil : 47.0))
        #expect(saved.longitude == (clear ? nil : -121.0))
        #expect(saved.geofenceRadius == (clear ? nil : 250))
        #expect(displayed?.name == saved.locationName)
        #expect(displayed?.radius == saved.geofenceRadius)
        #expect(try persistedTask(other.id, in: reader).title == "Unrelated pending edit")
        #expect(locationSaves == (clear ? 0 : 1))
        #expect(monitor.startRequests.count == (clear ? 1 : 2))
        #expect(monitor.stopRequests.count == (clear ? 1 : 0))
        #expect(monitor.region(id: task.id)?.radius == (clear ? nil : 250))
    }

    @Test("Saving an untouched location preserves the optional fields and modification stamp",
          arguments: ["Imported station", nil] as [String?])
    func untouchedDraftPreservesStoredValues(name: String?) throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "Existing task")
        let modified = Date(timeIntervalSinceReferenceDate: 50_000)
        task.locationName = name
        task.lastModifiedDate = modified
        context.insert(task)
        try context.save()

        let draft = try #require(LocationDraft.open(task: task, in: context))
        #expect(draft.save(to: task, in: context))

        let reader = ModelContext(container)
        let saved = try persistedTask(task.id, in: reader)
        #expect(saved.locationName == name)
        #expect(saved.latitude == nil)
        #expect(saved.longitude == nil)
        #expect(saved.geofenceRadius == nil)
        #expect(!saved.isDirty)
        #expect(saved.lastModifiedDate == modified)
    }

    @Test("A radius-only edit preserves newer location fields")
    func radiusEditDoesNotReplaceNewerPlace() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "Task")
        task.locationName = "Original station"
        task.latitude = 48
        task.longitude = -122
        context.insert(task)
        try context.save()
        var draft = try #require(LocationDraft.open(task: task, in: context))
        draft.radius = 250

        task.locationName = "Updated station"
        task.latitude = 47
        task.longitude = -121
        try ReminderSchedulingJournal.saveTaskChanges(in: context)

        #expect(draft.save(to: task, in: context, onLocationSaved: {}))
        let reader = ModelContext(container)
        let saved = try persistedTask(task.id, in: reader)
        #expect(saved.locationName == "Updated station")
        #expect(saved.latitude == 47)
        #expect(saved.longitude == -121)
        #expect(saved.geofenceRadius == 250)
    }

    @Test("A mounted location select or clear is rejected after revocation", arguments: [false, true])
    func revokedLocationDraft(clear: Bool) throws {
        try withRevokedLocationFixture(dirty: true) { context, task, draft in
            if clear { draft.clear() }
            else { draft.select(name: "New station", latitude: 47, longitude: -121) }
            let errors = ErrorState()
            var committed = 0
            var reconcile = 0
            #expect(!draft.save(to: task, in: context, errorState: errors,
                onSave: { _ in committed += 1 }, onLocationSaved: { reconcile += 1 }))
            #expect(errors.isPresented)
            #expect(committed == 0 && reconcile == 0)
            #expect(draft.name == (clear ? nil : "New station"))
            let reader = ModelContext(context.container)
            let saved = try persistedTask(task.id, in: reader)
            #expect(saved.locationName == "Original station")
            #expect(saved.latitude == 48 && saved.longitude == -122)
            #expect(saved.geofenceRadius == 150)
            #expect(saved.isDirty)
            #expect(saved.lastModifiedDate == Date(timeIntervalSinceReferenceDate: 50_000))
            #expect(try ReminderSchedulingJournal.capture(in: reader).isEmpty)
        }
    }

    @Test("A local radius edit survives revocation, keeps the latest place and preserves the outbound stamp", arguments: [false, true])
    func readOnlyLocationRadius(dirty: Bool) throws {
        try withRevokedLocationFixture(dirty: dirty, updatePlace: true) { context, task, draft in
            draft.radius = 250
            let errors = ErrorState()
            var committed = 0
            var reconcile = 0
            #expect(draft.save(to: task, in: context, errorState: errors,
                onSave: { _ in committed += 1 }, onLocationSaved: { reconcile += 1 }))
            #expect(!errors.isPresented)
            #expect(committed == 1 && reconcile == 1)
            let reader = ModelContext(context.container)
            let saved = try persistedTask(task.id, in: reader)
            #expect(saved.locationName == "Updated station")
            #expect(saved.latitude == 47 && saved.longitude == -121)
            #expect(saved.geofenceRadius == 250)
            #expect(saved.isDirty == dirty)
            #expect(saved.lastModifiedDate == Date(timeIntervalSinceReferenceDate: 50_000))
            #expect(try ReminderSchedulingJournal.capture(in: reader).count == 1)
        }
    }

    private func withRevokedLocationFixture(dirty: Bool, updatePlace: Bool = false,
        check: (ModelContext, TaskItem, inout LocationDraft) throws -> Void) throws {
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
        let task = TaskItem(title: "Existing location")
        context.insert(account)
        context.insert(list)
        context.insert(task)
        list.account = account
        task.taskList = list
        task.locationName = "Original station"
        task.latitude = 48
        task.longitude = -122
        task.geofenceRadius = 150
        task.isDirty = dirty
        task.lastModifiedDate = Date(timeIntervalSinceReferenceDate: 50_000)
        try context.save()
        var draft = try #require(LocationDraft.open(task: task, in: context))
        try #require(!list.isReadOnly)
        let listID = list.id
        let descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })
        let incoming = ModelContext(container)
        let revoked = try #require(try incoming.fetch(descriptor).first)
        revoked.isReadOnly = true
        if updatePlace {
            let updated = try persistedTask(task.id, in: incoming)
            updated.locationName = "Updated station"
            updated.latitude = 47
            updated.longitude = -121
        }
        try incoming.save()
        try #require(try ModelContext(container).fetch(descriptor).first?.isReadOnly == true)
        try check(context, task, &draft)
    }

    @Test("Opening or saving a stale picker handle cannot fault or revive a removed task")
    func staleHandleAfterExternalDeletion() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "Task")
        task.locationName = "Original station"
        let other = TaskItem(title: "Unrelated task")
        context.insert(task)
        context.insert(other)
        try context.save()
        let id = task.id
        var draft = try #require(LocationDraft.open(task: task, in: context))
        draft.select(name: "Changed station", latitude: 47, longitude: -121)

        let worker = ModelContext(container)
        let stored = try persistedTask(id, in: worker)
        worker.delete(stored)
        try ReminderSchedulingJournal.saveTaskChanges(in: worker)
        other.title = "Pending unrelated title"
        let errors = ErrorState()
        #expect(LocationDraft.open(task: task, in: context, errorState: errors) == nil)
        #expect(errors.isPresented)
        errors.dismiss()
        var callbacks = 0
        #expect(!draft.save(to: task, in: context, errorState: errors, onLocationSaved: { callbacks += 1 }))
        #expect(errors.isPresented)
        #expect(callbacks == 0)
        let reader = ModelContext(container)
        #expect(try reader.fetchCount(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })) == 0)
        #expect(try persistedTask(other.id, in: reader).title == "Unrelated task")
        #expect(other.title == "Pending unrelated title")
        #expect(context.hasChanges)
    }

    @Test("A failed location edit cannot affect committed geometry or work in a later unrelated save",
          arguments: [false, true], [false, true])
    func failedEditBeforeAnotherSave(earlierAdvisory: Bool, interveningSync: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "Task")
        task.locationName = "Original"
        task.latitude = 48
        task.longitude = -122
        task.geofenceRadius = 150
        let other = TaskItem(title: "Other")
        context.insert(task)
        context.insert(other)
        if earlierAdvisory { try ReminderSchedulingJournal.saveTaskChanges(in: context) }
        else { try context.save() }
        let id = task.id
        let baseline = ModelContext(container)
        let originalTickets = try CalendarMirrorState.pending(in: baseline, taskID: id)
        let originalReminders = try ReminderSchedulingJournal.capture(in: baseline)
        var draft = try #require(LocationDraft.open(task: task, in: context))
        draft.select(name: "Rejected", latitude: 47, longitude: -121)
        draft.radius = 250
        var promptCalls = 0
        struct SaveFailure: Error {}
        #expect(!draft.save(to: task, in: context, errorState: ErrorState(), save: { throw SaveFailure() },
                            onLocationSaved: { promptCalls += 1 }))
        await Task.yield()
        let beforeOtherSave = ModelContext(container)
        #expect(try persistedTask(id, in: beforeOtherSave).locationName == "Original")
        #expect(try CalendarMirrorState.pending(in: beforeOtherSave, taskID: id) == originalTickets)
        #expect(try ReminderSchedulingJournal.capture(in: beforeOtherSave) == originalReminders)
        #expect(promptCalls == 0)

        if interveningSync {
            let worker = ModelContext(container)
            let stored = try persistedTask(id, in: worker)
            stored.locationName = "Saved by sync"
            stored.latitude = 46
            stored.longitude = -120
            stored.geofenceRadius = 300
            try ReminderSchedulingJournal.saveTaskChanges(in: worker)
        }
        let beforeSave = ModelContext(container)
        let currentTickets = try CalendarMirrorState.pending(in: beforeSave, taskID: id)
        other.title = "Pending other edit"
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        let after = ModelContext(container)
        let saved = try persistedTask(id, in: after)
        #expect(saved.locationName == (interveningSync ? "Saved by sync" : "Original"))
        #expect(saved.latitude == (interveningSync ? 46 : 48))
        #expect(saved.longitude == (interveningSync ? -120 : -122))
        #expect(saved.geofenceRadius == (interveningSync ? 300 : 150))
        #expect(try persistedTask(other.id, in: after).title == "Pending other edit")
        let finalTickets = try CalendarMirrorState.pending(in: after, taskID: id)
        #expect(finalTickets.map(\.id) == currentTickets.map(\.id))
    }

    @Test("A later same-row editor save rebases the committed location without touching an unrelated row")
    func sameRowSaveRebasesAcrossMultipleCommits() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "Task")
        task.locationName = "Original"
        task.latitude = 48
        task.longitude = -122
        let other = TaskItem(title: "Other")
        other.locationName = "Independent location"
        context.insert(task)
        context.insert(other)
        try context.save()
        let id = task.id
        var draft = try #require(LocationDraft.open(task: task, in: context))
        draft.select(name: "Selected", latitude: 47, longitude: -121)
        other.title = "Unrelated pending edit"
        #expect(draft.save(to: task, in: context, onLocationSaved: {}))
        #expect(!context.changedModelsArray.contains(where: { $0 === task }))
        let first = ModelContext(container)
        #expect(try persistedTask(other.id, in: first).title == "Other")
        #expect(try persistedTask(id, in: first).locationName == "Selected")

        for iteration in 1...2 {
            let worker = ModelContext(container)
            let stored = try persistedTask(id, in: worker)
            stored.locationName = "Worker location \(iteration)"
            stored.latitude = 47 - Double(iteration)
            stored.longitude = -121 + Double(iteration)
            stored.geofenceRadius = 250 + Double(iteration)
            try ReminderSchedulingJournal.saveTaskChanges(in: worker)
            task.title = "Editor title \(iteration)"
            try ReminderSchedulingJournal.saveTaskChanges(in: context)
            let reader = ModelContext(container)
            let latest = try persistedTask(id, in: reader)
            #expect(latest.title == "Editor title \(iteration)")
            #expect(latest.locationName == "Worker location \(iteration)")
            #expect(latest.latitude == 47 - Double(iteration))
            #expect(latest.longitude == -121 + Double(iteration))
            #expect(latest.geofenceRadius == 250 + Double(iteration))
            let independent = try persistedTask(other.id, in: reader)
            #expect(independent.locationName == "Independent location")
            #expect(independent.title == "Unrelated pending edit")
        }
    }

    enum OutboundStampCase: CaseIterable, Sendable {
        case clean, alreadyDirty, deliberateEdit, acknowledged
    }

    @Test("A pending URL save preserves the correct outbound location revision", arguments: OutboundStampCase.allCases)
    func locationStampSurvivesPendingURL(scenario: OutboundStampCase) throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: "https://location-stamp.invalid", username: "fixture")
        let list = TaskList(serverURL: "/tasks/", name: "Fixture", colorHex: "#007AFF")
        let task = TaskItem(title: "CalDAV task")
        list.account = account
        task.taskList = list
        task.locationName = "Original"
        task.latitude = 48
        task.longitude = -122
        task.remoteHref = "/tasks/task.ics"
        task.etag = "original-etag"
        task.isLocalOnly = false
        task.attachmentStateKnown = true
        task.isDirty = scenario == .alreadyDirty
        let originalStamp = Date(timeIntervalSinceReferenceDate: 50_000)
        task.lastModifiedDate = originalStamp
        context.insert(account)
        context.insert(list)
        context.insert(task)
        try VTODOOpaqueState.empty.store(taskID: task.id, in: context)
        try SyncResourceFixture.prove(task, in: context)
        try context.save()

        let id = task.id
        let uid = task.uid
        var draft = try #require(LocationDraft.open(task: task, in: context))
        draft.select(name: "Selected", latitude: 47, longitude: -121)
        draft.radius = 250
        task.url = "https://pending.invalid/"
        #expect(draft.save(to: task, in: context, onLocationSaved: {}))

        let reader = ModelContext(container)
        let committed = try persistedTask(id, in: reader)
        let locationStamp = try #require(committed.lastModifiedDate)
        #expect(locationStamp > originalStamp)
        #expect(committed.isDirty)
        #expect(committed.url == nil)
        #expect(task.url == "https://pending.invalid/")

        var expectedStamp = locationStamp
        if scenario == .deliberateEdit {
            expectedStamp = locationStamp.addingTimeInterval(60)
            task.isDirty = true
            task.lastModifiedDate = expectedStamp
        } else if scenario == .acknowledged {
            let worker = ModelContext(container)
            let stored = try persistedTask(id, in: worker)
            stored.isDirty = false
            try worker.save()
        }
        try ReminderSchedulingJournal.saveTaskChanges(in: context)

        let outgoing = try SyncPushAcknowledgement.snapshot(taskID: id, calendarPath: "/tasks/", container: container)
        let after = ModelContext(container)
        let saved = try persistedTask(id, in: after)
        #expect(saved.url == "https://pending.invalid/")
        #expect(saved.locationName == "Selected")
        #expect(saved.latitude == 47)
        #expect(saved.longitude == -121)
        #expect(saved.geofenceRadius == 250)
        #expect(saved.lastModifiedDate == expectedStamp)
        #expect(saved.isDirty == (scenario != .acknowledged))
        if scenario == .acknowledged {
            #expect(outgoing == nil)
        } else {
            #expect(outgoing?.uid == uid)
            #expect(outgoing?.modifiedAt == expectedStamp)
            #expect(outgoing?.payload.contains("GEO:47.0;-121.0") == true)
        }

        if scenario == .deliberateEdit {
            let sent = try #require(outgoing)
            try SyncPushAcknowledgement.acknowledge(sent, etag: "accepted-etag", container: container)
            let acknowledged = ModelContext(container)
            let accepted = try persistedTask(id, in: acknowledged)
            #expect(!accepted.isDirty)
            #expect(accepted.etag == "accepted-etag")
            task.url = "https://later-pending.invalid/"
            try ReminderSchedulingJournal.saveTaskChanges(in: context)

            let refreshed = ModelContext(container)
            let later = try persistedTask(id, in: refreshed)
            #expect(later.url == "https://later-pending.invalid/")
            #expect(later.lastModifiedDate == expectedStamp)
            #expect(!later.isDirty)
            #expect(later.etag == "accepted-etag")
            #expect(later.remoteHref == sent.path)
            #expect(later.uid == sent.uid)
            #expect(try SyncPushAcknowledgement.snapshot(taskID: id, calendarPath: "/tasks/", container: container) == nil)
        }
    }

    private func persistedTask(_ id: String, in reader: ModelContext) throws -> TaskItem {
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        return try #require(try reader.fetch(descriptor).first)
    }
}
