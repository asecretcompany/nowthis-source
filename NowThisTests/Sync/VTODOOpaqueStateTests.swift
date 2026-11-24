import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite(.serialized)
@MainActor
struct VTODOOpaqueStateTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(SchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func data(_ uid: String = "opaque") throws -> ICalendarParser.VTODOData {
        try #require(try ICalendarParser.parseSingleVTODO(from: "BEGIN:VTODO\nUID:\(uid)\nSUMMARY:Imported\nCLASS:PRIVATE\nBEGIN:VALARM\nTRIGGER:-PT15M\nACTION:EMAIL\nDESCRIPTION:Custom\nEND:VALARM\nEND:VTODO"))
    }
    private func fixture(_ c: ModelContainer, remote: Bool = true) throws -> (TaskItem, TaskList) {
        let context = c.mainContext
        let account = ServerAccount(displayName: "Cloud", serverBaseURL: "https://example.com", username: "u")
        let list = TaskList(serverURL: "/one/", name: "One", colorHex: "#007AFF")
        let task = TaskItem(uid: "opaque", title: "Local")
        context.insert(account); context.insert(list); context.insert(task)
        list.account = account; task.taskList = list
        if remote {
            try SyncImportStore(context: context).applyFields(data(), to: task)
            task.remoteHref = "/one/opaque.ics"; task.etag = "baseline"
            try SyncResourceFixture.prove(task, in: context)
        }
        task.isDirty = true
        try context.save()
        return (task, list)
    }

    @Test func missingKnownEmptyCorruptAndUnsupportedVersionsAreDistinct() throws {
        let c = try container(); let context = c.mainContext
        #expect(try VTODOOpaqueState.load(taskID: "t", in: context) == nil)
        try VTODOOpaqueState.empty.store(taskID: "t", in: context)
        #expect(try VTODOOpaqueState.load(taskID: "t", in: context) == .empty)
        let row = try #require(try context.fetch(FetchDescriptor<SyncMetadata>()).first)
        row.syncToken = "broken"
        #expect(throws: VTODOOpaqueState.StateError.malformed) { try VTODOOpaqueState.load(taskID: "t", in: context) }
        row.syncToken = #"{"version":2}"#
        #expect(throws: VTODOOpaqueState.StateError.unsupportedVersion) { try VTODOOpaqueState.load(taskID: "t", in: context) }
    }

    @Test func importPersistsAcrossDiskReopenAndFreshSnapshot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let configuration = ModelConfiguration(url: url)
        var id = ""
        do {
            let c = try ModelContainer(for: Schema(SchemaV2.models), configurations: configuration)
            let (task, _) = try fixture(c); id = task.id
        }
        let reopened = try ModelContainer(for: Schema(SchemaV2.models), configurations: configuration)
        let snapshot = try #require(try SyncPushAcknowledgement.snapshot(taskID: id, calendarPath: "/one/", container: reopened))
        #expect(snapshot.payload.contains("CLASS:PRIVATE"))
        #expect(snapshot.payload.contains("ACTION:EMAIL"))
        #expect(snapshot.opaqueState == (try VTODOOpaqueState(data())))
    }

    @Test func sidecarChangeDuringPutRetainsDirtyAndAcceptedETag() throws {
        let c = try container(); let (task, _) = try fixture(c)
        let snapshot = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: "/one/", container: c))
        let other = ModelContext(c)
        var state = snapshot.opaqueState; state.opaqueProperties.append("COMMENT:new")
        try state.store(taskID: task.id, in: other); try other.save()
        try SyncPushAcknowledgement.acknowledge(snapshot, etag: "accepted", container: c)
        let fresh = ModelContext(c)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.isDirty); #expect(stored.etag == "accepted")
        #expect(try VTODOOpaqueState.load(taskID: task.id, in: fresh) == state)
    }

    @Test func remoteMissingStateBlocksAndFirstLocalPutPersistsKnownEmpty() throws {
        let c = try container(); let (task, _) = try fixture(c, remote: false)
        let snapshot = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: "/one/", container: c))
        try SyncPushAcknowledgement.acknowledge(snapshot, etag: "accepted", container: c)
        let fresh = ModelContext(c)
        #expect(try VTODOOpaqueState.load(taskID: task.id, in: fresh) == .empty)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(!stored.isDirty)
        try VTODOOpaqueState.remove(tasks: [stored], in: fresh); stored.isDirty = true; try fresh.save()
        #expect(throws: VTODOOpaqueState.StateError.missingRemoteState) {
            try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: "/one/", container: c)
        }
    }

    @Test func failedImportBatchDoesNotCommitTaskOrSidecar() throws {
        let c = try container(); let (_, list) = try fixture(c)
        var malformed = try data("bad"); malformed.opaqueProperties = ["END:VTODO"]
        let writer = SyncInboundBatchWriter(container: c, listID: list.id)
        #expect(throws: VTODOOpaqueState.StateError.self) {
            try writer.apply([ParsedRemoteTask(href: "/one/new.ics", etag: "n", todo: try data("new")),
                              ParsedRemoteTask(href: "/one/bad.ics", etag: "b", todo: malformed)])
        }
        let fresh = ModelContext(c)
        #expect(try fresh.fetch(FetchDescriptor<TaskItem>()).map(\.uid) == ["opaque"])
        let rows = try fresh.fetch(FetchDescriptor<SyncMetadata>()).filter { $0.id.hasPrefix(VTODOOpaqueState.prefix) }
        #expect(rows.count == 1)
    }

    @Test func moveRollbackSoftDeleteRestoreAndSourceAcknowledgementRetainState() throws {
        let c = try container(); let (task, source) = try fixture(c)
        let expected = try VTODOOpaqueState(data())
        let destination = TaskList(serverURL: "/two/", name: "Two", colorHex: "#007AFF")
        c.mainContext.insert(destination); destination.account = source.account
        TaskMover.move(task, to: destination, in: c.mainContext)
        #expect(try SyncPushSnapshot(task: task, calendarPath: "/two/").payload.contains("CLASS:PRIVATE"))
        #expect(TaskMover.rollBackRefusedPut(task, in: c.mainContext))
        #expect(try VTODOOpaqueState.load(taskID: task.id, in: c.mainContext) == expected)
        task.etag = "revalidated-source"
        try SyncResourceFixture.prove(task, in: c.mainContext)
        task.isDeletedLocally = true; try c.mainContext.save()
        let deletion = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: task.id, container: c))
        task.isDeletedLocally = false; try c.mainContext.save()
        _ = try SyncPushAcknowledgement.acknowledgeDeletion(deletion, container: c)
        #expect(try VTODOOpaqueState.load(taskID: task.id, in: ModelContext(c)) == expected)
        let context = ModelContext(c)
        let stored = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        stored.remoteHref = "/one/opaque.ics"; stored.etag = "revalidated-source"
        try SyncResourceFixture.prove(stored, in: context)
        TaskMover.move(stored, to: try #require(try context.fetch(FetchDescriptor<TaskList>()).first { $0.id == destination.id }), in: context)
        stored.remoteHref = "/two/opaque.ics"; stored.isDirty = false
        try context.save()
        let candidate = try #require(try SyncMoveSnapshot(task: stored))
        let sent = try #require(try SyncMoveAcknowledgement.deletionSnapshot(candidate, container: c))
        _ = try SyncMoveAcknowledgement.acknowledgeDelete(sent, container: c)
        #expect(try VTODOOpaqueState.load(taskID: task.id, in: ModelContext(c)) == expected)
        #expect(try ModelContext(c).fetch(FetchDescriptor<TaskItem>()).first?.pendingMoveFromHref == nil)
    }

    @Test func hardDeletionAndServerDeletionRemoveOnlyMatchingSidecars() async throws {
        for server in [false, true] {
            let c = try container(); let (task, list) = try fixture(c)
            let id = task.id
            try VTODOOpaqueState.empty.store(taskID: "unrelated", in: c.mainContext)
            task.isDirty = false; task.isDeletedLocally = !server; try c.mainContext.save()
            if server {
                _ = try await SyncInboundBatchWriter(container: c, listID: list.id).deleteExplicit(["/one/opaque.ics"])
            } else {
                let snapshot = try #require(try SyncPushAcknowledgement.deletionSnapshot(taskID: id, container: c))
                _ = try SyncPushAcknowledgement.acknowledgeDeletion(snapshot, container: c)
            }
            let fresh = ModelContext(c)
            #expect(try fresh.fetchCount(FetchDescriptor<TaskItem>()) == 0)
            #expect(try VTODOOpaqueState.load(taskID: id, in: fresh) == nil)
            #expect(try VTODOOpaqueState.load(taskID: "unrelated", in: fresh) == .empty)
        }
    }

    @Test func duplicateCleanupAndListCascadeRemoveDescendantState() throws {
        let c = try container(); let (task, list) = try fixture(c)
        let duplicate = TaskItem(uid: task.uid, title: "Old duplicate")
        c.mainContext.insert(duplicate); duplicate.taskList = list
        duplicate.lastModifiedDate = .distantPast; task.lastModifiedDate = Date()
        try VTODOOpaqueState.empty.store(taskID: duplicate.id, in: c.mainContext)
        let duplicateID = duplicate.id
        #expect(try TaskListHelpers.cleanupDuplicateUIDs(in: c.mainContext, listID: list.id) == 1)
        #expect(try VTODOOpaqueState.load(taskID: duplicateID, in: c.mainContext) == nil)
        let child = TaskItem(uid: "child", title: "Child"); c.mainContext.insert(child)
        child.parentTask = task; child.taskList = list
        try VTODOOpaqueState.empty.store(taskID: child.id, in: c.mainContext)
        try VTODOOpaqueState.remove(tasks: list.tasks, in: c.mainContext)
        c.mainContext.delete(list); try c.mainContext.save()
        #expect(try ModelContext(c).fetch(FetchDescriptor<SyncMetadata>()).filter { $0.id.hasPrefix(VTODOOpaqueState.prefix) }.isEmpty)
    }

    @Test func accountRemovalRetainsRescuedTaskSidecar() async throws {
        let c = try container(); let (remote, list) = try fixture(c)
        let local = TaskItem(uid: "local", title: "Unsynced"); c.mainContext.insert(local); local.taskList = list
        let remoteID = remote.id; let localID = local.id
        try VTODOOpaqueState(data("local")).store(taskID: localID, in: c.mainContext)
        let accountID = try #require(list.account?.id)
        try c.mainContext.save()
        try await AccountManager(modelContext: c.mainContext).removeAccount(accountID: accountID)
        let fresh = ModelContext(c)
        #expect(try VTODOOpaqueState.load(taskID: remoteID, in: fresh) == nil)
        #expect(try VTODOOpaqueState.load(taskID: localID, in: fresh)?.opaqueProperties == ["CLASS:PRIVATE"])
        #expect(try fresh.fetch(FetchDescriptor<TaskItem>()).first?.taskList?.account?.mode == .vault)
    }
    @Test(arguments: [60, 0, -1], [false, true])
    func acceptedReminderEditCannotResurrectOriginalAlarm(offset: Int, editDuringPut: Bool) throws {
        let c = try container(); let (task, _) = try fixture(c)
        task.reminderOffset = offset < 0 ? nil : offset
        try c.mainContext.save()
        let snapshot = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: "/one/", container: c))
        if editDuringPut { task.reminderOffset = 900; try c.mainContext.save() }
        try SyncPushAcknowledgement.acknowledge(snapshot, etag: "accepted", container: c)
        let fresh = ModelContext(c)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.isDirty == editDuringPut)
        let state = try #require(try VTODOOpaqueState.load(taskID: task.id, in: fresh))
        #expect(state.baselineReminderOffset == (offset < 0 ? nil : offset))
        #expect(!state.alarmBlocks.flatMap { $0 }.contains("ACTION:EMAIL"))
        stored.reminderOffset = 900
        #expect(try !SyncPushSnapshot.serialize(stored, stamp: Date()).contains("ACTION:EMAIL"))
    }

    @Test func unchangedCustomAlarmAndLocalFirstReminderSurviveAcknowledgement() throws {
        for remote in [false, true] {
            let c = try container(); let (task, _) = try fixture(c, remote: remote)
            task.reminderOffset = 900; try c.mainContext.save()
            let snapshot = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: "/one/", container: c))
            try SyncPushAcknowledgement.acknowledge(snapshot, etag: "accepted", container: c)
            let fresh = ModelContext(c)
            let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
            let state = try #require(try VTODOOpaqueState.load(taskID: task.id, in: fresh))
            #expect(state.baselineReminderOffset == 900)
            #expect(!state.alarmBlocks.isEmpty)
            let output = try SyncPushSnapshot.serialize(stored, stamp: snapshot.stamp)
            #expect(output == snapshot.payload)
            #expect(output.contains("ACTION:EMAIL") == remote)
        }
    }

    @Test func legacyCatchUpKeepsImportedBaselineAndDirtyFieldsBeforePut() throws {
        let c = try container(); let (task, list) = try fixture(c)
        try VTODOOpaqueState.remove(tasks: [task], in: c.mainContext)
        task.reminderOffset = 60; task.title = "Dirty title"; try c.mainContext.save()
        _ = try TaskPhotoLegacyCatchUp.apply(data(), taskID: task.id, listID: list.id,
            accountID: try #require(list.account?.id), href: "/one/opaque.ics", container: c)
        let fresh = ModelContext(c)
        #expect(try VTODOOpaqueState.load(taskID: task.id, in: fresh)?.baselineReminderOffset == 900)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "Dirty title"); #expect(stored.reminderOffset == 60)
        #expect(stored.isDirty)
    }

    @Test func tombstoneUsesFreshIdentityWithoutOpaqueState() throws {
        let c = try container(); let (task, list) = try fixture(c)
        try TaskMover.insertTombstone(for: task, href: "/old/opaque.ics", etag: nil, in: list, context: c.mainContext)
        try c.mainContext.save()
        let tombstone = try #require(try c.mainContext.fetch(FetchDescriptor<TaskItem>()).first { $0.isDeletedLocally })
        #expect(tombstone.id != task.id)
        #expect(try VTODOOpaqueState.load(taskID: tombstone.id, in: c.mainContext) == nil)
        #expect(try VTODOOpaqueState.load(taskID: task.id, in: c.mainContext) != nil)
    }

    @Test func legacyPendingMoveFetchesSourceEvenAfterOldDestinationPut() throws {
        let c = try container(); let (task, source) = try fixture(c)
        try VTODOOpaqueState.remove(tasks: [task], in: c.mainContext)
        let destination = TaskList(serverURL: "/two/", name: "Two", colorHex: "#007AFF")
        c.mainContext.insert(destination); destination.account = source.account
        TaskMover.move(task, to: destination, in: c.mainContext)
        task.remoteHref = "/two/opaque.ics"; task.isDirty = false
        try c.mainContext.save()
        let accountID = try #require(destination.account?.id)
        let request = try #require(try TaskPhotoLegacyCatchUp.requestInfo(taskID: task.id,
            listID: destination.id, accountID: accountID, container: c))
        #expect(request.href == "/one/opaque.ics")
        #expect(request.sourceListID == source.id)
    }

    @Test func serverBackedMissingHrefStillRequiresKnownOpaqueState() throws {
        let c = try container(); let (task, _) = try fixture(c, remote: false)
        task.isLocalOnly = false; task.isDirty = true
        try c.mainContext.save()
        #expect(throws: VTODOOpaqueState.StateError.missingRemoteState) {
            try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: "/one/", container: c)
        }
    }

    @Test(arguments: ["broken", #"{"version":2}"#])
    func unreadableStateDuringForbiddenPutCannotFallBackToDestructiveRollback(json: String) throws {
        let c = try container(); let (task, source) = try fixture(c)
        let destination = TaskList(serverURL: "/two/", name: "Two", colorHex: "#007AFF")
        c.mainContext.insert(destination); destination.account = source.account
        TaskMover.move(task, to: destination, in: c.mainContext); try c.mainContext.save()
        let snapshot = try #require(try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: "/two/", container: c))
        let edit = ModelContext(c)
        let key = VTODOOpaqueState.prefix + task.id
        let row = try #require(try edit.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first)
        row.syncToken = json; try edit.save()
        #expect(throws: VTODOOpaqueState.StateError.self) {
            try SyncPushAcknowledgement.rollBackRefusedMove(snapshot, container: c)
        }
        let fresh = ModelContext(c)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.taskList?.id == destination.id)
        #expect(stored.pendingMoveFromListID == source.id)
        #expect(stored.pendingMoveFromHref == "/one/opaque.ics")
        #expect(stored.isDirty); #expect(stored.remoteHref == nil)
        #expect(!fresh.hasChanges)
    }

}
