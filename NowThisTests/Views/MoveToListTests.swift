import Testing
import Foundation
import SwiftData

@testable import NowThis

/// What the move picker offers, and what choosing a row does.
///
/// The sheet renders from `MoveDestinations` — value types built once from the
/// models — so it never reads a `TaskList` a sync or an account removal has
/// deleted mid-render.
@Suite("Move to list")
@MainActor
struct MoveToListTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    private func list(_ name: String, in account: ServerAccount, context: ModelContext) -> TaskList {
        let list = TaskList(serverURL: "/cal/\(name.lowercased())/", name: name, colorHex: "#007AFF")
        context.insert(list)
        list.account = account
        return list
    }

    // MARK: - Destinations

    @Test("Lists are grouped by account, both sorted by name, empty accounts left out")
    func groupedAndSorted() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let zeta = ServerAccount(displayName: "Zeta cloud", serverBaseURL: "https://z.test", username: "sam")
        let alpha = ServerAccount(displayName: "Alpha cloud", serverBaseURL: "https://a.test", username: "sam")
        let empty = ServerAccount(displayName: "Empty", serverBaseURL: "https://e.test", username: "sam")
        for account in [zeta, alpha, empty] { context.insert(account) }
        _ = list("Work", in: zeta, context: context)
        _ = list("Home", in: zeta, context: context)
        _ = list("Errands", in: alpha, context: context)
        try context.save()

        let sections = MoveDestinations.sections(
            accounts: try context.fetch(FetchDescriptor<ServerAccount>()),
            currentListID: nil
        )

        #expect(sections.map(\.accountName) == ["Alpha cloud", "Zeta cloud"], "examined \(sections.count) sections")
        #expect(sections.last?.lists.map(\.name) == ["Home", "Work"])
    }

    @Test("The current list is marked and cannot be chosen; a read-only list cannot be chosen")
    func unavailableDestinations() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = ServerAccount(displayName: "Cloud", serverBaseURL: "https://c.test", username: "sam")
        context.insert(account)
        let work = list("Work", in: account, context: context)
        let shared = list("Shared", in: account, context: context)
        shared.isReadOnly = true
        let home = list("Home", in: account, context: context)
        try context.save()

        let rows = MoveDestinations.sections(
            accounts: [account], currentListID: work.id
        ).flatMap(\.lists)

        #expect(rows.count == 3, "examined \(rows.count) rows")
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[work.id]?.isCurrent == true)
        #expect(byID[work.id]?.isSelectable == false)
        #expect(byID[shared.id]?.isReadOnly == true)
        #expect(byID[shared.id]?.isSelectable == false)
        #expect(byID[home.id]?.isSelectable == true)
    }

    @Test("A task in a read-only list cannot be moved out of it")
    func readOnlySourceCannotBeMoved() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = ServerAccount(displayName: "Cloud", serverBaseURL: "https://c.test", username: "sam")
        context.insert(account)
        let shared = list("Shared", in: account, context: context)
        shared.isReadOnly = true
        let task = TaskItem(uid: "uid-1", title: "Renew passport")
        context.insert(task)
        task.taskList = shared
        try context.save()

        #expect(!MoveDestinations.canMove(task))
        shared.isReadOnly = false
        #expect(MoveDestinations.canMove(task))
    }

    // MARK: - Choosing a row

    @Test("Choosing a list moves the task there and saves")
    func performMoves() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = ServerAccount(displayName: "Cloud", serverBaseURL: "https://c.test", username: "sam")
        context.insert(account)
        let work = list("Work", in: account, context: context)
        let home = list("Home", in: account, context: context)
        let task = TaskItem(uid: "uid-1", title: "Renew passport")
        context.insert(task)
        task.taskList = work
        try context.save()

        #expect(MoveDestinations.perform(task, toListID: home.id, in: context))

        let fresh = ModelContext(container)
        let fetched = try fresh.fetch(FetchDescriptor<TaskItem>())
        #expect(fetched.count == 1, "examined \(fetched.count) tasks")
        #expect(fetched.first?.taskList?.id == home.id, "the move must be saved, not just made")
    }

    @Test("A board card moves by task ID, resolved when the list is chosen")
    func performByTaskID() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = ServerAccount(displayName: "Cloud", serverBaseURL: "https://c.test", username: "sam")
        context.insert(account)
        let work = list("Work", in: account, context: context)
        let home = list("Home", in: account, context: context)
        let task = TaskItem(uid: "uid-1", title: "Renew passport")
        context.insert(task)
        task.taskList = work
        try context.save()

        let request = try #require(MoveToListRequest(task: task))
        #expect(request.taskID == task.id)

        #expect(MoveDestinations.perform(taskID: request.taskID, toListID: home.id, in: context))
        #expect(task.taskList?.id == home.id)
        #expect(!MoveDestinations.perform(taskID: "gone", toListID: work.id, in: context),
                "a card whose task a sync deleted meanwhile moves nothing")
    }

    private struct MoveSaveFailure: Error {}

    @Test("A failed move cannot persist after either endpoint becomes read-only", arguments: [false, true])
    func refusedMoveRetryCannotLeak(revokeSource: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(SchemaV2.models)
        let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("local.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        context.autosaveEnabled = false
        let account = ServerAccount(displayName: "Cloud", serverBaseURL: "https://move.invalid", username: "fixture")
        let source = TaskList(serverURL: "/source/", name: "Source", colorHex: "#007AFF")
        let destination = TaskList(serverURL: "/destination/", name: "Destination", colorHex: "#007AFF")
        let task = TaskItem(title: "Move target")
        let peer = TaskItem(title: "Unrelated task")
        context.insert(account)
        context.insert(source)
        context.insert(destination)
        context.insert(task)
        context.insert(peer)
        source.account = account
        destination.account = account
        task.taskList = source
        task.remoteHref = "/source/task.ics"
        task.etag = "source-baseline"
        task.isDirty = true
        let priorStamp = Date(timeIntervalSinceReferenceDate: 120_000)
        task.lastModifiedDate = priorStamp
        try SyncResourceFixture.prove(task, in: context)
        try context.save()
        let taskID = task.id
        let peerID = peer.id
        let sourceID = source.id
        let destinationID = destination.id
        let revokedID = revokeSource ? sourceID : destinationID
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })
        let baseline = ModelContext(container)
        let originalMetadata = try metadata(in: baseline)
        var primarySaves = 0
        let errors = ErrorState()
        #expect(!MoveDestinations.perform(task, toListID: destinationID, in: context, errorState: errors, save: {
            primarySaves += 1
            throw MoveSaveFailure()
        }))
        #expect(primarySaves == 1 && errors.isPresented)
        let firstReader = ModelContext(container)
        let before = try #require(try firstReader.fetch(descriptor).first)
        #expect(before.taskList?.id == sourceID)
        #expect(try metadata(in: firstReader) == originalMetadata)
        errors.dismiss()

        let incoming = ModelContext(container)
        let revoked = try #require(try incoming.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == revokedID })).first)
        revoked.isReadOnly = true
        try incoming.save()
        #expect(!MoveDestinations.perform(task, toListID: destinationID, in: context, errorState: errors,
            save: { primarySaves += 1 }))
        #expect(primarySaves == 1 && errors.isPresented)
        #expect(errors.currentError == String(localized: TaskWriteEligibility.readOnlyEditMessage))

        peer.title = "Unrelated edit saved later"
        try context.save()
        let reader = ModelContext(container)
        let saved = try #require(try reader.fetch(descriptor).first)
        let savedPeer = try #require(try reader.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == peerID })).first)
        #expect(savedPeer.title == "Unrelated edit saved later")
        #expect(saved.taskList?.id == sourceID)
        #expect(saved.remoteHref == "/source/task.ics" && saved.etag == "source-baseline")
        #expect(saved.pendingMoveFromHref == nil && saved.pendingMoveFromListID == nil)
        #expect(saved.isDirty && saved.lastModifiedDate == priorStamp)
        #expect(try metadata(in: reader) == originalMetadata)
    }

    @Test("A mounted move retry rejects changed source or same-ID destination replacement", arguments: [false, true])
    func mountedMoveRejectsReplacedTarget(replaceDestination: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(SchemaV2.models)
        let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("local.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        context.autosaveEnabled = false
        let account = ServerAccount(vaultDisplayName: "Local")
        context.insert(account)
        let source = list("Source", in: account, context: context)
        let destination = list("Destination", in: account, context: context)
        let alternate = list("Alternate", in: account, context: context)
        let task = TaskItem(title: "Move target")
        let peer = TaskItem(title: "Peer")
        context.insert(task)
        context.insert(peer)
        task.taskList = source
        try context.save()
        let sourceID = source.id
        let alternateID = alternate.id
        let destinationID = destination.id
        let taskID = task.id
        let peerID = peer.id
        let target = try #require(MoveDestinations.sections(accounts: [account], currentListID: sourceID)
            .flatMap(\.lists).first { $0.id == destinationID })
        let request = try #require(MoveToListRequest(task: task))
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })
        let errors = ErrorState()
        var saves = 0
        var revalidations = 0
        #expect(!MoveDestinations.perform(request, to: target, in: context, errorState: errors, save: { _ in
            saves += 1
            throw MoveSaveFailure()
        }))
        try #require(saves == 1 && errors.isPresented)
        errors.dismiss()

        let incoming = ModelContext(container)
        let incomingTask = try #require(try incoming.fetch(descriptor).first)
        if replaceDestination {
            let destinationDescriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == destinationID })
            let oldDestination = try #require(try incoming.fetch(destinationDescriptor).first)
            let account = try #require(oldDestination.account)
            incoming.delete(oldDestination)
            try incoming.save()
            let replacement = TaskList(id: destinationID, serverURL: "/replacement/", name: "Replacement", colorHex: "#007AFF")
            incoming.insert(replacement)
            replacement.account = account
            try incoming.save()
            try #require(replacement.persistentModelID != target.persistentID)
        } else {
            let alternateDescriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == alternateID })
            incomingTask.taskList = try #require(try incoming.fetch(alternateDescriptor).first)
            try incoming.save()
        }

        #expect(!MoveDestinations.perform(request, to: target, in: context, errorState: errors,
            save: { _ in saves += 1 }, revalidate: { revalidations += 1 }))
        #expect(errors.isPresented)
        #expect(saves == 1 && revalidations == 0)
        peer.title = "Peer saved later"
        try context.save()
        let reader = ModelContext(container)
        let stored = try #require(try reader.fetch(descriptor).first)
        let savedPeer = try #require(try reader.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == peerID })).first)
        #expect(stored.taskList?.id == (replaceDestination ? sourceID : alternateID))
        #expect(stored.pendingMoveFromHref == nil && stored.pendingMoveFromListID == nil)
        #expect(savedPeer.title == "Peer saved later")
        #expect(try metadata(in: reader).isEmpty)
    }

    private func metadata(in context: ModelContext) throws -> [String: String] {
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.syncToken ?? "") })
    }

    @Test("Choosing a list that has since been deleted does nothing")
    func performIgnoresAMissingList() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = ServerAccount(displayName: "Cloud", serverBaseURL: "https://c.test", username: "sam")
        context.insert(account)
        let work = list("Work", in: account, context: context)
        let task = TaskItem(uid: "uid-1", title: "Renew passport")
        context.insert(task)
        task.taskList = work
        try context.save()

        #expect(!MoveDestinations.perform(task, toListID: "gone", in: context))
        #expect(task.taskList?.id == work.id)
    }
}
