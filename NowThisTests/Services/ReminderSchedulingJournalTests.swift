import Foundation
import SwiftData
import Testing

@testable import NowThis

@Suite("Durable reminder scheduling tickets", .serialized)
@MainActor
struct ReminderSchedulingJournalTests {
    @Test("Local save boundary persists the edited due date and ticket together")
    func dueDateEditAndTicketSaveTogether() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let task = TaskItem(title: "Local edit")
        context.insert(task)
        try context.save()
        task.dueDate = Date(timeIntervalSince1970: 2_000_000_000)
        try ReminderSchedulingJournal.saveTaskChanges(in: context)
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<TaskItem>()).first?.dueDate == task.dueDate)
        #expect(try ReminderSchedulingJournal.capture(in: read).count == 1)
    }

    @Test("A local save failure cannot persist or acknowledge its recovery ticket")
    func localSaveFailureRetainsUncommittedWork() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        context.insert(TaskItem(title: "Pending"))
        struct SaveFailure: Error {}
        #expect(throws: SaveFailure.self) {
            try ReminderSchedulingJournal.saveTaskChanges(in: context, save: { throw SaveFailure() })
        }
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
        #expect(try !ReminderSchedulingJournal.capture(in: context).isEmpty)
        context.rollback()
    }

    @Test("A task and its scheduling ticket survive reopening the same store")
    func mutationAndTicketSurviveReopenTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reminder.store")
        let schema = Schema(SchemaV2.models)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        var ticketID = ""
        do {
            let first = try ModelContainer(for: schema, configurations: [configuration])
            first.mainContext.autosaveEnabled = false
            let task = TaskItem(title: "Persisted task")
            task.dueDate = Date(timeIntervalSince1970: 2_000_000_000)
            first.mainContext.insert(task)
            ticketID = ReminderSchedulingJournal.enqueue(in: first.mainContext)
            try first.mainContext.save()
        }
        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let stored = try #require(try reopened.mainContext.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "Persisted task")
        #expect(stored.dueDate == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(try ReminderSchedulingJournal.capture(in: reopened.mainContext) == [ticketID])
    }

    @Test("Discarding an acknowledgment transaction leaves its saved ticket intact")
    func failedSaveDoesNotAcknowledgeScheduling() throws {
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        main.autosaveEnabled = false
        let ticket = ReminderSchedulingJournal.enqueue(in: main)
        try main.save()
        let failingTransaction = ModelContext(container)
        failingTransaction.autosaveEnabled = false
        try ReminderSchedulingJournal.acknowledge([ticket], planDigest: "confirmed",
            deferredTaskIDs: [], earliestDeferredFireDate: nil, in: failingTransaction)
        failingTransaction.rollback()
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)) == [ticket])
    }

    @Test("An older acknowledgment cannot clear a ticket from another context")
    func acknowledgmentLeavesNewerContextTicket() throws {
        let container = try DAVSyncScenario.container()
        let old = ReminderSchedulingJournal.enqueue(in: container.mainContext)
        try container.mainContext.save()
        let transaction = ModelContext(container)
        transaction.autosaveEnabled = false
        let captured = try ReminderSchedulingJournal.capture(in: transaction)
        let newerContext = ModelContext(container)
        let newer = ReminderSchedulingJournal.enqueue(in: newerContext)
        try newerContext.save()
        try ReminderSchedulingJournal.acknowledge(captured, planDigest: "older-plan",
            deferredTaskIDs: [], earliestDeferredFireDate: nil, in: transaction)
        try transaction.save()
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)) == [newer])
        #expect(newer != old)
    }

    @Test("Acknowledgments preserve unrelated import and photo metadata")
    func journalNeverChangesImportOrPhotoMetadata() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let checkpoint = SyncMetadata(id: "collection-v1:fixture", collectionPath: "/one/")
        checkpoint.syncToken = "existing-delta-token"
        checkpoint.lastCTag = "existing-ctag"
        let photo = SyncMetadata(id: "taskPhotoCleanup:fixture", collectionPath: "/photos/")
        photo.photoFolderID = "keep-folder"
        context.insert(checkpoint); context.insert(photo)
        let ticket = ReminderSchedulingJournal.enqueue(in: context)
        try context.save()
        try ReminderSchedulingJournal.acknowledge([ticket], planDigest: "digest",
            deferredTaskIDs: ["later"], earliestDeferredFireDate: Date(timeIntervalSince1970: 2_000_000_000),
            in: context)
        try context.save()
        let rows = try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>())
        #expect(rows.first { $0.id == checkpoint.id }?.syncToken == "existing-delta-token")
        #expect(rows.first { $0.id == checkpoint.id }?.lastCTag == "existing-ctag")
        #expect(rows.first { $0.id == photo.id }?.photoFolderID == "keep-folder")
        let outcome = try #require(rows.first { $0.id == "reminder-outcome-v1" }?.syncToken)
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(outcome.utf8)) as? [String: Any])
        #expect(decoded["version"] as? Int == 1)
        #expect(decoded["deferredTaskIDs"] as? [String] == ["later"])
    }

    @Test("An unsaved task overlay cannot be acknowledged as durable")
    func overlayCannotBeAcknowledgedBeforeSave() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let ticket = ReminderSchedulingJournal.enqueue(in: context)
        try context.save()
        context.insert(TaskItem(title: "Unsaved edit"))
        #expect(throws: ReminderSchedulingJournal.Failure.unsavedChanges) {
            try ReminderSchedulingJournal.acknowledge([ticket], planDigest: "unsaved",
                deferredTaskIDs: [], earliestDeferredFireDate: nil, in: context)
        }
    }

    @Test("A committed inbound task batch carries a scheduling recovery ticket")
    func inboundCommitCreatesRecoveryTicket() throws {
        let container = try DAVSyncScenario.container()
        let list = TaskList(id: "list", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        container.mainContext.insert(list)
        try container.mainContext.save()
        let writer = SyncInboundBatchWriter(container: container, listID: list.id)
        let resource = ParsedRemoteTask(href: "/one/uid.ics", etag: "e1",
            todo: try ICalendarParser.parseSingleVTODO(from: "BEGIN:VTODO\nUID:uid\nSUMMARY:Reminder\nDUE:20330518T033320Z\nEND:VTODO"))
        let commit = try writer.apply([resource])
        #expect(commit?.insertedIDs.count == 1)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).count == 1)
    }
}
