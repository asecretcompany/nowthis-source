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
