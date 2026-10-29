import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - SmartListCounts Tests
//
// `SmartListsSection` used to hold a `@Query` over every `TaskItem` and
// recompute all five smart-list counts inside `body` on every render — a full
// walk of every task doing per-task calendar math, ~90 ms at 1,650 tasks, run
// 3-9 times per add or complete. `SmartListCounts.compute` is the pure
// aggregation extracted from that loop; `fetch` runs it against a background
// `ModelContext`; `SmartListCountsModel` republishes the result once per save.

@Suite("Smart List Counts")
struct SmartListCountsTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(SchemaV2.models)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("compute applies the sidebar rules")
    func computeAppliesSidebarRules() throws {
        let now = try #require(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))

        let rows: [SmartListCounts.Row] = [
            // completed, timed now - 2h → completed only
            .init(isCompleted: true, dueDate: now.addingTimeInterval(-2 * 3600), isDueDateOnly: false),
            // active, no due → all only
            .init(isCompleted: false, dueDate: nil, isDueDateOnly: false),
            // active, timed now - 2h → all, today, overdue
            .init(isCompleted: false, dueDate: now.addingTimeInterval(-2 * 3600), isDueDateOnly: false),
            // active, timed now + 2h → all, today, upcoming
            .init(isCompleted: false, dueDate: now.addingTimeInterval(2 * 3600), isDueDateOnly: false),
            // active, timed now + 3 days → all, upcoming
            .init(isCompleted: false, dueDate: now.addingTimeInterval(3 * 86400), isDueDateOnly: false),
            // active, timed now + 10 days → all only
            .init(isCompleted: false, dueDate: now.addingTimeInterval(10 * 86400), isDueDateOnly: false),
            // active, date-only yesterday → all, today, overdue
            .init(
                isCompleted: false,
                dueDate: DueDateHelper.dateOnlyValue(for: now.addingTimeInterval(-86400)),
                isDueDateOnly: true
            )
        ]

        let counts = SmartListCounts.compute(rows: rows, now: now)

        #expect(counts == SmartListCounts(today: 3, upcoming: 2, overdue: 2, all: 6, completed: 1))
    }

    @Test("fetch counts only live roots")
    func fetchCountsOnlyLiveRoots() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let root = TaskItem(title: "Root, no due date", priority: .none)
        context.insert(root)

        let subtask = TaskItem(title: "Subtask", priority: .none)
        subtask.parentTask = root
        subtask.parentUID = root.uid
        context.insert(subtask)

        let deletedRoot = TaskItem(title: "Soft-deleted root", priority: .none)
        deletedRoot.isDeletedLocally = true
        context.insert(deletedRoot)

        let completedRoot = TaskItem(title: "Completed root", priority: .none, status: .completed)
        context.insert(completedRoot)

        try context.save()

        let counts = try SmartListCounts.fetch(from: container)

        #expect(counts.all == 1)
        #expect(counts.completed == 1)
        #expect(counts.today == 0)
        #expect(counts.upcoming == 0)
        #expect(counts.overdue == 0)
    }

    @Test("the model publishes after another context saves")
    @MainActor
    func modelPublishesAfterAnotherContextSaves() async throws {
        let container = try makeContainer()

        // Seed one active root *before* `start`, so the model's own initial
        // fetch has something to find. This is what makes the first poll
        // below prove the initial fetch actually ran, instead of merely
        // observing the model's zero-valued starting state.
        let seedContext = ModelContext(container)
        seedContext.insert(TaskItem(title: "First"))
        try seedContext.save()

        let model = SmartListCountsModel(debounce: .milliseconds(10))
        model.start(container: container)

        for _ in 0..<40 {
            if model.counts.all == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(model.counts.all == 1)

        // Saved off the main actor, on a fresh context — the shape of a
        // `SyncEngine` background-context save, which is exactly what the
        // `didSave` observer must pick up regardless of which context posted
        // the notification.
        try await Task.detached {
            let otherContext = ModelContext(container)
            otherContext.insert(TaskItem(title: "Second"))
            try otherContext.save()
        }.value

        for _ in 0..<40 {
            if model.counts.all == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.counts.all == 2)
    }

    /// A slow, older fetch racing a fast, newer one must not win: the model
    /// must keep whichever result belongs to the most recently started
    /// `refreshNow()`, not whichever detached fetch happens to finish last.
    ///
    /// The order is pinned by construction, not by timing. The injected
    /// `fetch` closure counts its own calls behind a lock: call 1 (`start`'s
    /// own immediate refresh) returns right away; call 2 — claimed by the
    /// OLDER `refreshNow()` started explicitly below — blocks on a
    /// `DispatchSemaphore` until the test signals it; call 3 and later —
    /// claimed by the NEWER `refreshNow()` — return immediately. The test
    /// waits (asynchronously, never blocking the main actor) until call 2 is
    /// actually inside the closure before running the newer refresh, so the
    /// newer refresh can only ever claim call 3. Only then does it release
    /// call 2 and confirm its now-stale result is rejected.
    @Test("a stale fetch does not overwrite counts a newer fetch already published")
    @MainActor
    func staleFetchDoesNotOverwriteNewerCounts() async throws {
        let container = try makeContainer()
        let counter = FetchCallCounter()

        let model = SmartListCountsModel(debounce: .milliseconds(10)) { _ in
            let call = counter.next()
            switch call {
            case 1:
                return SmartListCounts()
            case 2:
                counter.markEntered()
                counter.gate.wait()
                return SmartListCounts(all: 1)
            default:
                return SmartListCounts(all: 2)
            }
        }

        model.start(container: container)

        // Wait for call 1 — start's own immediate refresh — to have
        // happened, so the OLDER refresh below is guaranteed to claim call 2.
        for _ in 0..<200 {
            if counter.callCount >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(counter.callCount >= 1)

        // The OLDER refresh: claims call 2 and blocks inside the fetch
        // closure until the test signals `gate` below.
        let older = Task { @MainActor in await model.refreshNow() }

        // Wait until call 2 is actually inside the closure — not merely
        // dispatched — before starting the newer refresh below. Never block
        // the main actor with a semaphore wait here: the older task needs
        // the main actor free to dispatch its own detached fetch.
        for _ in 0..<200 {
            if counter.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(counter.entered)

        // The NEWER refresh: claims call 3, which returns immediately with
        // the fresh value.
        await model.refreshNow()
        #expect(model.counts.all == 2)

        // Release the OLDER fetch now that the newer counts are published.
        // Its result is stale; the generation guard must reject it rather
        // than let it overwrite the newer counts.
        counter.gate.signal()
        await older.value
        #expect(model.counts.all == 2)
    }
}

/// Thread-safe state for the injected `fetch` closure above: a lock-protected
/// call index that pins which physical call takes which branch, a
/// lock-protected `entered` flag the test polls to know the OLDER call is
/// actually blocked (not merely dispatched), and a semaphore the test signals
/// to release it. `SmartListCountsModel.refreshNow()` runs `fetch` inside
/// `Task.detached`, so competing calls can land on different threads at once
/// — bundling this state behind one lock is what pins the order by
/// construction instead of leaving it to whichever job reaches it first.
private final class FetchCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var _entered = false
    let gate = DispatchSemaphore(value: 0)

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func markEntered() {
        lock.lock()
        _entered = true
        lock.unlock()
    }

    var entered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _entered
    }
}
