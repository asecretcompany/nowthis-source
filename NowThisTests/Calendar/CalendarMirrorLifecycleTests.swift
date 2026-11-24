import Foundation
import Security
import SwiftData
import Testing
@testable import NowThis

private actor MirrorLifecycleGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

/// A remote service stand-in; production managers still own all receipts and decisions.
actor MirrorLifecycleTransport: NextcloudCalendarTransport {
    struct Remote: Sendable {
        let intent: CalendarEventIntent
        let version: CalendarEventVersion
    }
    var events: [String: Remote] = [:]
    var writes: [CalendarEventIntent] = []
    var removals: [CalendarEventIntent] = []
    var failingRemovalAccount: String?
    private var afterPut: (@MainActor @Sendable () throws -> Void)?
    private var afterRead: (@MainActor @Sendable () throws -> Void)?
    private var afterRemove: (@MainActor @Sendable () throws -> Void)?
    private var afterCollectionProof: (@MainActor @Sendable () throws -> Void)?
    private var nextCollectionProofGate: MirrorLifecycleGate?
    func afterNextPut(_ action: @escaping @MainActor @Sendable () throws -> Void) { afterPut = action }
    func afterNextRead(_ action: @escaping @MainActor @Sendable () throws -> Void) { afterRead = action }
    func afterNextRemove(_ action: @escaping @MainActor @Sendable () throws -> Void) { afterRemove = action }
    func afterNextCollectionProof(_ action: @escaping @MainActor @Sendable () throws -> Void) { afterCollectionProof = action }
    fileprivate func gateNextCollectionProof(_ gate: MirrorLifecycleGate) { nextCollectionProofGate = gate }

    func failRemoval(for account: String?) { failingRemovalAccount = account }
    func forget(_ href: String) { events.removeValue(forKey: href) }
    func discover(address: NextcloudServerAddress, admitted: CommittedAccountCredentials,
                  validate: @escaping CalendarRequestValidation) async throws -> CalDAVDiscoveryResult {
        try await validate()
        return .init(principalURL: nil, calendarHomeURL: address.baseURL.appendingPathComponent("calendars/\(admitted.scope.username)/"),
                     calendars: .init(live: [], trashed: []), collectionAddresses: [])
    }
    func ensureCollection(target: URL, marker: String, create: Bool, admitted: CommittedAccountCredentials,
                          validate: @escaping CalendarRequestValidation) async throws -> URL {
        try await validate()
        let action = afterCollectionProof
        afterCollectionProof = nil
        try await action?()
        let gate = nextCollectionProofGate
        nextCollectionProofGate = nil
        await gate?.suspend()
        try Task.checkCancellation()
        return target
    }
    func read(target: CalendarEventTarget, admitted: CommittedAccountCredentials,
              validate: @escaping CalendarRequestValidation) async throws -> CalendarEventRead {
        try await validate()
        let action = afterRead
        afterRead = nil
        try await action?()
        guard let value = events[target.href] else { return .absent }
        return .present(value.version, operation: value.intent.operation, proof: try #require(value.intent.bodyProof))
    }
    func put(_ intent: CalendarEventIntent, admitted: CommittedAccountCredentials,
             validate: @escaping CalendarRequestValidation) async throws -> CalendarEventWrite {
        try await validate()
        if intent.kind == .create {
            guard events[intent.target.href] == nil else { throw CalDAVError.conflict(etag: nil) }
        } else {
            guard events[intent.target.href]?.version == intent.priorVersion else { throw CalDAVError.conflict(etag: nil) }
        }
        writes.append(intent)
        let version = intent.target.version(try #require(CalendarStrongETag("\"v\(writes.count)\"")))
        events[intent.target.href] = .init(intent: intent, version: version)
        let action = afterPut
        afterPut = nil
        try await action?()
        return .acknowledged(version)
    }
    func remove(_ intent: CalendarEventIntent, admitted: CommittedAccountCredentials,
                validate: @escaping CalendarRequestValidation) async throws {
        try await validate()
        removals.append(intent)
        if failingRemovalAccount == admitted.scope.id { throw CalDAVError.unauthorized }
        if let existing = events[intent.target.href], existing.version != intent.priorVersion {
            throw CalDAVError.conflict(etag: nil)
        }
        events.removeValue(forKey: intent.target.href)
        let action = afterRemove
        afterRemove = nil
        try await action?()
    }
}

@Suite(.serialized)
@MainActor
struct CalendarMirrorLifecycleTests {
    private let credentials = KeychainManager(operations: .init(copyMatching: { _ in
        (errSecSuccess, Data("fixture".utf8) as NSData)
    }))

    private func fixture() throws -> (ModelContainer, ServerAccount, TaskItem) {
        let container = try ModelContainer(for: Schema(SchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let account = ServerAccount(displayName: "Destination", serverBaseURL: "https://mirror-lifecycle.invalid", username: "first")
        let list = TaskList(serverURL: account.serverBaseURL, name: "Source", colorHex: "#000000")
        list.account = account
        let task = TaskItem(title: "Original")
        task.taskList = list
        task.dueDate = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(account); context.insert(list); context.insert(task)
        try context.save()
        return (container, account, task)
    }

    private func manager(_ remote: MirrorLifecycleTransport) -> NextcloudCalendarSyncManager {
        NextcloudCalendarSyncManager(transport: remote, keychainManager: credentials)
    }

    private func coordinator(_ remote: MirrorLifecycleTransport, container: ModelContainer,
                             onFailure: @escaping @MainActor (String) -> Void = { _ in }) -> CalendarMirrorCoordinator {
        CalendarMirrorCoordinator(container: container, nextcloud: manager(remote),
            apple: AppleCalendarSyncManager(store: FakeAppleCalendarStore(), makeJournal: {
                AppleCalendarOwnershipJournal(container: $0, anchor: AppleCalendarAnchor { _, _ in Data(repeating: 23, count: 32) },
                                              selector: "coordinator")
            }), appleEnabled: { false }, nextcloudEnabled: { true }, onFailure: onFailure)
    }

    @Test(arguments: [false, true])
    func appLocalCoordinatorReportsAndRetainsWorkOnlyWithAppleEvidence(hasAppleEvidence: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(SchemaV2.models)
        let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("app.store"),
                                               cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = container.mainContext
        context.autosaveEnabled = false
        let vault = ServerAccount(vaultDisplayName: "Local Vault")
        let list = TaskList(serverURL: "", name: "Local", colorHex: "#000000")
        list.account = vault
        let task = TaskItem(title: "Seeded task")
        task.taskList = list
        task.dueDate = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(vault)
        context.insert(list)
        context.insert(task)
        let malformedID = AppleCalendarOwnership.prefix + "unresolved"
        if hasAppleEvidence {
            let row = SyncMetadata(id: malformedID, collectionPath: "")
            row.syncToken = "{"
            context.insert(row)
        }
        try context.save()
        try #require(try context.fetch(FetchDescriptor<SyncMetadata>()).map(\.id) == (hasAppleEvidence ? [malformedID] : []))

        var failures: [String] = []
        let worker = CalendarMirrorCoordinator(container: container, appleEnabled: { false }, nextcloudEnabled: { false },
                                               debounce: .milliseconds(1), onFailure: { failures.append($0) })
        await worker.reconcileNow()
        #expect(failures.count == (hasAppleEvidence ? 1 : 0))

        worker.startObserving()
        let unrelatedID = "ordinary-collection"
        context.insert(SyncMetadata(id: unrelatedID, collectionPath: "/ordinary/"))
        task.title = "Committed after startup"
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        let wake = try #require(worker.pendingWork)
        let taskID = task.id
        try #require(try CalendarMirrorState.pending(in: ModelContext(container)).map(\.taskID) == [taskID])
        await wake.value

        let committed = ModelContext(container)
        #expect(try committed.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID }))
            .first?.title == "Committed after startup")
        #expect(try CalendarMirrorState.pending(in: committed).map(\.taskID) == (hasAppleEvidence ? [taskID] : []))
        #expect(failures.count == (hasAppleEvidence ? 2 : 0))
        let rows = try committed.fetch(FetchDescriptor<SyncMetadata>())
        #expect(rows.contains { $0.id == unrelatedID && $0.collectionPath == "/ordinary/" })
        let appleRows = rows.filter { $0.id.hasPrefix(AppleCalendarOwnership.prefix) }
        #expect(appleRows.map(\.id) == (hasAppleEvidence ? [malformedID] : []))
        #expect(appleRows.first?.syncToken == (hasAppleEvidence ? "{" : nil))
    }

    @Test(arguments: ["empty", "legacy", "residualClaim", "malformedDestination"])
    func appleManagedInventoryUsesAnchorOnlyWithOwnershipEvidence(evidence: String) throws {
        let (container, _, _) = try fixture()
        let context = container.mainContext
        let store = FakeAppleCalendarStore()
        let prefix = AppleCalendarOwnership.prefix + String(repeating: "f", count: 64)
        let evidenceID: String?
        switch evidence {
        case "legacy": evidenceID = prefix
        case "residualClaim": evidenceID = prefix + ":item:" + String(repeating: "a", count: 64)
        case "malformedDestination": evidenceID = prefix + ":destination"
        default: evidenceID = nil
        }
        if let evidenceID {
            let row = SyncMetadata(id: evidenceID, collectionPath: "")
            row.syncToken = "{"
            context.insert(row)
            try context.save()
        }
        var anchorReads: [Bool] = []
        let apple = AppleCalendarSyncManager(store: store, makeJournal: {
            AppleCalendarOwnershipJournal(container: $0, anchor: AppleCalendarAnchor { _, create in
                anchorReads.append(create)
                return create ? Data(repeating: 27, count: 32) : nil
            }, selector: "inventory-test")
        })
        if let evidenceID {
            #expect(throws: CalendarSyncError.ownershipUncertain) {
                try apple.managedTaskIDs(container: container)
            }
            #expect(anchorReads == [false])
            let rows = try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>())
            #expect(rows.count == 1)
            #expect(rows.first?.id == evidenceID)
            #expect(rows.first?.syncToken == "{")
        } else {
            #expect(try apple.managedTaskIDs(container: container).isEmpty)
            #expect(anchorReads.isEmpty)
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<SyncMetadata>()) == 0)
        }
        #expect(store.savedCalendars.isEmpty)
        #expect(store.savedEvents.isEmpty)
    }

    @Test func disabledAppleInventoryRetainsAnOwnedTicketUntilReenabled() async throws {
        @MainActor final class AppleSyncPreference {
            var enabled = false
        }
        let (container, _, task) = try fixture()
        let store = FakeAppleCalendarStore()
        let apple = AppleCalendarSyncManager(store: store, makeJournal: {
            AppleCalendarOwnershipJournal(container: $0,
                anchor: AppleCalendarAnchor { _, _ in Data(repeating: 29, count: 32) }, selector: "disabled-inventory")
        })
        try #require(try apple.syncSingleTask(task))
        let owned = try #require(store.savedEvents.values.first)
        #expect(try apple.managedTaskIDs(container: container) == [task.id])
        let preference = AppleSyncPreference()
        var failures: [String] = []
        let worker = CalendarMirrorCoordinator(container: container, apple: apple, appleEnabled: { preference.enabled },
                                               nextcloudEnabled: { false }, onFailure: { failures.append($0) })
        task.dueDate = nil
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        let tickets = try CalendarMirrorState.pending(in: ModelContext(container), taskID: task.id)
        try #require(tickets.count == 1)

        await worker.reconcileNow()
        #expect(store.event(id: owned.id) == owned)
        #expect(try CalendarMirrorState.pending(in: ModelContext(container), taskID: task.id) == tickets)

        preference.enabled = true
        await worker.reconcileNow()
        #expect(store.event(id: owned.id) == nil)
        #expect(try CalendarMirrorState.pending(in: ModelContext(container), taskID: task.id).isEmpty)
        #expect(failures.isEmpty)
    }

    @Test func committedSaveLeavesWorkButFailedSaveDoesNot() throws {
        let (container, _, task) = try fixture()
        task.title = "Committed"
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        #expect(try CalendarMirrorState.pending(in: ModelContext(container)).map(\.taskID) == [task.id])
        let other = TaskItem(title: "Uncommitted")
        container.mainContext.insert(other)
        struct SaveFailure: Error {}
        #expect(throws: SaveFailure.self) {
            try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext, save: { throw SaveFailure() })
        }
        #expect(try !CalendarMirrorState.pending(in: ModelContext(container)).contains { $0.taskID == other.id })
        container.mainContext.rollback()
    }

    @Test func committedDueClearRemovesBothDestinationsAndRetainsFailedOne() async throws {
        let (container, first, task) = try fixture()
        let second = ServerAccount(displayName: "Other", serverBaseURL: "https://other-lifecycle.invalid", username: "second")
        container.mainContext.insert(second); try container.mainContext.save()
        let remote = MirrorLifecycleTransport()
        for account in [first, second] {
            #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id, role: .managedMirror, container: container))
        }
        let before = try persistedNextcloudReceipts(container)
        #expect(Set(before.map { $0.target.href }).count == 2)
        task.dueDate = nil
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        await remote.failRemoval(for: first.id)
        await #expect(throws: (any Error).self) {
            try await manager(remote).reconcileManaged(accountID: first.id, container: container, isEnabled: { true })
        }
        #expect(try await manager(remote).reconcileManaged(accountID: second.id, container: container, isEnabled: { true }))
        #expect(try persistedNextcloudReceipts(container).first { $0.scope.id == first.id }?.pending?.kind == .remove)
        #expect(try persistedNextcloudReceipts(container).first { $0.scope.id == second.id }?.wasRemoved == true)
        await remote.failRemoval(for: nil)
        #expect(try await manager(remote).reconcileManaged(accountID: first.id, container: container, isEnabled: { true }))
        #expect(await remote.events.isEmpty)
        #expect(try persistedNextcloudReceipts(container).allSatisfy { $0.wasRemoved && $0.pending == nil })
    }

    @Test func watchTransactionReplayUpdatesOnlyItsExistingCalendarMirror() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id,
                                                         role: .managedMirror, container: container))
        let operationID = UUID()
        let result = WatchEditTransaction.apply(.complete(uid: task.uid), operationID: operationID,
            container: container, isProUnlocked: true, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(result == WatchEditReply.applied)
        #expect(try !CalendarMirrorState.pending(in: ModelContext(container), taskID: task.id).isEmpty)

        let worker = coordinator(remote, container: container)
        await worker.reconcileNow()
        #expect(await remote.writes.count == 2)
        #expect(await remote.events.count == 1)
        #expect(await remote.writes.last?.kind == .update)
        #expect(await remote.writes.first?.target == remote.writes.last?.target)

        let replay = WatchEditTransaction.apply(.complete(uid: task.uid), operationID: operationID,
            container: container, isProUnlocked: true, now: Date(timeIntervalSince1970: 1_800_000_001))
        #expect(replay == WatchEditReply.applied)
        await worker.reconcileNow()
        #expect(await remote.writes.count == 2)
    }

    @Test func failedWatchTransactionDoesNotCreateCalendarWorkOrExport() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id,
                                                         role: .managedMirror, container: container))
        let failed = WatchEditTransaction.apply(.complete(uid: task.uid), operationID: UUID(),
            container: container, isProUnlocked: true, now: Date(timeIntervalSince1970: 1_800_000_000),
            save: { _ in throw WatchTransactionSaveFailure.failed })
        #expect(failed == WatchEditReply.unconfirmed)
        #expect(try CalendarMirrorState.pending(in: ModelContext(container), taskID: task.id).isEmpty)

        await coordinator(remote, container: container).reconcileNow()
        #expect(await remote.writes.count == 1)
        #expect(await remote.events.count == 1)
    }

    @Test func savedAppDraftQueuesRecoveryWithoutGrantingAutomaticCalendarCreation() async throws {
        let (container, _, template) = try fixture()
        let remote = MirrorLifecycleTransport()
        let draft = TaskCreationDraft()
        let ownedContext = draft.context(in: container)
        let listID = try #require(template.taskList?.id)
        let descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })
        let sourceList = try #require(try ownedContext.fetch(descriptor).first)
        let created = try draft.task(title: "Quick Add through owned save")
        created.taskList = sourceList
        created.dueDate = template.dueDate
        ownedContext.insert(created)
        #expect(draft.saveOwnedChanges(errorState: ErrorState()))
        let createdID = created.id
        #expect(try !CalendarMirrorState.pending(in: ModelContext(container), taskID: createdID).isEmpty)

        await coordinator(remote, container: container).reconcileNow()
        #expect(await remote.writes.isEmpty)
        #expect(await remote.events.isEmpty)

        let failedDraft = TaskCreationDraft()
        let failedContext = failedDraft.context(in: container)
        let failedTask = try failedDraft.task(title: "Failed Quick Add")
        failedTask.taskList = try #require(try failedContext.fetch(descriptor).first)
        failedContext.insert(failedTask)
        #expect(!failedDraft.saveOwnedChanges(errorState: ErrorState(), save: { throw WatchTransactionSaveFailure.failed }))
        failedDraft.discardOwnedChanges()
        #expect(try CalendarMirrorState.pending(in: ModelContext(container), taskID: failedTask.id).isEmpty)
        await coordinator(remote, container: container).reconcileNow()
        #expect(await remote.writes.isEmpty)
        #expect(await remote.events.isEmpty)
    }

    @Test func sameUIDFromTwoSourceAccountsKeepsIndependentDestinationMirrors() async throws {
        let (container, _, firstTask) = try fixture()
        let firstSource = try #require(firstTask.taskList?.account)
        let destination = ServerAccount(displayName: "Mirror destination", serverBaseURL: "https://same-uid-destination.invalid",
                                        username: "destination")
        let secondSource = ServerAccount(displayName: "Second source", serverBaseURL: "https://second-source.invalid",
                                         username: "source-two")
        let secondList = TaskList(serverURL: secondSource.serverBaseURL, name: "Second source list", colorHex: "#000000")
        secondList.account = secondSource
        let secondTask = TaskItem(uid: firstTask.uid, title: "Same UID, different source")
        secondTask.taskList = secondList
        secondTask.dueDate = firstTask.dueDate
        container.mainContext.insert(destination)
        container.mainContext.insert(secondSource)
        container.mainContext.insert(secondList)
        container.mainContext.insert(secondTask)
        try container.mainContext.save()
        #expect(firstSource.id != secondSource.id)

        let remote = MirrorLifecycleTransport()
        for task in [firstTask, secondTask] {
            #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: destination.id,
                                                             role: .managedMirror, container: container))
        }
        #expect(await remote.events.count == 2)
        try SyncPushAcknowledgement.finalizeDeletion(firstTask, in: container.mainContext)
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        await coordinator(remote, container: container).reconcileNow()

        #expect(await remote.events.count == 1)
        #expect(await remote.removals.count == 1)
        #expect(try CalendarMirrorState.pending(in: ModelContext(container), taskID: firstTask.id).isEmpty)
        #expect(try CalendarMirrorState.pending(in: ModelContext(container), taskID: secondTask.id).isEmpty)
    }

    @Test func siriCompletionAdvancesAndUpdatesOnlyItsExistingMirror() async throws {
        let (container, account, task) = try fixture()
        task.recurrenceRule = "FREQ=DAILY"
        try container.mainContext.save()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id,
                                                         role: .managedMirror, container: container))
        let originalDue = try #require(task.dueDate)

        let completed = try await CompleteTaskIntent(task: TaskEntity(
            id: task.id, title: task.title, isCompleted: false, listName: "Source"
        )).performWithContainer(container)
        #expect(!completed)
        #expect(task.dueDate == Calendar.current.date(byAdding: .day, value: 1, to: originalDue))

        await coordinator(remote, container: container).reconcileNow()
        #expect(await remote.writes.count == 2)
        #expect(await remote.writes.map(\.kind) == [.create, .update])
        #expect(try persistedNextcloudReceipts(container).first?.acknowledged != nil)
    }

    @Test func siriDeletionRemovesTheExistingManagedMirror() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id,
                                                         role: .managedMirror, container: container))
        let savedEvents = await remote.events
        let original = try #require(savedEvents.values.first)

        _ = try await DeleteTaskIntent(task: TaskEntity(
            id: task.id, title: task.title, isCompleted: false, listName: "Source"
        )).performWithContainer(container)
        await coordinator(remote, container: container).reconcileNow()

        #expect(await remote.removals.count == 1)
        #expect(await remote.removals.first?.target.href == original.intent.target.href)
        #expect(await remote.events.isEmpty)
    }

    @Test func existingReceiptRemovedDuringCollectionProofCannotAllocateReplacement() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id,
                                                         role: .managedMirror, container: container))
        task.title = "Committed edit"
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        let original = try #require(try persistedNextcloudReceipts(container).first)
        let snapshot = try CalendarTaskSnapshot(task, account: AccountCredentialScope(account), role: .managedMirror)
        let eventKey = try CalendarReceiptKey.event(task: snapshot, binding: original.bindingID)
        let claimKey = try CalendarReceiptKey.claim(original)
        let scope = try AccountCredentialScope(account)
        let destination = try #require(try CalendarReceiptStore.destination(for: scope, in: ModelContext(container)))
        let destinationKey = try CalendarReceiptKey.destination(destination)

        await remote.afterNextCollectionProof {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let event = try #require(try context.fetch(FetchDescriptor<SyncMetadata>()).first { $0.id == eventKey })
            let claim = try #require(try context.fetch(FetchDescriptor<SyncMetadata>()).first { $0.id == claimKey })
            let rows = try context.fetch(FetchDescriptor<SyncMetadata>())
            _ = try #require(rows.first { $0.id == destinationKey })
            var current = try #require(try CalendarReceiptStore.destination(for: scope, in: ModelContext(container)))
            current.eventCount = 0
            event.modelContext?.delete(event)
            claim.modelContext?.delete(claim)
            try CalendarReceiptStore.store(current, in: context)
            try context.save()
        }
        await #expect(throws: (any Error).self) {
            try await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true })
        }

        #expect(await remote.writes.count == 1)
        #expect(await remote.events.count == 1)
        #expect(try persistedNextcloudReceipts(container).isEmpty)
    }

    @Test func lostCleanupReceiptDuringCollectionProofCannotAcknowledgeTicket() async throws {
        let (container, account, task) = try fixture()
        let deletedTaskID = task.id
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: deletedTaskID, accountID: account.id,
                                                         role: .managedMirror, container: container))
        task.dueDate = nil
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        let original = try #require(try persistedNextcloudReceipts(container).first)
        let snapshot = try CalendarTaskSnapshot(task, account: AccountCredentialScope(account), role: .managedMirror)
        let eventKey = try CalendarReceiptKey.event(task: snapshot, binding: original.bindingID)
        let scope = try AccountCredentialScope(account)
        let destination = try #require(try CalendarReceiptStore.destination(for: scope, in: ModelContext(container)))

        await remote.afterNextCollectionProof {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let event = try #require(try context.fetch(FetchDescriptor<SyncMetadata>()).first { $0.id == eventKey })
            event.modelContext?.delete(event)
            var current = try #require(try CalendarReceiptStore.destination(for: scope, in: ModelContext(container)))
            current.eventCount = 0
            try CalendarReceiptStore.store(current, in: context)
            try context.save()
        }
        var failures: [String] = []
        await coordinator(remote, container: container, onFailure: { failures.append($0) }).reconcileNow()

        #expect(!failures.isEmpty)
        #expect(try !CalendarMirrorState.pending(in: ModelContext(container), taskID: deletedTaskID).isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>())
            .contains { $0.id.hasPrefix(CalendarReceiptKey.claims(account.id)) })
        #expect(await remote.removals.isEmpty)
        #expect(await remote.events.count == 1)
    }

    @Test func missingDestinationWithResidualReceiptsRetainsPurgeWhileOtherScopeFinishes() async throws {
        let (container, first, task) = try fixture()
        let deletedTaskID = task.id
        let second = ServerAccount(displayName: "Second destination", serverBaseURL: "https://second-destination.invalid",
                                   username: "second")
        container.mainContext.insert(second)
        try container.mainContext.save()
        let remote = MirrorLifecycleTransport()
        for destination in [first, second] {
            #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: destination.id,
                                                             role: .managedMirror, container: container))
        }
        let secondScope = try AccountCredentialScope(second)
        let secondDestination = try #require(try CalendarReceiptStore.destination(for: secondScope, in: ModelContext(container)))
        let secondDestinationKey = try CalendarReceiptKey.destination(secondDestination)
        let savedDestinationRow = try #require(try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>())
            .first { $0.id == secondDestinationKey })
        let savedDestination = (savedDestinationRow.id, savedDestinationRow.collectionPath, savedDestinationRow.syncToken,
                               savedDestinationRow.lastCTag)

        try SyncPushAcknowledgement.finalizeDeletion(task, in: container.mainContext)
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        let removeDestination = ModelContext(container)
        removeDestination.autosaveEnabled = false
        let missingRow = try #require(try removeDestination.fetch(FetchDescriptor<SyncMetadata>())
            .first { $0.id == secondDestinationKey })
        removeDestination.delete(missingRow)
        try removeDestination.save()

        var failures: [String] = []
        await coordinator(remote, container: container, onFailure: { failures.append($0) }).reconcileNow()
        #expect(!failures.isEmpty)
        #expect(try !CalendarMirrorState.pending(in: ModelContext(container), taskID: deletedTaskID).isEmpty)
        #expect(await remote.events.count == 1)

        let removeAccount = ModelContext(container)
        removeAccount.autosaveEnabled = false
        let secondAccountID = second.id
        let missingAccount = try #require(removeAccount.fetch(FetchDescriptor<ServerAccount>(
            predicate: #Predicate { $0.id == secondAccountID })).first)
        removeAccount.delete(missingAccount)
        try removeAccount.save()
        failures.removeAll()
        await coordinator(remote, container: container, onFailure: { failures.append($0) }).reconcileNow()
        #expect(!failures.isEmpty)
        #expect(try !CalendarMirrorState.pending(in: ModelContext(container), taskID: deletedTaskID).isEmpty)
        #expect(await remote.events.count == 1)

        let restore = ModelContext(container)
        restore.autosaveEnabled = false
        restore.insert(ServerAccount(id: second.id, displayName: second.displayName,
            serverBaseURL: second.serverBaseURL, username: second.username, mode: second.mode))
        let restored = SyncMetadata(id: savedDestination.0, collectionPath: savedDestination.1)
        restored.lastCTag = savedDestination.3
        restored.syncToken = savedDestination.2
        restore.insert(restored)
        try restore.save()
        await coordinator(remote, container: container).reconcileNow()
        #expect(await remote.events.isEmpty)
        #expect(try CalendarMirrorState.pending(in: ModelContext(container), taskID: deletedTaskID).isEmpty)
    }

    @Test func foregroundReplaySurvivesCancelledActiveCalendarPass() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id,
                                                         role: .managedMirror, container: container))
        task.title = "Committed during foreground replay"
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        let gate = MirrorLifecycleGate()
        await remote.gateNextCollectionProof(gate)
        let worker = CalendarMirrorCoordinator(container: container, nextcloud: manager(remote),
            apple: AppleCalendarSyncManager(store: FakeAppleCalendarStore(), makeJournal: {
                AppleCalendarOwnershipJournal(container: $0,
                    anchor: AppleCalendarAnchor { _, _ in Data(repeating: 31, count: 32) }, selector: "foreground-replay")
            }), appleEnabled: { false }, nextcloudEnabled: { true }, debounce: .milliseconds(1))

        let backgroundPass = Task { await worker.reconcileNow() }
        await gate.waitUntilEntered()
        worker.pause()
        let foregroundReplay = Task { await worker.reconcileNow() }
        await gate.release()
        await backgroundPass.value
        await foregroundReplay.value

        #expect(await remote.writes.count == 2)
        #expect(await remote.writes.last?.body?.contains("SUMMARY:Committed during foreground replay") == true)
        #expect(try CalendarMirrorState.pending(in: ModelContext(container), taskID: task.id).isEmpty)
    }

    @Test func delayedForegroundRecoveryCannotRestartCalendarWorkAfterBackgrounding() async throws {
        let (container, _, task) = try fixture()
        let store = FakeAppleCalendarStore()
        let apple = AppleCalendarSyncManager(store: store, makeJournal: {
            AppleCalendarOwnershipJournal(container: $0,
                anchor: AppleCalendarAnchor { _, _ in Data(repeating: 37, count: 32) }, selector: "delayed-foreground")
        })
        #expect(try apple.syncSingleTask(task))
        let original = try #require(store.savedEvents.values.first)
        task.title = "Change waits for the next active scene"
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)

        let scheduler = SyncScheduler(syncEngine: SyncEngine(), keychainManager: credentials,
            onWidgetReload: {}, onNotificationFlush: { _ in })
        scheduler.lastSyncDate = Date()
        scheduler.configureCalendarMirrors(container: container, apple: apple, appleEnabled: { true })
        let recoveryGate = MirrorLifecycleGate()
        let foregroundCallback = Task {
            await scheduler.startForegroundWork(modelContext: container.mainContext) {
                await recoveryGate.suspend()
            }
        }
        await recoveryGate.waitUntilEntered()
        scheduler.pauseCalendarMirrors()
        await recoveryGate.release()
        await foregroundCallback.value

        #expect(store.event(id: original.id) == original)
        #expect(try !CalendarMirrorState.pending(in: ModelContext(container), taskID: task.id).isEmpty)
    }

    @Test func preexistingConflictingPurgeHoldsOneLinkAndDoesNotStarveVerifiedPeer() async throws {
        let (container, account, firstTask) = try fixture()
        let peer = TaskItem(title: "Verified peer")
        peer.taskList = firstTask.taskList
        peer.dueDate = firstTask.dueDate
        container.mainContext.insert(peer)
        try container.mainContext.save()
        let remote = MirrorLifecycleTransport()
        for task in [firstTask, peer] {
            #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id,
                                                             role: .managedMirror, container: container))
        }

        let destination = try #require(try CalendarReceiptStore.destination(for: AccountCredentialScope(account),
            in: ModelContext(container)))
        let keys = try CalendarReceiptStore.eventKeys(for: destination, in: ModelContext(container))
        let firstSnapshot = try CalendarTaskSnapshot(firstTask, account: AccountCredentialScope(account), role: .managedMirror)
        let firstKey = try CalendarReceiptKey.event(task: firstSnapshot, binding: destination.id)
        let deleted = keys[0] == firstKey ? firstTask : peer
        let surviving = deleted.id == firstTask.id ? peer : firstTask
        let deletedID = deleted.id
        let deletedIdentity = CalendarMirrorState.Identity(deleted)
        try SyncPushAcknowledgement.finalizeDeletion(deleted, in: container.mainContext)
        surviving.dueDate = nil
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)

        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(deletedIdentity)) as? [String: Any])
        json["uid"] = "conflicting-purge-source"
        let conflictIdentity = try JSONDecoder().decode(CalendarMirrorState.Identity.self,
            from: JSONSerialization.data(withJSONObject: json))
        let conflicting = CalendarMirrorState.Ticket(version: 2,
            id: CalendarMirrorState.attributedTicketID(identity: conflictIdentity, purged: true),
            identity: conflictIdentity, purged: true)
        let row = SyncMetadata(id: conflicting.id, collectionPath: "")
        row.lastCTag = deletedID
        row.syncToken = String(decoding: try JSONEncoder().encode(conflicting), as: UTF8.self)
        container.mainContext.insert(row)
        try container.mainContext.save()

        await #expect(throws: (any Error).self) {
            try await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true })
        }
        #expect(await remote.removals.count == 1)
        #expect(await remote.events.count == 1)
        #expect(try CalendarMirrorState.pending(in: ModelContext(container), taskID: deletedID, requireComplete: true)
            .filter(\.purged).count == 2)
    }

    @Test func misindexedConflictingPurgeNeverAuthorizesNextcloudRemoval() async throws {
        let (container, account, deleted) = try fixture()
        let peer = TaskItem(title: "Verified live peer")
        peer.taskList = deleted.taskList
        peer.dueDate = deleted.dueDate
        container.mainContext.insert(peer)
        try container.mainContext.save()
        let remote = MirrorLifecycleTransport()
        for task in [deleted, peer] {
            #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id,
                role: .managedMirror, container: container))
        }
        let deletedID = deleted.id
        try SyncPushAcknowledgement.finalizeDeletion(deleted, in: container.mainContext)
        peer.dueDate = nil
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)

        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(CalendarMirrorState.Identity(deleted))) as? [String: Any])
        encoded["uid"] = "unproved-competing-source"
        let conflictIdentity = try JSONDecoder().decode(CalendarMirrorState.Identity.self,
            from: JSONSerialization.data(withJSONObject: encoded))
        let conflict = CalendarMirrorState.Ticket(version: 2,
            id: CalendarMirrorState.attributedTicketID(identity: conflictIdentity, purged: true),
            identity: conflictIdentity, purged: true)
        let context = ModelContext(container)
        let row = SyncMetadata(id: conflict.id, collectionPath: "")
        row.lastCTag = deletedID
        row.syncToken = String(decoding: try JSONEncoder().encode(conflict), as: UTF8.self)
        context.insert(row)
        try context.save()
        row.lastCTag = "corrupted-task-index"
        try context.save()

        await #expect(throws: (any Error).self) {
            try await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true })
        }
        #expect(await remote.removals.count == 1)
        #expect(await remote.events.count == 1)
        #expect(try CalendarMirrorState.pending(in: ModelContext(container), taskID: deletedID)
            .contains { $0.purged })
    }

    @Test func misindexedConflictingPurgeInsertedDuringProofRetainsNextcloudLink() async throws {
        let (container, account, task) = try fixture()
        let deletedID = task.id
        let identity = CalendarMirrorState.Identity(task)
        let peer = TaskItem(title: "Verified peer")
        peer.taskList = task.taskList
        peer.dueDate = task.dueDate
        container.mainContext.insert(peer)
        try container.mainContext.save()
        let remote = MirrorLifecycleTransport()
        for linked in [task, peer] {
            #expect(try await manager(remote).syncSingleTask(taskID: linked.id, accountID: account.id,
                role: .managedMirror, container: container))
        }
        try SyncPushAcknowledgement.finalizeDeletion(task, in: container.mainContext)
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        await remote.afterNextRemove { throw WatchTransactionSaveFailure.failed }
        await #expect(throws: WatchTransactionSaveFailure.failed.self) {
            try await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true })
        }

        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any])
        encoded["uid"] = "misindexed-after-proof"
        let conflictIdentity = try JSONDecoder().decode(CalendarMirrorState.Identity.self,
            from: JSONSerialization.data(withJSONObject: encoded))
        let conflict = CalendarMirrorState.Ticket(version: 2,
            id: CalendarMirrorState.attributedTicketID(identity: conflictIdentity, purged: true),
            identity: conflictIdentity, purged: true)
        await remote.afterNextRead {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let row = SyncMetadata(id: conflict.id, collectionPath: "")
            row.lastCTag = "corrupted-task-index"
            row.syncToken = String(decoding: try JSONEncoder().encode(conflict), as: UTF8.self)
            context.insert(row)
            try context.save()
        }
        await #expect(throws: (any Error).self) {
            try await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true })
        }
        #expect(await remote.removals.count == 1)
        #expect(await remote.events.count == 1)
        #expect(try persistedNextcloudReceipts(container).first { $0.taskID == deletedID }?.pending?.kind == .remove)
    }

    private enum PurgeKeyDamage: CaseIterable {
        case unknownKind, advisoryKind, advisoryKindWithSpacedPayload, advisoryKindWithEscapedPayload, taskDigest

        func corrupt(_ key: String) throws -> String {
            let purgePrefix = CalendarMirrorState.prefix + "task-v2:purge:"
            switch self {
            case .unknownKind:
                return key.replacingOccurrences(of: "task-v2:purge:", with: "task-v2:purge;")
            case .advisoryKind, .advisoryKindWithSpacedPayload, .advisoryKindWithEscapedPayload:
                return key.replacingOccurrences(of: "task-v2:purge:", with: "task-v2:advisory:")
            case .taskDigest:
                let suffix = key.dropFirst(purgePrefix.count)
                let firstDigit = try #require(suffix.first)
                return purgePrefix + (firstDigit == "0" ? "1" : "0") + suffix.dropFirst()
            }
        }
    }

    @Test(arguments: PurgeKeyDamage.allCases, [false, true])
    private func damagedPhysicalPurgeKeyHoldsRemovalAndLetsLivePeerFinish(
        damage: PurgeKeyDamage, duringRecoveryProof: Bool
    ) async throws {
        let (container, account, task) = try fixture()
        let taskID = task.id
        let identity = CalendarMirrorState.Identity(task)
        let peer = TaskItem(title: "Verified live peer")
        peer.taskList = task.taskList
        peer.dueDate = task.dueDate
        container.mainContext.insert(peer)
        try container.mainContext.save()

        let remote = MirrorLifecycleTransport()
        let sync = manager(remote)
        for linked in [task, peer] {
            try #require(try await sync.syncSingleTask(taskID: linked.id, accountID: account.id,
                role: .managedMirror, container: container))
        }
        let initialReceipts = try persistedNextcloudReceipts(container)
        let original = try #require(initialReceipts.first { $0.taskID == taskID })
        let livePeer = try #require(initialReceipts.first { $0.taskID == peer.id })
        try SyncPushAcknowledgement.finalizeDeletion(task, in: container.mainContext)
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)

        if duringRecoveryProof {
            // Leave the event present and its original DELETE pending so exact
            // read-back would normally authorize a retry.
            await remote.failRemoval(for: account.id)
            await #expect(throws: CalDAVError.self) {
                try await sync.reconcileManaged(accountID: account.id, container: container, isEnabled: { true })
            }
            await remote.failRemoval(for: nil)
            try #require(await remote.removals.map(\.target.href) == [original.target.href])
            try #require(try persistedNextcloudReceipts(container)
                .first { $0.taskID == taskID }?.pending?.kind == .remove)
        }
        let heldReceipt = try #require(try persistedNextcloudReceipts(container).first { $0.taskID == taskID })
        let removalsBeforeReconcile = await remote.removals.count
        peer.dueDate = nil
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)

        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any])
        encoded["uid"] = "competing-purge-identity"
        let competingIdentity = try JSONDecoder().decode(CalendarMirrorState.Identity.self,
            from: JSONSerialization.data(withJSONObject: encoded))
        let intactID = CalendarMirrorState.attributedTicketID(identity: competingIdentity, purged: true)
        let competing = CalendarMirrorState.Ticket(version: 2, id: intactID, identity: competingIdentity, purged: true)
        let encoder = JSONEncoder()
        if damage == .advisoryKindWithSpacedPayload { encoder.outputFormatting = .prettyPrinted }
        var rawPayload = String(decoding: try encoder.encode(competing), as: UTF8.self)
        if damage == .advisoryKindWithEscapedPayload {
            rawPayload = rawPayload.replacingOccurrences(of: "calendar-mirror-work-v1:", with: "calendar\\u002dmirror-work-v1:")
        }
        let payload = rawPayload
        try #require(try JSONDecoder().decode(CalendarMirrorState.Ticket.self, from: Data(payload.utf8)) == competing)
        let damagedID = try damage.corrupt(intactID)
        try #require(damagedID != intactID)
        let saveDamagedKey: @MainActor @Sendable () throws -> Void = {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let row = SyncMetadata(id: intactID, collectionPath: "")
            row.lastCTag = taskID
            row.syncToken = payload
            context.insert(row)
            try context.save()
            row.id = damagedID
            try context.save()
        }
        if duringRecoveryProof {
            await remote.afterNextRead(saveDamagedKey)
        } else {
            try saveDamagedKey()
        }

        await #expect(throws: CalendarReceiptStore.Held.self) {
            try await sync.reconcileManaged(accountID: account.id, container: container, isEnabled: { true })
        }

        #expect(await remote.removals.dropFirst(removalsBeforeReconcile).map(\.target.href) == [livePeer.target.href])
        let events = await remote.events
        #expect(Set(events.keys) == [original.target.href])
        let receipts = try persistedNextcloudReceipts(container)
        #expect(receipts.first { $0.taskID == taskID } == heldReceipt)
        #expect(receipts.first { $0.taskID == peer.id }?.wasRemoved == true)
        let damaged = try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate {
            $0.id == damagedID
        }))
        #expect(damaged.first?.lastCTag == taskID)
        #expect(damaged.first?.syncToken == payload)
    }

    @Test func malformedJournalRecordDoesNotStarveVerifiedTicket() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id,
                                                         role: .managedMirror, container: container))
        task.title = "Verified committed peer"
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        let malformed = SyncMetadata(id: CalendarMirrorState.prefix + UUID().uuidString, collectionPath: "")
        malformed.syncToken = "{" // No task identity can safely be inferred.
        container.mainContext.insert(malformed)
        try container.mainContext.save()

        var failures: [String] = []
        await coordinator(remote, container: container, onFailure: { failures.append($0) }).reconcileNow()

        #expect(await remote.writes.count == 2)
        #expect(await remote.writes.last?.body?.contains("SUMMARY:Verified committed peer") == true)
        #expect(!failures.isEmpty)
        #expect(try CalendarMirrorState.pending(in: ModelContext(container), taskID: task.id).count == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>())
            .contains { $0.id == malformed.id && $0.syncToken == "{" })
    }

    @Test func ordinaryWakePagesPastOneHundredMalformedJournalKeys() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id,
            role: .managedMirror, container: container))
        task.title = "Ticket after damaged page"
        try container.mainContext.save()

        let context = ModelContext(container)
        context.autosaveEnabled = false
        for index in 0..<100 {
            let id = CalendarMirrorState.prefix + String(format: "00000000-0000-0000-0000-%012d", index)
            let malformed = SyncMetadata(id: id, collectionPath: "")
            malformed.lastCTag = task.id
            malformed.syncToken = "{"
            context.insert(malformed)
        }
        let identity = CalendarMirrorState.Identity(task)
        let validID = CalendarMirrorState.prefix + "ffffffff-ffff-ffff-ffff-ffffffffffff"
        let ticket = CalendarMirrorState.Ticket(id: validID, identity: identity, purged: false)
        let valid = SyncMetadata(id: validID, collectionPath: "")
        valid.lastCTag = task.id
        valid.syncToken = String(decoding: try JSONEncoder().encode(ticket), as: UTF8.self)
        context.insert(valid)
        try context.save()

        var failures: [String] = []
        let worker = coordinator(remote, container: container, onFailure: { failures.append($0) })
        let ordinaryWake = try #require(worker.request())
        await ordinaryWake.value

        #expect(await remote.writes.count == 2)
        #expect(await remote.writes.last?.kind == .update)
        #expect(await remote.events.count == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>()).contains { $0.id == validID } == false)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>()).filter {
            $0.id.hasPrefix(CalendarMirrorState.prefix) && $0.syncToken == "{"
        }.count == 100)
        #expect(!failures.isEmpty)
    }

    @Test func ordinaryWakeContinuesPastMoreThanOneThousandMalformedKeys() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id,
            role: .managedMirror, container: container))
        task.title = "Ticket after multiple physical pages"
        try container.mainContext.save()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for index in 0..<1_100 {
            let id = CalendarMirrorState.prefix + String(format: "00000000-0000-0000-0000-%012d", index)
            let malformed = SyncMetadata(id: id, collectionPath: "")
            malformed.lastCTag = task.id
            malformed.syncToken = "{"
            context.insert(malformed)
        }
        let identity = CalendarMirrorState.Identity(task)
        let validID = CalendarMirrorState.prefix + "ffffffff-ffff-ffff-ffff-ffffffffffff"
        let ticket = CalendarMirrorState.Ticket(id: validID, identity: identity, purged: false)
        let valid = SyncMetadata(id: validID, collectionPath: "")
        valid.lastCTag = task.id
        valid.syncToken = String(decoding: try JSONEncoder().encode(ticket), as: UTF8.self)
        context.insert(valid)
        try context.save()

        let worker = coordinator(remote, container: container)
        let first = try #require(worker.request())
        await first.value
        #expect(await remote.writes.count == 1)
        let second = try #require(worker.request())
        await second.value

        #expect(await remote.writes.count == 2)
        #expect(await remote.writes.last?.body?.contains("SUMMARY:Ticket after multiple physical pages") == true)
        #expect(await remote.events.count == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>()).contains { $0.id == validID } == false)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>()).filter {
            $0.id.hasPrefix(CalendarMirrorState.prefix) && $0.syncToken == "{"
        }.count == 1_100)
    }

    @Test func ordinaryWakeCursorSurvivesTwoThousandValidHeldTickets() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id,
            role: .managedMirror, container: container))
        task.title = "Ticket beyond two thousand held rows"
        try container.mainContext.save()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let identity = CalendarMirrorState.Identity(task)
        let held = CalendarMirrorState.Identity.heldMarker(for: identity)
        for index in 0..<2_000 {
            let id = CalendarMirrorState.prefix + String(format: "00000000-0000-0000-0000-%012d", index)
            let ticket = CalendarMirrorState.Ticket(id: id, identity: held, purged: false)
            let row = SyncMetadata(id: id, collectionPath: "")
            row.lastCTag = held.taskID
            row.syncToken = String(decoding: try JSONEncoder().encode(ticket), as: UTF8.self)
            context.insert(row)
        }
        let validID = CalendarMirrorState.prefix + "ffffffff-ffff-ffff-ffff-ffffffffffff"
        let validTicket = CalendarMirrorState.Ticket(id: validID, identity: identity, purged: false)
        let valid = SyncMetadata(id: validID, collectionPath: "")
        valid.lastCTag = task.id
        valid.syncToken = String(decoding: try JSONEncoder().encode(validTicket), as: UTF8.self)
        context.insert(valid)
        try context.save()

        let worker = coordinator(remote, container: container)
        for _ in 0..<2 {
            let wake = try #require(worker.request())
            await wake.value
        }
        #expect(await remote.writes.count == 1)
        let laterWake = try #require(worker.request())
        await laterWake.value

        #expect(await remote.writes.count == 2)
        #expect(await remote.writes.last?.body?.contains("SUMMARY:Ticket beyond two thousand held rows") == true)
        #expect(await remote.events.count == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>()).contains { $0.id == validID } == false)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>()).filter {
            $0.id.hasPrefix(CalendarMirrorState.prefix)
        }.count == 2_000)
    }

    @Test func ordinaryWakeWrapsToNewLowerSortingTicketAfterPhysicalEnd() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id,
            role: .managedMirror, container: container))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        task.title = "High key update"
        try container.mainContext.save()
        let identity = CalendarMirrorState.Identity(task)
        let highID = CalendarMirrorState.prefix + "ffffffff-ffff-ffff-ffff-ffffffffffff"
        let highTicket = CalendarMirrorState.Ticket(id: highID, identity: identity, purged: false)
        let highRow = SyncMetadata(id: highID, collectionPath: "")
        highRow.lastCTag = task.id
        highRow.syncToken = String(decoding: try JSONEncoder().encode(highTicket), as: UTF8.self)
        context.insert(highRow)
        try context.save()

        let worker = coordinator(remote, container: container)
        let highWake = try #require(worker.request())
        await highWake.value
        #expect(await remote.writes.count == 2)

        task.title = "Lower key after wrap"
        try container.mainContext.save()
        let lowID = CalendarMirrorState.prefix + "00000000-0000-0000-0000-000000000001"
        let lowTicket = CalendarMirrorState.Ticket(id: lowID, identity: identity, purged: false)
        let lowRow = SyncMetadata(id: lowID, collectionPath: "")
        lowRow.lastCTag = task.id
        lowRow.syncToken = String(decoding: try JSONEncoder().encode(lowTicket), as: UTF8.self)
        context.insert(lowRow)
        try context.save()

        let wrapWake = try #require(worker.request())
        await wrapWake.value

        #expect(await remote.writes.count == 3)
        #expect(await remote.writes.last?.body?.contains("SUMMARY:Lower key after wrap") == true)
        #expect(try !ModelContext(container).fetch(FetchDescriptor<SyncMetadata>()).contains { $0.id == lowID })
    }

    @Test func exactPurgeIgnoresOverTenThousandUnrelatedHeldAdvisoryTickets() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id,
            role: .managedMirror, container: container))
        let identity = CalendarMirrorState.Identity(task)
        try SyncPushAcknowledgement.finalizeDeletion(task, in: container.mainContext)
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)

        let context = ModelContext(container)
        context.autosaveEnabled = false
        for index in 0..<10_001 {
            let taskID = "unrelated-held-\(index)"
            let markerIdentity = CalendarMirrorState.Identity.heldMarker(for: identity)
            var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(markerIdentity)) as! [String: Any]
            encoded["taskID"] = taskID
            let heldIdentity = try JSONDecoder().decode(CalendarMirrorState.Identity.self,
                from: JSONSerialization.data(withJSONObject: encoded))
            let operationID = try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)))
            let id = CalendarMirrorState.attributedTicketID(identity: heldIdentity, purged: false,
                                                            operationID: operationID)
            let ticket = CalendarMirrorState.Ticket(version: 2, id: id, identity: heldIdentity, purged: false)
            let row = SyncMetadata(id: id, collectionPath: "")
            row.lastCTag = taskID
            row.syncToken = String(decoding: try JSONEncoder().encode(ticket), as: UTF8.self)
            context.insert(row)
        }
        try context.save()

        try await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true })

        #expect(await remote.removals.count == 1)
        #expect(await remote.events.isEmpty)
        #expect(try CalendarMirrorState.purge(for: identity, in: ModelContext(container)) != nil)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>()).filter {
            $0.id.contains(":task-v2:advisory:")
        }.count == 10_001)
    }

    @Test(arguments: ["", "task-v2:unknown:"])
    func unattributedJournalRowCannotAuthorizeAnExactPurge(unknownKeyspace: String) throws {
        let (container, _, task) = try fixture()
        let identity = CalendarMirrorState.Identity(task)
        try CalendarMirrorState.stagePurge([task], in: container.mainContext)
        try container.mainContext.save()

        let unattributed = SyncMetadata(id: CalendarMirrorState.prefix + unknownKeyspace + UUID().uuidString,
                                        collectionPath: "")
        unattributed.lastCTag = "unattributed-journal-task"
        unattributed.syncToken = "unsupported"
        container.mainContext.insert(unattributed)
        try container.mainContext.save()

        #expect(throws: CalendarMirrorState.Held.self) {
            try CalendarMirrorState.purge(for: identity, in: ModelContext(container))
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>()).contains {
            $0.id == unattributed.id && $0.syncToken == "unsupported"
        })
    }

    @Test func overCapAdvisoryEditHistoryDoesNotHideExactPurge() throws {
        let (container, _, task) = try fixture()
        let identity = CalendarMirrorState.Identity(task)
        for _ in 0..<1_001 {
            let id = CalendarMirrorState.attributedTicketID(identity: identity, purged: false)
            let ticket = CalendarMirrorState.Ticket(version: 2, id: id, identity: identity, purged: false)
            let row = SyncMetadata(id: ticket.id, collectionPath: "")
            row.lastCTag = identity.taskID
            row.syncToken = String(decoding: try JSONEncoder().encode(ticket), as: UTF8.self)
            container.mainContext.insert(row)
        }
        try container.mainContext.save()
        try CalendarMirrorState.stagePurge([task], in: container.mainContext)
        try container.mainContext.save()

        let context = ModelContext(container)
        let purge = try #require(try CalendarMirrorState.purge(for: identity, in: context))
        let advisory = TaskItem(title: "Advisory with a purge key in its source UID")
        advisory.id = task.id
        advisory.uid = purge.id
        let advisoryIdentity = CalendarMirrorState.Identity(advisory)
        let advisoryID = CalendarMirrorState.attributedTicketID(identity: advisoryIdentity, purged: false)
        let ticket = CalendarMirrorState.Ticket(version: 2, id: advisoryID, identity: advisoryIdentity, purged: false)
        let row = SyncMetadata(id: advisoryID, collectionPath: "")
        row.lastCTag = task.id
        row.syncToken = String(decoding: try JSONEncoder().encode(ticket), as: UTF8.self)
        context.insert(row)
        try context.save()

        let completePurge = try CalendarMirrorState.purge(for: identity, in: ModelContext(container))
        #expect(completePurge?.purged == true)
        #expect(completePurge?.identity == identity)
    }

    @Test func conflictingPurgeDuringRemovalProofRetainsLinkAndContinuesPeerCleanup() async throws {
        let (container, account, task) = try fixture()
        let deletedID = task.id
        let originalIdentity = CalendarMirrorState.Identity(task)
        let peer = TaskItem(title: "Verified peer")
        peer.taskList = task.taskList
        peer.dueDate = task.dueDate
        container.mainContext.insert(peer)
        try container.mainContext.save()

        let remote = MirrorLifecycleTransport()
        for linked in [task, peer] {
            #expect(try await manager(remote).syncSingleTask(taskID: linked.id, accountID: account.id,
                                                             role: .managedMirror, container: container))
        }
        try SyncPushAcknowledgement.finalizeDeletion(task, in: container.mainContext)
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        struct LostRemovalResponse: Error {}
        await remote.afterNextRemove { throw LostRemovalResponse() }
        await #expect(throws: LostRemovalResponse.self) {
            try await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true })
        }
        #expect(try persistedNextcloudReceipts(container).first { $0.taskID == deletedID }?.pending?.kind == .remove)

        var conflictingObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(originalIdentity)) as? [String: Any])
        conflictingObject["uid"] = "different-source-identity"
        let conflictingIdentity = try JSONDecoder().decode(CalendarMirrorState.Identity.self,
            from: JSONSerialization.data(withJSONObject: conflictingObject))
        let conflictingTicket = CalendarMirrorState.Ticket(version: 2,
            id: CalendarMirrorState.attributedTicketID(identity: conflictingIdentity, purged: true),
            identity: conflictingIdentity, purged: true)
        let conflictingData = try JSONEncoder().encode(conflictingTicket)
        await remote.afterNextRead {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let row = SyncMetadata(id: conflictingTicket.id, collectionPath: "")
            row.lastCTag = deletedID
            row.syncToken = String(decoding: conflictingData, as: UTF8.self)
            context.insert(row)
            try context.save()
        }
        await #expect(throws: (any Error).self) {
            try await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true })
        }

        let pendingPurges = try CalendarMirrorState.pending(in: ModelContext(container), taskID: deletedID,
                                                             requireComplete: true).filter(\.purged)
        #expect(pendingPurges.count == 2)
        #expect(try persistedNextcloudReceipts(container).first { $0.taskID == deletedID }?.pending?.kind == .remove)
        #expect(await remote.removals.count == 1)
        #expect(await remote.events.count == 1)
    }

    @Test func purgeRetainsExactCleanupAndManualExport() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        for role in [CalendarEventRole.managedMirror, .manualExport] {
            #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id, role: role, container: container))
        }
        let manual = try #require(try persistedNextcloudReceipts(container).first { $0.role == .manualExport })
        try SyncPushAcknowledgement.finalizeDeletion(task, in: container.mainContext)
        try container.mainContext.save()
        #expect(try await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true }))
        let remaining = await remote.events
        #expect(Set(remaining.keys) == [manual.target.href])
        #expect(try persistedNextcloudReceipts(container).first { $0.role == .manualExport } == manual)
    }

    @Test func appleCommittedChangesNeverCreateAndPurgeOnlyOwnedMirror() throws {
        let (container, _, task) = try fixture()
        let store = FakeAppleCalendarStore()
        func manager() -> AppleCalendarSyncManager {
            AppleCalendarSyncManager(store: store, makeJournal: {
                AppleCalendarOwnershipJournal(container: $0, anchor: AppleCalendarAnchor { _, _ in Data(repeating: 13, count: 32) },
                                              selector: "lifecycle")
            })
        }
        #expect(try !manager().reconcileManaged(container: container, isEnabled: { true }))
        #expect(store.savedEvents.isEmpty)
        #expect(try manager().syncSingleTask(task))
        let owned = try #require(store.savedEvents.values.first)
        let manual = try store.save(store.newEvent(owned.calendar, title: "Manual"))
        task.title = "Committed title"
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        #expect(try manager().reconcileManaged(container: container, isEnabled: { true }))
        #expect(store.event(id: owned.id)?.content.title == "Committed title")
        try SyncPushAcknowledgement.finalizeDeletion(task, in: container.mainContext)
        try container.mainContext.save()
        #expect(try manager().reconcileManaged(container: container, isEnabled: { true }))
        #expect(store.event(id: owned.id) == nil)
        #expect(store.event(id: manual.id) == manual)
    }

    @Test func nextcloudNewEntryCannotCreateOrRestoreRemovedMirror() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await !manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true }))
        #expect(await remote.writes.isEmpty)
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id, role: .managedMirror, container: container))
        task.dueDate = nil
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        #expect(try await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true }))
        task.dueDate = Date()
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        #expect(try await !manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true }))
        #expect(await remote.writes.count == 1)
    }

    @Test func disabledAndChangedSourceRetainEvents() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id, role: .managedMirror, container: container))
        task.dueDate = nil
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        #expect(try await !manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { false }))
        let vault = ServerAccount(vaultDisplayName: "Vault")
        let list = TaskList(serverURL: "", name: "Private", colorHex: "#000000")
        list.account = vault
        container.mainContext.insert(vault); container.mainContext.insert(list)
        task.taskList = list
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        await #expect(throws: (any Error).self) {
            try await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true })
        }
        #expect(await remote.events.count == 1)
        #expect(await remote.removals.isEmpty)
    }

    @Test(arguments: ["edit", "clear", "purge"])
    func oldCreateOutcomeRecoversBeforeLatestCommittedChange(change: String) async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        let id = task.id
        await remote.afterNextPut {
            if change == "purge" { try SyncPushAcknowledgement.finalizeDeletion(task, in: container.mainContext) }
            else if change == "clear" { task.dueDate = nil }
            else { task.title = "Latest committed" }
            try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        }
        #expect(try await !manager(remote).syncSingleTask(taskID: id, accountID: account.id, role: .managedMirror, container: container))
        #expect(try persistedNextcloudReceipts(container).first?.pending?.kind == .create)
        let reconciled = try? await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true })
        #expect(reconciled == true)
        let writes = await remote.writes
        #expect(writes.filter { $0.kind == .create }.count == 1)
        if change == "edit" {
            #expect(writes.count == 2)
            #expect(writes.last?.body?.contains("SUMMARY:Latest committed") == true)
        } else { #expect(await remote.events.isEmpty) }
        #expect(try persistedNextcloudReceipts(container).first?.pending == nil)
    }

    @Test func absentObsoleteCreateDoesNotCreateToRemove() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        await remote.afterNextPut {
            task.dueDate = nil
            try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        }
        #expect(try await !manager(remote).syncSingleTask(taskID: task.id, accountID: account.id, role: .managedMirror, container: container))
        let target = try #require(try persistedNextcloudReceipts(container).first?.target)
        await remote.forget(target.href)
        let result = try? await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true })
        #expect(result == true)
        #expect(await remote.writes.count == 1)
        #expect(await remote.removals.isEmpty)
        #expect(try persistedNextcloudReceipts(container).first?.pending == nil)
    }

    @Test func legacyOriginIsHeldWithoutAReplacement() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id, role: .managedMirror, container: container))
        let context = ModelContext(container)
        let row = try #require(try context.fetch(FetchDescriptor<SyncMetadata>()).first { $0.id.hasPrefix("calendar-nextcloud-v1:event:") })
        let encoded = try #require(row.syncToken)
        var json = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        json.removeValue(forKey: "lifecycleOrigin")
        row.syncToken = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        try context.save()
        let raw = row.syncToken
        task.title = "Should remain local"
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        await #expect(throws: (any Error).self) {
            try await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true })
        }
        #expect(await remote.writes.count == 1)
        #expect(row.syncToken == raw)
    }

    @Test func changedOriginEvidenceCannotAuthorizeMovedSource() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id, role: .managedMirror, container: container))
        let moved = TaskList(serverURL: "https://other-source.invalid", name: "Changed source", colorHex: "#000000")
        container.mainContext.insert(moved)
        task.taskList = moved
        task.title = "Private changed content"
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        let context = ModelContext(container)
        let row = try #require(try context.fetch(FetchDescriptor<SyncMetadata>()).first { $0.id.hasPrefix("calendar-nextcloud-v1:event:") })
        var event = try JSONDecoder().decode(CalendarEventReceipt.self, from: Data(try #require(row.syncToken).utf8))
        event.lifecycleOrigin = try CalendarTaskSnapshot(task, account: AccountCredentialScope(account), role: .managedMirror)
        row.syncToken = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        try context.save()
        await #expect(throws: (any Error).self) {
            try await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true })
        }
        #expect(await remote.writes.count == 1)
    }

    @Test func interruptedUpdateRecoversWithoutReplayingOldBody() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id, role: .managedMirror, container: container))
        task.title = "First update"
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        await remote.afterNextPut {
            task.title = "Second update"
            try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        }
        #expect(try await !manager(remote).syncSingleTask(taskID: task.id, accountID: account.id, role: .managedMirror, container: container))
        #expect(try await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true }))
        let writes = await remote.writes
        #expect(writes.count == 3)
        #expect(writes.filter { $0.body?.contains("SUMMARY:First update") == true }.count == 1)
        #expect(writes.last?.body?.contains("SUMMARY:Second update") == true)
    }

    @Test func taskReplacementDuringRecoveryCannotAcknowledgeOldOperation() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        await remote.afterNextPut {
            task.title = "New desired state"
            try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        }
        #expect(try await !manager(remote).syncSingleTask(taskID: task.id, accountID: account.id, role: .managedMirror, container: container))
        await remote.afterNextRead {
            task.uid = "replacement-identity"
            try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        }
        await #expect(throws: (any Error).self) {
            try await manager(remote).reconcileManaged(accountID: account.id, container: container, isEnabled: { true })
        }
        #expect(try persistedNextcloudReceipts(container).first?.pending?.kind == .create)
        #expect(try persistedNextcloudReceipts(container).first?.acknowledged == nil)
        #expect(await remote.writes.count == 1)
    }

    @Test(arguments: ["create", "update"], ["edit", "clear", "purge"])
    func applePendingOutcomeUsesExactIdentityAcrossCommittedChange(phase: String, change: String) throws {
        let (container, _, task) = try fixture()
        let store = FakeAppleCalendarStore()
        struct Interrupted: Error {}
        func manager(failingSave: Int? = nil) -> AppleCalendarSyncManager {
            var count = 0
            return AppleCalendarSyncManager(store: store, makeJournal: {
                AppleCalendarOwnershipJournal(container: $0,
                    anchor: AppleCalendarAnchor { _, _ in Data(repeating: 17, count: 32) }, selector: "pending-lifecycle",
                    save: { context in
                        count += 1
                        if count == failingSave { throw Interrupted() }
                        try context.save()
                    })
            })
        }
        if phase == "update" {
            #expect(try manager().syncSingleTask(task))
            task.title = "First update"
            try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        }
        #expect(throws: Interrupted.self) { try manager(failingSave: phase == "create" ? 6 : 2).syncSingleTask(task) }
        let owned = try #require(store.savedEvents.values.first)
        let commits = store.eventCommits
        if change == "purge" { try SyncPushAcknowledgement.finalizeDeletion(task, in: container.mainContext) }
        else if change == "clear" { task.dueDate = nil }
        else { task.title = "Latest Apple content" }
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        #expect(try manager().reconcileManaged(container: container, isEnabled: { true }))
        #expect(store.savedCalendars.count == 1)
        if change == "edit" {
            #expect(store.event(id: owned.id)?.content.title == "Latest Apple content")
            #expect(store.eventCommits == commits + 1)
        } else {
            #expect(store.event(id: owned.id) == nil)
            #expect(store.eventCommits == commits)
        }
    }

    @Test func restartDrainsCommittedWorkAndDoesNotPublishDrafts() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id, role: .managedMirror, container: container))
        task.title = "First commit"
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        task.title = "Latest commit"
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        task.title = "Unsaved draft"
        await coordinator(remote, container: container).reconcileNow()
        #expect(await remote.writes.count == 1)
        #expect(try !CalendarMirrorState.pending(in: ModelContext(container)).isEmpty)
        container.mainContext.rollback()
        await coordinator(remote, container: container).reconcileNow()
        let writes = await remote.writes
        #expect(writes.count == 2)
        #expect(writes.last?.body?.contains("SUMMARY:Latest commit") == true)
        #expect(try CalendarMirrorState.pending(in: ModelContext(container)).isEmpty)
        await coordinator(remote, container: container).reconcileNow()
        #expect(await remote.writes.count == 2)
    }

    @Test func coordinatorReportsRetainedFailureAndCompletesOtherDestination() async throws {
        let (container, first, task) = try fixture()
        let second = ServerAccount(displayName: "Second", serverBaseURL: "https://second-worker.invalid", username: "second")
        container.mainContext.insert(second); try container.mainContext.save()
        let remote = MirrorLifecycleTransport()
        for account in [first, second] {
            #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id, role: .managedMirror, container: container))
        }
        task.dueDate = nil
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        await remote.failRemoval(for: first.id)
        var failures: [String] = []
        await coordinator(remote, container: container, onFailure: { failures.append($0) }).reconcileNow()
        #expect(failures.count == 1)
        #expect(try persistedNextcloudReceipts(container).first { $0.scope.id == second.id }?.wasRemoved == true)
        #expect(try !CalendarMirrorState.pending(in: ModelContext(container)).isEmpty)
        await remote.failRemoval(for: nil)
        await coordinator(remote, container: container).reconcileNow()
        #expect(await remote.events.isEmpty)
        #expect(try CalendarMirrorState.pending(in: ModelContext(container)).isEmpty)
    }

    @Test func inboundCommitEnqueuesInSameTransaction() async throws {
        let (container, account, task) = try fixture()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: account.id, role: .managedMirror, container: container))
        let list = try #require(task.taskList)
        let data = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:\(task.uid)\r\nSUMMARY:Inbound committed\r\nDUE:20231114T221320Z\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
        let parsed = try ICalendarParser.parseSingleVTODO(from: data)
        let resource = ParsedRemoteTask(href: "/tasks/inbound.ics", etag: "inbound", todo: parsed)
        let writer = SyncInboundBatchWriter(container: container, listID: list.id, expectedAccountID: account.id)
        _ = try writer.apply([resource])
        #expect(try CalendarMirrorState.pending(in: ModelContext(container)).contains { $0.taskID == task.id })
        await coordinator(remote, container: container).reconcileNow()
        #expect(await remote.writes.last?.body?.contains("SUMMARY:Inbound committed") == true)
    }

    @Test func inboundImportWithUnrepresentableMirrorUIDStillCommits() async throws {
        let (container, account, task) = try fixture()
        let list = try #require(task.taskList)
        let originalTaskID = task.id
        let longUID = String(repeating: "u", count: 3_000)
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: originalTaskID, accountID: account.id,
                                                         role: .managedMirror, container: container))
        let parsedLong = try ICalendarParser.parseSingleVTODO(from:
            "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VTODO\nUID:\(longUID)\nSUMMARY:Long UID\nDUE:20231114T221320Z\nEND:VTODO\nEND:VCALENDAR")
        let parsedNormal = try ICalendarParser.parseSingleVTODO(from:
            "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VTODO\nUID:\(task.uid)\nSUMMARY:Normal UID committed\nDUE:20231114T221320Z\nEND:VTODO\nEND:VCALENDAR")
        let longTodo = try #require(parsedLong)
        let normalTodo = try #require(parsedNormal)
        let writer = SyncInboundBatchWriter(container: container, listID: list.id, expectedAccountID: account.id)

        let commit = try writer.apply([
            ParsedRemoteTask(href: "/tasks/long.ics", etag: "long", todo: longTodo),
            ParsedRemoteTask(href: "/tasks/normal.ics", etag: "normal", todo: normalTodo)
        ])

        #expect(commit != nil)
        let fresh = ModelContext(container)
        let imported = try fresh.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.uid == longUID })).first
        #expect(imported?.title == "Long UID")
        let original = try fresh.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == originalTaskID })).first
        #expect(original?.title == "Normal UID committed")
        let tickets = try CalendarMirrorState.pending(in: fresh)
        #expect(tickets.contains { $0.taskID == originalTaskID })
        let held = try #require(imported.flatMap { item in tickets.first { $0.taskID == item.id } })
        #expect(!held.identity.isValid)
        var failures: [String] = []
        await coordinator(remote, container: container, onFailure: { failures.append($0) }).reconcileNow()
        #expect(await remote.writes.count == 2)
        #expect(await remote.writes.last?.body?.contains("SUMMARY:Normal UID committed") == true)
        #expect(await remote.events.count == 1)
        #expect(failures.count == 1)
        #expect(try CalendarMirrorState.pending(in: ModelContext(container)).map(\.taskID) == [held.taskID])
    }
    @Test func listCascadeCapturesIdentityBeforeRelationshipsDisappear() throws {
        let (container, _, task) = try fixture()
        let identity = CalendarMirrorState.Identity(task)
        let list = try #require(task.taskList)
        try TaskListHelpers.settlePendingMoves(beforeDeleting: list, in: container.mainContext)
        container.mainContext.delete(list)
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).isEmpty)
        #expect(try CalendarMirrorState.purge(for: identity, in: ModelContext(container)) != nil)
    }

    @Test func duplicateCleanupCapturesOriginalSourceBeforeDeleting() throws {
        let (container, _, task) = try fixture()
        let identity = CalendarMirrorState.Identity(task)
        task.lastModifiedDate = Date(timeIntervalSince1970: 1)
        let survivor = TaskItem(uid: task.uid, title: "Newest")
        survivor.taskList = task.taskList
        survivor.lastModifiedDate = Date(timeIntervalSince1970: 2)
        container.mainContext.insert(survivor); try container.mainContext.save()
        #expect(try TaskListHelpers.cleanupDuplicateUIDs(in: container.mainContext) == 1)
        try container.mainContext.save()
        #expect(try CalendarMirrorState.purge(for: identity, in: ModelContext(container)) != nil)
    }

    @Test func corruptPeerRetainsWorkWithoutStarvingVerifiedRemoval() async throws {
        let (container, account, task) = try fixture()
        let peer = TaskItem(title: "Peer")
        peer.taskList = task.taskList; peer.dueDate = task.dueDate
        container.mainContext.insert(peer); try container.mainContext.save()
        let remote = MirrorLifecycleTransport()
        for item in [task, peer] {
            #expect(try await manager(remote).syncSingleTask(taskID: item.id, accountID: account.id, role: .managedMirror, container: container))
        }
        let damaged = try #require(try persistedNextcloudReceipts(container).first { $0.taskID == peer.id })
        let key = try CalendarReceiptKey.event(task: #require(damaged.lifecycleOrigin), binding: damaged.bindingID)
        let rows = try container.mainContext.fetch(FetchDescriptor<SyncMetadata>())
        let row = try #require(rows.first { $0.id == key })
        row.syncToken = "corrupted"
        task.dueDate = nil; peer.dueDate = nil
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        var failures = 0
        await coordinator(remote, container: container, onFailure: { _ in failures += 1 }).reconcileNow()
        #expect(await remote.removals.count == 1)
        #expect(await remote.removals.first?.snapshot.id == task.id)
        #expect(failures == 1)
        #expect(try !CalendarMirrorState.pending(in: ModelContext(container)).isEmpty)
    }

    @Test func lostReceiptAndClaimNeverAcknowledgeCleanupTicket() async throws {
        let (container, account, task) = try fixture()
        let destination = ServerAccount(displayName: "Mirror destination", serverBaseURL: "https://mirror-destination.invalid", username: "destination")
        container.mainContext.insert(destination); try container.mainContext.save()
        let remote = MirrorLifecycleTransport()
        #expect(try await manager(remote).syncSingleTask(taskID: task.id, accountID: destination.id, role: .managedMirror, container: container))
        let receipt = try #require(try persistedNextcloudReceipts(container).first { $0.scope.id == destination.id })
        let key = try CalendarReceiptKey.event(task: #require(receipt.lifecycleOrigin), binding: receipt.bindingID)
        let claim = try CalendarReceiptKey.claim(receipt)
        for row in try container.mainContext.fetch(FetchDescriptor<SyncMetadata>()) where row.id == key || row.id == claim {
            container.mainContext.delete(row)
        }
        task.dueDate = nil
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        var failures = 0
        await coordinator(remote, container: container, onFailure: { _ in failures += 1 }).reconcileNow()
        #expect(await remote.removals.isEmpty)
        #expect(failures == 1)
        #expect(try !CalendarMirrorState.pending(in: ModelContext(container)).isEmpty)
    }

    @Test func purgeCannotInferIdentityFromTruncatedHistory() throws {
        let (container, _, task) = try fixture()
        let identity = CalendarMirrorState.Identity(task)
        task.uid = "replacement"
        let conflicting = CalendarMirrorState.Identity(task)
        container.mainContext.rollback()
        for index in 0...1_000 {
            let rowIdentity = index == 1_000 ? conflicting : identity
            let id = CalendarMirrorState.attributedTicketID(identity: rowIdentity, purged: true)
            let ticket = CalendarMirrorState.Ticket(version: 2, id: id, identity: rowIdentity, purged: true)
            let row = SyncMetadata(id: id, collectionPath: "")
            row.lastCTag = identity.taskID
            row.syncToken = String(decoding: try JSONEncoder().encode(ticket), as: UTF8.self)
            container.mainContext.insert(row)
        }
        try container.mainContext.save()
        #expect(throws: CalendarMirrorState.Held.self) {
            try CalendarMirrorState.purge(for: identity, in: ModelContext(container))
        }
    }

    @Test func invalidPurgedIdentityBlocksAnOlderValidPurgeTicket() throws {
        let (container, _, task) = try fixture()
        let original = CalendarMirrorState.Identity(task)
        try CalendarMirrorState.stagePurge([task], in: container.mainContext)
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)

        task.uid = String(repeating: "u", count: 3_000)
        container.mainContext.delete(task)
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)

        #expect(throws: CalendarMirrorState.Held.self) {
            try CalendarMirrorState.purge(for: original, in: ModelContext(container))
        }
    }

    @Test func coordinatorDrainsTicketsAcrossAFullPage() async throws {
        let (container, _, _) = try fixture()
        for index in 0..<101 {
            container.mainContext.insert(TaskItem(title: "Ticket \(index)"))
        }
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        #expect(try CalendarMirrorState.pending(in: ModelContext(container)).count == 101)

        await coordinator(MirrorLifecycleTransport(), container: container).reconcileNow()

        let remainingTickets = try CalendarMirrorState.pending(in: ModelContext(container))
        #expect(remainingTickets.isEmpty, "Remaining ticket IDs: \(remainingTickets.map(\.id))")
    }

}

private enum WatchTransactionSaveFailure: Error { case failed }
