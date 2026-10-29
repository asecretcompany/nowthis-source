import Foundation
import SwiftData

/// Helpers for task list display filtering.
enum TaskListHelpers {

    /// Removes duplicate tasks by UID, keeping the first occurrence.
    ///
    /// This is a safety net for cases where the same VTODO ends up
    /// in multiple local TaskList records (e.g., from overlapping
    /// calendar discovery).
    static func deduplicateByUID(_ tasks: [TaskItem]) -> [TaskItem] {
        var seen = Set<String>()
        return tasks.filter { task in
            guard seen.insert(task.uid).inserted else { return false }
            return true
        }
    }

    /// Sorts tasks by the given option while keeping completed tasks below all
    /// active ones, so a newly added (incomplete) task never lands under the
    /// "done" items. The chosen sort field (e.g. due date/time) is still
    /// honored *within* the active group and *within* the completed group.
    static func sortedWithCompletedLast(
        _ tasks: [TaskItem],
        by option: TaskSortOption,
        ascending: Bool
    ) -> [TaskItem] {
        let comparator = option.comparator(ascending: ascending)
        let active = tasks.filter { $0.status != .completed }.sorted(by: comparator)
        let completed = tasks.filter { $0.status == .completed }.sorted(by: comparator)
        return active + completed
    }

    /// Returns a parent task's subtasks in display order: non-deleted children
    /// sorted with completed ones pinned below active ones, honoring the chosen
    /// sort within each group — the same rule `displayedTasks` applies to the
    /// root list. Without this, subtasks render in arbitrary SwiftData
    /// relationship order, so their manual order (which round-trips to Nextcloud)
    /// and completed-at-bottom behavior are lost under a parent.
    ///
    /// Pure ordering, valid for any parent — including one that was never inserted
    /// into a context. **A view body must call `orderedSubtasksIfLive` instead**,
    /// which adds the liveness guard this function deliberately does not.
    static func orderedSubtasks(
        of parent: TaskItem,
        by option: TaskSortOption,
        ascending: Bool
    ) -> [TaskItem] {
        let active = parent.subtasks.filter { !$0.isDeletedLocally }
        return sortedWithCompletedLast(active, by: option, ascending: ascending)
    }

    /// `orderedSubtasks`, but empty for a parent whose backing row is gone.
    ///
    /// This is the one a view body wants. A row asks for its children *before* it
    /// checks its own liveness — the chevron, the expansion test and the drag
    /// payload all run first — so the traversal itself has to be safe. Reading
    /// `subtasks` on a task an account delete has cascaded away traps in SwiftData
    /// rather than returning nothing.
    ///
    /// The guard lives here rather than in `orderedSubtasks` because
    /// `modelContext == nil` is also true of a model that was *never inserted*,
    /// which is perfectly safe to read — and is how this type's own unit tests
    /// construct their fixtures. Conflating the two would make those tests
    /// silently assert nothing.
    static func orderedSubtasksIfLive(
        of parent: TaskItem,
        by option: TaskSortOption,
        ascending: Bool
    ) -> [TaskItem] {
        guard parent.modelContext != nil else { return [] }
        return orderedSubtasks(of: parent, by: option, ascending: ascending)
    }

    /// The subset of `tasks` whose backing row is still present in `context`'s store.
    ///
    /// The cheap liveness signal a view body reaches for — `modelContext != nil`,
    /// used by `TaskRowData.init?` and ``orderedSubtasksIfLive(of:by:ascending:)``
    /// — only catches a delete made on the **main** context, which detaches the
    /// model and nils its context. The `SyncEngine` deletes on its own
    /// **background** context instead (`reconcileDeletions` for a task the server
    /// dropped, `pushDeletion` after a successful DELETE), and nothing tells the
    /// main context: its `@Query` array still holds the task, still attached. The
    /// cheap guard passes, and the first attribute read then faults against a row
    /// that is no longer there — trapping inside `ModelContext.fulfill` rather
    /// than returning nothing:
    ///
    ///     TaskItem.status.getter
    ///     PersistentModel.getValue<A>(forKey:)
    ///     _KKMDBackingData.getValue<A>(forKey:)
    ///     ModelContext.fulfill<A, B>(_:of:for:)
    ///     DefaultStore.fulfill<A>(_:from:for:editingState:)
    ///
    /// This reads only `persistentModelID`, which resolves no fault, so it is
    /// safe to call on exactly the models it exists to catch.
    ///
    /// Fails **open**: if the identifier fetch itself throws, every task is
    /// returned. Blanking the user's list on a transient store error is a worse
    /// outcome than the narrow crash window this closes.
    static func liveTasks(_ tasks: [TaskItem], in context: ModelContext,
                          matching descriptor: FetchDescriptor<TaskItem> = FetchDescriptor<TaskItem>()) -> [TaskItem] {
        let interval = PerformanceTrace.begin("TaskProjection", count: tasks.count)
        defer { PerformanceTrace.end("TaskProjection", interval) }
        var scopedDescriptor = descriptor
        scopedDescriptor.includePendingChanges = true
        guard let identifiers = try? context.fetchIdentifiers(scopedDescriptor) else {
            return tasks
        }
        let live = Set(identifiers)
        return tasks.filter { live.contains($0.persistentModelID) }
    }

    /// Identifier checks precede attribute reads after a cross-context cascade.
    static func liveModels<Model: PersistentModel>(_ models: [Model], in context: ModelContext,
                                                  matching descriptor: FetchDescriptor<Model> = FetchDescriptor<Model>()) -> [Model] {
        var descriptor = descriptor
        descriptor.includePendingChanges = true
        guard let identifiers = try? context.fetchIdentifiers(descriptor) else { return models }
        let live = Set(identifiers)
        return models.filter { live.contains($0.persistentModelID) }
    }

    /// Marks a task **and everything beneath it** deleted, so each row gets its
    /// own DELETE.
    ///
    /// Only the row the user actually swiped used to be flagged. `findDeletedTasks`
    /// returns exactly the flagged rows, so only the parent's DELETE went out —
    /// and because `pushDeletion` hard-deletes on success, SwiftData's cascade
    /// then removed the children locally while their copies sat untouched on the
    /// server. The next pull re-created them with no parent to attach to, as
    /// top-level tasks. The user lost two subtasks and gained two strangers.
    ///
    /// Iterative rather than recursive, with a seen-set: a subtask tree is
    /// user-shaped and nests infinitely, and a cycle — however one got in — would
    /// otherwise hang the app rather than fail.
    ///
    /// Downwards only. Deleting a subtask is not deleting its parent.
    ///
    /// No liveness guard here on purpose: this is a mutation path, and every
    /// caller has already established that the task is live before offering to
    /// delete it. Adding one would also swallow a never-inserted model, which is
    /// indistinguishable from a deleted one and is how fixtures are built.
    /// - Returns: the `id` of every task marked, so the caller can cancel their
    ///   reminders. A subtask's notifications are as real as its parent's, and
    ///   the row that offers the delete only ever knew about one of them.
    @discardableResult
    static func markDeleted(_ task: TaskItem, now: Date = Date()) -> [String] {
        var stack = [task]
        var seen: Set<String> = []
        var marked: [String] = []
        while let current = stack.popLast() {
            guard seen.insert(current.id).inserted else { continue }
            current.isDeletedLocally = true
            current.isDirty = true
            current.lastModifiedDate = now
            marked.append(current.id)
            stack.append(contentsOf: current.subtasks)
        }
        return marked
    }

    /// Records that a task's tags were edited on this device.
    ///
    /// Call after mutating `task.tags`. None of the three editing paths did —
    /// the picker's toggle, the create-and-add field, and the x on a pill all
    /// mutated the relationship directly and left the task clean — and the two
    /// consequences were both invisible:
    ///
    /// - **It never reached the server.** The push reads `isDirty`, so a tag you
    ///   added here stayed here, and no other device ever saw it. Whatever the
    ///   inbound rule is, this is the half that has to work first: there is no
    ///   parity between a device and a server the device never tells.
    /// - **The next pull overwrote it.** The inbound gate refuses to apply
    ///   anything to a dirty task, which is exactly how an unpushed local edit is
    ///   protected — and a clean task has no such protection. Before `CATEGORIES`
    ///   were applied inbound at all this was hidden, because nothing overwrote
    ///   tags for the same reason nothing delivered them.
    ///
    /// Separate from ``TaskCompletionLogic`` because tags are a relationship, not
    /// a field: the caller has already made the change and this records it.
    static func markTagsChanged(on task: TaskItem, now: Date = Date()) {
        task.lastModifiedDate = now
        task.isDirty = true
    }

    /// How deep a task sits under its top-level ancestor. 0 for a top-level task.
    ///
    /// Cycle-guarded for the same reason as ``markDeleted(_:now:)``.
    static func depth(of task: TaskItem) -> Int {
        var depth = 0
        var seen: Set<String> = [task.id]
        var current = task.parentTask
        while let parent = current, seen.insert(parent.id).inserted {
            depth += 1
            current = parent.parentTask
        }
        return depth
    }

    /// Spacing between adjacent values when renumbering manual order. Comfortably
    /// larger than 1 so values stay distinct (and leave room for future inserts),
    /// while staying tiny next to the seconds-since-2001 scale Nextcloud uses.
    static let manualSortSpacing = 1024

    /// The `X-APPLE-SORT-ORDER` value Nextcloud Tasks computes for a task with no
    /// explicit manual order: the number of seconds between the task's creation
    /// and the 2001-01-01 reference epoch. Seeding our values on this scale lets
    /// manual ordering round-trip with Nextcloud rather than being clobbered.
    static func defaultSortOrder(for createdDate: Date) -> Int {
        Int(createdDate.timeIntervalSinceReferenceDate)
    }

    /// Returns a `manualSortOrder` value that places a newly inserted task above
    /// every existing task (lower values sort first), staying on Nextcloud's sort
    /// scale. Returns `0` when the list is empty, so the task keeps its seeded value.
    static func topSortOrder(forInsertingInto tasks: [TaskItem]) -> Int {
        guard let minimum = tasks.map(\.effectiveSortOrder).min() else { return 0 }
        return minimum - 1
    }

    /// Renumbers `manualSortOrder` to match the given display order, keeping the
    /// values on Nextcloud's `X-APPLE-SORT-ORDER` scale: the list is anchored at
    /// its smallest existing (effective) value and each subsequent task is spaced
    /// by `manualSortSpacing`. Any task whose value changes is marked dirty so the
    /// new order is pushed; tasks already in position are left untouched to avoid
    /// needless sync churn.
    static func assignManualOrder(_ orderedTasks: [TaskItem]) {
        guard let anchor = orderedTasks.map(\.effectiveSortOrder).min() else { return }
        for (index, task) in orderedTasks.enumerated() {
            let newValue = anchor + index * manualSortSpacing
            guard task.manualSortOrder != newValue else { continue }
            task.manualSortOrder = newValue
            task.isDirty = true
            task.lastModifiedDate = Date()
        }
    }

    /// Keeps the DELETEs that moves into `list` still owe, before `list` is deleted.
    ///
    /// `TaskList.tasks` cascades, so deleting the list takes a task just moved into
    /// it along with its pending-move fields — the only record that its old copy in
    /// the source list has not been removed yet. The source list's next pull would
    /// then re-import that copy, bringing back a task the user deleted. Each such
    /// move leaves a tombstone in its source list instead, which the ordinary
    /// deletion push flushes. The moved task itself still goes with the list.
    ///
    /// The caller deletes the list and saves.
    static func settlePendingMoves(beforeDeleting list: TaskList, in modelContext: ModelContext) {
        let listID = list.id
        let moved = (try? modelContext.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.taskList?.id == listID && $0.pendingMoveFromHref != nil }
        ))) ?? []
        for task in moved {
            guard let href = task.pendingMoveFromHref, let sourceID = task.pendingMoveFromListID else { continue }
            var descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == sourceID })
            descriptor.fetchLimit = 1
            guard let source = try? modelContext.fetch(descriptor).first else { continue }
            // No etag: the move discarded the source copy's, and the DELETE is owed regardless.
            TaskMover.insertTombstone(for: task, href: href, etag: nil, in: source, context: modelContext)
        }
    }

    /// Removes duplicate TaskItems from the data store, keeping the newest per UID.
    ///
    /// Scans non-deleted TaskItems, groups by `uid`, and for any UID with
    /// more than one TaskItem, deletes all but the one with the latest
    /// `lastModifiedDate`. The caller must save the context after calling this.
    ///
    /// - Parameters:
    ///   - modelContext: The SwiftData model context to operate on.
    ///   - listID: Restricts the scan to one list. `nil` scans the whole store, which is
    ///     what a caller with no particular collection in hand wants; sync names the
    ///     collection it just pulled instead of walking every account on the device.
    /// - Returns: The number of duplicate TaskItems removed.
    @discardableResult
    static func cleanupDuplicateUIDs(in modelContext: ModelContext, listID: String? = nil) -> Int {
        let allTasks: [TaskItem]
        do {
            // Scoped when the caller names a list. Sync passes the collection it just
            // pulled, so one account's sync stops walking every other account's tasks —
            // and a duplicate can only arise within the collection that carries the UID.
            let descriptor: FetchDescriptor<TaskItem>
            if let listID {
                descriptor = FetchDescriptor<TaskItem>(
                    predicate: #Predicate { !$0.isDeletedLocally && $0.taskList?.id == listID }
                )
            } else {
                descriptor = FetchDescriptor<TaskItem>(
                    predicate: #Predicate { !$0.isDeletedLocally }
                )
            }
            allTasks = try modelContext.fetch(descriptor)
        } catch {
            return 0
        }

        // Group by UID
        var uidGroups: [String: [TaskItem]] = [:]
        for task in allTasks {
            uidGroups[task.uid, default: []].append(task)
        }

        var removedCount = 0
        for (_, group) in uidGroups where group.count > 1 {
            // Sort by lastModifiedDate descending — keep the first (newest)
            let sorted = group.sorted {
                ($0.lastModifiedDate ?? .distantPast) > ($1.lastModifiedDate ?? .distantPast)
            }
            for duplicate in sorted.dropFirst() {
                modelContext.delete(duplicate)
                removedCount += 1
            }
        }

        return removedCount
    }

    /// The occurrences the Upcoming / Overdue smart lists show for an
    /// already-filtered set of tasks, sorted by occurrence date.
    ///
    /// `tasks` must already be liveness-checked, de-duplicated and filtered by the
    /// caller; this function only decides *which dated instances* of them appear.
    ///
    /// **A task contributes exactly one occurrence, at its own `dueDate` — never one
    /// per recurrence instance.** For Upcoming that date *is* the next occurrence, since
    /// the list only admits tasks still due ahead of `now`; for Overdue it is the
    /// instance actually waiting to be completed.
    ///
    /// These lists used to project a recurring task's further instances into extra rows,
    /// and both halves of that were wrong. A row renders from `TaskRowData`, which
    /// snapshots `task.dueDate`, so every projected row of a daily task showed the *base*
    /// date: a task due Aug 30 at 20:15 sorted correctly into Aug 31's slot and then
    /// printed "Aug 30 at 20:15" there. The occurrence date reached the sort, the section
    /// header and the accessibility label, but never the badge the reader actually sees.
    /// The checkbox was wrong for the same reason — every projected row completed the one
    /// underlying task, advancing the series no matter which instance was tapped.
    ///
    /// Collapsing to the single real instance fixes both at once, and needs no checkbox
    /// gate: `occurrenceDate == task.dueDate` holds for every result, so the date on a row
    /// and the task its checkbox completes cannot drift apart.
    /// `RecurringOccurrenceCollapseTests` pins that invariant.
    static func occurrences(
        from tasks: [TaskItem],
        smartList: SmartList,
        now: Date
    ) -> [TaskOccurrence] {
        var occurrences: [TaskOccurrence] = []

        if smartList == .upcoming {
            // Upcoming: 4 weeks out
            let cutoff = Calendar.current.date(byAdding: .day, value: 28, to: now) ?? now

            for task in tasks {
                guard let due = task.dueDate, due >= now else { continue }

                // The task's own due date (if within window)
                if due <= cutoff {
                    occurrences.append(TaskOccurrence(task: task, occurrenceDate: due))
                }
            }
        } else {
            for task in tasks {
                guard let due = task.dueDate else { continue }
                guard DueDateHelper.isOverdue(dueDate: due, isDateOnly: task.isDueDateOnly) else { continue }

                occurrences.append(TaskOccurrence(task: task, occurrenceDate: due))
            }
        }

        occurrences.sort { $0.occurrenceDate < $1.occurrenceDate }
        return occurrences
    }
}
