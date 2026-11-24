import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - TaskListHelpers Sorting & Manual Order Tests

/// Covers the "completed tasks sink to the bottom", "new items above done",
/// and manual-reorder behaviors of the task list.
@Suite("TaskListHelpers sorting & manual order")
struct TaskListSortingTests {

    // MARK: - Completed-at-bottom

    @Test("Completed tasks sort below active tasks regardless of due date")
    func completedTasksPinnedToBottom() {
        let activeNoDue = TaskItem(title: "Active no due")

        let doneEarly = TaskItem(title: "Done early")
        doneEarly.status = .completed
        doneEarly.dueDate = Date(timeIntervalSinceNow: -7200) // earliest due date

        let activeLater = TaskItem(title: "Active later")
        activeLater.dueDate = Date(timeIntervalSinceNow: 3600)

        let sorted = TaskListHelpers.sortedWithCompletedLast(
            [doneEarly, activeNoDue, activeLater],
            by: .dueDate,
            ascending: true
        )

        let firstCompletedIndex = sorted.firstIndex { $0.status == .completed }
        let lastActiveIndex = sorted.lastIndex { $0.status != .completed }
        #expect(firstCompletedIndex != nil)
        #expect(lastActiveIndex != nil)
        #expect(lastActiveIndex! < firstCompletedIndex!)
        #expect(sorted.last?.title == "Done early")
    }

    @Test("Active tasks are date-sorted within their group")
    func activeTasksHonorDateSort() {
        let later = TaskItem(title: "Later")
        later.dueDate = Date(timeIntervalSinceNow: 3600)

        let earlier = TaskItem(title: "Earlier")
        earlier.dueDate = Date(timeIntervalSinceNow: -3600)

        let sorted = TaskListHelpers.sortedWithCompletedLast(
            [later, earlier],
            by: .dueDate,
            ascending: true
        )

        #expect(sorted.map(\.title) == ["Earlier", "Later"])
    }

    @Test("Completed tasks are date-sorted within their own group")
    func completedTasksHonorDateSortWithinGroup() {
        let doneLater = TaskItem(title: "Done later")
        doneLater.status = .completed
        doneLater.dueDate = Date(timeIntervalSinceNow: 3600)

        let doneEarlier = TaskItem(title: "Done earlier")
        doneEarlier.status = .completed
        doneEarlier.dueDate = Date(timeIntervalSinceNow: -3600)

        let sorted = TaskListHelpers.sortedWithCompletedLast(
            [doneLater, doneEarlier],
            by: .dueDate,
            ascending: true
        )

        #expect(sorted.map(\.title) == ["Done earlier", "Done later"])
    }

    @Test("A new active task with no due date still sorts above completed tasks")
    func newActiveTaskAboveDone() {
        let done = TaskItem(title: "Done")
        done.status = .completed
        done.dueDate = Date(timeIntervalSinceNow: -3600)

        let newTask = TaskItem(title: "Brand new") // no due date

        let sorted = TaskListHelpers.sortedWithCompletedLast(
            [done, newTask],
            by: .dueDate,
            ascending: true
        )

        #expect(sorted.map(\.title) == ["Brand new", "Done"])
    }

    // MARK: - New task placement

    @Test("New task gets a sort order above all existing tasks")
    func topSortOrderIsAboveExisting() throws {
        let a = TaskItem(title: "A"); a.manualSortOrder = 3
        let b = TaskItem(title: "B"); b.manualSortOrder = 7

        let order = try #require(TaskListHelpers.topSortOrder(forInsertingInto: [a, b]))

        #expect(order < 3)
        #expect(order < 7)
    }

    @Test("Top sort order for an empty list is zero")
    func topSortOrderEmpty() {
        #expect(TaskListHelpers.topSortOrder(forInsertingInto: []) == 0)
    }

    @Test("An inserted task gets a usable rank when the first stored rank is one")
    func inlineInsertionSkipsLegacyZero() throws {
        let first = TaskItem(title: "First")
        first.manualSortOrder = 1
        let inserted = TaskItem(title: "Inserted")
        inserted.manualSortOrder = try #require(TaskListHelpers.topSortOrder(forInsertingInto: [first]))

        #expect(inserted.effectiveSortOrder < first.effectiveSortOrder)
    }

    // MARK: - Nextcloud sort-order scale (X-APPLE-SORT-ORDER parity)

    @Test("defaultSortOrder is seconds since the 2001 reference epoch (Nextcloud's fallback)")
    func defaultSortOrderMatchesNextcloud() {
        let date = Date(timeIntervalSinceReferenceDate: 123_456)
        #expect(TaskListHelpers.defaultSortOrder(for: date) == 123_456)
    }

    @Test("A new task is seeded on Nextcloud's scale from its creation date")
    func newTaskSeededFromCreationDate() {
        let task = TaskItem(title: "Fresh")
        #expect(task.manualSortOrder == Int(task.createdDate.timeIntervalSinceReferenceDate))
        // A 2001-relative seconds value, not a tiny 0/1/2 integer.
        #expect(task.manualSortOrder > 700_000_000)
    }

    @Test("effectiveSortOrder falls back to the creation-date value for legacy unordered tasks")
    func effectiveSortOrderFallback() {
        let task = TaskItem(title: "Legacy")
        task.manualSortOrder = 0 // simulate a pre-seed row in the store
        #expect(task.effectiveSortOrder == Int(task.createdDate.timeIntervalSinceReferenceDate))

        task.manualSortOrder = 42 // an explicit manual order wins
        #expect(task.effectiveSortOrder == 42)
    }

    // MARK: - Manual reorder renumbering (Nextcloud-scale)

    @Test("assignManualOrder spaces tasks on the Nextcloud sort scale in display order")
    func assignManualOrderSpacing() {
        let a = TaskItem(title: "A"); a.manualSortOrder = 500; a.isDirty = false
        let b = TaskItem(title: "B"); b.manualSortOrder = 900; b.isDirty = false
        let c = TaskItem(title: "C"); c.manualSortOrder = 200; c.isDirty = false

        // New display order after a drag: C, A, B
        TaskListHelpers.assignManualOrder([c, a, b], ascending: true)

        // Anchored at the smallest existing value, spaced by manualSortSpacing,
        // preserving the display order (strictly increasing).
        #expect(c.manualSortOrder == 200)
        #expect(a.manualSortOrder == 200 + TaskListHelpers.manualSortSpacing)
        #expect(b.manualSortOrder == 200 + 2 * TaskListHelpers.manualSortSpacing)
        #expect(c.manualSortOrder < a.manualSortOrder)
        #expect(a.manualSortOrder < b.manualSortOrder)
        // c was already at the anchor; only a and b moved.
        #expect(!c.isDirty)
        #expect(a.isDirty)
        #expect(b.isDirty)
    }

    @Test("assignManualOrder keeps reordered values on Nextcloud's large-integer scale")
    func assignManualOrderKeepsNextcloudScale() {
        let a = TaskItem(title: "A")
        let b = TaskItem(title: "B")
        let c = TaskItem(title: "C")

        // Drag into order: B, C, A
        TaskListHelpers.assignManualOrder([b, c, a], ascending: true)

        #expect(b.manualSortOrder < c.manualSortOrder)
        #expect(c.manualSortOrder < a.manualSortOrder)
        // Not collapsed to 0/1/2 — values stay on the seconds-since-2001 scale
        // so the app's order interleaves with Nextcloud's order.
        #expect(b.manualSortOrder > 700_000_000)
    }

    @Test("assignManualOrder leaves already-spaced tasks clean to avoid sync churn")
    func assignManualOrderNoOpStaysClean() {
        let a = TaskItem(title: "A"); a.manualSortOrder = 1_000; a.isDirty = false
        let b = TaskItem(title: "B")
        b.manualSortOrder = 1_000 + TaskListHelpers.manualSortSpacing; b.isDirty = false

        TaskListHelpers.assignManualOrder([a, b], ascending: true)

        #expect(!a.isDirty)
        #expect(!b.isDirty)
        #expect(a.manualSortOrder == 1_000)
    }

    @Test("Manual move denies a read-only changed sibling and allows an unchanged read-only anchor",
          arguments: [false, true])
    @MainActor
    func manualMoveChecksOnlyChangedRanks(unchangedReadOnlyAnchor: Bool) throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let writable = TaskList(serverURL: "/owned/", name: "Owned", colorHex: "#007AFF")
        let readOnly = TaskList(serverURL: "/shared/", name: "Shared", colorHex: "#007AFF")
        readOnly.isReadOnly = true
        let anchor = TaskItem(title: "Anchor")
        let sibling = TaskItem(title: "Shifted sibling")
        let dragged = TaskItem(title: "Dragged")
        let displayed = [anchor, sibling, dragged]
        let before = Date(timeIntervalSince1970: 1_728_000_000)
        let ranks = [1_000, 2_024, 3_048]
        context.insert(writable)
        context.insert(readOnly)
        for (task, rank) in zip(displayed, ranks) {
            context.insert(task)
            task.manualSortOrder = rank
            task.lastModifiedDate = before
        }
        anchor.taskList = unchangedReadOnlyAnchor ? readOnly : writable
        sibling.taskList = unchangedReadOnlyAnchor ? writable : readOnly
        dragged.taskList = writable
        try context.save()
        let ids = displayed.map(\.id)
        let deniedTaskID = unchangedReadOnlyAnchor ? anchor.id : sibling.id
        let errors = ErrorState()

        let moved = TaskListHelpers.saveManualMove(displayed, from: IndexSet(integer: 2), to: 1,
            ascending: true, in: context,
            matching: FetchDescriptor(predicate: TaskListView.taskQueryPredicate(for: .smart(.all))),
            errorState: errors)
        #expect(moved == unchangedReadOnlyAnchor)
        #expect(errors.isPresented == !unchangedReadOnlyAnchor)
        #expect(!context.hasChanges)
        let read = ModelContext(container)
        let rows = try read.fetch(FetchDescriptor<TaskItem>())
        let orderedByID = try ids.map { id in try #require(rows.first { $0.id == id }) }
        #expect(orderedByID.map(\.manualSortOrder) == (unchangedReadOnlyAnchor ? [1_000, 3_048, 2_024] : ranks))
        let deniedTask = try #require(rows.first { $0.id == deniedTaskID })
        #expect(!deniedTask.isDirty && deniedTask.lastModifiedDate == before)
        #expect(try CalendarMirrorState.pending(in: read, taskID: deniedTaskID).isEmpty)
        if !unchangedReadOnlyAnchor {
            #expect(rows.allSatisfy { !$0.isDirty && $0.lastModifiedDate == before })
            #expect(try ReminderSchedulingJournal.capture(in: read).isEmpty)
            #expect(try CalendarMirrorState.pending(in: read).isEmpty)
        }
    }

    @Test("The requested root and subtask orders survive a save in both manual directions",
          arguments: [true, false], [true, false])
    @MainActor
    func manualMovePersistsDisplayOrder(ascending: Bool, children: Bool) throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let parent = TaskItem(title: "Parent")
        let unrelated = TaskItem(title: "Unrelated")
        unrelated.manualSortOrder = 20
        unrelated.isDirty = false
        context.insert(unrelated)
        if children { context.insert(parent) }

        let list = TaskList(serverURL: "/order/", name: "Fixture", colorHex: "#007AFF")
        context.insert(list)
        let ranks = ascending ? [Int.min, 30, Int.max - 1] : [Int.max - 1, 30, Int.min]
        let siblings = try DAVSyncScenario.importRankedTasks(
            Array(zip(["A", "B", "C"], ranks)) + [("Done", 25)], list: list, in: context)
        let done = siblings[3]
        done.status = .completed
        if children { siblings.forEach { $0.parentTask = parent } }
        try context.save()

        let displayed: [TaskItem]
        let source: IndexSet
        let destination: Int
        let descriptor: FetchDescriptor<TaskItem>
        if children {
            let ordered = TaskListHelpers.orderedSubtasksIfLive(of: parent, by: .manually, ascending: ascending)
            let projection = TaskListHierarchyProjection(roots: [parent], isVisible: { _ in true },
                id: { $0.id }, orderedChildren: { $0 === parent ? ordered : [] })
            let move = try #require(projection.move(from: IndexSet(integer: 3), to: 1))
            displayed = try #require(move.siblings)
            source = move.source
            destination = move.destination
            let parentID = try #require(move.parentID)
            descriptor = FetchDescriptor(predicate: #Predicate { !$0.isDeletedLocally && $0.parentTask?.id == parentID })
        } else {
            displayed = TaskListHelpers.sortedWithCompletedLast(siblings, by: .manually, ascending: ascending)
            source = IndexSet(integer: 2)
            destination = 0
            descriptor = FetchDescriptor(predicate: TaskListView.taskQueryPredicate(for: .taskList(list.id)))
        }
        try #require(displayed.map(\.title) == ["A", "B", "C", "Done"])
        #expect(TaskListHelpers.saveManualMove(displayed, from: source, to: destination,
            ascending: ascending, in: context, matching: descriptor))

        let reload = ModelContext(container)
        let reloaded = try reload.fetch(FetchDescriptor<TaskItem>(sortBy: [SortDescriptor(\.createdDate)]))
        let ordered: [TaskItem]
        if children {
            let reloadedParent = try #require(reloaded.first { $0.title == "Parent" })
            ordered = TaskListHelpers.orderedSubtasksIfLive(of: reloadedParent, by: .manually, ascending: ascending)
        } else {
            ordered = TaskListHelpers.sortedWithCompletedLast(reloaded.filter { $0.title != "Unrelated" },
                by: .manually, ascending: ascending)
        }
        #expect(ordered.map(\.title) == ["C", "A", "B", "Done"])
        #expect(reloaded.first { $0.title == "Unrelated" }?.manualSortOrder == 20)
        #expect(reloaded.first { $0.title == "Unrelated" }?.isDirty == false)
        #expect(ordered.last?.manualSortOrder == 25)
        #expect(ordered.last?.isDirty == false)
    }

    @Test("Inline insertion normalizes only the destination roots when an imported minimum is exhausted",
          arguments: [true, false])
    @MainActor
    func inlineInsertionWithImportedExtremes(destinationHasMinimum: Bool) throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let list = TaskList(serverURL: "/order/", name: "Destination", colorHex: "#007AFF")
        let otherList = TaskList(serverURL: "/other/", name: "Other", colorHex: "#007AFF")
        context.insert(list)
        context.insert(otherList)
        let minimum = destinationHasMinimum ? Int.min : 42
        let destination = try DAVSyncScenario.importRankedTasks(
            [("First", minimum), ("Second", minimum), ("Last", Int.max - 1), ("Child", Int.min)],
            list: list, in: context)
        destination[3].parentTask = destination[0]
        let unrelated = try DAVSyncScenario.importRankedTasks([("Other", Int.min)], list: otherList, in: context)
        try context.save()

        let snapshot = [destination[3], unrelated[0]].map { ($0.uid, $0.manualSortOrder, $0.lastModifiedDate) }
        let draft = TaskCreationDraft()
        let inserted = try draft.task(title: "Inserted")
        inserted.taskList = list
        let roots = Array(destination.prefix(3)) + unrelated
        #expect(TaskListHelpers.saveInlineTask(inserted, withLowerRankThan: roots, manualAscending: true, in: context))

        let reload = ModelContext(container)
        let reloaded = try reload.fetch(FetchDescriptor<TaskItem>(sortBy: [SortDescriptor(\.createdDate)]))
        let ordered = TaskListHelpers.sortedWithCompletedLast(
            reloaded.filter { $0.taskList?.serverURL == "/order/" && $0.parentTask == nil },
            by: .manually, ascending: true)
        #expect(ordered.map(\.title) == ["Inserted", "First", "Second", "Last"])
        if destinationHasMinimum {
            #expect(Set(ordered.map(\.effectiveSortOrder)).count == ordered.count)
            #expect(ordered.allSatisfy { $0.isDirty })
        } else {
            #expect(ordered.map(\.manualSortOrder) == [41, 42, 42, Int.max - 1])
            #expect(ordered.map(\.isDirty) == [true, false, false, false])
        }
        for (uid, order, modified) in snapshot {
            let untouched = try #require(reloaded.first { $0.uid == uid })
            #expect(untouched.manualSortOrder == order)
            #expect(untouched.lastModifiedDate == modified)
            #expect(!untouched.isDirty)
        }
    }

    @Test("Inline compaction preserves query order for visible ties in either manual direction",
          arguments: [true, false])
    @MainActor
    func inlineCompactionPreservesVisibleTies(ascending: Bool) throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let list = TaskList(serverURL: "/order/", name: "Destination", colorHex: "#007AFF")
        let otherList = TaskList(serverURL: "/other/", name: "Other", colorHex: "#007AFF")
        context.insert(list)
        context.insert(otherList)
        let tasks = try DAVSyncScenario.importRankedTasks([
            ("First", Int.min), ("Second", Int.min), ("Third", Int.min), ("Last", Int.max - 1),
            ("DoneFirst", Int.min), ("DoneSecond", Int.min), ("FreshFirst", Int.min), ("FreshSecond", Int.min),
            ("Child", Int.min)
        ], list: list, in: context)
        tasks[4].status = .completed
        tasks[5].status = .completed
        tasks[8].parentTask = tasks[0]
        let unrelated = try DAVSyncScenario.importRankedTasks([("Other", Int.min)], list: otherList, in: context)
        try context.save()

        // The view sorts a stable query snapshot. Use a tie order different
        // from creation order and omit two roots that the fresh fetch can see.
        let query = [tasks[1], tasks[0], tasks[2], tasks[3], tasks[5], tasks[4]] + unrelated
        let liveRoots = TaskListHelpers.liveTasks(query, in: context,
            matching: FetchDescriptor(predicate: TaskListView.taskQueryPredicate(for: .smart(.all))))
        let visibleBefore = TaskListHelpers.sortedWithCompletedLast(liveRoots.filter { $0.taskList?.id == list.id },
            by: .manually, ascending: ascending)
        let expectedBefore = ascending
            ? ["Second", "First", "Third", "Last", "DoneSecond", "DoneFirst"]
            : ["Last", "Second", "First", "Third", "DoneSecond", "DoneFirst"]
        try #require(visibleBefore.map(\.title) == expectedBefore)

        let untouched = [tasks[8], unrelated[0]].map { ($0.uid, $0.manualSortOrder, $0.lastModifiedDate) }
        let draft = TaskCreationDraft()
        let inserted = try draft.task(title: "Inserted")
        inserted.taskList = list
        #expect(TaskListHelpers.saveInlineTask(inserted, withLowerRankThan: liveRoots,
            manualAscending: ascending, in: context))

        let reload = ModelContext(container)
        let reloaded = try reload.fetch(FetchDescriptor<TaskItem>())
        let ordered = TaskListHelpers.sortedWithCompletedLast(
            reloaded.filter { $0.taskList?.serverURL == "/order/" && $0.parentTask == nil },
            by: .manually, ascending: ascending)
        let expectedAfter = ascending
            ? ["Inserted", "Second", "First", "Third", "FreshFirst", "FreshSecond", "Last", "DoneSecond", "DoneFirst"]
            : ["Last", "Second", "First", "Third", "FreshFirst", "FreshSecond", "Inserted", "DoneSecond", "DoneFirst"]
        #expect(ordered.map(\.title) == expectedAfter)
        #expect(Set(ordered.map(\.effectiveSortOrder)).count == ordered.count)
        for (uid, rank, modified) in untouched {
            let row = try #require(reloaded.first { $0.uid == uid })
            #expect(row.manualSortOrder == rank)
            #expect(row.lastModifiedDate == modified)
            #expect(!row.isDirty)
        }
    }

    // MARK: - Subtask display ordering

    /// Subtasks must follow the same display rule as the root list — completed
    /// children pinned below active ones, the active sort honored within each
    /// group — so they line up under their parent instead of in arbitrary
    /// relationship order.
    @Test("Subtasks are returned sorted with completed children pinned to the bottom")
    func subtasksSortedCompletedLast() {
        let parent = TaskItem(title: "Parent")

        let doneChild = TaskItem(title: "Done child")
        doneChild.status = .completed
        doneChild.dueDate = Date(timeIntervalSinceNow: -7200) // earliest due

        let laterChild = TaskItem(title: "Later child")
        laterChild.dueDate = Date(timeIntervalSinceNow: 3600)

        let earlierChild = TaskItem(title: "Earlier child")
        earlierChild.dueDate = Date(timeIntervalSinceNow: -3600)

        parent.subtasks = [doneChild, laterChild, earlierChild]

        let ordered = TaskListHelpers.orderedSubtasks(
            of: parent,
            by: .dueDate,
            ascending: true
        )

        #expect(ordered.map(\.title) == ["Earlier child", "Later child", "Done child"])
    }

    @Test("Subtasks honor manual sort order, lowest value first")
    func subtasksHonorManualOrder() {
        let parent = TaskItem(title: "Parent")
        let first = TaskItem(title: "First"); first.manualSortOrder = 100
        let middle = TaskItem(title: "Middle"); middle.manualSortOrder = 200
        let last = TaskItem(title: "Last"); last.manualSortOrder = 300
        parent.subtasks = [last, first, middle]

        let ordered = TaskListHelpers.orderedSubtasks(
            of: parent,
            by: .manually,
            ascending: true
        )

        #expect(ordered.map(\.title) == ["First", "Middle", "Last"])
    }

    @Test("Locally-deleted subtasks are excluded from the display order")
    func deletedSubtasksExcluded() {
        let parent = TaskItem(title: "Parent")
        let visible = TaskItem(title: "Visible")
        let gone = TaskItem(title: "Gone"); gone.isDeletedLocally = true
        parent.subtasks = [visible, gone]

        let ordered = TaskListHelpers.orderedSubtasks(
            of: parent,
            by: .manually,
            ascending: true
        )

        #expect(ordered.map(\.title) == ["Visible"])
    }
}

extension DAVSyncScenario {
    static func importRankedTasks(_ entries: [(String, Int)], list: TaskList,
                                  in context: ModelContext) throws -> [TaskItem] {
        let store = try SyncImportStore(context: context)
        var imported: [String: TaskItem] = [:]
        return try entries.enumerated().map { index, entry in
            let (title, rank) = entry
            let uid = title.lowercased()
            let raw = """
            BEGIN:VCALENDAR
            BEGIN:VTODO
            UID:\(uid)
            SUMMARY:\(title)
            CREATED:20260101T12000\(index)Z
            LAST-MODIFIED:20260102T120000Z
            X-APPLE-SORT-ORDER:\(rank)
            END:VTODO
            END:VCALENDAR
            """
            let parsed = try store.parse(.init(href: list.serverURL + uid + ".ics", etag: "fixture", icsData: raw))
            try #require(parsed.todo?.manualSortOrder == rank)
            try #require(store.apply(parsed, list: list, uidMap: &imported))
            let task = try #require(imported[uid])
            try #require(task.manualSortOrder == rank)
            return task
        }
    }
}
