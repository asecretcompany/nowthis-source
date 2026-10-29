import Testing
import Foundation
import SwiftData

@testable import NowThis

/// The two fields that record a move the server has not caught up with yet.
///
/// They are optional with no default, which is what keeps this inside SchemaV2's
/// lightweight migration: `NowThisMigrationPlan` lists model *types*, not
/// properties, so adding optionals needs no explicit plan (see the reasoning
/// recorded at `NowThisMigrationPlan.swift:49`).
@Suite("TaskItem pending move")
struct TaskItemPendingMoveTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    // Spec §8, case 9.
    @Test("A task with no move in flight persists both fields as nil")
    func fieldsDefaultToNilAcrossAFreshContext() throws {
        // The container is held in a `let` that outlives every context below.
        // `try makeContainer().mainContext` deallocates it mid-test, which
        // SIGTRAPs the process and makes the whole run report green with zero
        // tests — see the recorded failure mode.
        let container = try makeContainer()

        let writeContext = ModelContext(container)
        let task = TaskItem(uid: "uid-untouched", title: "Renew passport")
        writeContext.insert(task)
        try writeContext.save()

        // A fresh context forces a real read back out of the store rather than
        // handing back the in-memory instance we just wrote.
        let readContext = ModelContext(container)
        let fetched = try readContext.fetch(FetchDescriptor<TaskItem>())

        #expect(fetched.count == 1, "examined \(fetched.count) tasks")
        #expect(fetched.first?.pendingMoveFromHref == nil)
        #expect(fetched.first?.pendingMoveFromListID == nil)
    }

    @Test("Both fields survive a round trip through the store")
    func fieldsPersist() throws {
        let container = try makeContainer()

        let writeContext = ModelContext(container)
        let list = TaskList(serverURL: "https://example.test/cal/work/", name: "Work", colorHex: "#007AFF")
        writeContext.insert(list)
        let task = TaskItem(uid: "uid-moving", title: "Renew passport")
        task.pendingMoveFromHref = "/cal/work/uid-moving.ics"
        task.pendingMoveFromListID = list.id
        writeContext.insert(task)
        try writeContext.save()

        let readContext = ModelContext(container)
        let fetched = try readContext.fetch(FetchDescriptor<TaskItem>())

        #expect(fetched.count == 1, "examined \(fetched.count) tasks")
        #expect(fetched.first?.pendingMoveFromHref == "/cal/work/uid-moving.ics")
        #expect(fetched.first?.pendingMoveFromListID == list.id)
    }
}
