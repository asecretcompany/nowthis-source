import Foundation
import SwiftData
import Testing
@testable import NowThis

/// In-memory container using the full `SchemaV2.models` list (D4: the varargs
/// `ModelContainer(for: TaskItem.self, ...)` form omits `TaskList` and breaks
/// relationship-dependent tests — see `NowThisTests/Models/MigrationPlanTests.swift:12`).
@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema(SchemaV2.models)
    return try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    )
}

@Suite("WatchSnapshotBuilder")
@MainActor
struct WatchSnapshotBuilderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // fixed clock
    private let calendar = Calendar(identifier: .gregorian)

    @Test func includesOverdueAndSevenDayWindowExcludesBeyond() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let overdueTask = TaskItem(title: "Overdue")
        overdueTask.dueDate = now.addingTimeInterval(-86_400) // yesterday
        overdueTask.isDueDateOnly = false

        let inWindowTask = TaskItem(title: "Due tomorrow")
        inWindowTask.dueDate = now.addingTimeInterval(86_400) // tomorrow
        inWindowTask.isDueDateOnly = false

        let beyondWindowTask = TaskItem(title: "Due in 8 days")
        beyondWindowTask.dueDate = now.addingTimeInterval(8 * 86_400) // beyond the 7-day window
        beyondWindowTask.isDueDateOnly = false

        for task in [overdueTask, inWindowTask, beyondWindowTask] {
            context.insert(task)
        }
        try context.save()

        // No lists passed in, so the per-list "head of 50" bonus rule (which
        // would otherwise pull in every active task in a list regardless of due
        // date) can't interfere with the window-scoping assertion below.
        let snapshot = WatchSnapshotBuilder.build(
            tasks: [overdueTask, inWindowTask, beyondWindowTask],
            lists: [],
            isProUnlocked: true,
            defaultListID: nil,
            now: now,
            calendar: calendar
        )

        // Presence + exact ordering: overdue first, then ascending due date.
        #expect(snapshot.tasks.map(\.uid) == [overdueTask.uid, inWindowTask.uid])
        // Absence: the beyond-7-day task must not sneak in.
        #expect(!snapshot.tasks.contains { $0.uid == beyondWindowTask.uid })
        #expect(snapshot.tasks.count == 2)
        // Well under `taskCap`, so `truncated` must be false (no test anywhere
        // else asserts this — a hardcoded `truncated = true` would still pass
        // every other test in this file).
        #expect(snapshot.truncated == false)
    }

    @Test func dateOnlyTaskDueTodayIsIncludedAndKeepsFlag() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let todayTask = TaskItem(title: "Date-only, due today")
        // Midnight-UTC value carrying "now"'s local calendar day, exactly as
        // DueDateHelper expects a VALUE=DATE due date to be stored.
        todayTask.dueDate = DueDateHelper.dateOnlyValue(for: now, calendar: calendar)
        todayTask.isDueDateOnly = true

        // A genuinely overdue timed task and a timed task due in 3 days. These
        // pin down *where in the ordering* the date-only task lands — proving
        // correct window placement, not just inclusion. A naive implementation
        // that compares `now` against the raw midnight-UTC `dueDate` instead of
        // composing `DueDateHelper.effectiveDeadline` would also include
        // `todayTask` (its raw stored value is `< windowEnd` too), but it would
        // misrank it as overdue (rank 0) instead of merely due (rank 1): the raw
        // stored value sits hours in the past relative to `now` (it's midnight
        // UTC of "today", not end-of-local-day), which is *more* in the past than
        // `overdueTask`'s due date (1 hour ago) — flipping the two tasks' order.
        let overdueTask = TaskItem(title: "Genuinely overdue")
        overdueTask.dueDate = now.addingTimeInterval(-3_600) // 1 hour ago
        overdueTask.isDueDateOnly = false

        let dueIn3DaysTask = TaskItem(title: "Due in 3 days")
        dueIn3DaysTask.dueDate = now.addingTimeInterval(3 * 86_400)
        dueIn3DaysTask.isDueDateOnly = false

        for task in [todayTask, overdueTask, dueIn3DaysTask] {
            context.insert(task)
        }
        try context.save()

        let snapshot = WatchSnapshotBuilder.build(
            tasks: [todayTask, overdueTask, dueIn3DaysTask],
            lists: [],
            isProUnlocked: true,
            defaultListID: nil,
            now: now,
            calendar: calendar
        )

        // Presence, and correct window placement: overdue task first (rank 0),
        // then the date-only "due today" task (rank 1, NOT overdue), then the
        // due-in-3-days task (rank 1, later due date).
        #expect(snapshot.tasks.map(\.uid) == [overdueTask.uid, todayTask.uid, dueIn3DaysTask.uid])

        // The flag must survive the *actual* wire round trip (JSON via
        // contextDictionary), not just live in the in-memory struct.
        let dict = try snapshot.contextDictionary()
        let decoded = try #require(WatchSnapshot(contextDictionary: dict))
        #expect(decoded.tasks.first { $0.uid == todayTask.uid }?.isDueDateOnly == true)
    }

    @Test func completedAndSoftDeletedTasksAreExcluded() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let completedTask = TaskItem(title: "Already done", status: .completed)
        completedTask.dueDate = now.addingTimeInterval(3_600) // would be in-window if active

        // Soft-deleted (isDeletedLocally): queued for a DELETE on next push, but
        // not yet hard-deleted from SwiftData — must not appear on the wrist
        // (decision D3). Not `.completed`, so this exercises the OTHER half of
        // the `active` filter's `&&`.
        let deletedTask = TaskItem(title: "Soft-deleted")
        deletedTask.dueDate = now.addingTimeInterval(3_600) // would be in-window if active
        deletedTask.isDeletedLocally = true

        for task in [completedTask, deletedTask] {
            context.insert(task)
        }
        try context.save()

        let snapshot = WatchSnapshotBuilder.build(
            tasks: [completedTask, deletedTask],
            lists: [],
            isProUnlocked: true,
            defaultListID: nil,
            now: now,
            calendar: calendar
        )

        #expect(snapshot.tasks.isEmpty)
    }

    @Test func capAt400SetsTruncated() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        var tasks: [TaskItem] = []
        for index in 0..<450 {
            let task = TaskItem(title: "Task \(index)")
            task.dueDate = now.addingTimeInterval(86_400) // due tomorrow, inside the window
            context.insert(task)
            tasks.append(task)
        }
        try context.save()

        let snapshot = WatchSnapshotBuilder.build(
            tasks: tasks,
            lists: [],
            isProUnlocked: true,
            defaultListID: nil,
            now: now,
            calendar: calendar
        )

        #expect(snapshot.tasks.count == 400)
        #expect(snapshot.truncated == true)
    }

    @Test func listMetaCarriesCountsAndColor() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let workList = TaskList(serverURL: "https://example.com/dav", name: "Work", colorHex: "#FF00FF")
        let homeList = TaskList(serverURL: "https://example.com/dav", name: "Home", colorHex: "#00FF00")
        context.insert(workList)
        context.insert(homeList)

        let active1 = TaskItem(title: "Active 1")
        active1.taskList = workList
        let active2 = TaskItem(title: "Active 2")
        active2.taskList = workList
        let completed = TaskItem(title: "Done", status: .completed)
        completed.taskList = workList

        // A second list with its own single active task. Without this, replacing
        // `activeTaskCount`'s per-list filter with a plain `active.count` (all
        // tasks across every list) would still yield 2 for `workList` and this
        // test wouldn't notice — the scoping bug would be invisible.
        let homeActive = TaskItem(title: "Home Active")
        homeActive.taskList = homeList

        for task in [active1, active2, completed, homeActive] {
            context.insert(task)
        }
        try context.save()

        let snapshot = WatchSnapshotBuilder.build(
            tasks: [active1, active2, completed, homeActive],
            lists: [workList, homeList],
            isProUnlocked: true,
            defaultListID: nil,
            now: now,
            calendar: calendar
        )

        #expect(snapshot.lists.count == 2)
        let workMeta = try #require(snapshot.lists.first { $0.id == workList.id })
        #expect(workMeta.name == "Work")
        #expect(workMeta.colorHex == workList.colorHex)
        // Only the 2 active Work tasks count — the completed one must not, and
        // Home's active task must not leak in (proves per-list scoping, not just
        // a global active count).
        #expect(workMeta.activeTaskCount == 2)

        let homeMeta = try #require(snapshot.lists.first { $0.id == homeList.id })
        #expect(homeMeta.name == "Home")
        #expect(homeMeta.colorHex == homeList.colorHex)
        #expect(homeMeta.activeTaskCount == 1)
    }

    /// Exercises Rule 2 (per-list head of `perListHead`) and Rule 3 (uid dedupe)
    /// together — every other test in this file passes `lists: []`, so the head
    /// loop never runs, and the one test that does pass a non-empty `lists:`
    /// (`listMetaCarriesCountsAndColor`) never asserts on `snapshot.tasks`. That
    /// leaves `perListHead = 50`, the `.prefix(perListHead)` cutoff, and the uid
    /// dedupe `filter` completely unfalsifiable without this test.
    @Test func perListHeadCapsAtFiftyAndDedupesAgainstWindowedTasks() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let list = TaskList(serverURL: "https://example.com/dav", name: "Backlog", colorHex: "#0000FF")
        context.insert(list)

        // Qualifies under BOTH Rule 1 (due tomorrow, inside the 7-day window) and
        // Rule 2 (lowest sort order in the list, so it lands in the head-of-50) —
        // this is what makes it a dedupe witness: it appears twice in the
        // pre-dedupe concatenation (`windowed` + `perListPicks`), and must appear
        // exactly once in the final snapshot.
        let dueTomorrowTask = TaskItem(title: "Due tomorrow")
        dueTomorrowTask.dueDate = now.addingTimeInterval(86_400)
        dueTomorrowTask.isDueDateOnly = false
        dueTomorrowTask.taskList = list
        dueTomorrowTask.manualSortOrder = 1 // smallest — guarantees a head slot

        // 60 active, no-due-date tasks in the same list, each with a distinct,
        // explicit `manualSortOrder` (never 0 — that's the "unseeded legacy row"
        // sentinel that falls back to `createdDate`, which would make ordering
        // depend on wall-clock creation time instead of this assignment).
        var noDueTasks: [TaskItem] = []
        for index in 0..<60 {
            let task = TaskItem(title: "No due date \(index)")
            task.taskList = list
            task.manualSortOrder = index + 2 // 2...61, all larger than dueTomorrowTask's 1
            noDueTasks.append(task)
        }

        for task in [dueTomorrowTask] + noDueTasks {
            context.insert(task)
        }
        try context.save()

        let snapshot = WatchSnapshotBuilder.build(
            tasks: [dueTomorrowTask] + noDueTasks,
            lists: [list],
            isProUnlocked: true,
            defaultListID: nil,
            now: now,
            calendar: calendar
        )

        // The list has 61 active tasks total (60 no-due + 1 due-tomorrow); the
        // head selects the 50 with the smallest `effectiveSortOrder`:
        // dueTomorrowTask (sortOrder 1) + the 49 no-due tasks with the smallest
        // sort orders (noDueTasks[0...48], sortOrder 2...50). noDueTasks[49]
        // (sortOrder 51 — 51st-ranked in the list) misses the head cutoff, and
        // (having no due date) doesn't qualify via Rule 1 either, so it's absent.
        let expectedPresent = [dueTomorrowTask] + noDueTasks[0..<49]
        let expectedAbsent = noDueTasks[49..<60]

        // Exact ordering: dueTomorrowTask (rank 1, has a due date) first, then
        // the 49 admitted no-due-date tasks (rank 2) in ascending
        // `effectiveSortOrder`. This single equality proves the head cutoff is
        // exactly 50 (not unlimited, not some other number) and that dedupe
        // collapsed dueTomorrowTask's two qualifying paths into one entry.
        // (NOT a discriminator for the *final* sort's rank-2 tie-break in
        // isolation: with a single list, the per-list head selection below has
        // already sorted these by `effectiveSortOrder`, and Swift's `sorted` is
        // stable, so that ordering survives even if the final sort's own
        // tie-break were deleted. See
        // `noDueDateTasksAcrossListsAreGloballyOrderedByEffectiveSortOrder` for a
        // test that isolates that line specifically.)
        #expect(snapshot.tasks.map(\.uid) == expectedPresent.map(\.uid))

        // Dedupe, stated directly per the review's ask: present exactly once,
        // not twice, despite qualifying under both Rule 1 and Rule 2.
        #expect(snapshot.tasks.filter { $0.uid == dueTomorrowTask.uid }.count == 1)

        // The 51st-ranked task (first one past the head cutoff) must be absent.
        #expect(!snapshot.tasks.contains { $0.uid == noDueTasks[49].uid })
        for task in expectedAbsent {
            #expect(!snapshot.tasks.contains { $0.uid == task.uid })
        }
    }

    /// Isolates Rule 4's rank-2 (no-due-date) tie-break — `deduped.sorted`'s
    /// `default: return lhs.effectiveSortOrder < rhs.effectiveSortOrder` branch —
    /// from the per-list head selection's own `.sorted { effectiveSortOrder }`.
    ///
    /// With only one list, the per-list head is already sorted correctly, and
    /// Swift's `sorted(by:)` is stable, so the final sort's own comparator can be
    /// deleted without this file's other tests noticing (confirmed by actually
    /// deleting it locally). Two lists whose per-list-sorted contributions are
    /// concatenated in *list* order — which is NOT the same as the globally
    /// sorted order once interleaved — forces the final sort to do real work.
    @Test func noDueDateTasksAcrossListsAreGloballyOrderedByEffectiveSortOrder() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let listA = TaskList(serverURL: "https://example.com/dav", name: "List A", colorHex: "#111111")
        let listB = TaskList(serverURL: "https://example.com/dav", name: "List B", colorHex: "#222222")
        context.insert(listA)
        context.insert(listB)

        // Interleaved sort orders: within each list, ascending; but concatenated
        // list-by-list (A's picks then B's picks, since that's how `perListPicks`
        // is built), the order is [10, 30, 20, 40] — NOT globally ascending. Only
        // a real final sort by `effectiveSortOrder` produces [10, 20, 30, 40].
        let taskA1 = TaskItem(title: "A1, sortOrder 10")
        taskA1.taskList = listA
        taskA1.manualSortOrder = 10
        let taskA2 = TaskItem(title: "A2, sortOrder 30")
        taskA2.taskList = listA
        taskA2.manualSortOrder = 30

        let taskB1 = TaskItem(title: "B1, sortOrder 20")
        taskB1.taskList = listB
        taskB1.manualSortOrder = 20
        let taskB2 = TaskItem(title: "B2, sortOrder 40")
        taskB2.taskList = listB
        taskB2.manualSortOrder = 40

        for task in [taskA1, taskA2, taskB1, taskB2] {
            context.insert(task)
        }
        try context.save()

        let snapshot = WatchSnapshotBuilder.build(
            tasks: [taskA1, taskA2, taskB1, taskB2],
            lists: [listA, listB],
            isProUnlocked: true,
            defaultListID: nil,
            now: now,
            calendar: calendar
        )

        #expect(snapshot.tasks.map(\.uid) == [taskA1.uid, taskB1.uid, taskA2.uid, taskB2.uid])
    }

    @Test func entitlementAndDefaultListPassThrough() throws {
        let snapshot = WatchSnapshotBuilder.build(
            tasks: [],
            lists: [],
            isProUnlocked: false,
            defaultListID: "L9",
            now: now,
            calendar: calendar
        )

        #expect(snapshot.isProUnlocked == false)
        #expect(snapshot.defaultListID == "L9")
        #expect(snapshot.generatedAt == now)
        #expect(snapshot.schemaVersion == WatchSnapshot.currentSchemaVersion)
    }
}
