import Foundation
import SwiftData
import SwiftUI

/// The sidebar's five smart-list counts, computed off the main actor instead
/// of inside `SmartListsSection`'s `body`.
///
/// The section used to hold a `@Query` over every `TaskItem` and recompute all
/// five counts on every render — a full walk of every task doing per-task
/// calendar math, ~90 ms at 1,650 tasks, run 3-9 times per add or complete.
/// This type separates the pure aggregation (`compute`) from the SwiftData
/// fetch (`fetch`), so the walk can run on a background `ModelContext` and the
/// result can be tested without a container at all.
struct SmartListCounts: Equatable, Sendable {
    var today = 0
    var upcoming = 0
    var overdue = 0
    var all = 0
    var completed = 0

    subscript(_ list: SmartList) -> Int {
        switch list {
        case .today: return today
        case .upcoming: return upcoming
        case .overdue: return overdue
        case .all: return all
        case .completed: return completed
        }
    }

    /// The fields `compute` needs from one root `TaskItem`, read while the
    /// model is alive on `fetch`'s own context — no live model crosses back
    /// to the caller.
    struct Row: Sendable {
        let isCompleted: Bool
        let dueDate: Date?
        let isDueDateOnly: Bool
    }

    /// Pure aggregation mirroring the rules the old per-render loop applied.
    ///
    /// `rows` must already be roots (`parentTask == nil`) that are not
    /// `isDeletedLocally` — `fetch`'s predicate guarantees this before mapping
    /// to `Row`. Only `.completed` tasks are excluded from `all`; cancelled
    /// tasks still count there.
    static func compute(rows: [Row], now: Date) -> SmartListCounts {
        var counts = SmartListCounts()
        let endOfWeek = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now

        for row in rows {
            if row.isCompleted {
                counts.completed += 1
                continue
            }

            counts.all += 1

            guard let due = row.dueDate else { continue }

            if TaskListFilter.shouldIncludeInToday(
                dueDate: due,
                isDueDateOnly: row.isDueDateOnly,
                isCompleted: false,
                now: now
            ) {
                counts.today += 1
            }
            if due >= now && due <= endOfWeek {
                counts.upcoming += 1
            }
            if now >= DueDateHelper.effectiveDeadline(for: due, isDateOnly: row.isDueDateOnly) {
                counts.overdue += 1
            }
        }

        return counts
    }

    /// Fetches on a `ModelContext` of its own — never the caller's main one —
    /// so the walk over every root task runs off whichever actor calls this.
    static func fetch(from container: ModelContainer, now: Date = Date()) throws -> SmartListCounts {
        let context = ModelContext(container)
        let predicate = #Predicate<TaskItem> { !$0.isDeletedLocally && $0.parentTask == nil }
        let roots = try context.fetch(FetchDescriptor<TaskItem>(predicate: predicate))
        let rows = roots.map {
            Row(isCompleted: $0.status == .completed, dueDate: $0.dueDate, isDueDateOnly: $0.isDueDateOnly)
        }
        return compute(rows: rows, now: now)
    }
}

/// Publishes ``SmartListCounts`` for `SmartListsSection`, refreshed from a
/// background fetch instead of recomputed on every render.
///
/// Observes `ModelContext.didSave` from **any** context, not just the main
/// one — the sync engine commits inbound tasks on its own background context
/// (see `SyncEngine`), which a `@Query` bound to the main context never
/// observes. A burst of saves (checking off several tasks, or a multi-task
/// sync pull) is coalesced into a single background walk by the debounce.
@MainActor
final class SmartListCountsModel: ObservableObject {
    @Published private(set) var counts = SmartListCounts()

    private let debounce: Duration
    private let fetch: @Sendable (ModelContainer) throws -> SmartListCounts
    private var container: ModelContainer?
    /// `nonisolated(unsafe)`: `deinit` on a `@MainActor` class is itself
    /// nonisolated and can run on whatever thread releases the last
    /// reference — which, now that saves (and therefore the `Task { @MainActor
    /// ... }` hops they schedule) happen off the main actor, is no longer
    /// guaranteed to be main. `MainActor.assumeIsolated` would trap in that
    /// case, and `deinit` cannot `await` its way onto the main actor to avoid
    /// it. `NSObjectProtocol` observer tokens are safe to remove from any
    /// thread, so this property opts out of actor isolation instead.
    private nonisolated(unsafe) var saveObserver: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    /// Bumped at the start of every `refreshNow()`. A detached fetch only
    /// publishes its result if this is still the generation it captured,
    /// so a slow fetch that finishes after a newer one started can't
    /// overwrite fresher counts.
    private var generation = 0

    init(
        debounce: Duration = .milliseconds(300),
        fetch: @escaping @Sendable (ModelContainer) throws -> SmartListCounts = { try SmartListCounts.fetch(from: $0) }
    ) {
        self.debounce = debounce
        self.fetch = fetch
    }

    /// Starts observing saves and fetches the first snapshot. Idempotent:
    /// `SmartListsSection` starts this from a `.task`, which can re-run (e.g.
    /// when the view reappears — scene activation is handled separately, by
    /// `onChange(of: scenePhase)`), and a second call must not register a
    /// second observer or replace the container mid-flight.
    func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container

        // `object: nil` catches saves from any context. `queue: nil` runs
        // this block synchronously on the posting thread instead of hopping
        // to main first: NotificationCenter makes the poster wait for a
        // `queue: .main` block to run on main, so a save from `SyncEngine`'s
        // background context (or any cooperative-pool save) would otherwise
        // wait out a main-thread stall before `save()` could even return.
        // Hopping to the main actor ourselves — after the notification has
        // already fired, off whatever thread posted it — keeps
        // `scheduleRefresh`'s `@MainActor` state isolated without making the
        // saver wait for it.
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }

        Task { await refreshNow() }
    }

    /// Cancels any pending debounce and starts a new one, so a burst of saves
    /// collapses into one fetch instead of one per save.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled else { return }
            await self.refreshNow()
        }
    }

    /// Runs `fetch` inside `Task.detached`, so the fetch and its walk over
    /// every root task never touch the main actor. Republishes only when the
    /// result changed and its generation is still current — see
    /// `generation` — so an older fetch that finishes late can't overwrite
    /// newer counts. A thrown fetch leaves the last-known counts in place
    /// rather than resetting to zero.
    func refreshNow() async {
        guard let container else { return }
        generation += 1
        let thisGeneration = generation
        let fetch = self.fetch
        let result = await Task.detached(priority: .userInitiated) {
            try? fetch(container)
        }.value

        guard thisGeneration == generation, let result, result != counts else { return }
        counts = result
    }

    deinit {
        if let saveObserver {
            NotificationCenter.default.removeObserver(saveObserver)
        }
    }
}
