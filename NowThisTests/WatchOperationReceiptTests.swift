import Foundation
import SwiftData
import Testing
import WatchConnectivity
@testable import NowThis

@Suite("Watch atomic receipts")
@MainActor
struct WatchOperationReceiptTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(SchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func duplicateAddAndRecurringCompletionApplyExactlyOnceWhileRetained() throws {
        let container = try container()
        let context = container.mainContext
        let list = TaskList(serverURL: "", name: "Inbox", colorHex: "")
        let recurring = TaskItem(uid: "recurring", title: "Daily")
        recurring.recurrenceRule = "FREQ=DAILY"
        recurring.dueDate = now
        context.insert(list)
        context.insert(recurring)
        try context.save()
        let addID = UUID(), completeID = UUID()
        var firstTicketIDs: Set<String>?
        for _ in 0..<2 {
            #expect(WatchEditTransaction.apply(.add(rawText: "Buy milk tomorrow", listID: list.id,
                dueDate: nil, priorityRaw: nil), operationID: addID, container: container,
                isProUnlocked: true, now: now) == WatchEditReply.applied)
            #expect(WatchEditTransaction.apply(.complete(uid: "recurring"), operationID: completeID,
                container: container, isProUnlocked: true, now: now) == WatchEditReply.applied)
            let tickets = try ReminderSchedulingJournal.capture(in: ModelContext(container))
            if let firstTicketIDs { #expect(tickets == firstTicketIDs) }
            else { firstTicketIDs = tickets; #expect(!tickets.isEmpty) }
        }
        let read = ModelContext(container)
        let tasks = try read.fetch(FetchDescriptor<TaskItem>())
        let additions = tasks.filter { $0.title == "Buy milk" }
        #expect(additions.count == 1)
        let addition = try #require(additions.first)
        let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: now))
        #expect(addition.dueDate == DueDateHelper.dateOnlyValue(for: tomorrow))
        #expect(addition.isDueDateOnly)
        #expect(tasks.first { $0.uid == "recurring" }?.dueDate == now.addingTimeInterval(86_400))
        #expect(try WatchReceiptStore.recent(in: read, now: now).count == 2)
    }

    @Test(arguments: [false, true])
    func repeatedTagsUseOneSavedIdentityThroughReplay(hasExistingTag: Bool) throws {
        let container = try container()
        let context = container.mainContext
        let list = TaskList(serverURL: "", name: "Inbox", colorHex: "")
        context.insert(list)
        let existing = NowThis.Tag(id: "existing-work", name: "Work")
        if hasExistingTag { context.insert(existing) }
        try context.save()
        let edit = WatchEdit.add(rawText: "Buy milk tomorrow @work @Work @work @cafe @café @CAFÉ",
                                listID: list.id, dueDate: nil, priorityRaw: nil)
        let operationID = UUID()
        var publications = 0
        for _ in 0..<2 {
            #expect(WatchEditTransaction.apply(edit, operationID: operationID, container: container,
                isProUnlocked: true, now: now, didCommit: { publications += 1 }) == WatchEditReply.applied)
        }

        let read = ModelContext(container)
        let tasks = try read.fetch(FetchDescriptor<TaskItem>())
        let task = try #require(tasks.first)
        let tags = try read.fetch(FetchDescriptor<NowThis.Tag>())
        #expect(tasks.count == 1)
        #expect(task.title == "Buy milk")
        #expect(task.isDueDateOnly)
        #expect(tags.count == 3)
        #expect(task.tags.count == 3)
        #expect(Set(task.tags.map(\.id)) == Set(tags.map(\.id)))
        #expect(Set(tags.map(\.name)) == [hasExistingTag ? "Work" : "work", "cafe", "café"])
        if hasExistingTag {
            #expect(task.tags.contains { $0.id == existing.id && $0.name == "Work" })
        }
        #expect(publications == 1)
        #expect(try WatchReceiptStore.recent(in: read, now: now).count == 1)
    }

    @Test func unreadableTagsCommitOnlyAnInvalidReceipt() throws {
        let container = try container()
        let context = container.mainContext
        let list = TaskList(serverURL: "", name: "Inbox", colorHex: "")
        let existing = NowThis.Tag(name: "Work")
        context.insert(list)
        context.insert(existing)
        try context.save()
        let edit = WatchEdit.add(rawText: "Buy milk @work @Work", listID: list.id, dueDate: nil, priorityRaw: nil)
        let operationID = UUID()
        var lookups = 0
        var publications = 0
        struct FetchFailure: Error {}
        for _ in 0..<2 {
            #expect(WatchEditTransaction.apply(edit, operationID: operationID, container: container,
                isProUnlocked: true, now: now, fetchTags: { _ in
                    lookups += 1
                    throw FetchFailure()
                }, didCommit: { publications += 1 }) == WatchEditReply.invalid)
        }

        let read = ModelContext(container)
        #expect(lookups == 1)
        #expect(publications == 0)
        #expect(try read.fetch(FetchDescriptor<TaskItem>()).isEmpty)
        #expect(try read.fetch(FetchDescriptor<NowThis.Tag>()).map(\.id) == [existing.id])
        #expect(try ReminderSchedulingJournal.capture(in: read).isEmpty)
        #expect(try WatchReceiptStore.find(operationID, in: read, now: now)?.result == WatchEditReply.invalid)
    }

    @Test(arguments: [false, true])
    func readOnlyWatchDenialPersistsOnlyInvalidReceipt(failSave: Bool) throws {
        let container = try container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let list = TaskList(serverURL: "", name: "Shared", colorHex: "")
        list.isReadOnly = true
        let task = TaskItem(uid: "target", title: "Keep this title")
        task.taskList = list
        task.dueDate = now
        let unrelated = TaskItem(title: "Unrelated")
        context.insert(list)
        context.insert(task)
        context.insert(unrelated)
        try context.save()
        unrelated.title = "Unrelated pending"
        let taskID = task.id
        let listID = list.id
        let operations: [WatchEdit] = [
            .add(rawText: "Keep this draft @new", listID: listID, dueDate: now, priorityRaw: 1),
            .complete(uid: task.uid),
            .uncomplete(uid: task.uid)
        ]
        var saves = 0
        var publications = 0
        struct SaveFailure: Error {}
        for edit in operations {
            let id = UUID()
            let result = WatchEditTransaction.apply(edit, operationID: id, container: container,
                isProUnlocked: true, now: now, save: { writer in
                    saves += 1
                    if failSave { throw SaveFailure() }
                    try writer.save()
                }, didCommit: { publications += 1 })
            #expect(result == (failSave ? WatchEditReply.unconfirmed : WatchEditReply.invalid))
            let reader = ModelContext(container)
            let receipt = try WatchReceiptStore.find(id, in: reader, now: now)
            if failSave { #expect(receipt == nil) }
            else {
                #expect(receipt?.result == WatchEditReply.invalid)
                let encoded = try JSONEncoder().encode(try #require(receipt))
                let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
                #expect(object["refusalReason"] == "readOnlyList")
            }
            #expect(try ReminderSchedulingJournal.capture(in: reader).isEmpty)
            #expect(try reader.fetch(FetchDescriptor<NowThis.Tag>()).isEmpty)
            let tasks = try reader.fetch(FetchDescriptor<TaskItem>())
            #expect(tasks.count == 2)
            let saved = try #require(tasks.first { $0.id == taskID })
            #expect(saved.status == .needsAction && saved.title == "Keep this title" && saved.dueDate == now)
            #expect(tasks.first { $0.id != taskID }?.title == "Unrelated")
        }
        #expect(saves == operations.count && publications == 0)
        #expect(unrelated.title == "Unrelated pending" && context.hasChanges)
        withExtendedLifetime(container) {}
    }

    @Test func failedOwnedSaveCannotLeakMutationReceiptOrTicketIntoLaterMainSave() throws {
        let container = try container()
        let main = container.mainContext
        main.autosaveEnabled = false
        let target = TaskItem(uid: "target", title: "Target")
        let unrelated = TaskItem(title: "Before")
        main.insert(target); main.insert(unrelated)
        try main.save()
        unrelated.title = "Keep my pending edit"
        let id = UUID()
        struct SaveFailure: Error {}
        var publications = 0
        let result = WatchEditTransaction.apply(.complete(uid: "target"), operationID: id,
            container: container, isProUnlocked: true, now: now, save: { _ in throw SaveFailure() },
            didCommit: { publications += 1 })
        #expect(publications == 0)
        #expect(result == WatchEditReply.unconfirmed)
        #expect(unrelated.title == "Keep my pending edit")
        #expect(main.hasChanges)
        try main.save()
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<TaskItem>()).first { $0.uid == "target" }?.status == .needsAction)
        #expect(try WatchReceiptStore.find(id, in: read, now: now) == nil)
        #expect(try ReminderSchedulingJournal.capture(in: read).isEmpty)
    }

    @Test(arguments: ["FREQ=MONTHLY;BYMONTHDAY=15", "FREQ=DAILY;COUNT=3"]) func terminalRejectionsAreDurableAndDoNotTouchTasks(_ raw: String) throws {
        let container = try container()
        let main = container.mainContext
        let task = TaskItem(uid: "unsupported", title: "Repeat")
        task.recurrenceRule = raw
        task.dueDate = now
        main.insert(task)
        try main.save()
        let cases: [(WatchEdit, Bool, String)] = [
            (.complete(uid: "unsupported"), true, WatchEditReply.unsupportedRecurrence),
            (.complete(uid: "missing"), true, WatchEditReply.unknownTask),
            (.complete(uid: "unsupported"), false, WatchEditReply.locked),
            (.add(rawText: "", listID: nil, dueDate: nil, priorityRaw: nil), true, WatchEditReply.invalid),
            (.add(rawText: "a" + String(repeating: "\u{301}", count: 16_000), listID: nil,
                  dueDate: nil, priorityRaw: nil), true, WatchEditReply.invalid)
        ]
        var publications = 0
        for (edit, unlocked, expected) in cases {
            let id = UUID()
            #expect(WatchEditTransaction.apply(edit, operationID: id, container: container,
                isProUnlocked: unlocked, now: now, didCommit: { publications += 1 }) == expected)
            #expect(try WatchReceiptStore.find(id, in: ModelContext(container), now: now)?.result == expected)
        }
        #expect(publications == 0)
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<TaskItem>()).first?.dueDate == now)
        #expect(try ReminderSchedulingJournal.capture(in: read).isEmpty)
    }

    @Test func receiptRetentionIsBoundedAndLookupsReachBeyondRecentSnapshot() throws {
        let container = try container()
        let context = ModelContext(container)
        let oldest = UUID()
        let unrelated = SyncMetadata(id: "reminder-ticket-v1:test", collectionPath: "")
        context.insert(unrelated)
        for index in 0..<513 {
            try WatchReceiptStore.record(WatchOperationReceipt(id: index == 0 ? oldest : UUID(), result: "applied"),
                in: context, now: now.addingTimeInterval(Double(index)))
        }
        try context.save()
        #expect(try context.fetch(FetchDescriptor<SyncMetadata>()).count == 513)
        #expect(try WatchReceiptStore.recent(in: context, now: now.addingTimeInterval(600)).count == 64)
        #expect(try WatchReceiptStore.find(oldest, in: context, now: now.addingTimeInterval(600)) == nil)
        let retained = try #require(try context.fetch(FetchDescriptor<SyncMetadata>()).first {
            $0.lastFullSync == now.addingTimeInterval(1)
        })
        let id = try #require(UUID(uuidString: String(retained.id.dropFirst(WatchReceiptStore.prefix.count))))
        #expect(try WatchReceiptStore.lookup([id], in: context, now: now.addingTimeInterval(600)).first?.result == "applied")
        #expect(try WatchReceiptStore.lookup([id], in: context, now: now.addingTimeInterval(31 * 86400)).first?.result == "unconfirmed")
    }

    @Test func completeContextBudgetIncludesReceiptsAndLegacyFailureMetadataWithoutTruncatingText() throws {
        let huge = WatchTask(id: "huge", uid: "huge", title: String(repeating: "🦉", count: 20_000),
            dueDate: nil, isDueDateOnly: false, priorityRaw: 0, isCompleted: false, listID: "", parentUID: nil)
        let small = WatchTask(id: "small", uid: "small", title: "Preserve all of this title",
            dueDate: nil, isDueDateOnly: false, priorityRaw: 0, isCompleted: false, listID: "", parentUID: nil)
        let receipts = (0..<64).map { _ in WatchOperationReceipt(id: UUID(), result: WatchEditReply.unsupportedRecurrence) }
        let snapshot = WatchSnapshot(schemaVersion: 1, isProUnlocked: true, generatedAt: now,
            lists: [], tasks: [huge, small], truncated: false, defaultListID: nil, receipts: receipts)
        let context = try WatchSnapshotBudget.context(snapshot, completionFailureID: "failure", completionFailureUID: "task")
        let bytes = try PropertyListSerialization.data(fromPropertyList: context, format: .binary, options: 0)
        #expect(bytes.count <= 60_000)
        let decoded = try #require(WatchSnapshot(contextDictionary: context))
        #expect(decoded.truncated)
        #expect(decoded.tasks == [small])
        #expect(decoded.receipts == receipts)
        #expect(context[WatchEditReply.completionFailureIDKey] as? String == "failure")
    }
    @Test func oversizedLegacyFailureCannotStarveValidReceipts() throws {
        let receipt = WatchOperationReceipt(id: UUID(), result: WatchEditReply.locked)
        let snapshot = WatchSnapshot(schemaVersion: 1, isProUnlocked: false, generatedAt: now,
            lists: [], tasks: [], truncated: false, defaultListID: nil, receipts: [receipt])
        let context = try WatchSnapshotBudget.context(snapshot, completionFailureID: "failure",
            completionFailureUID: String(repeating: "x", count: 70_000))
        #expect(try PropertyListSerialization.data(fromPropertyList: context, format: .binary, options: 0).count <= 60_000)
        #expect(WatchSnapshot(contextDictionary: context)?.receipts == [receipt])
        #expect(context[WatchEditReply.completionFailureUIDKey] == nil)
    }

    @Test func expiredReceiptMayApplyAgainAndReplacesOneRow() throws {
        let container = try container()
        let main = container.mainContext
        let list = TaskList(serverURL: "", name: "Inbox", colorHex: "")
        main.insert(list)
        try main.save()
        let id = UUID()
        let edit = WatchEdit.add(rawText: "Milk", listID: list.id, dueDate: nil, priorityRaw: nil)
        #expect(WatchEditTransaction.apply(edit, operationID: id, container: container,
            isProUnlocked: true, now: now) == WatchEditReply.applied)
        #expect(WatchEditTransaction.apply(edit, operationID: id, container: container,
            isProUnlocked: true, now: now.addingTimeInterval(31 * 86400)) == WatchEditReply.applied)
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<TaskItem>()).count == 2)
        #expect(try WatchReceiptStore.recent(in: read, now: now.addingTimeInterval(31 * 86400)).count == 1)
    }

    @Test func committedWatchDelegateEditRefreshesPhoneQueriesAndSpotlightOnlyOnce() async throws {
        let container = try container()
        let main = container.mainContext
        main.autosaveEnabled = false
        let list = TaskList(serverURL: "", name: "Inbox", colorHex: "")
        let unrelated = TaskItem(title: "Saved unrelated")
        main.insert(list); main.insert(unrelated)
        try main.save()
        unrelated.title = "Pending unrelated"
        let sink = SuspendedSpotlightSink()
        let indexer = SpotlightIndexer(worker: SpotlightIndexWorker(sink: sink, store: SpotlightTestStore()),
            source: SpotlightSnapshotReader())
        indexer.startObserving(modelContext: main, coalescingWindow: .milliseconds(10))
        var widgetReloads = 0
        let scheduler = SyncScheduler(onWidgetReload: { widgetReloads += 1 })
        scheduler.configureSpotlight(modelContext: main, indexer: indexer)
        let entitlement = ProEntitlement(client: ProStoreTestClient(), cache: ProEntitlementCache(defaults: nil), testerBuild: { true }, forcePaywall: { false })
        entitlement.isTesterBuild = true
        let bridge = WatchBridge(session: SpySession(), entitlement: entitlement, syncScheduler: scheduler,
            modelContainer: container)
        let payload = try WatchEdit.add(rawText: "Buy milk", listID: list.id, dueDate: nil,
            priorityRaw: nil).userInfoDictionary(operationID: UUID())
        let previousToken = scheduler.dataRefreshToken
        func deliver() async -> String? {
            await withCheckedContinuation { continuation in
                bridge.session(WCSession.default, didReceiveMessage: payload, replyHandler: { reply in
                    continuation.resume(returning: reply[WatchEditReply.key] as? String)
                })
            }
        }
        #expect(await deliver() == WatchEditReply.applied)
        #expect(scheduler.unscopedRefreshRevision == 1)
        #expect(scheduler.dataRefreshToken != previousToken)
        for _ in 0..<100 {
            if await sink.values().values.contains(where: { $0.title == "Buy milk" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await sink.values().values.contains { $0.title == "Buy milk" })
        #expect(widgetReloads == 1)
        let indexCount = await sink.indexCount
        #expect(await deliver() == WatchEditReply.applied)
        try await Task.sleep(for: .milliseconds(30))
        #expect(scheduler.unscopedRefreshRevision == 1)
        #expect(widgetReloads == 1)
        #expect(await sink.indexCount == indexCount)
        #expect(scheduler.latestCommittedChange == nil)
        #expect(main.hasChanges)
        #expect(unrelated.title == "Pending unrelated")
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).contains { $0.title == "Saved unrelated" })
    }

    @Test func unreadableRetainedReceiptCannotReplayEvenAfterAnotherCommitPrunes() throws {
        let container = try container()
        let context = container.mainContext
        let list = TaskList(serverURL: "", name: "Inbox", colorHex: "")
        context.insert(list)
        let id = UUID()
        let receipt = SyncMetadata(id: WatchReceiptStore.prefix + id.uuidString, collectionPath: "")
        receipt.lastFullSync = now
        receipt.syncToken = "broken JSON"
        context.insert(receipt)
        try context.save()
        let edit = WatchEdit.add(rawText: "Do not duplicate", listID: list.id, dueDate: nil, priorityRaw: nil)
        #expect(WatchEditTransaction.apply(edit, operationID: id, container: container,
            isProUnlocked: true, now: now) == WatchEditReply.unconfirmed)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).isEmpty)
        #expect(WatchEditTransaction.apply(.add(rawText: "Different edit", listID: list.id, dueDate: nil,
            priorityRaw: nil), operationID: UUID(), container: container,
            isProUnlocked: true, now: now.addingTimeInterval(1)) == WatchEditReply.applied)
        #expect(WatchEditTransaction.apply(edit, operationID: id, container: container,
            isProUnlocked: true, now: now.addingTimeInterval(2)) == WatchEditReply.unconfirmed)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).map(\.title) == ["Different edit"])
        #expect(try WatchReceiptStore.lookup([id], in: ModelContext(container), now: now).first?.result == WatchEditReply.unconfirmed)
    }

}
