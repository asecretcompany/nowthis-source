import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Spotlight Projection")
@MainActor
struct SpotlightProjectionTests {
    @Test func builderCapturesPendingTaskValuesWithoutSaving() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "Before edit")
        context.insert(task)
        try context.save()
        task.title = "Pending title"
        task.descriptionText = "Pending description"
        task.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        task.priority = .high

        let snapshot = try #require(SpotlightIndexer.snapshot(from: task))

        #expect(snapshot.title == "Pending title")
        #expect(snapshot.contentDescription == "Pending description")
        #expect(snapshot.dueDate == task.dueDate)
        #expect(snapshot.priorityDescription == "high priority")
        withExtendedLifetime(container) {}
    }

    @Test func pendingSoftDeleteIsExcludedFromTheProjection() {
        let snapshot = SpotlightProjection.snapshot(from: SpotlightTaskInput(
            id: "deleted",
            title: "Pending deletion",
            isDeleted: true
        ))
        #expect(snapshot == nil)
    }

    @Test func deltaUpdatesChangedIDsAndRemovesMissingIDsIncludingEmptyAccount() {
        let old = SpotlightTaskSnapshot(id: "kept", title: "Old")
        let removed = SpotlightTaskSnapshot(id: "removed", title: "Gone")
        let changed = SpotlightTaskSnapshot(id: "kept", title: "New")

        let delta = SpotlightProjection.delta(
            current: [changed],
            previous: [old, removed]
        )
        #expect(delta.changed.map(\.id) == ["kept"])
        #expect(delta.removedIDs == ["removed"])

        let emptyAccount = SpotlightProjection.delta(current: [], previous: [old, removed])
        #expect(emptyAccount.changed.isEmpty)
        #expect(Set(emptyAccount.removedIDs) == ["kept", "removed"])

        let noOp = SpotlightProjection.delta(current: [changed], previous: [changed])
        #expect(noOp.changed.isEmpty)
        #expect(noOp.removedIDs.isEmpty)
    }

    @Test func generationQueueKeepsOnlyLatestPendingSnapshot() {
        var queue = SpotlightGenerationCoalescer<Int>()
        let firstGeneration = queue.enqueue(1)
        let secondGeneration = queue.enqueue(2)

        #expect(!queue.isCurrent(firstGeneration))
        #expect(queue.isCurrent(secondGeneration))
        let pending = queue.takePending()
        #expect(pending?.generation == secondGeneration)
        #expect(pending?.value == 2)
        #expect(queue.takePending() == nil)
    }

    @Test func batchesStayWithinConfiguredLimit() {
        let batches = SpotlightProjection.batches(Array(0..<11), maximumCount: 4)
        #expect(batches == [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10]])
    }
}
