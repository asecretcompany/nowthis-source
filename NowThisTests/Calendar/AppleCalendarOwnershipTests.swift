import Foundation
import SwiftData
import Security
import EventKit
import Testing
@testable import NowThis

@Suite("Apple Calendar ownership")
@MainActor
struct AppleCalendarOwnershipTests {
    private func fixture() throws -> (ModelContainer, FakeAppleCalendarStore, TaskItem) {
        let container = try ModelContainer(for: Schema(SchemaV2.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        let task = TaskItem(title: "Owned task")
        task.dueDate = Date()
        container.mainContext.insert(task)
        try container.mainContext.save()
        return (container, FakeAppleCalendarStore(), task)
    }

    private func manager(_ store: FakeAppleCalendarStore,
                         token: Data? = Data(repeating: 7, count: 32),
                         linkLimit: Int = AppleCalendarOwnership.maximumLinks,
                         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) -> AppleCalendarSyncManager {
        AppleCalendarSyncManager(store: store, makeJournal: {
            AppleCalendarOwnershipJournal(container: $0, anchor: AppleCalendarAnchor { _, _ in token },
                selector: "ownership-test", linkLimit: linkLimit, save: save)
        })
    }

    @Test("An unrelated calendar named NowThis is never adopted or swept")
    func unrelatedTitleMatch() async throws {
        let (container, store, _) = try fixture()
        let calendar = try store.createCalendar()
        let manual = try store.save(store.newEvent(calendar.binding, title: "Unrelated"))
        _ = await manager(store).syncAll(modelContext: container.mainContext)
        #expect(store.savedCalendars.count == 2)
        #expect(store.event(id: manual.id) == manual)
    }

    @Test("Deleted tasks remove only their owned event, retaining manual events in the managed calendar")
    func onlyOwnedDeleted() async throws {
        let (container, store, task) = try fixture()
        let manager = manager(store)
        _ = await manager.syncAll(modelContext: container.mainContext)
        let owned = try #require(store.savedEvents.values.first)
        let manual = try store.save(store.newEvent(owned.calendar, title: "Manual"))
        container.mainContext.delete(task)
        try container.mainContext.save()
        _ = await manager.syncAll(modelContext: container.mainContext)
        #expect(store.event(id: owned.id) == nil)
        #expect(store.event(id: manual.id) == manual)
    }

    @Test("Explicit exports retain their legacy link and content through mirror creation and due clearing")
    func manualExportIsSeparate() throws {
        let (container, store, task) = try fixture()
        let calendar = try store.createCalendar()
        let manual = try store.save(store.newEvent(calendar.binding, title: "Edited export"))
        task.calendarEventID = manual.id
        try container.mainContext.save()
        let manager = manager(store)
        try manager.syncSingleTask(task)
        #expect(store.event(id: manual.id) == manual)
        #expect(task.calendarEventID == manual.id)
        task.dueDate = nil
        try container.mainContext.save()
        try manager.syncSingleTask(task)
        #expect(store.event(id: manual.id) == manual)
        #expect(task.calendarEventID == manual.id)
    }

    @Test("Managed updates preserve a user's event URL")
    func userURLPreserved() throws {
        let (container, store, task) = try fixture()
        task.url = "https://example.invalid/task"
        try container.mainContext.save()
        let manager = manager(store)
        try manager.syncSingleTask(task)
        var event = try #require(store.savedEvents.values.first)
        event.content.url = URL(string: "https://example.invalid/user")
        store.savedEvents[event.id] = event
        task.title = "Changed"
        try container.mainContext.save()
        try manager.syncSingleTask(task)
        #expect(store.event(id: event.id)?.content.title == "Changed")
        #expect(store.event(id: event.id)?.content.url?.absoluteString == "https://example.invalid/user")
    }

    @Test("Creation-eligible Detail saves retain an existing link after a real move to Vault")
    func automaticEntryHoldsMovedSourceForUpdateAndDueClear() throws {
        let (container, store, task) = try fixture()
        let manager = manager(store)
        #expect(try manager.syncSingleTask(task))
        let owned = try #require(store.savedEvents.values.first)

        let vault = ServerAccount(vaultDisplayName: "Private Vault")
        let privateList = TaskList(serverURL: "", name: "Private", colorHex: "#000000")
        privateList.account = vault
        container.mainContext.insert(vault)
        container.mainContext.insert(privateList)
        #expect(TaskMover.move(task, to: privateList, in: container.mainContext).count == 1)
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)

        try TaskDetailView.applyStatusChange(.completed, to: task, in: container.mainContext,
            requestReconcile: { _ in })
        #expect(throws: CalendarSyncError.linkUncertain.self) { try manager.syncSingleTask(task) }
        #expect(store.event(id: owned.id) == owned)

        task.dueDate = nil
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        #expect(throws: CalendarSyncError.linkUncertain.self) { try manager.syncSingleTask(task) }
        #expect(store.event(id: owned.id) == owned)
    }
    @Test("Renaming a managed calendar preserves its binding")
    func renamedCalendar() async throws {
        let (container, store, task) = try fixture()
        let manager = manager(store)
        _ = await manager.syncAll(modelContext: container.mainContext)
        let owned = try #require(store.savedEvents.values.first)
        store.savedCalendars[0].title = "Personal renamed mirror"
        task.title = "Updated after rename"
        try container.mainContext.save()
        #expect(try manager.syncSingleTask(task))
        #expect(store.savedCalendars.count == 1)
        #expect(store.event(id: owned.id)?.content.title == "Updated after rename")
    }

    @Test("Unresolved identities and revoked access never mutate events or replace the calendar",
          arguments: ["calendarID", "sourceID", "storeID", "eventID", "moved", "recurring", "access"])
    func unresolvedIdentity(reason: String) async throws {
        let (container, store, task) = try fixture()
        let manager = manager(store)
        _ = await manager.syncAll(modelContext: container.mainContext)
        let owned = try #require(store.savedEvents.values.first)
        switch reason {
        case "calendarID": store.savedCalendars[0].binding.id = "invalidated"
        case "sourceID": store.savedCalendars[0].binding.sourceID = "changed-source"
        case "storeID": store.storeIdentifier = "replaced-store"
        case "eventID": store.savedEvents[owned.id]?.itemID = "invalidated-item"
        case "moved": store.savedEvents[owned.id]?.calendar.id = "other-calendar"
        case "recurring": store.savedEvents[owned.id]?.recurring = true
        default: store.hasAccess = false
        }
        let before = store.savedEvents
        container.mainContext.delete(task)
        try container.mainContext.save()
        #expect(await manager.syncAll(modelContext: container.mainContext) == false)
        #expect(manager.lastError != nil)
        #expect(store.savedEvents == before)
        #expect(store.savedCalendars.count == 1)
    }

    @Test("A foreign local anchor cannot adopt another device's events")
    func foreignAnchor() async throws {
        let (container, store, task) = try fixture()
        _ = await manager(store).syncAll(modelContext: container.mainContext)
        let owned = try #require(store.savedEvents.values.first)
        task.title = "Other device"
        try container.mainContext.save()
        #expect(try manager(store, token: Data(repeating: 8, count: 32)).syncSingleTask(task))
        #expect(store.event(id: owned.id) == owned)
        #expect(store.savedCalendars.count == 2)
        #expect(store.savedEvents.count == 2)
    }

    @Test("Missing or malformed local anchor holds all existing ownership", arguments: [false, true])
    func lostAnchor(corrupt: Bool) async throws {
        let (container, store, task) = try fixture()
        _ = await manager(store).syncAll(modelContext: container.mainContext)
        let before = store.savedEvents
        task.title = "Do not write"
        try container.mainContext.save()
        #expect(throws: (any Error).self) {
            try manager(store, token: corrupt ? Data([0]) : nil).syncSingleTask(task)
        }
        #expect(store.savedEvents == before)
        #expect(store.savedCalendars.count == 1)
    }

    @Test("Malformed and unsupported persisted ownership is retained without any EventKit effect",
          arguments: ["not JSON", "{\"version\":99}"])
    func corruptRecord(json: String) async throws {
        let (container, store, _) = try fixture()
        let journal = AppleCalendarOwnershipJournal(container: container,
            anchor: AppleCalendarAnchor { _, _ in Data(repeating: 7, count: 32) }, selector: "ownership-test")
        let row = SyncMetadata(id: AppleCalendarOwnership.prefix + (try journal.scope()) + ":destination", collectionPath: "")
        row.syncToken = json
        container.mainContext.insert(row)
        try container.mainContext.save()
        #expect(await manager(store).syncAll(modelContext: container.mainContext) == false)
        #expect(store.savedCalendars.isEmpty)
        #expect(store.savedEvents.isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>()).first?.syncToken == json)
    }

    @Test("Failed intent persistence and acknowledgement never cause an untracked or duplicate creation",
          arguments: 1...6)
    func interruptedCreation(failingSave: Int) async throws {
        let (container, store, _) = try fixture()
        var saves = 0
        let interrupted = manager(store, save: { context in
            saves += 1
            if saves == failingSave { throw ProbeFailure.interrupted }
            try context.save()
        })
        #expect(await interrupted.syncAll(modelContext: container.mainContext) == false)
        let calendars = store.savedCalendars.count
        let events = store.savedEvents.count
        if failingSave <= 2 { #expect(calendars == 0) }
        if failingSave <= 5 { #expect(events == 0) }
        let retry = manager(store)
        _ = await retry.syncAll(modelContext: container.mainContext)
        if failingSave == 1 {
            #expect(store.savedCalendars.count == 1)
            #expect(store.savedEvents.count == 1)
        } else if failingSave == 3 || failingSave == 4 {
            // A committed calendar resolves; a failed event intent made no external write.
            #expect(store.savedCalendars.count == 1)
            #expect(store.savedEvents.count == 1)
        } else {
            #expect(store.savedCalendars.count == calendars)
            #expect(store.savedEvents.count == events)
        }
    }

    @Test("Deletion acknowledgement failure retains its obligation without touching a manual event")
    func interruptedRemoval() async throws {
        let (container, store, task) = try fixture()
        _ = await manager(store).syncAll(modelContext: container.mainContext)
        let owned = try #require(store.savedEvents.values.first)
        let manual = try store.save(store.newEvent(owned.calendar, title: "Manual"))
        container.mainContext.delete(task)
        try container.mainContext.save()
        var saves = 0
        _ = await manager(store, save: { context in
            saves += 1
            if saves == 2 { throw ProbeFailure.interrupted }
            try context.save()
        }).syncAll(modelContext: container.mainContext)
        #expect(store.event(id: owned.id) == nil)
        #expect(store.event(id: manual.id) == manual)
        let retry = manager(store)
        #expect(await retry.syncAll(modelContext: container.mainContext) == false)
        #expect(retry.lastError != nil)
        #expect(store.event(id: manual.id) == manual)
        let state = try AppleCalendarOwnershipJournal(container: container,
            anchor: AppleCalendarAnchor { _, _ in Data(repeating: 7, count: 32) }, selector: "ownership-test").load()
        #expect(state.links[task.id]?.pending?.action == .remove)
    }

    @Test("Unsaved drafts never reach EventKit or become saved by mirroring")
    func dirtyContext() async throws {
        let (container, store, task) = try fixture()
        task.title = "Draft"
        #expect(try manager(store).syncSingleTask(task) == false)
        #expect(await manager(store).syncAll(modelContext: container.mainContext) == false)
        #expect(store.savedCalendars.isEmpty)
        #expect(container.mainContext.hasChanges)
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(saved.title == "Owned task")
    }

    @Test("Incomplete native EventKit objects yield no ownership snapshot")
    func incompleteNativeObject() {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        #expect(EventKitCalendarStore.value(event) == nil)
        let calendar = EKCalendar(for: .event, eventStore: store)
        #expect(EventKitCalendarStore.value(calendar) == nil)
    }

    enum ProbeFailure: Error { case interrupted }

    @Test("An unresolved active or orphan link does not strand an independently owned orphan", arguments: [false, true])
    func heldOrphanDoesNotBlockOthers(active: Bool) async throws {
        let (container, store, first) = try fixture()
        first.id = "a-held"
        let second = TaskItem(id: "z-removable", title: "Second owned")
        second.dueDate = Date()
        container.mainContext.insert(second)
        try container.mainContext.save()
        _ = await manager(store).syncAll(modelContext: container.mainContext)
        let firstEvent = try #require(store.savedEvents.values.first { $0.content.title == first.title })
        let secondEvent = try #require(store.savedEvents.values.first { $0.content.title == second.title })
        // Models an externally completed removal whose acknowledgement was lost.
        store.savedEvents[firstEvent.id] = nil
        if !active { container.mainContext.delete(first) }
        container.mainContext.delete(second)
        try container.mainContext.save()
        let sync = manager(store)
        #expect(await sync.syncAll(modelContext: container.mainContext))
        #expect(sync.lastError != nil)
        #expect(store.event(id: secondEvent.id) == nil)
    }

    @Test("A missing link with residual ownership never creates a replacement through single-task sync",
          arguments: ["rowOnly", "residualClaim", "countOnly", "cachedMissingRows"])
    func missingLinkCannotCreateDuplicate(evidence: String) throws {
        let (container, store, task) = try fixture()
        #expect(try manager(store).syncSingleTask(task))
        let journal = AppleCalendarOwnershipJournal(container: container,
            anchor: AppleCalendarAnchor { _, _ in Data(repeating: 7, count: 32) }, selector: "ownership-test")
        if evidence == "cachedMissingRows" { _ = try journal.taskIDs() }
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>())
        context.delete(try #require(rows.first { $0.id.contains(":link:") }))
        if evidence == "countOnly" || evidence == "cachedMissingRows" {
            context.delete(try #require(rows.first { $0.id.contains(":item:") }))
        }
        if evidence == "residualClaim" {
            let row = try #require(rows.first { $0.id.hasSuffix(":destination") })
            var destination = try JSONDecoder().decode(AppleCalendarOwnership.Destination.self,
                from: Data(try #require(row.syncToken).utf8))
            destination.linkCount = 0
            row.syncToken = String(decoding: try JSONEncoder().encode(destination), as: UTF8.self)
        }
        try context.save()
        let beforeEvents = store.savedEvents
        let beforeRows = try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>())
            .map { ($0.id, $0.syncToken) }
        let sync = AppleCalendarSyncManager(store: store, makeJournal: { _ in journal })
        #expect(throws: (any Error).self) { try sync.syncSingleTask(task) }
        #expect(store.savedEvents == beforeEvents)
        #expect(store.savedCalendars.count == 1)
        let after = try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>())
        #expect(after.count == beforeRows.count)
        for row in after { #expect(beforeRows.contains { $0.0 == row.id && $0.1 == row.syncToken }) }
    }

    @Test("At capacity, an unlinked task does not block proven orphan removal")
    func capacityDoesNotBlockRemoval() async throws {
        let (container, store, retained) = try fixture()
        let orphan = TaskItem(title: "Owned orphan")
        orphan.dueDate = Date()
        container.mainContext.insert(orphan)
        try container.mainContext.save()
        let sync = manager(store, linkLimit: 2)
        #expect(await sync.syncAll(modelContext: container.mainContext))
        #expect(store.savedEvents.count == 2)
        let orphanEvent = try #require(store.savedEvents.values.first { $0.content.title == orphan.title })
        container.mainContext.delete(orphan)
        let newTask = TaskItem(title: "New dated task")
        newTask.dueDate = Date()
        container.mainContext.insert(newTask)
        try container.mainContext.save()
        #expect(await sync.syncAll(modelContext: container.mainContext))
        #expect(store.event(id: orphanEvent.id) == nil)
        #expect(store.savedEvents.values.contains { $0.content.title == retained.title })
        #expect(store.savedEvents.count <= 2)
        _ = await sync.syncAll(modelContext: container.mainContext)
        #expect(store.savedEvents.values.contains { $0.content.title == newTask.title })
        #expect(store.savedEvents.count == 2)
    }

    @Test("Malformed foreign ownership payload cannot block the valid local anchor")
    func foreignCorruptionIsIgnored() async throws {
        let (container, store, task) = try fixture()
        _ = await manager(store).syncAll(modelContext: container.mainContext)
        let event = try #require(store.savedEvents.values.first)
        let foreign = SyncMetadata(id: AppleCalendarOwnership.prefix + String(repeating: "f", count: 64), collectionPath: "")
        foreign.syncToken = "malformed foreign payload"
        container.mainContext.insert(foreign)
        container.mainContext.delete(task)
        try container.mainContext.save()
        #expect(await manager(store).syncAll(modelContext: container.mainContext))
        #expect(store.event(id: event.id) == nil)
        let id = foreign.id
        let retained = try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == id }))
        #expect(retained.first?.syncToken == "malformed foreign payload")
    }

    @Test("Ownership records remain small when task notes grow and only one task changes")
    func recordsContainBoundedIdentityEvidence() async throws {
        let (container, store, first) = try fixture()
        first.descriptionText = String(repeating: "long task notes ", count: 8_000)
        let second = TaskItem(title: "Second")
        second.dueDate = Date()
        container.mainContext.insert(second)
        try container.mainContext.save()
        var largestPayload = 0
        var rewrittenIDs: [String] = []
        let sync = manager(store, save: { context in
            let rows = (context.insertedModelsArray + context.changedModelsArray).compactMap { $0 as? SyncMetadata }
            largestPayload = max(largestPayload, rows.map { $0.syncToken?.utf8.count ?? 0 }.max() ?? 0)
            rewrittenIDs += rows.map(\.id)
            try context.save()
        })
        #expect(await sync.syncAll(modelContext: container.mainContext))
        #expect(largestPayload < 8_192)
        let rowsBefore = try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>())
        let before = Dictionary(uniqueKeysWithValues: rowsBefore.map { ($0.id, $0.syncToken) })
        rewrittenIDs = []
        first.title = "Updated one task"
        try container.mainContext.save()
        #expect(try sync.syncSingleTask(first))
        let rowsAfter = try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>())
        #expect(rowsAfter.count == 5)
        #expect(rewrittenIDs.count == 2) // Intent and receipt, regardless of task note size or peer links.
        #expect(Set(rewrittenIDs).count == 1)
        #expect(rowsAfter.filter { before[$0.id] != $0.syncToken }.count == 1)
    }

    @Test("Syntactically valid inconsistent ownership is rejected during load",
          arguments: ["overflow", "unacknowledged", "missingUpdateContent", "unknownVersion", "oversized", "linkOverflow"])
    func decodableCorruptionIsHeld(kind: String) async throws {
        let (container, store, _) = try fixture()
        _ = await manager(store).syncAll(modelContext: container.mainContext)
        let journal = AppleCalendarOwnershipJournal(container: container,
            anchor: AppleCalendarAnchor { _, _ in Data(repeating: 7, count: 32) }, selector: "ownership-test")
        let state = try journal.load()
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>())
        let row: SyncMetadata
        switch kind {
        case "overflow", "unacknowledged", "unknownVersion", "oversized":
            row = try #require(rows.first { $0.id.hasSuffix(":destination") })
            var destination = try #require(state.destination)
            if kind == "overflow" { destination.revision = Int.max }
            else if kind == "unacknowledged" { destination.acknowledged = false }
            else if kind == "unknownVersion" { destination.version = 99 }
            row.syncToken = String(decoding: try JSONEncoder().encode(destination), as: UTF8.self)
            if kind == "oversized" { row.syncToken! += String(repeating: " ", count: 8_193) }
        default:
            row = try #require(rows.first { $0.id.contains(":link:") })
            var link = try #require(state.links.values.first)
            if kind == "linkOverflow" { link.revision = Int.max }
            else { link.pending = .init(action: .update) }
            row.syncToken = String(decoding: try JSONEncoder().encode(link), as: UTF8.self)
        }
        try context.save()
        #expect(throws: (any Error).self) { try journal.load() }
    }

    @Test("A pending update is retained when identity resolves but requested fields did not commit")
    func pendingUpdateNeedsContentProof() async throws {
        let (container, store, task) = try fixture()
        _ = await manager(store).syncAll(modelContext: container.mainContext)
        let journal = AppleCalendarOwnershipJournal(container: container,
            anchor: AppleCalendarAnchor { _, _ in Data(repeating: 7, count: 32) }, selector: "ownership-test")
        var link = try #require(try journal.loadLink(taskID: task.id))
        var requested = try #require(store.savedEvents.values.first?.content)
        requested.title = "Requested update"
        link.pending = .init(action: .update, fingerprint: try requested.ownershipFingerprint())
        try journal.persistLink(&link)
        task.title = requested.title
        try container.mainContext.save()
        var saves = 0
        let interrupted = manager(store, save: { context in
            saves += 1
            if saves == 2 { throw ProbeFailure.interrupted }
            try context.save()
        })
        #expect(throws: (any Error).self) { try interrupted.syncSingleTask(task) }
        #expect(try journal.load().links[task.id]?.pending != nil)
    }

    @Test("A pending create with contradictory EventKit fields is not promoted or overwritten")
    func pendingCreateRequiresFrozenContentProof() throws {
        let (container, store, task) = try fixture()
        var saves = 0
        let interrupted = manager(store, save: { context in
            saves += 1
            if saves == 6 { throw ProbeFailure.interrupted }
            try context.save()
        })
        #expect(throws: ProbeFailure.interrupted.self) { try interrupted.syncSingleTask(task) }
        let journal = AppleCalendarOwnershipJournal(container: container,
            anchor: AppleCalendarAnchor { _, _ in Data(repeating: 7, count: 32) }, selector: "ownership-test")
        let pending = try #require(try journal.loadLink(taskID: task.id))
        #expect(pending.pending?.action == .create)
        let pendingEventID = try #require(pending.event)
        let original = try #require(store.event(pendingEventID))
        var contradictory = original
        contradictory.content.title = "Unproven EventKit content"
        store.savedEvents[contradictory.id] = contradictory
        let commitCount = store.eventCommits

        #expect(throws: CalendarSyncError.linkUncertain.self) {
            try manager(store).reconcileManaged(container: container, taskIDs: [task.id], isEnabled: { true })
        }
        #expect(store.event(id: original.id) == contradictory)
        #expect(store.eventCommits == commitCount)
        #expect(try journal.loadLink(taskID: task.id)?.pending?.action == .create)
    }

    @Test("Due clear retains a pending update when EventKit no longer matches its frozen fields")
    func dueClearCannotReplaceUnprovenPendingUpdate() throws {
        let (container, store, task) = try fixture()
        #expect(try manager(store).syncSingleTask(task))
        task.title = "Frozen update intent"
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
        var saves = 0
        let interrupted = manager(store, save: { context in
            saves += 1
            if saves == 2 { throw ProbeFailure.interrupted }
            try context.save()
        })
        #expect(throws: ProbeFailure.interrupted.self) { try interrupted.syncSingleTask(task) }
        let journal = AppleCalendarOwnershipJournal(container: container,
            anchor: AppleCalendarAnchor { _, _ in Data(repeating: 7, count: 32) }, selector: "ownership-test")
        let pending = try #require(try journal.loadLink(taskID: task.id))
        #expect(pending.pending?.action == .update)
        let pendingEventID = try #require(pending.event)
        let original = try #require(store.event(pendingEventID))
        var contradictory = original
        contradictory.content.title = "Foreign replacement fields"
        store.savedEvents[contradictory.id] = contradictory
        task.dueDate = nil
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)

        #expect(throws: CalendarSyncError.linkUncertain.self) {
            try manager(store).reconcileManaged(container: container, taskIDs: [task.id], isEnabled: { true })
        }
        #expect(store.event(id: original.id) == contradictory)
        #expect(try journal.loadLink(taskID: task.id)?.pending?.action == .update)
    }

    @Test("A conflicting purge holds its Apple link while a verified peer still clears")
    func preexistingConflictingPurgeDoesNotStarveApplePeer() throws {
        let (container, store, deleted) = try fixture()
        let peer = TaskItem(title: "Verified Apple peer")
        peer.taskList = deleted.taskList
        peer.dueDate = deleted.dueDate
        container.mainContext.insert(peer)
        try container.mainContext.save()
        let sync = manager(store)
        #expect(try sync.syncSingleTask(deleted))
        #expect(try sync.syncSingleTask(peer))
        let deletedLink = try #require(try AppleCalendarOwnershipJournal(container: container,
            anchor: AppleCalendarAnchor { _, _ in Data(repeating: 7, count: 32) }, selector: "ownership-test")
            .loadLink(taskID: deleted.id))
        let deletedEvent = try #require(deletedLink.event)

        try SyncPushAcknowledgement.finalizeDeletion(deleted, in: container.mainContext)
        peer.dueDate = nil
        try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)

        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(CalendarMirrorState.Identity(deleted))) as? [String: Any])
        encoded["uid"] = "conflicting-apple-purge-source"
        let conflictIdentity = try JSONDecoder().decode(CalendarMirrorState.Identity.self,
            from: JSONSerialization.data(withJSONObject: encoded))
        let ticket = CalendarMirrorState.Ticket(version: 2,
            id: CalendarMirrorState.attributedTicketID(identity: conflictIdentity, purged: true),
            identity: conflictIdentity, purged: true)
        let row = SyncMetadata(id: ticket.id, collectionPath: "")
        row.lastCTag = deleted.id
        row.syncToken = String(decoding: try JSONEncoder().encode(ticket), as: UTF8.self)
        container.mainContext.insert(row)
        try container.mainContext.save()

        #expect(throws: CalendarSyncError.linkUncertain.self) {
            try sync.reconcileManaged(container: container, taskIDs: [deleted.id, peer.id], isEnabled: { true })
        }
        #expect(store.savedEvents.count == 1)
        #expect(store.event(deletedEvent) != nil)
        #expect(try CalendarMirrorState.purgeEvidence(for: deleted.id, in: ModelContext(container)).count == 2)
    }

    @Test("Explicit retry completes an owned update whose EventKit commit previously failed")
    func explicitRetryCompletesFailedEventKitUpdate() throws {
        let (container, store, task) = try fixture()
        let sync = manager(store)
        #expect(try sync.syncSingleTask(task))
        let original = try #require(store.savedEvents.values.first)
        task.title = "Retry after EventKit failure"
        try container.mainContext.save()
        let journal = AppleCalendarOwnershipJournal(container: container,
            anchor: AppleCalendarAnchor { _, _ in Data(repeating: 7, count: 32) }, selector: "ownership-test")
        store.failNextEventCommit = true

        #expect(throws: CalendarSyncError.linkUncertain.self) {
            try sync.syncSingleTask(task)
        }
        let pending = try #require(try journal.loadLink(taskID: task.id)?.pending)
        #expect(pending.action == .update)
        #expect(pending.retryFingerprint == nil)
        #expect(store.event(id: original.id) == original)

        var operationObservedAtCommit: UUID?
        var itemObservedAtCommit: AppleEventIdentity?
        store.afterEventCommit = {
            operationObservedAtCommit = try? journal.loadLink(taskID: task.id)?.pending?.id
            itemObservedAtCommit = try? journal.loadLink(taskID: task.id)?.event
        }
        #expect(try sync.syncSingleTask(task))
        #expect(operationObservedAtCommit == pending.id)
        #expect(itemObservedAtCommit == original.identity)
        #expect(store.savedEvents.count == 1)
        #expect(store.event(id: original.id)?.content.title == task.title)
        #expect(try journal.loadLink(taskID: task.id)?.pending == nil)
    }

    @Test("Update intent and acknowledgement interruptions recover without duplicate writes", arguments: [1, 2])
    func interruptedUpdate(failingSave: Int) async throws {
        let (container, store, task) = try fixture()
        _ = await manager(store).syncAll(modelContext: container.mainContext)
        task.title = "Requested committed update"
        try container.mainContext.save()
        let commits = store.eventCommits
        var saves = 0
        let interrupted = manager(store, save: { context in
            saves += 1
            if saves == failingSave { throw ProbeFailure.interrupted }
            try context.save()
        })
        #expect(throws: (any Error).self) { try interrupted.syncSingleTask(task) }
        #expect(store.eventCommits == commits + (failingSave == 2 ? 1 : 0))
        #expect(try manager(store).syncSingleTask(task))
        #expect(store.eventCommits == commits + 1)
        #expect(store.savedEvents.count == 1)
        #expect(store.savedEvents.values.first?.content.title == task.title)
    }

    @Test("Changed identity returned from update staging is never committed", arguments: ["item", "calendar", "recurrence"])
    func stagedUpdateDriftIsHeld(drift: String) async throws {
        let (container, store, task) = try fixture()
        _ = await manager(store).syncAll(modelContext: container.mainContext)
        let before = store.savedEvents
        store.updateDrift = drift
        task.title = "Updated"
        try container.mainContext.save()
        #expect(throws: (any Error).self) { try manager(store).syncSingleTask(task) }
        #expect(store.savedEvents == before)
    }

    @Test("Anchor creation races read the device-only winner without replacing it")
    func anchorCreationRace() throws {
        let winner = Data(repeating: 19, count: 32)
        var reads = 0
        var additions = 0
        let adapter = AppleCalendarAnchor.keychain(operations: .init(read: { query in
            let values = query as NSDictionary
            #expect(values[kSecAttrSynchronizable] as? Bool == false)
            #expect(values[kSecAttrAccount] as? String == "local-store")
            reads += 1
            return reads == 1 ? (errSecItemNotFound, nil) : (errSecSuccess, winner as NSData)
        }, add: { query in
            let values = query as NSDictionary
            #expect(values[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            #expect(values[kSecAttrSynchronizable] as? Bool == false)
            additions += 1
            return errSecDuplicateItem
        }))
        #expect(try adapter.read("local-store", true) == winner)
        #expect(additions == 1)
        #expect(reads == 2)
    }

    @Test("Inaccessible, corrupt and missing-held anchors never get replaced", arguments: ["inaccessible", "corrupt", "missing"])
    func anchorUncertainty(reason: String) throws {
        var additions = 0
        let adapter = AppleCalendarAnchor.keychain(operations: .init(read: { _ in
            switch reason {
            case "inaccessible": return (errSecInteractionNotAllowed, nil)
            case "corrupt": return (errSecSuccess, Data([1]) as NSData)
            default: return (errSecItemNotFound, nil)
            }
        }, add: { _ in additions += 1; return errSecSuccess }))
        if reason == "missing" { #expect(try adapter.read("local-store", false) == nil) }
        else { #expect(throws: (any Error).self) { try adapter.read("local-store", true) } }
        #expect(additions == 0)
    }

    @Test("A stale acknowledgement cannot overwrite newer pending work")
    func staleReceipt() async throws {
        let (container, store, _) = try fixture()
        _ = await manager(store).syncAll(modelContext: container.mainContext)
        let journal = AppleCalendarOwnershipJournal(container: container,
            anchor: AppleCalendarAnchor { _, _ in Data(repeating: 7, count: 32) }, selector: "ownership-test")
        var first = try #require(try journal.load().links.values.first)
        var newer = first
        newer.pending = .init(action: .remove)
        try journal.persistLink(&newer)
        first.pending = nil
        #expect(throws: (any Error).self) { try journal.persistLink(&first) }
        #expect(try journal.loadLink(taskID: first.taskID)?.pending?.action == .remove)
    }

    @Test("Duplicate event claims in corrupt ownership are held without touching either task or event")
    func duplicateClaims() async throws {
        let (container, store, _) = try fixture()
        _ = await manager(store).syncAll(modelContext: container.mainContext)
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>())
        let row = try #require(rows.first { $0.id.contains(":link:") })
        var duplicate = try JSONDecoder().decode(AppleCalendarOwnership.Link.self, from: Data(try #require(row.syncToken).utf8))
        duplicate.taskID = "another-task"
        duplicate.identity = UUID()
        let duplicateRow = SyncMetadata(id: AppleCalendarOwnership.prefix + duplicate.scope + ":link:" + Data(duplicate.taskID.utf8).base64EncodedString(), collectionPath: "")
        duplicateRow.syncToken = String(decoding: try JSONEncoder().encode(duplicate), as: UTF8.self)
        context.insert(duplicateRow)
        try context.save()
        let before = store.savedEvents
        #expect(await manager(store).syncAll(modelContext: container.mainContext) == false)
        #expect(store.savedEvents == before)
    }

}

@MainActor
final class FakeAppleCalendarStore: AppleCalendarStore {
    var hasAccess = true
    var eventCommits = 0
    var storeIdentifier = "fake-local-store"
    private var stagedCalendar: AppleCalendarValue?
    private var stagedEvent: AppleEventValue?
    private var stagedRemoval: AppleEventValue?
    var savedCalendars: [AppleCalendarValue] = []
    var savedEvents: [String: AppleEventValue] = [:]
    var updateDrift: String?
    var failNextEventCommit = false
    var afterEventCommit: (() -> Void)?

    func calendars() -> [AppleCalendarValue] { savedCalendars }
    func createCalendar() throws -> AppleCalendarValue {
        let value = AppleCalendarValue(binding: AppleCalendarBinding(id: UUID().uuidString,
            sourceID: "local-source", sourceType: 0), title: "NowThis")
        savedCalendars.append(value)
        return value
    }
    func newEvent(_ calendar: AppleCalendarBinding, title: String) -> AppleEventValue {
        AppleEventValue(id: "", itemID: "", calendar: calendar, recurring: false,
            content: AppleEventContent(title: title, start: Date(), end: Date().addingTimeInterval(1800)))
    }
    func event(id: String) -> AppleEventValue? { savedEvents[id] }
    func events(calendar: AppleCalendarBinding, start: Date, end: Date) -> [AppleEventValue] {
        savedEvents.values.filter { $0.calendar == calendar && $0.content.start >= start && $0.content.start <= end }
    }
    func save(_ event: AppleEventValue) throws -> AppleEventValue {
        var event = event
        if event.id.isEmpty { event.id = UUID().uuidString; event.itemID = UUID().uuidString }
        savedEvents[event.id] = event
        return event
    }
    func remove(_ event: AppleEventValue) throws { savedEvents[event.id] = nil }
    func calendar(_ binding: AppleCalendarBinding) -> AppleCalendarValue? {
        guard hasAccess else { return nil }
        return savedCalendars.first { $0.binding == binding }
    }
    func event(_ identity: AppleEventIdentity) -> AppleEventValue? {
        guard hasAccess, calendar(identity.calendar) != nil,
              let value = savedEvents.values.first(where: { $0.itemID == identity.itemID }),
              value.calendar == identity.calendar, !value.recurring,
              identity.id.isEmpty || value.id == identity.id else { return nil }
        return value
    }
    func stageCalendar() throws -> AppleCalendarValue {
        let value = AppleCalendarValue(binding: AppleCalendarBinding(id: UUID().uuidString,
            sourceID: "local-source", sourceType: 0), title: "NowThis")
        stagedCalendar = value
        return value
    }
    func commitCalendar() throws -> AppleCalendarValue {
        let value = try #require(stagedCalendar)
        savedCalendars.append(value)
        stagedCalendar = nil
        return value
    }
    func stageEvent(calendar: AppleCalendarBinding, content: AppleEventContent) throws -> AppleEventValue {
        let value = AppleEventValue(id: UUID().uuidString, itemID: UUID().uuidString, calendar: calendar,
                                   recurring: false, content: content)
        stagedEvent = value
        return value
    }
    func stageUpdate(_ identity: AppleEventValue, content: AppleEventContent) throws -> AppleEventValue {
        var value = try #require(event(identity.identity))
        let url = value.content.url
        value.content = content
        value.content.url = url
        switch updateDrift {
        case "item": value.itemID = "recreated-item"
        case "calendar": value.calendar.id = "moved-calendar"
        case "recurrence": value.recurring = true
        default: break
        }
        stagedEvent = value
        return value
    }
    func commitEvent() throws -> AppleEventValue {
        eventCommits += 1
        if failNextEventCommit {
            failNextEventCommit = false
            throw AppleCalendarOwnershipTests.ProbeFailure.interrupted
        }
        let value = try #require(stagedEvent)
        savedEvents[value.id] = value
        stagedEvent = nil
        let action = afterEventCommit
        afterEventCommit = nil
        action?()
        return value
    }
    func stageRemoval(_ identity: AppleEventValue) throws { stagedRemoval = try #require(event(identity.identity)) }
    func commitRemoval() throws {
        let value = try #require(stagedRemoval)
        savedEvents[value.id] = nil
        stagedRemoval = nil
    }
    func reset() { stagedCalendar = nil; stagedEvent = nil; stagedRemoval = nil }

}
