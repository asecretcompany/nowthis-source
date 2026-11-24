import Foundation
import SwiftData
import Testing
import XCTest

@testable import NowThis

@Suite("Account removal recovery", .serialized)
@MainActor
struct AccountRemovalTests {
    private enum Failure: LocalizedError {
        case credentials
        var errorDescription: String? { "Injected credential deletion failure" }
    }

    @Test("Overlapping removals serialize their rescue and deletion steps", arguments: [false, true])
    func overlappingRemovalsSerialize(sameAccount: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let first = ServerAccount(displayName: "First", serverBaseURL: "https://example.invalid", username: "first")
        let second = ServerAccount(displayName: "Second", serverBaseURL: "https://example.invalid", username: "second")
        context.insert(first)
        context.insert(second)
        try context.save()
        let firstID = first.id
        let secondAccountID = second.id
        let secondID = sameAccount ? firstID : secondAccountID
        let entered = AsyncStream<Void>.makeStream()
        var resumeDeletion: CheckedContinuation<Void, Never>?
        var credentialDeletes: [String] = []
        let firstManager = AccountManager(modelContext: context, deleteCredentials: { id in
            credentialDeletes.append(id)
            await withCheckedContinuation {
                resumeDeletion = $0
                entered.continuation.yield()
                entered.continuation.finish()
            }
        })
        let secondManager = AccountManager(modelContext: ModelContext(container), deleteCredentials: {
            credentialDeletes.append($0)
        })

        let earlier = Task { try await firstManager.removeAccount(accountID: firstID) }
        for await _ in entered.stream { break }
        let later = await startAccountOperation { try await secondManager.removeAccount(accountID: secondID) }
        #expect(credentialDeletes == [firstID])
        resumeDeletion?.resume()
        try await earlier.value
        try await later.value

        let remaining = try ModelContext(container).fetch(FetchDescriptor<ServerAccount>()).map(\.id)
        #expect(credentialDeletes == (sameAccount ? [firstID] : [firstID, secondID]))
        #expect(remaining == (sameAccount ? [secondAccountID] : []))
    }

    @Test("Credential deletion failure keeps the account and sheet, and shows the error")
    func credentialFailureKeepsAccountAndSheet() async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let account = ServerAccount(displayName: "Leaving", serverBaseURL: "https://example.com",
                                    username: "alice", mode: .nextcloud)
        context.insert(account)
        let draft = TaskItem(title: "Saved unrelated task")
        context.insert(draft)
        try context.save()
        let accountID = account.id
        draft.notes = "An unrelated unsaved draft"
        var removedIDs: [String] = []
        let manager = AccountManager(modelContext: context, deleteCredentials: { id in
            removedIDs.append(id)
            throw Failure.credentials
        })
        var dismissed = false

        let error = await AccountEditView.performAccountRemoval(
            accountID: accountID, remove: manager.removeAccount,
            dismiss: { dismissed = true })

        #expect(error == Failure.credentials.localizedDescription)
        #expect(!dismissed, "A failed removal must keep its sheet open for recovery")
        #expect(removedIDs == [accountID])
        #expect(try ModelContext(container).fetch(FetchDescriptor<ServerAccount>()).map(\.id) == [accountID])
        #expect(draft.notes == "An unrelated unsaved draft")
        #expect(context.hasChanges)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.notes.isEmpty == true)
    }

    @Test("Failed preservation discovery aborts before any rescue, credential deletion or save",
          arguments: ["lists", "second-list-tasks", "recovery-accounts"])
    func preservationReadFailureAbortsRemoval(stage: String) async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let fixture = try makeFixture(in: context)
        fixture.unrelated.notes = "Keep this unrelated unsaved note"
        var reads = AccountManager.PreservationReads()
        var taskReads = 0
        switch stage {
        case "lists": reads.lists = { _, _ in throw Failure.credentials }
        case "second-list-tasks":
            reads.tasks = { context, descriptor in
                taskReads += 1
                if taskReads == 2 { throw Failure.credentials }
                return try context.fetch(descriptor)
            }
        default: reads.accounts = { _ in throw Failure.credentials }
        }
        var credentialDeletes = 0
        let manager = AccountManager(modelContext: context,
            deleteCredentials: { _ in credentialDeletes += 1 }, preservationReads: reads)
        var dismissed = false

        let error = await AccountEditView.performAccountRemoval(
            accountID: fixture.accountID, remove: manager.removeAccount,
            dismiss: { dismissed = true })

        #expect(error != nil)
        #expect(!dismissed)
        #expect(credentialDeletes == 0)
        if stage == "second-list-tasks" { #expect(taskReads == 2) }
        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<ServerAccount>()) == 2)
        #expect(try fresh.fetchCount(FetchDescriptor<TaskList>()) == 3)
        #expect(try Set(fresh.fetch(FetchDescriptor<TaskItem>()).map(\.id)) == fixture.allIDs)
        #expect(try ReminderSchedulingJournal.capture(in: fresh).isEmpty)
        #expect(fixture.rescuedChild.parentTask?.id == fixture.removedParentID)
        #expect(fixture.rescuedChild.taskList?.account?.id == fixture.accountID)
        #expect(fixture.unrelated.notes == "Keep this unrelated unsaved note")
        #expect(context.hasChanges)
        #expect(context.insertedModelsArray.isEmpty)
        #expect(context.deletedModelsArray.isEmpty)
        #expect(context.changedModelsArray.count == 1)
        #expect(try fresh.fetch(FetchDescriptor<TaskItem>()).first { $0.id == fixture.unrelated.id }?.notes.isEmpty == true)
        for id in fixture.allIDs {
            #expect(try VTODOOpaqueState.load(taskID: id, in: fresh) != nil)
        }
    }

    @Test("Observed account removal preserves rescued children, sidecars and reminders, and purges only removed Spotlight IDs")
    func removalUsesExistingSavedProjections() async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let fixture = try makeFixture(in: context)
        let notificationStore = CoordinatorNotificationStore(pending: [
            .init(identifier: "foreign-request", fireDate: nil, badge: nil, title: nil)
        ])
        let initial = await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: context, store: notificationStore, badgesEnabled: false, policy: .background)
        #expect(initial.status == .confirmed)
        #expect(notificationStore.pending["reminder-" + fixture.removedParentID] != nil)
        #expect(notificationStore.pending["reminder-" + fixture.rescuedChild.id] != nil)

        let removal = XCTestExpectation(description: "Observed saved removal reaches Spotlight sink")
        let sink = RemovalSpotlightSink(expectedRemovals: fixture.removedIDs, removal: removal)
        let indexer = SpotlightIndexer(
            worker: SpotlightIndexWorker(sink: sink, store: SpotlightTestStore()),
            source: SpotlightSnapshotReader())
        await indexer.reindexAll(modelContext: context)
        // Soft-deleted local data was never searchable; all other fixture IDs were.
        #expect(await Set(sink.values().keys) == fixture.allIDs.subtracting([fixture.softDeletedID]))
        indexer.startObserving(modelContext: context, coalescingWindow: .zero)
        fixture.unrelated.notes = "An unrelated draft must survive the removal save"
        let manager = AccountManager(modelContext: context)
        var dismissed = false

        let error = await AccountEditView.performAccountRemoval(
            accountID: fixture.accountID, remove: manager.removeAccount,
            dismiss: { dismissed = true })

        #expect(error == nil)
        #expect(dismissed)
        let fresh = ModelContext(container)
        let remaining = try fresh.fetch(FetchDescriptor<TaskItem>())
        let remainingIDs = Set(remaining.map(\.id))
        #expect(remainingIDs == fixture.survivingIDs)
        #expect(try fresh.fetch(FetchDescriptor<ServerAccount>()).map(\.id) == [fixture.vaultID])
        #expect(fixture.rescuedChild.parentTask == nil)
        #expect(fixture.rescuedChild.taskList?.isRecoveryList == true)
        #expect(fixture.rescuedChild.taskList?.account?.id == fixture.vaultID)
        #expect(remaining.first { $0.id == fixture.unrelated.id }?.notes == "An unrelated draft must survive the removal save")
        for id in fixture.survivingIDs {
            #expect(try VTODOOpaqueState.load(taskID: id, in: fresh)?.opaqueProperties == ["CLASS:PRIVATE", "COMMENT:" + id])
        }
        for id in fixture.removedIDs.union([fixture.softDeletedID]) {
            #expect(try VTODOOpaqueState.load(taskID: id, in: fresh) == nil)
        }
        let metadataIDs = Set(try fresh.fetch(FetchDescriptor<SyncMetadata>()).map(\.id))
        #expect(!metadataIDs.contains(fixture.leavingCheckpoint))
        #expect(metadataIDs.contains(fixture.stayingCheckpoint))
        #expect(try !ReminderSchedulingJournal.capture(in: fresh).isEmpty,
                "Account cascade saves a durable recovery ticket before requesting reconciliation")
        let reconciled = await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: context, store: notificationStore, badgesEnabled: false, policy: .background)
        #expect(reconciled.status == .confirmed)
        #expect(notificationStore.pending["foreign-request"] != nil)
        #expect(!notificationStore.removedIdentifiers.contains("foreign-request"))
        #expect(notificationStore.pending["reminder-" + fixture.rescuedChild.id] != nil)
        #expect(notificationStore.pending["reminder-" + fixture.unrelated.id] != nil)
        for id in fixture.removedIDs {
            #expect(notificationStore.pending["reminder-" + id] == nil)
            #expect(notificationStore.removedIdentifiers.contains("reminder-" + id))
        }
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)

        // Wait on the sink's actual deletion event. Do not manually request a reindex:
        // NowThisApp's same main-context save observer must be sufficient.
        let wait = await XCTWaiter.fulfillment(of: [removal], timeout: 10)
        #expect(wait == .completed)
        #expect(await Set(sink.values().keys) == fixture.survivingIDs)
        #expect(await Set(sink.removedIDs) == fixture.removedIDs)
        #expect(await sink.clearCount == 0)
        withExtendedLifetime((container, indexer)) {}
    }

    private struct Fixture {
        let accountID: String
        let vaultID: String
        let removedParentID: String
        let softDeletedID: String
        let rescuedChild: TaskItem
        let unrelated: TaskItem
        let allIDs: Set<String>
        let removedIDs: Set<String>
        let survivingIDs: Set<String>
        let leavingCheckpoint: String
        let stayingCheckpoint: String
    }

    private func makeFixture(in context: ModelContext) throws -> Fixture {
        let account = ServerAccount(displayName: "Leaving cloud", serverBaseURL: "https://example.com",
                                    username: "alice", mode: .nextcloud)
        let vault = ServerAccount(vaultDisplayName: "Existing vault")
        context.insert(account)
        context.insert(vault)
        let first = TaskList(serverURL: "/first/", name: "First", colorHex: "#007AFF")
        let second = TaskList(serverURL: "/second/", name: "Second", colorHex: "#007AFF")
        let staying = TaskList(serverURL: "", name: "Staying", colorHex: "#007AFF")
        for list in [first, second, staying] { context.insert(list) }
        first.account = account
        second.account = account
        staying.account = vault
        let parent = TaskItem(id: "synced-parent", title: "Removed parent")
        let remote = TaskItem(id: "second-remote", title: "Removed from second list")
        let child = TaskItem(id: "unsynced-child", title: "Rescue child of synced parent")
        let emptyHref = TaskItem(id: "empty-href", title: "Rescue empty href")
        let deleted = TaskItem(id: "deleted-local", title: "Already deleted")
        let unrelated = TaskItem(id: "unrelated", title: "Other account")
        let tasks = [parent, remote, child, emptyHref, deleted, unrelated]
        for task in tasks {
            context.insert(task)
            task.dueDate = Date().addingTimeInterval(3_600)
            task.reminderOffset = 0
            var state = VTODOOpaqueState.empty
            state.opaqueProperties = ["CLASS:PRIVATE", "COMMENT:" + task.id]
            try state.store(taskID: task.id, in: context)
        }
        parent.taskList = first; parent.remoteHref = "/first/parent.ics"; parent.isLocalOnly = false
        remote.taskList = second; remote.remoteHref = "/second/remote.ics"; remote.isLocalOnly = false
        child.taskList = first; child.parentTask = parent
        // Never-synced is defined by remoteHref, independently of isLocalOnly/isDirty.
        child.isLocalOnly = false; child.isDirty = false
        emptyHref.taskList = second; emptyHref.remoteHref = ""; emptyHref.isDirty = false
        deleted.taskList = second; deleted.isDeletedLocally = true
        unrelated.taskList = staying
        let checkpoint = SyncImportCheckpoint.identity(accountID: account.id, listID: first.id,
            baseURL: account.serverBaseURL, username: account.username, months: 12)
        let otherCheckpoint = SyncImportCheckpoint.identity(accountID: vault.id, listID: staying.id,
            baseURL: "", username: "", months: 12)
        context.insert(SyncMetadata(id: checkpoint, collectionPath: "/first/"))
        context.insert(SyncMetadata(id: otherCheckpoint, collectionPath: ""))
        try context.save()
        return Fixture(accountID: account.id, vaultID: vault.id, removedParentID: parent.id,
            softDeletedID: deleted.id, rescuedChild: child, unrelated: unrelated,
            allIDs: Set(tasks.map(\.id)), removedIDs: [parent.id, remote.id],
            survivingIDs: [child.id, emptyHref.id, unrelated.id],
            leavingCheckpoint: checkpoint, stayingCheckpoint: otherCheckpoint)
    }

}


private actor RemovalSpotlightSink: SpotlightIndexSink {
    private var items: [String: SpotlightTaskSnapshot] = [:]
    private(set) var removedIDs: [String] = []
    private(set) var clearCount = 0
    private let expectedRemovals: Set<String>
    private let removal: XCTestExpectation
    private var signalled = false

    init(expectedRemovals: Set<String>, removal: XCTestExpectation) {
        self.expectedRemovals = expectedRemovals
        self.removal = removal
    }

    func index(_ snapshots: [SpotlightTaskSnapshot], expiresAt: Date) {
        for snapshot in snapshots { items[snapshot.id] = snapshot }
    }

    func remove(_ identifiers: [String]) {
        removedIDs += identifiers
        for id in identifiers { items.removeValue(forKey: id) }
        if !signalled, expectedRemovals.isSubset(of: Set(removedIDs)) {
            signalled = true
            removal.fulfill()
        }
    }

    func removeAll() { clearCount += 1; items.removeAll() }
    func values() -> [String: SpotlightTaskSnapshot] { items }
}
