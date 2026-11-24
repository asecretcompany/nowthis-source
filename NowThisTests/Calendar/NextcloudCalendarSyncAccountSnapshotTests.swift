import Foundation
import SwiftData
import Security
import Testing
@testable import NowThis

/// Suspends the actual network boundary until the test changes the store.
private actor PausedCalendarTransport: NextcloudCalendarTransport {
    enum Pause: Sendable { case put, delete, collection, none }
    struct Request: Sendable {
        let path: String
        let body: String?
        let baseURL: String
    }
    private let pause: Pause
    private let failPut: Bool
    private let failPutNumber: Int?
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?
    private(set) var puts: [Request] = []
    private(set) var deletes: [Request] = []
    private(set) var collections: [String] = []

    init(pause: Pause = .put, failPut: Bool = false, failPutNumber: Int? = nil) {
        self.pause = pause
        self.failPut = failPut
        self.failPutNumber = failPutNumber
    }

    func waitUntilRequest() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func resume() { resumeWaiter?.resume(); resumeWaiter = nil }

    private func suspend(at stage: Pause) async {
        guard stage == pause, !entered else { return }
        await withCheckedContinuation { continuation in
            resumeWaiter = continuation
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
        }
    }

    func discover(address: NextcloudServerAddress, admitted: CommittedAccountCredentials,
                  validate: @escaping CalendarRequestValidation) async throws -> CalDAVDiscoveryResult {
        try await validate()
        let home = try #require(URL(string: "\(address.baseURL.absoluteString)/calendars/\(admitted.scope.username)/"))
        return .init(principalURL: nil, calendarHomeURL: home, calendars: .init(live: [], trashed: []), collectionAddresses: [])
    }

    func ensureCollection(target: URL, marker: String, create: Bool, admitted: CommittedAccountCredentials,
                          validate: @escaping CalendarRequestValidation) async throws -> URL {
        try await validate()
        collections.append(admitted.scope.serverBaseURL)
        await suspend(at: .collection)
        return target
    }

    func read(target: CalendarEventTarget, admitted: CommittedAccountCredentials,
              validate: @escaping CalendarRequestValidation) async throws -> CalendarEventRead {
        try await validate()
        return .absent
    }

    func put(_ intent: CalendarEventIntent, admitted: CommittedAccountCredentials,
             validate: @escaping CalendarRequestValidation) async throws -> CalendarEventWrite {
        try await validate()
        puts.append(Request(path: intent.target.href, body: intent.body, baseURL: admitted.scope.serverBaseURL))
        await suspend(at: .put)
        if failPut || puts.count == failPutNumber { throw CalDAVError.unauthorized }
        return .acknowledged(intent.target.version(try #require(CalendarStrongETag("\"version-\(puts.count)\""))))
    }

    func remove(_ intent: CalendarEventIntent, admitted: CommittedAccountCredentials,
                validate: @escaping CalendarRequestValidation) async throws {
        try await validate()
        deletes.append(Request(path: intent.target.href, body: nil, baseURL: admitted.scope.serverBaseURL))
        await suspend(at: .delete)
    }

}

@Suite("Nextcloud calendar snapshot safety", .serialized)
@MainActor
struct NextcloudCalendarSyncAccountSnapshotTests {
    private let testKeychain = KeychainManager(operations: .init(copyMatching: { _ in
        (errSecSuccess, Data("test".utf8) as NSData)
    }))

    @Test("An old network response cannot overwrite a newer task event href")
    func editWhileNetworkSuspended() async throws {
        let container = try ModelContainer(for: Schema(SchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let account = ServerAccount(displayName: "Test", serverBaseURL: "https://example.com", username: "first")
        let task = TaskItem(title: "Before")
        task.dueDate = Date(timeIntervalSince1970: 1700000000)
        context.insert(account)
        context.insert(task)
        try context.save()
        let transport = PausedCalendarTransport()
        let manager = NextcloudCalendarSyncManager(transport: transport, keychainManager: testKeychain)
        let taskID = task.id
        let accountID = account.id
        let sync = Task { try await manager.syncSingleTask(taskID: taskID, accountID: accountID, role: .managedMirror, container: container) }
        await transport.waitUntilRequest()
        task.title = "After"
        task.calendarEventHref = "/newer-event.ics"
        try context.save()
        await transport.resume()
        #expect(try await sync.value == false)
        #expect(task.title == "After")
        #expect(task.calendarEventHref == "/newer-event.ics")
        #expect(try persistedNextcloudReceipts(container).first?.acknowledged == nil)
    }
    @Test("Pending account deletion is not saved by calendar sync and later accounts continue")
    func pendingAccountDeletionBetweenAccounts() async throws {
        let container = try ModelContainer(for: Schema(SchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let first = ServerAccount(displayName: "First", serverBaseURL: "https://example.com", username: "first")
        let second = ServerAccount(displayName: "Second", serverBaseURL: "https://example.net", username: "second")
        let task = TaskItem(title: "Survives account removal")
        task.dueDate = Date(timeIntervalSince1970: 1700000000)
        context.insert(first)
        context.insert(second)
        context.insert(task)
        try context.save()
        let firstID = first.id
        let transport = PausedCalendarTransport()
        let manager = NextcloudCalendarSyncManager(transport: transport, keychainManager: testKeychain)
        let secondID = second.id
        let taskID = task.id
        let sync = Task { try await manager.syncAll(accountID: firstID, container: container) }
        await transport.waitUntilRequest()
        context.delete(first)
        await transport.resume()
        #expect(try await sync.value == false)
        #expect(context.hasChanges, "Calendar sync must not commit the user's pending account removal")
        let stored = ModelContext(container)
        #expect(try stored.fetch(FetchDescriptor<ServerAccount>(predicate: #Predicate { $0.id == firstID })).count == 1)
        try context.save()
        #expect(try await manager.syncAll(accountID: secondID, container: container))
        let after = ModelContext(container)
        #expect(try after.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first?.calendarEventHref == nil)
        #expect(try persistedNextcloudReceipts(container).first { $0.scope.id == secondID }?.acknowledged?.version.href.hasPrefix("https://example.net/calendars/second/") == true)
    }

    private func fixture() throws -> (ModelContainer, ServerAccount, TaskItem) {
        let container = try ModelContainer(for: Schema(SchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        let account = ServerAccount(displayName: "First", serverBaseURL: "https://example.com", username: "first")
        let task = TaskItem(title: "Original")
        task.uid = "task-uid"
        task.dueDate = Date(timeIntervalSince1970: 1700000000)
        container.mainContext.insert(account)
        container.mainContext.insert(task)
        try container.mainContext.save()
        return (container, account, task)
    }

    private func storedTask(_ id: String, container: ModelContainer) throws -> TaskItem? {
        try ModelContext(container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first
    }

    @Test("Deleting the first account during collection creation skips it and processes the next account")
    func deletedAccountDoesNotStopLaterAccounts() async throws {
        let (container, first, task) = try fixture()
        let second = ServerAccount(displayName: "Second", serverBaseURL: "https://second.example.com", username: "second")
        container.mainContext.insert(second)
        try container.mainContext.save()
        let accountIDs = [first.id, second.id]
        let taskID = task.id
        let transport = PausedCalendarTransport(pause: .collection)
        let manager = NextcloudCalendarSyncManager(transport: transport, keychainManager: testKeychain)
        let sync = Task {
            var changed = 0
            for id in accountIDs {
                if try await manager.syncAll(accountID: id, container: container) { changed += 1 }
            }
            return changed
        }
        await transport.waitUntilRequest()
        container.mainContext.delete(first)
        try container.mainContext.save()
        await transport.resume()
        #expect(try await sync.value == 1)
        #expect(try storedTask(taskID, container: container)?.calendarEventHref == nil)
        #expect(try persistedNextcloudReceipts(container).first?.acknowledged?.version.href.hasPrefix("https://second.example.com/calendars/second/") == true)
        let puts = await transport.puts
        #expect(puts.count == 1)
        #expect(puts.first?.baseURL == "https://second.example.com")
    }

    @Test("Deleted tasks are never resurrected after an in-flight PUT", arguments: [false, true])
    func taskDeletionWhileSuspended(saved: Bool) async throws {
        let (container, account, task) = try fixture()
        let accountID = account.id
        let taskID = task.id
        let transport = PausedCalendarTransport()
        let manager = NextcloudCalendarSyncManager(transport: transport, keychainManager: testKeychain)
        let sync = Task { try await manager.syncSingleTask(taskID: taskID, accountID: accountID, role: .managedMirror, container: container) }
        await transport.waitUntilRequest()
        container.mainContext.delete(task)
        if saved { try container.mainContext.save() }
        await transport.resume()
        #expect(try await sync.value == false)
        if saved {
            #expect(try storedTask(taskID, container: container) == nil)
        } else {
            #expect(container.mainContext.hasChanges)
            #expect(try storedTask(taskID, container: container)?.calendarEventHref == nil)
        }
    }

    @Test("Changed task or account values invalidate a response", arguments: ["title", "uid", "list", "stamp", "deleted", "account", "pendingDraft"])
    func changedValuesRejectResponse(change: String) async throws {
        let (container, account, task) = try fixture()
        let taskID = task.id
        let accountID = account.id
        let transport = PausedCalendarTransport()
        let manager = NextcloudCalendarSyncManager(transport: transport, keychainManager: testKeychain)
        let sync = Task { try await manager.syncSingleTask(taskID: taskID, accountID: accountID, role: .managedMirror, container: container) }
        await transport.waitUntilRequest()
        switch change {
        case "title": task.title = "Edited without a timestamp change"
        case "uid": task.uid = "replacement"
        case "list":
            let list = TaskList(serverURL: "https://example.com/moved/", name: "Moved", colorHex: "#007AFF")
            container.mainContext.insert(list)
            task.taskList = list
        case "stamp": task.lastModifiedDate = Date(timeIntervalSince1970: 1800000000)
        case "deleted": task.isDeletedLocally = true
        case "account": account.serverBaseURL = "https://changed.example.com"
        default: container.mainContext.insert(TaskItem(title: "Unrelated unsaved draft"))
        }
        if change != "pendingDraft" { try container.mainContext.save() }
        await transport.resume()
        #expect(try await sync.value == false)
        #expect(try storedTask(taskID, container: container)?.calendarEventHref == nil)
        #expect(try persistedNextcloudReceipts(container).first?.acknowledged == nil)
        #expect(try persistedNextcloudReceipts(container).first?.pending != nil)
        if change == "pendingDraft" {
            #expect(container.mainContext.hasChanges)
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 1)
        }
    }

    @Test("No-due and explicit deletion acknowledge only an owned managed link", arguments: [false, true])
    func eventDeletion(explicit: Bool) async throws {
        let (container, account, task) = try fixture()
        let accountID = account.id
        let taskID = task.id
        let transport = PausedCalendarTransport(pause: .delete)
        let manager = NextcloudCalendarSyncManager(transport: transport, keychainManager: testKeychain)
        #expect(try await manager.syncSingleTask(taskID: taskID, accountID: accountID, role: .managedMirror, container: container))
        let before = try #require(try persistedNextcloudReceipts(container).first?.acknowledged)
        if !explicit {
            task.dueDate = nil
            try container.mainContext.save()
        }
        let sync = Task {
            if explicit { return try await manager.deleteManagedEvent(taskID: taskID, accountID: accountID, container: container) }
            return try await manager.syncSingleTask(taskID: taskID, accountID: accountID, role: .managedMirror, container: container)
        }
        await transport.waitUntilRequest()
        #expect(try persistedNextcloudReceipts(container).first?.acknowledged == before)
        await transport.resume()
        #expect(try await sync.value)
        let after = try #require(try persistedNextcloudReceipts(container).first)
        #expect(after.acknowledged == nil)
        #expect(after.pending == nil)
        #expect(after.wasRemoved)
        let deletes = await transport.deletes
        #expect(deletes.map(\.path) == [before.version.href])
    }

    @Test("A stale DELETE cannot acknowledge removal after a newer link or edit")
    func staleDeletion() async throws {
        let (container, account, task) = try fixture()
        let taskID = task.id
        let accountID = account.id
        let transport = PausedCalendarTransport(pause: .delete)
        let manager = NextcloudCalendarSyncManager(transport: transport, keychainManager: testKeychain)
        #expect(try await manager.syncSingleTask(taskID: taskID, accountID: accountID, role: .managedMirror, container: container))
        let before = try #require(try persistedNextcloudReceipts(container).first?.acknowledged)
        task.dueDate = nil
        try container.mainContext.save()
        let sync = Task { try await manager.syncSingleTask(taskID: taskID, accountID: accountID, role: .managedMirror, container: container) }
        await transport.waitUntilRequest()
        task.calendarEventHref = "/replacement.ics"
        try container.mainContext.save()
        await transport.resume()
        #expect(try await sync.value == false)
        #expect(try storedTask(taskID, container: container)?.calendarEventHref == "/replacement.ics")
        #expect(try persistedNextcloudReceipts(container).first?.acknowledged == before)
        #expect(try persistedNextcloudReceipts(container).first?.pending?.kind == .remove)
    }

    @Test("A successful write saves its receipt and unchanged content sends no duplicate mutation")
    func successAndNoOp() async throws {
        let (container, account, task) = try fixture()
        let taskID = task.id
        let accountID = account.id
        let transport = PausedCalendarTransport(pause: .none)
        let manager = NextcloudCalendarSyncManager(transport: transport, keychainManager: testKeychain)
        #expect(try await manager.syncSingleTask(taskID: taskID, accountID: accountID, role: .managedMirror, container: container))
        let saved = try #require(try storedTask(taskID, container: container))
        #expect(saved.calendarEventHref == nil)
        #expect(saved.title == "Original")
        #expect(saved.dueDate == Date(timeIntervalSince1970: 1700000000))
        #expect(try await manager.syncSingleTask(taskID: taskID, accountID: accountID, role: .managedMirror, container: container) == false)
        let puts = await transport.puts
        #expect(puts.count == 1)
        #expect(puts.first?.body?.contains("SUMMARY:Original") == true)
        #expect(puts.first?.body?.contains("RELATED-TO:task-uid") == true)
        #expect(try persistedNextcloudReceipts(container).first?.acknowledged?.version.href == puts.first?.path)
    }

    @Test("Auto-sync publishes only newly committed links and retains no live model reads after suspension", arguments: ["success", "deleted", "failure", "unchanged"])
    func autoSyncPublication(outcome: String) async throws {
        let (container, account, task) = try fixture()
        let transport = PausedCalendarTransport(pause: outcome == "unchanged" ? .none : .put, failPut: outcome == "failure")
        let manager = NextcloudCalendarSyncManager(transport: transport, keychainManager: testKeychain)
        if outcome == "unchanged" {
            #expect(try await manager.syncSingleTask(taskID: task.id, accountID: account.id, role: .managedMirror, container: container))
        }
        var publications = 0
        let defaults = UserDefaults.standard
        let oldApple = defaults.object(forKey: "appleCalendarSyncEnabled")
        let oldNextcloud = defaults.object(forKey: "nextcloudCalendarSyncEnabled")
        defaults.set(false, forKey: "appleCalendarSyncEnabled")
        defaults.set(true, forKey: "nextcloudCalendarSyncEnabled")
        let work = CalendarAutoSync.syncTaskIfEnabled(task, accounts: [account], manager: manager, onCommit: { publications += 1 })
        // Preference reads happen synchronously, so restore before yielding to other tests.
        defaults.set(oldApple, forKey: "appleCalendarSyncEnabled")
        defaults.set(oldNextcloud, forKey: "nextcloudCalendarSyncEnabled")
        let sync = try #require(work)
        if outcome != "unchanged" { await transport.waitUntilRequest() }
        if outcome == "deleted" {
            container.mainContext.delete(task)
            try container.mainContext.save()
        }
        await transport.resume()
        await sync.value
        #expect(publications == (outcome == "success" ? 1 : 0))
    }

    @Test("Both integrations save only derived changes and Nextcloud still runs", arguments: ["changed", "unchanged", "pendingDraft"])
    func bothCalendarsEnabled(outcome: String) async throws {
        let (container, account, task) = try fixture()
        let taskID = task.id
        if outcome == "unchanged" {
            task.calendarEventID = "apple-event"
            try container.mainContext.save()
        }
        if outcome == "pendingDraft" {
            container.mainContext.insert(TaskItem(title: "Unrelated draft"))
        }
        let transport = PausedCalendarTransport(pause: .none)
        let manager = NextcloudCalendarSyncManager(transport: transport, keychainManager: testKeychain)
        if outcome == "unchanged" {
            #expect(try await manager.syncSingleTask(taskID: taskID, accountID: account.id, role: .managedMirror, container: container))
        }
        var publications = 0
        var appleCalls = 0
        let defaults = UserDefaults.standard
        let oldApple = defaults.object(forKey: "appleCalendarSyncEnabled")
        let oldNextcloud = defaults.object(forKey: "nextcloudCalendarSyncEnabled")
        defaults.set(true, forKey: "appleCalendarSyncEnabled")
        defaults.set(true, forKey: "nextcloudCalendarSyncEnabled")
        let work = CalendarAutoSync.syncTaskIfEnabled(task, accounts: [account], manager: manager,
            appleSync: { ownedTask in
                #expect(ownedTask.modelContext !== container.mainContext)
                appleCalls += 1
                guard outcome != "unchanged" else { return false }
                let context = try #require(ownedTask.modelContext)
                context.insert(SyncMetadata(id: "apple-sidecar-ack", collectionPath: ""))
                try context.save()
                return true
            }, onCommit: { publications += 1 })
        defaults.set(oldApple, forKey: "appleCalendarSyncEnabled")
        defaults.set(oldNextcloud, forKey: "nextcloudCalendarSyncEnabled")
        await work?.value
        let saved = try #require(try storedTask(taskID, container: container))
        let puts = await transport.puts
        if outcome == "pendingDraft" {
            #expect(appleCalls == 0)
            #expect(puts.isEmpty)
            #expect(saved.calendarEventID == nil)
            #expect(saved.calendarEventHref == nil)
            #expect(container.mainContext.hasChanges)
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 1)
        } else {
            #expect(appleCalls == 1)
            #expect(puts.count == 1)
            #expect(saved.calendarEventID == (outcome == "unchanged" ? "apple-event" : nil))
            let sidecars = try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>())
            #expect(sidecars.contains(where: { $0.id == "apple-sidecar-ack" }) == (outcome == "changed"))
            #expect(saved.calendarEventHref == nil)
            #expect(try persistedNextcloudReceipts(container).first?.acknowledged?.version.href == puts.first?.path)
            #expect(!container.mainContext.hasChanges)
        }
        #expect(publications == (outcome == "changed" ? 2 : 0))
    }

    @Test("Bulk sync publishes an earlier commit once when a later network request fails")
    func partialSuccessPublishesOnThrow() async throws {
        let (container, account, _) = try fixture()
        let second = TaskItem(title: "Second")
        second.dueDate = Date(timeIntervalSince1970: 1700000000)
        container.mainContext.insert(second)
        try container.mainContext.save()
        let transport = PausedCalendarTransport(pause: .none, failPutNumber: 2)
        let manager = NextcloudCalendarSyncManager(transport: transport, keychainManager: testKeychain)
        var publications = 0
        do {
            try await manager.syncAll(accountID: account.id, container: container) { publications += 1 }
            Issue.record("The second network request should fail")
        } catch CalDAVError.unauthorized {
            // The first owned-context commit must remain visible despite this error.
        }
        #expect(publications == 1)
        let stored = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(try persistedNextcloudReceipts(container).compactMap(\.acknowledged).count == 1)
        #expect(stored.count == 2)
    }

    private func fileBackedFixture(directory: URL) throws -> (writable: ModelContainer, readOnly: ModelContainer, accountID: String, taskID: String) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema(SchemaV2.models)
        let url = directory.appendingPathComponent("calendar.store")
        let writable = try ModelContainer(for: schema, configurations:
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        writable.mainContext.autosaveEnabled = false
        let account = ServerAccount(displayName: "First", serverBaseURL: "https://example.com", username: "first")
        let task = TaskItem(title: "Persisted task")
        task.uid = "persisted-uid"
        task.dueDate = Date(timeIntervalSince1970: 1700000000)
        writable.mainContext.insert(account)
        writable.mainContext.insert(task)
        try writable.mainContext.save()
        let readOnly = try ModelContainer(for: schema, configurations:
            ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none))
        readOnly.mainContext.autosaveEnabled = false
        return (writable, readOnly, account.id, task.id)
    }

    @Test("Read-only persistence before intent sends no mutations, while a failed acknowledgement leaves the PUT pending", arguments: [false, true])
    func ownedSaveFailure(afterNetwork: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try fileBackedFixture(directory: directory)
        let transport = PausedCalendarTransport(pause: .none)
        let manager = NextcloudCalendarSyncManager(transport: transport, keychainManager: testKeychain,
            makeCommitContext: { container, phase in
                ModelContext(afterNetwork && phase != .acknowledgeEvent ? container : fixture.readOnly)
            })
        var publications = 0
        await #expect(throws: CocoaError.self) {
            try await manager.syncSingleTask(taskID: fixture.taskID, accountID: fixture.accountID,
                role: .managedMirror, container: fixture.writable) { publications += 1 }
        }
        let puts = await transport.puts
        let collections = await transport.collections
        #expect(puts.count == (afterNetwork ? 1 : 0))
        #expect(collections.count == (afterNetwork ? 1 : 0))
        #expect(publications == 0)
        let receipts = try persistedNextcloudReceipts(fixture.writable)
        #expect(receipts.count == (afterNetwork ? 1 : 0))
        #expect(receipts.first?.acknowledged == nil)
        #expect(receipts.first?.pending?.target.href == puts.first?.path)
        let stored = try #require(try storedTask(fixture.taskID, container: fixture.writable))
        #expect(stored.calendarEventHref == nil)
        #expect(stored.title == "Persisted task")
        #expect(!fixture.readOnly.mainContext.hasChanges)
    }

    @Test("Apple sidecar save failure suppresses publication and preserves the legacy link")
    func appleOwnedSaveFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try fileBackedFixture(directory: directory)
        let task = try #require(try fixture.readOnly.mainContext.fetch(FetchDescriptor<TaskItem>()).first)
        var appleCalls = 0
        var publications = 0
        let defaults = UserDefaults.standard
        let oldApple = defaults.object(forKey: "appleCalendarSyncEnabled")
        let oldNextcloud = defaults.object(forKey: "nextcloudCalendarSyncEnabled")
        defaults.set(true, forKey: "appleCalendarSyncEnabled")
        defaults.set(false, forKey: "nextcloudCalendarSyncEnabled")
        defer {
            defaults.set(oldApple, forKey: "appleCalendarSyncEnabled")
            defaults.set(oldNextcloud, forKey: "nextcloudCalendarSyncEnabled")
        }
        let work = CalendarAutoSync.syncTaskIfEnabled(task, accounts: [], appleSync: { ownedTask in
            #expect(ownedTask.modelContext !== fixture.readOnly.mainContext)
            appleCalls += 1
            let context = try #require(ownedTask.modelContext)
            context.insert(SyncMetadata(id: "apple-sidecar-failed", collectionPath: ""))
            try context.save()
            return true
        }, onCommit: { publications += 1 })
        #expect(work == nil)
        #expect(appleCalls == 1)
        #expect(publications == 0)
        let stored = try #require(try storedTask(fixture.taskID, container: fixture.writable))
        #expect(stored.calendarEventID == nil)
        #expect(stored.title == "Persisted task")
        #expect(!fixture.readOnly.mainContext.hasChanges)
    }

    @Test("A later real owned-store save failure preserves and publishes only the earlier batch commit")
    func laterOwnedSaveFailurePreservesEarlierCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try fileBackedFixture(directory: directory)
        let second = TaskItem(title: "Second persisted task")
        second.uid = "second-persisted-uid"
        second.dueDate = Date(timeIntervalSince1970: 1700000000)
        fixture.writable.mainContext.insert(second)
        try fixture.writable.mainContext.save()
        let transport = PausedCalendarTransport(pause: .none)
        var commitAttempts = 0
        let manager = NextcloudCalendarSyncManager(transport: transport, keychainManager: testKeychain, makeCommitContext: { container, phase in
            #expect(container === fixture.writable)
            if phase == .acknowledgeEvent { commitAttempts += 1 }
            return ModelContext(commitAttempts == 2 ? fixture.readOnly : fixture.writable)
        })
        var publications = 0
        var saveFailed = false
        do {
            try await manager.syncAll(accountID: fixture.accountID, container: fixture.writable) { publications += 1 }
            Issue.record("The second owned context must reject its save to the read-only store")
        } catch {
            saveFailed = true
            let failure = error as NSError
            #expect(failure.domain == NSCocoaErrorDomain)
            #expect(failure.code == CocoaError.Code.fileWriteNoPermission.rawValue)
        }
        #expect(saveFailed)
        #expect(commitAttempts == 2)
        let puts = await transport.puts
        #expect(puts.count == 2)
        #expect(publications == 1)
        let stored = try ModelContext(fixture.writable).fetch(FetchDescriptor<TaskItem>())
        #expect(stored.count == 2)
        let receipts = try persistedNextcloudReceipts(fixture.writable)
        #expect(receipts.compactMap { $0.acknowledged?.version.href } == [try #require(puts.first).path])
        #expect(receipts.compactMap { $0.pending?.target.href } == [try #require(puts.last).path])
        #expect(Set(stored.map(\.title)) == ["Persisted task", "Second persisted task"])
        #expect(!fixture.writable.mainContext.hasChanges)
        #expect(!fixture.readOnly.mainContext.hasChanges)
    }

}

@MainActor
func persistedNextcloudReceipts(_ container: ModelContainer) throws -> [CalendarEventReceipt] {
    let prefix = "calendar-nextcloud-v1:event:"
    let rows = try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: prefix) }))
    return try rows.map { row in
        try JSONDecoder().decode(CalendarEventReceipt.self, from: Data(try #require(row.syncToken).utf8))
    }
}
