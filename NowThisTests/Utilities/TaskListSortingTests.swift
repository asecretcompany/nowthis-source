import Testing
import Foundation

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
    func topSortOrderIsAboveExisting() {
        let a = TaskItem(title: "A"); a.manualSortOrder = 3
        let b = TaskItem(title: "B"); b.manualSortOrder = 7

        let order = TaskListHelpers.topSortOrder(forInsertingInto: [a, b])

        #expect(order < 3)
        #expect(order < 7)
    }

    @Test("Top sort order for an empty list is zero")
    func topSortOrderEmpty() {
        #expect(TaskListHelpers.topSortOrder(forInsertingInto: []) == 0)
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
        TaskListHelpers.assignManualOrder([c, a, b])

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
        TaskListHelpers.assignManualOrder([b, c, a])

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

        TaskListHelpers.assignManualOrder([a, b])

        #expect(!a.isDirty)
        #expect(!b.isDirty)
        #expect(a.manualSortOrder == 1_000)
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
