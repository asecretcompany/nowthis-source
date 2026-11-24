import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import NowThis

@MainActor
struct GeofenceReconciliationTests {
    @Test("A committed geometry change replaces a region with the same task ID")
    func replacesRegionWithChangedGeometry() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = insertTask(in: context)
        try context.save()

        let monitor = TestGeofenceMonitoring()
        let manager = makeManager(monitor, container: container)
        await manager.pendingWork?.value
        #expect(monitor.region(id: task.id)?.radius == 150)

        task.latitude = 47
        task.longitude = -121
        task.geofenceRadius = 250
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        await manager.pendingWork?.value

        let region = try #require(monitor.region(id: task.id))
        #expect(monitor.monitoredRegions.count == 1)
        #expect(region.center.latitude == 47)
        #expect(region.center.longitude == -121)
        #expect(region.radius == 250)
        #expect(monitor.startRequests.count == 2)
    }

    @Test("A saved location is the only first-use prompt and its authorization result controls monitoring",
          arguments: [false, true])
    func firstUsePermission(granted: Bool) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = TaskItem(title: "Task")
        context.insert(task)
        try context.save()
        let monitor = TestGeofenceMonitoring()
        monitor.authorizationStatus = .notDetermined
        var issues: [GeofenceManager.Issue] = []
        let manager = makeManager(monitor, container: container, report: { issues.append($0) })
        #expect(monitor.permissionRequests == 0)
        #expect(manager.pendingWork == nil)

        var draft = try #require(LocationDraft.open(task: task, in: context))
        draft.select(name: "Station", latitude: 48, longitude: -122)
        #expect(draft.save(to: task, in: context, onLocationSaved: manager.requestPermission))
        #expect(monitor.permissionRequests == 1)
        #expect(monitor.startRequests.isEmpty)
        // An unchanged callback may arrive immediately after creating CLLocationManager.
        manager.authorizationChanged(to: .notDetermined)
        manager.requestPermission()
        #expect(monitor.permissionRequests == 1)

        monitor.authorizationStatus = granted ? .authorizedWhenInUse : .denied
        manager.authorizationChanged(to: monitor.authorizationStatus)
        await manager.pendingWork?.value

        #expect(monitor.region(id: task.id)?.radius == (granted ? 100 : nil))
        #expect(manager.permissionIssue == (granted ? nil : .denied))
        #expect(issues == (granted ? [] : [.denied]))
    }

    enum Removal: CaseIterable, Sendable { case complete, cancel, softDelete, hardDelete }

    @Test("Committed completion, cancellation and deletions remove regions and suppress stale callbacks",
          arguments: Removal.allCases)
    func removesIneligibleTasks(removal: Removal) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = insertTask(in: context)
        let id = task.id
        try context.save()

        let monitor = TestGeofenceMonitoring()
        var alerts: [String] = []
        let manager = makeManager(monitor, container: container, notify: { id, _ in alerts.append(id) })
        await manager.pendingWork?.value
        let region = try #require(monitor.region(id: id))
        manager.handleRegionEvent(GeofenceManager.Region(region), entering: true)
        #expect(alerts == [id])

        switch removal {
        case .complete, .cancel:
            try TaskDetailView.applyStatusChange(removal == .complete ? .completed : .cancelled, to: task, in: context,
                                                 requestReconcile: { _ in }, cancelReminder: { _ in })
        case .softDelete:
            #expect(TaskDeletionPersistence.perform(task, in: context) == [id])
        case .hardDelete:
            context.delete(task)
            try ReminderSchedulingJournal.saveTaskChanges(in: context)
        }

        manager.handleRegionEvent(GeofenceManager.Region(region), entering: false)
        #expect(alerts == [id])
        await manager.pendingWork?.value
        #expect(monitor.region(id: id) == nil)
        #expect(monitor.stopRequests == [id])
    }

    @Test("Committed inbound deletes and account cascades stop obsolete reminders", arguments: [false, true])
    func remoteAndAccountRemoval(removeAccount: Bool) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: "https://geofence.invalid", username: "fixture")
        let list = TaskList(serverURL: account.serverBaseURL, name: "Fixture", colorHex: "#007AFF")
        let task = insertTask(in: context)
        let href = "/fixtures/location.ics"
        let id = task.id
        list.account = account
        task.taskList = list
        task.remoteHref = href
        task.etag = "saved"
        task.isLocalOnly = false
        context.insert(account)
        context.insert(list)
        try context.save()

        let monitor = TestGeofenceMonitoring()
        var alerts: [String] = []
        let manager = makeManager(monitor, container: container, notify: { id, _ in alerts.append(id) })
        await manager.pendingWork?.value
        let region = try #require(monitor.region(id: id))

        if removeAccount {
            let accountManager = AccountManager(modelContext: context, deleteCredentials: { _ in })
            try await accountManager.removeAccount(accountID: account.id)
        } else {
            let writer = SyncInboundBatchWriter(container: container, listID: list.id, expectedAccountID: account.id)
            let commit = try await writer.deleteExplicit([href])
            #expect(commit?.change.deletedIDs == [id])
        }

        manager.handleRegionEvent(GeofenceManager.Region(region), entering: true)
        #expect(alerts.isEmpty)
        await manager.pendingWork?.value
        #expect(monitor.region(id: id) == nil)
        #expect(monitor.stopRequests == [id])
    }

    @Test("A committed server-wins conflict wakes geofences even while the app scene is inactive",
          arguments: [false, true])
    func syncConflictUpdatesGeometry(sceneInactive: Bool) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let host = "location-conflict-" + UUID().uuidString.lowercased() + ".invalid"
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: "https://" + host, username: "fixture")
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        let task = insertTask(in: context)
        context.insert(account)
        context.insert(list)
        list.account = account
        task.taskList = list
        task.remoteHref = "/one/location.ics"
        task.etag = "old"
        task.isLocalOnly = false
        task.isDirty = true
        task.attachmentStateKnown = true
        list.syncCTag = "c1"
        list.lastFullPullDate = Date()
        SyncEngine.markCategoriesCaughtUp(listID: list.id)
        try VTODOOpaqueState.empty.store(taskID: task.id, in: context)
        try SyncResourceFixture.prove(task, in: context)
        try SyncResourceFixture.proveSource(task, etag: "old", in: context)
        try context.save()
        try DAVSyncScenario.seedRecentCheckpoint(for: list, in: container)

        let monitor = TestGeofenceMonitoring()
        let manager = makeManager(monitor, container: container)
        await manager.pendingWork?.value
        #expect(monitor.region(id: task.id)?.center.latitude == 48)

        let remote = ICalendarSerializer.serialize(uid: task.uid, summary: "Remote edit",
                                                    location: "New station", latitude: 47, longitude: -121)
        let configuration = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]) + [
            .init(status: 412, body: ""),
            .init(status: 200, body: remote, headers: ["ETag": "fresh"])
        ])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: configuration,
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let scheduler = SyncScheduler(syncEngine: engine, onWidgetReload: {}, onNotificationFlush: { _ in },
                                      onCommittedTaskChange: manager.requestReconciliation)
        let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
        if sceneInactive { scheduler.pauseCalendarMirrors() }
        // The background engine path pulls only. A full sync is what reaches a PUT conflict.
        let outcome = await engine.performFullSyncOutcome(accountID: account.id, serverBaseURL: account.serverBaseURL,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
        #expect(outcome.status == .completed)
        #expect(ScriptedDAVProtocol.requests(host: host).filter { $0.method == "PUT" }.count == 1)
        for _ in 0..<50 where scheduler.latestCommittedChange?.changedIDs.contains(task.id) != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(scheduler.latestCommittedChange?.changedIDs == [task.id])
        await manager.pendingWork?.value
        #expect(monitor.region(id: task.id)?.center.latitude == 47)
        #expect(monitor.region(id: task.id)?.center.longitude == -121)
        #expect(monitor.startRequests.count == 2)
    }

    @Test("Activation and delivery read committed geometry while metadata and other stores do not wake the manager")
    func readsOnlyTheConfiguredSavedStore() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = insertTask(in: context)
        try context.save()

        let monitor = TestGeofenceMonitoring()
        var alerts: [String] = []
        let manager = makeManager(monitor, container: container, notify: { id, _ in alerts.append(id) })
        await manager.pendingWork?.value
        let original = try #require(monitor.region(id: task.id))

        let otherStore = try makeContainer()
        _ = insertTask(in: otherStore.mainContext)
        try ReminderSchedulingJournal.saveTaskChanges(in: otherStore.mainContext)
        context.insert(SyncMetadata(id: "fixture-metadata", collectionPath: ""))
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        #expect(manager.pendingWork == nil)

        task.status = .completed
        task.latitude = 46
        manager.requestReconciliation()
        await manager.pendingWork?.value
        manager.handleRegionEvent(GeofenceManager.Region(original), entering: true)
        #expect(alerts == [task.id])
        #expect(monitor.region(id: task.id) === original)

        // Another process cannot post an in-process notification. Activation recovers its saved changes.
        let writer = ModelContext(container)
        let id = task.id
        let saved = try #require(try writer.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
        saved.latitude = 47
        try writer.save()
        #expect(manager.pendingWork == nil)
        manager.handleRegionEvent(GeofenceManager.Region(original), entering: false)
        #expect(alerts == [id])

        manager.requestReconciliation()
        await manager.pendingWork?.value
        #expect(monitor.region(id: id)?.center.latitude == 47)
        #expect(context.hasChanges)
    }

    @Test("Invalid locations do not occupy slots and the 20 valid winners follow stable due and creation priority")
    func regionBudgetAndPriority() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let due = Date(timeIntervalSince1970: 1_700_000_000)
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        for index in 0...20 {
            let task = insertTask(id: "task-\(index)", in: context)
            task.dueDate = index < 2 ? due : nil
            task.createdDate = index < 2 ? created : created.addingTimeInterval(Double(index))
        }
        let invalidCoordinate = insertTask(id: "invalid-coordinate", in: context)
        invalidCoordinate.latitude = 100
        invalidCoordinate.dueDate = .distantPast
        let invalidRadius = insertTask(id: "invalid-radius", in: context)
        invalidRadius.geofenceRadius = -1
        invalidRadius.dueDate = .distantPast
        let clampedRadius = try #require(try context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.id == "task-1" })).first)
        clampedRadius.geofenceRadius = 2_000
        try context.save()

        let monitor = TestGeofenceMonitoring()
        let manager = makeManager(monitor, container: container)
        await manager.pendingWork?.value
        let winners = Set([0, 1] + Array(3...20)).map { "task-\($0)" }
        #expect(Set(monitor.monitoredRegions.map(\.identifier)) == Set(winners))
        #expect(Array(monitor.startRequests.prefix(2)) == ["task-0", "task-1"])
        #expect(monitor.region(id: "task-1")?.radius == 1_000)
        #expect(monitor.peakOccupied == 20)
    }

    @Test("Pending starts reserve capacity and a delayed old geometry is replaced after acknowledgment")
    func pendingStartsDeduplicateAndRefresh() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = insertTask(in: context)
        try context.save()

        let monitor = TestGeofenceMonitoring()
        monitor.delayStarts = true
        let manager = makeManager(monitor, container: container)
        await manager.pendingWork?.value
        task.latitude = 47
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        await manager.pendingWork?.value
        #expect(monitor.startRequests == [task.id])

        let old = try #require(monitor.completeStart(id: task.id))
        manager.monitoringStarted(GeofenceManager.Region(old))
        await manager.pendingWork?.value
        let replacement = try #require(monitor.completeStart(id: task.id))
        manager.monitoringStarted(GeofenceManager.Region(replacement))
        #expect(monitor.startRequests == [task.id, task.id])
        #expect(monitor.region(id: task.id)?.center.latitude == 47)
        #expect(manager.pendingWork == nil)
    }

    @Test("A delayed stop does not free a slot early")
    func pendingStopKeepsItsSlot() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        for index in 0..<20 {
            _ = insertTask(id: "existing-\(index)", in: context)
        }
        try context.save()

        let monitor = TestGeofenceMonitoring()
        let manager = makeManager(monitor, container: container)
        await manager.pendingWork?.value
        monitor.delayStops = true
        let newTask = insertTask(id: "next", in: context)
        newTask.dueDate = .distantPast
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        await manager.pendingWork?.value

        let oldID = try #require(monitor.stopRequests.first)
        #expect(monitor.stopRequests == [oldID])
        #expect(monitor.startRequests.count == 20)
        #expect(monitor.region(id: newTask.id) == nil)

        // The original stop never took effect. The next wake can reissue it.
        monitor.delayStops = false
        manager.requestReconciliation()
        await manager.pendingWork?.value
        #expect(monitor.stopRequests == [oldID, oldID])
        #expect(monitor.startRequests.count == 21)
        #expect(monitor.region(id: newTask.id) != nil)
        #expect(monitor.peakOccupied == 20)
    }

    @Test("A reported asynchronous start failure can retry on the next wake")
    func reportsFailedStart() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = insertTask(in: context)
        try context.save()

        let monitor = TestGeofenceMonitoring()
        monitor.delayStarts = true
        var issues: [GeofenceManager.Issue] = []
        let manager = makeManager(monitor, container: container, report: { issues.append($0) })
        await manager.pendingWork?.value
        let failedRequest = monitor.pendingStarts.removeValue(forKey: task.id)
        let failed = try #require(failedRequest)
        struct StartFailure: Error {}
        manager.monitoringFailed(GeofenceManager.Region(failed), error: StartFailure())
        #expect(issues == [.updateFailed])
        #expect(monitor.startRequests == [task.id])
        #expect(manager.pendingWork == nil)

        monitor.delayStarts = false
        manager.requestReconciliation()
        await manager.pendingWork?.value
        #expect(monitor.startRequests == [task.id, task.id])
        #expect(monitor.region(id: task.id) != nil)
    }

    @Test("Delayed and unidentified callbacks keep unresolved start capacity reserved")
    func unknownStartFailuresKeepTheirSlots() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let due = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0...20 {
            let task = insertTask(id: "task-\(index)", in: context)
            task.dueDate = due.addingTimeInterval(Double(index))
        }
        try context.save()

        let monitor = TestGeofenceMonitoring()
        monitor.delayStarts = true
        var issues: [GeofenceManager.Issue] = []
        let manager = makeManager(monitor, container: container, report: { issues.append($0) })
        await manager.pendingWork?.value
        let delayed = try #require(monitor.pendingStarts["task-19"])
        manager.monitoringFailed(GeofenceManager.Region(delayed), error: CLError(.regionMonitoringResponseDelayed))
        #expect(issues.isEmpty)

        let later = try #require(try context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.id == "task-20" })).first)
        let edited = try #require(try context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.id == "task-0" })).first)
        later.dueDate = .distantPast
        edited.latitude = 47
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        await manager.pendingWork?.value
        #expect(monitor.startRequests.count == 20)

        manager.monitoringFailed(nil, error: CLError(.regionMonitoringFailure))
        #expect(issues == [.updateFailed])
        manager.requestReconciliation()
        await manager.pendingWork?.value
        #expect(monitor.startRequests.filter { $0 == "task-0" }.count == 2)
        #expect((monitor.pendingStarts["task-0"] as? CLCircularRegion)?.center.latitude == 47)
        #expect(!monitor.startRequests.contains("task-20"))
        #expect(monitor.peakOccupied == 20)

        let late = CLCircularRegion(center: .init(latitude: 48, longitude: -122), radius: 150, identifier: "task-0")
        monitor.monitoredRegions.insert(late)
        manager.monitoringStarted(GeofenceManager.Region(late))
        manager.requestReconciliation()
        await manager.pendingWork?.value
        #expect(monitor.startRequests.filter { $0 == "task-0" }.count == 2)

        // Only a terminal error identifying the old region frees that reservation.
        monitor.pendingStarts.removeValue(forKey: "task-19")
        manager.monitoringFailed(GeofenceManager.Region(delayed), error: CLError(.regionMonitoringFailure))
        await manager.pendingWork?.value
        #expect(monitor.startRequests.contains("task-20"))
        #expect(monitor.peakOccupied == 20)
    }

    @Test("Old geometry or a deleted task cannot present an obsolete monitoring error")
    func staleIdentifiedFailuresDoNotSurface() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = insertTask(in: context)
        let id = task.id
        try context.save()
        let monitor = TestGeofenceMonitoring()
        var issues: [GeofenceManager.Issue] = []
        let manager = makeManager(monitor, container: container, report: { issues.append($0) })
        await manager.pendingWork?.value
        let original = try #require(monitor.region(id: id))

        task.latitude = 47
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        await manager.pendingWork?.value
        let updated = try #require(monitor.region(id: id))
        manager.monitoringFailed(GeofenceManager.Region(original), error: CLError(.regionMonitoringFailure))
        #expect(issues.isEmpty)

        context.delete(task)
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        manager.monitoringFailed(GeofenceManager.Region(updated), error: CLError(.regionMonitoringFailure))
        #expect(issues.isEmpty)
        await manager.pendingWork?.value
    }

    @Test("An unidentified error triggers cleanup of an obsolete unknown registration")
    func unknownObsoleteRegistrationGetsStopped() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        for index in 0...20 {
            let task = insertTask(id: "task-\(index)", in: context)
            task.dueDate = Date(timeIntervalSince1970: Double(index + 1))
        }
        try context.save()
        let monitor = TestGeofenceMonitoring()
        monitor.delayStarts = true
        let manager = makeManager(monitor, container: container)
        await manager.pendingWork?.value
        #expect(monitor.startRequests.count == 20)

        let later = try #require(try context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.id == "task-20" })).first)
        later.dueDate = .distantPast
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        await manager.pendingWork?.value
        monitor.pendingStarts.removeValue(forKey: "task-19")
        manager.monitoringFailed(nil, error: CLError(.regionMonitoringFailure))
        manager.requestReconciliation()
        await manager.pendingWork?.value

        #expect(monitor.stopRequests.contains("task-19"))
        #expect(!monitor.startRequests.contains("task-20"))
        #expect(monitor.peakOccupied == 20)

        // The obsolete registration can still arrive after the cancellation
        // request. Its observed removal releases the reserved capacity.
        let late = CLCircularRegion(center: .init(latitude: 48, longitude: -122), radius: 150, identifier: "task-19")
        monitor.monitoredRegions.insert(late)
        manager.monitoringStarted(GeofenceManager.Region(late))
        await manager.pendingWork?.value
        #expect(monitor.region(id: "task-19") == nil)
        #expect(monitor.startRequests.contains("task-20"))
        #expect(monitor.peakOccupied == 20)
    }

    @Test("Global failures from retry starts cannot keep the manager waking itself",
          arguments: [false, true])
    func globalFailureFeedbackStops(olderGeometryVisible: Bool) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let tasks = (0...20).map { index in
            let task = insertTask(id: "task-\(index)", in: context)
            task.dueDate = Date(timeIntervalSince1970: Double(index + 1))
            return task
        }
        try context.save()
        let monitor = TestGeofenceMonitoring()
        monitor.delayStarts = true
        let manager = makeManager(monitor, container: container)
        await manager.pendingWork?.value
        if olderGeometryVisible {
            let original = try #require(monitor.completeStart(id: "task-19"))
            manager.monitoringStarted(GeofenceManager.Region(original))
            tasks[19].latitude = 47
            try ReminderSchedulingJournal.saveTaskChanges(in: context)
            await manager.pendingWork?.value
            #expect(monitor.region(id: "task-19")?.center.latitude == 48)
            #expect((monitor.pendingStarts["task-19"] as? CLCircularRegion)?.center.latitude == 47)
            monitor.delayStops = true
        }
        tasks[20].dueDate = .distantPast
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        await manager.pendingWork?.value
        let startsBeforeFailure = monitor.startRequests.count
        let stopsBeforeFailure = monitor.stopRequests.count
        #expect(startsBeforeFailure == (olderGeometryVisible ? 21 : 20))
        #expect(stopsBeforeFailure == (olderGeometryVisible ? 1 : 0))

        var feedback = 0
        monitor.onStart = {
            guard feedback < 60 else { return }
            feedback += 1
            manager.monitoringFailed(nil, error: CLError(.regionMonitoringFailure))
        }
        defer { monitor.onStart = nil }
        manager.monitoringFailed(nil, error: CLError(.regionMonitoringFailure))
        await manager.pendingWork?.value
        #expect(manager.pendingWork == nil)
        #expect(monitor.stopRequests.count == stopsBeforeFailure + 1)
        #expect(monitor.stopRequests.allSatisfy { $0 == "task-19" })
        #expect(monitor.startRequests.count == startsBeforeFailure + 19)
        #expect(feedback == 19)
        #expect(monitor.peakOccupied == 20)
        #expect(!monitor.startRequests.contains("task-20"))
        if olderGeometryVisible {
            #expect(monitor.region(id: "task-19")?.center.latitude == 48)
            #expect((monitor.pendingStarts["task-19"] as? CLCircularRegion)?.center.latitude == 47)
            manager.monitoringFailed(nil, error: CLError(.regionMonitoringFailure))
            #expect(manager.pendingWork == nil)
        }

        // An independent wake can still retry, and exact settlement admits the winner.
        manager.requestReconciliation()
        await manager.pendingWork?.value
        #expect(manager.pendingWork == nil)
        #expect(monitor.startRequests.count == startsBeforeFailure + 38)
        #expect(monitor.stopRequests.count == stopsBeforeFailure + 2)
        let obsolete = try #require(monitor.pendingStarts["task-19"])
        monitor.pendingStarts.removeValue(forKey: "task-19")
        monitor.onStart = nil
        manager.monitoringFailed(GeofenceManager.Region(obsolete), error: CLError(.regionMonitoringFailure))
        if olderGeometryVisible {
            // The definitive B failure frees its reservation, but A is still observed.
            await manager.pendingWork?.value
            #expect(!monitor.startRequests.contains("task-20"))
            monitor.completeStop(id: "task-19")
            manager.requestReconciliation()
        }
        await manager.pendingWork?.value
        #expect(monitor.startRequests.contains("task-20"))
        #expect(monitor.peakOccupied == 20)
    }

    private func makeContainer() throws -> ModelContainer {
        let container = try DAVSyncScenario.container()
        container.mainContext.autosaveEnabled = false
        return container
    }

    private func insertTask(id: String = UUID().uuidString, in context: ModelContext) -> TaskItem {
        let task = TaskItem(id: id, title: "Location reminder")
        task.latitude = 48
        task.longitude = -122
        task.geofenceRadius = 150
        context.insert(task)
        return task
    }

    private func makeManager(_ monitor: TestGeofenceMonitoring, container: ModelContainer,
                             report: @escaping (GeofenceManager.Issue) -> Void = { _ in },
                             notify: ((String, Bool) -> Void)? = nil) -> GeofenceManager {
        let manager = GeofenceManager(locationManager: monitor, debounce: .zero, report: report, notify: notify)
        manager.configure(container: container)
        return manager
    }
}

@MainActor
final class TestGeofenceMonitoring: GeofenceMonitoring {
    var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    var circularMonitoringAvailable = true
    var maximumRegionMonitoringDistance: CLLocationDistance = 1_000
    var monitoredRegions: Set<CLRegion> = []
    var delayStarts = false
    var delayStops = false
    var pendingStarts: [String: CLRegion] = [:]
    var onStart: (() -> Void)?

    private(set) var permissionRequests = 0
    private(set) var startRequests: [String] = []
    private(set) var stopRequests: [String] = []
    private(set) var peakOccupied = 0

    func requestWhenInUseAuthorization() { permissionRequests += 1 }

    func startMonitoring(for region: CLRegion) {
        startRequests.append(region.identifier)
        if delayStarts {
            pendingStarts[region.identifier] = region
        } else {
            activate(region)
        }
        peakOccupied = max(peakOccupied, Set(monitoredRegions.map(\.identifier)).union(pendingStarts.keys).count)
        onStart?()
    }

    func stopMonitoring(for region: CLRegion) {
        stopRequests.append(region.identifier)
        if !delayStops { completeStop(id: region.identifier) }
    }

    func completeStart(id: String) -> CLRegion? {
        guard let region = pendingStarts.removeValue(forKey: id) else { return nil }
        activate(region)
        return region
    }

    func completeStop(id: String) {
        monitoredRegions = monitoredRegions.filter { $0.identifier != id }
    }

    func region(id: String) -> CLCircularRegion? {
        monitoredRegions.first { $0.identifier == id } as? CLCircularRegion
    }

    private func activate(_ region: CLRegion) {
        completeStop(id: region.identifier)
        monitoredRegions.insert(region)
    }
}
