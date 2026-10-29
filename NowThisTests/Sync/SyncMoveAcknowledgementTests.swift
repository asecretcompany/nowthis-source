import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Pending move acknowledgement")
@MainActor
struct SyncMoveAcknowledgementTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private struct Fixture {
        let source: TaskList
        let firstDestination: TaskList
        let secondDestination: TaskList
        let task: TaskItem
    }

    private func makeFixture(in context: ModelContext) throws -> Fixture {
        let account = ServerAccount(displayName: "Nextcloud", serverBaseURL: "https://cloud.example.test",
                                    username: "sam", mode: .nextcloud)
        context.insert(account)
        let source = TaskList(serverURL: "/cal/source/", name: "Source", colorHex: "#007AFF")
        let first = TaskList(serverURL: "/cal/first/", name: "First", colorHex: "#FF9500")
        let second = TaskList(serverURL: "/cal/second/", name: "Second", colorHex: "#34C759")
        for list in [source, first, second] {
            context.insert(list)
            list.account = account
        }
        let task = TaskItem(uid: "move-race", title: "Original")
        context.insert(task)
        task.taskList = source
        task.remoteHref = "/cal/source/move-race.ics"
        task.etag = "source-etag"
        task.isLocalOnly = false
        TaskMover.move(task, to: first, in: context)
        task.remoteHref = "/cal/first/move-race.ics"
        task.etag = "first-etag"
        task.isDirty = false
        try context.save()
        return Fixture(source: source, firstDestination: first, secondDestination: second, task: task)
    }

    private func makeRunContext(container: ModelContainer, sourceID: String) throws -> (ModelContext, [TaskItem]) {
        let context = ModelContext(container)
        let candidates = PendingMoveSweep.candidates(sourceListIDs: [sourceID], in: context)
        return (context, candidates)
    }

    @Test("DELETE success preserves a saved title edit made while the request is suspended")
    func successPreservesSavedEdit() async throws {
        let container = try makeContainer()
        let fixture = try makeFixture(in: container.mainContext)
        let (syncContext, candidates) = try makeRunContext(container: container, sourceID: fixture.source.id)
        let pause = DeletePause()
        let run = Task {
            await PendingMoveSweep.run(candidates, in: syncContext) { _ in await pause.wait() }
        }
        await pause.waitUntilEntered()

        fixture.task.title = "Saved while DELETE was in flight"
        fixture.task.isDirty = true
        try container.mainContext.save()
        await pause.resume()
        #expect(!(await run.value))
        try syncContext.save()

        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.title == "Saved while DELETE was in flight")
        #expect(stored.isDirty)
        #expect(stored.pendingMoveFromHref == nil)
        #expect(stored.pendingMoveFromListID == nil)
    }

    @Test("DELETE success preserves an unsaved title edit in the UI context")
    func successPreservesUnsavedEdit() async throws {
        let container = try makeContainer()
        let fixture = try makeFixture(in: container.mainContext)
        let (syncContext, candidates) = try makeRunContext(container: container, sourceID: fixture.source.id)
        let pause = DeletePause()
        let run = Task {
            await PendingMoveSweep.run(candidates, in: syncContext) { _ in await pause.wait() }
        }
        await pause.waitUntilEntered()

        fixture.task.title = "Unsaved while DELETE was in flight"
        fixture.task.isDirty = true
        await pause.resume()
        #expect(!(await run.value))
        try syncContext.save()

        #expect(fixture.task.title == "Unsaved while DELETE was in flight")
        #expect(fixture.task.isDirty)
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(stored.pendingMoveFromHref == nil)
        #expect(stored.pendingMoveFromListID == nil)
    }

    @Test("DELETE success leaves markers for a newer destination move")
    func successDoesNotAcknowledgeNewDestination() async throws {
        let container = try makeContainer()
        let fixture = try makeFixture(in: container.mainContext)
        let (syncContext, candidates) = try makeRunContext(container: container, sourceID: fixture.source.id)
        let pause = DeletePause()
        let run = Task {
            await PendingMoveSweep.run(candidates, in: syncContext) { _ in await pause.wait() }
        }
        await pause.waitUntilEntered()

        TaskMover.move(fixture.task, to: fixture.secondDestination, in: container.mainContext)
        try container.mainContext.save()
        await pause.resume()
        #expect(!(await run.value))
        try syncContext.save()

        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
            .first { !$0.isDeletedLocally })
        #expect(stored.taskList?.id == fixture.secondDestination.id)
        #expect(stored.pendingMoveFromHref == "/cal/source/move-race.ics")
        #expect(stored.pendingMoveFromListID == fixture.source.id)
        #expect(stored.remoteHref == nil)
    }

    @Test("DELETE success leaves a move pending when the UI changed its source marker")
    func successDoesNotClearChangedMarker() async throws {
        let container = try makeContainer()
        let fixture = try makeFixture(in: container.mainContext)
        let (syncContext, candidates) = try makeRunContext(container: container, sourceID: fixture.source.id)
        let pause = DeletePause()
        let run = Task {
            await PendingMoveSweep.run(candidates, in: syncContext) { _ in await pause.wait() }
        }
        await pause.waitUntilEntered()

        TaskMover.move(fixture.task, to: fixture.source, in: container.mainContext)
        try container.mainContext.save()
        await pause.resume()
        #expect(!(await run.value))
        try syncContext.save()

        #expect(fixture.task.taskList?.id == fixture.source.id)
        #expect(fixture.task.remoteHref == "/cal/source/move-race.ics")
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
            .first { !$0.isDeletedLocally })
        #expect(stored.taskList?.id == fixture.source.id)
        #expect(stored.pendingMoveFromHref == nil)
    }

    @Test("Cancellation after DELETE leaves the move pending")
    func cancellationLeavesMovePending() async throws {
        let container = try makeContainer()
        let fixture = try makeFixture(in: container.mainContext)
        let (syncContext, candidates) = try makeRunContext(container: container, sourceID: fixture.source.id)
        let pause = DeletePause()
        let run = Task {
            await PendingMoveSweep.run(candidates, in: syncContext) { _ in await pause.wait() }
        }
        await pause.waitUntilEntered()

        run.cancel()
        await pause.resume()
        #expect(!(await run.value))
        try syncContext.save()

        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
            .first { !$0.isDeletedLocally })
        #expect(stored.pendingMoveFromHref == "/cal/source/move-race.ics")
        #expect(stored.pendingMoveFromListID == fixture.source.id)
    }

    @Test("A later move is not rolled back when DELETE is refused")
    func refusalDoesNotRollbackLaterMove() async throws {
        let container = try makeContainer()
        let fixture = try makeFixture(in: container.mainContext)
        let (syncContext, candidates) = try makeRunContext(container: container, sourceID: fixture.source.id)
        let pause = DeletePause()
        let run = Task {
            await PendingMoveSweep.run(candidates, in: syncContext) { _ in
                await pause.wait()
                throw CalDAVError.forbidden
            }
        }
        await pause.waitUntilEntered()

        TaskMover.move(fixture.task, to: fixture.secondDestination, in: container.mainContext)
        try container.mainContext.save()
        await pause.resume()
        #expect(await run.value)
        try syncContext.save()

        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
            .first { !$0.isDeletedLocally })
        #expect(stored.taskList?.id == fixture.secondDestination.id)
        #expect(stored.pendingMoveFromHref == "/cal/source/move-race.ics")
        #expect(stored.pendingMoveFromListID == fixture.source.id)
        #expect(stored.remoteHref == nil)
    }

    @Test("A refusal does not roll back a saved title edit")
    func refusalPreservesSavedEdit() async throws {
        let container = try makeContainer()
        let fixture = try makeFixture(in: container.mainContext)
        let (syncContext, candidates) = try makeRunContext(container: container, sourceID: fixture.source.id)
        let pause = DeletePause()
        let run = Task {
            await PendingMoveSweep.run(candidates, in: syncContext) { _ in
                await pause.wait()
                throw CalDAVError.forbidden
            }
        }
        await pause.waitUntilEntered()

        fixture.task.title = "Saved newer title"
        fixture.task.isDirty = true
        try container.mainContext.save()
        await pause.resume()
        #expect(await run.value)
        try syncContext.save()

        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
            .first { !$0.isDeletedLocally })
        #expect(stored.title == "Saved newer title")
        #expect(stored.taskList?.id == fixture.firstDestination.id)
        #expect(stored.pendingMoveFromHref == "/cal/source/move-race.ics")
    }

    @Test("A refusal does not roll back an unsaved title edit")
    func refusalPreservesUnsavedEdit() async throws {
        let container = try makeContainer()
        let fixture = try makeFixture(in: container.mainContext)
        let (syncContext, candidates) = try makeRunContext(container: container, sourceID: fixture.source.id)
        let pause = DeletePause()
        let run = Task {
            await PendingMoveSweep.run(candidates, in: syncContext) { _ in
                await pause.wait()
                throw CalDAVError.forbidden
            }
        }
        await pause.waitUntilEntered()

        fixture.task.title = "Unsaved newer title"
        fixture.task.isDirty = true
        await pause.resume()
        #expect(await run.value)
        try syncContext.save()

        #expect(fixture.task.title == "Unsaved newer title")
        #expect(fixture.task.taskList?.id == fixture.firstDestination.id)
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
            .first { !$0.isDeletedLocally })
        #expect(stored.taskList?.id == fixture.firstDestination.id)
        #expect(stored.pendingMoveFromHref == "/cal/source/move-race.ics")
    }
}

private actor DeletePause {
    private var entered: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var hasEntered = false

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { entered = $0 }
    }

    func wait() async {
        hasEntered = true
        entered?.resume()
        entered = nil
        await withCheckedContinuation { release = $0 }
    }

    func resume() {
        release?.resume()
        release = nil
    }
}
