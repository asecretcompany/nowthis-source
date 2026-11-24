import Foundation
import SwiftData
import SwiftUI

/// Helpers for task list display filtering.
enum TaskListHelpers {

    /// Search precedes UID deduplication: another copy of a task may be the
    /// one whose title or metadata matches the user's query.
    static func searchAndDeduplicate(_ sortedTasks: [TaskItem], query: String) -> [TaskItem] {
        let matching = query.isEmpty ? sortedTasks : sortedTasks.filter { matchesSearch($0, query: query) }
        return deduplicateByUID(matching)
    }

    static func matchesSearch(_ task: TaskItem, query: String) -> Bool {
        // Preserve locale-aware case/diacritic folding and metadata matches.
        task.title.localizedStandardContains(query)
            || (task.descriptionText?.localizedStandardContains(query) ?? false)
            || (task.locationName?.localizedStandardContains(query) ?? false)
            || task.tags.contains { $0.name.localizedStandardContains(query) }
    }


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
        markDeleted(deletionSubtree(of: task), now: now)
    }

    /// Marks an already-admitted exact write set without walking the relationship tree again.
    @discardableResult
    static func markDeleted(_ admitted: [TaskItem], now: Date = Date()) -> [String] {
        for current in admitted {
            current.isDeletedLocally = true
            current.isDirty = true
            current.lastModifiedDate = now
        }
        return admitted.map(\.id)
    }

    /// The deletion walk includes deleted intermediate nodes: their active descendants
    /// still need tombstones before server cleanup can cascade through the branch.
    /// Keep the original ID-based seen set, order, and never-inserted fixture support.
    static func deletionSubtree(of task: TaskItem) -> [TaskItem] {
        var stack = [task]
        var seen: Set<String> = []
        var subtree: [TaskItem] = []
        while let current = stack.popLast() {
            guard seen.insert(current.id).inserted else { continue }
            subtree.append(current)
            stack.append(contentsOf: current.subtasks)
        }
        return subtree
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

    /// Offsets a rank in the usable integer sequence, which skips the legacy
    /// unset value 0. The wider result lets callers check bounds before storing it.
    static func manualRank(offset: Int128, from anchor: Int) -> Int128 {
        let rank = Int128(anchor) + offset
        if anchor < 0 && rank >= 0 { return rank + 1 }
        if anchor > 0 && rank <= 0 { return rank - 1 }
        return rank
    }

    /// Returns a lower rank than the current roots, or nil when they exhaust the lower
    /// bound. A legacy row can have different displayed (raw) and synced ranks.
    /// Return 0 for an empty scope so the new task uses its creation-date rank.
    static func topSortOrder(forInsertingInto tasks: [TaskItem]) -> Int? {
        guard let minimum = tasks.lazy.map({ min($0.manualSortOrder, $0.effectiveSortOrder) }).min() else { return 0 }
        return Int(exactly: manualRank(offset: -1, from: minimum))
    }

    @MainActor
    static func saveInlineTask(_ task: TaskItem, withLowerRankThan liveRoots: [TaskItem],
                               manualAscending: Bool, in context: ModelContext,
                               errorState: ErrorState? = nil, save: (() throws -> Void)? = nil) -> Bool {
        let ranks: (assignments: [(task: TaskItem, rank: Int)], normalizing: Bool)
        do {
            ranks = try inlineRankAssignments(task, liveRoots: liveRoots,
                manualAscending: manualAscending, in: context)
            let eligibility = TaskWriteEligibility(writingIn: context)
            let destination = task.taskList.map {
                TaskWriteEligibility.CreationDestination.list(id: $0.id, expectedPersistentID: $0.persistentModelID)
            } ?? .unbound
            _ = try eligibility.destination(destination)
            try eligibility.tasks(ranks.assignments.map(\.task).filter { $0 !== task })
        } catch {
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState, creating: true)
            return false
        }

        let snapshots = ranks.assignments.map(\.task).filter { $0 !== task }.map {
            (task: $0, rank: $0.manualSortOrder, dirty: $0.isDirty, modified: $0.lastModifiedDate)
        }
        let existingTickets = Set(context.insertedModelsArray.compactMap { ($0 as? SyncMetadata)?.id })
        let now = Date()
        for assignment in ranks.assignments {
            if assignment.task === task && !ranks.normalizing {
                task.manualSortOrder = assignment.rank
            } else {
                setManualRank(assignment.rank, on: assignment.task, now: now)
            }
        }
        task.isDirty = true
        context.insert(task)
        do {
            // Keep old mirror hints until the shared commit is durable, so a
            // failed insertion only owns appended journal rows.
            try ReminderSchedulingJournal.saveTaskChanges(in: context,
                retireCalendarAdvisory: false, save: save)
            return true
        } catch {
            let id = task.id
            if context.insertedModelsArray.contains(where: { $0 === task }) {
                let tickets = context.insertedModelsArray.compactMap { $0 as? SyncMetadata }.filter {
                    !existingTickets.contains($0.id) && ($0.id.hasPrefix(ReminderSchedulingJournal.ticketPrefix)
                        || $0.id.hasPrefix(CalendarMirrorState.prefix))
                }
                context.delete(task)
                for ticket in tickets { context.delete(ticket) }
            } else {
                var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
                descriptor.includePendingChanges = false
                descriptor.fetchLimit = 1
                if let committed = try? ModelContext(context.container).fetch(descriptor).first,
                   committed.persistentModelID == task.persistentModelID {
                    CalendarMirrorState.publishCommit(in: context.container, includesTaskChanges: true)
                    return true
                }
            }
            for snapshot in snapshots {
                snapshot.task.manualSortOrder = snapshot.rank
                snapshot.task.isDirty = snapshot.dirty
                snapshot.task.lastModifiedDate = snapshot.modified
            }
            ViewPersistence.report(error, to: errorState)
            return false
        }
    }

    private static func inlineRankAssignments(_ task: TaskItem, liveRoots: [TaskItem],
                                              manualAscending: Bool, in context: ModelContext)
        throws -> (assignments: [(task: TaskItem, rank: Int)], normalizing: Bool) {
        let draftID = task.persistentModelID
        if let rank = topSortOrder(forInsertingInto: liveRoots.filter { $0.persistentModelID != draftID }) {
            return ([(task, rank)], false)
        }
        // All Tasks can contain other lists' extreme ranks. Only the list
        // receiving this task can be renumbered to make room for it.
        let listID = task.taskList?.id
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate {
            !$0.isDeletedLocally && $0.parentTask == nil && $0.taskList?.id == listID
        }, sortBy: [SortDescriptor(\.createdDate), SortDescriptor(\.id)])
        let roots = try context.fetch(descriptor).filter { $0.persistentModelID != draftID }
        if let rank = topSortOrder(forInsertingInto: roots) { return ([(task, rank)], false) }

        // Keep the query's tie order, then append roots absent from the snapshot.
        var byID = Dictionary(uniqueKeysWithValues: roots.map { ($0.persistentModelID, $0) })
        let known = liveRoots.compactMap { byID.removeValue(forKey: $0.persistentModelID) }
        let newToSnapshot = roots.filter { byID[$0.persistentModelID] != nil }
        let ordered = (known + newToSnapshot).sorted(
            by: TaskSortOption.manually.comparator(ascending: manualAscending))
        return (manualOrderAssignments(manualAscending ? [task] + ordered : ordered + [task],
                                       ascending: manualAscending), true)
    }

    /// Assigns spaced ranks in the requested display direction. Prefer the
    /// existing minimum when the sequence fits with space at both ends.
    static func assignManualOrder(_ orderedTasks: [TaskItem], ascending: Bool) {
        let now = Date()
        for assignment in manualOrderAssignments(orderedTasks, ascending: ascending) {
            setManualRank(assignment.rank, on: assignment.task, now: now)
        }
    }

    static func manualOrderAssignments(_ orderedTasks: [TaskItem], ascending: Bool) -> [(task: TaskItem, rank: Int)] {
        guard let first = orderedTasks.first,
              let minimum = orderedTasks.lazy.map(\.effectiveSortOrder).min() else { return [] }
        let preferredSpacing = Int128(manualSortSpacing)
        let intervals = Int128(orderedTasks.count - 1)
        let range = Int128(Int.max) - Int128(Int.min) - 1 // Exclude zero.
        let spacing = (intervals + 2) * preferredSpacing <= range ? preferredSpacing : 1
        let lastOffset = intervals * spacing

        let preferredAnchor = minimum == 0 ? 1 : minimum
        let anchor: Int
        if Int(exactly: manualRank(offset: -spacing, from: preferredAnchor)) != nil,
           Int(exactly: manualRank(offset: lastOffset + spacing, from: preferredAnchor)) != nil {
            anchor = preferredAnchor
        } else {
            let seed = max(defaultSortOrder(for: first.createdDate), 1)
            anchor = Int(exactly: manualRank(offset: lastOffset + spacing, from: seed)) != nil
                ? seed : Int.min + Int(spacing)
        }

        return orderedTasks.enumerated().compactMap { index, task in
            let position = ascending ? index : orderedTasks.count - 1 - index
            let rank = Int(manualRank(offset: Int128(position) * spacing, from: anchor))
            return task.manualSortOrder == rank ? nil : (task, rank)
        }
    }

    static func setManualRank(_ rank: Int, on task: TaskItem, now: Date) {
        guard task.manualSortOrder != rank else { return }
        task.manualSortOrder = rank
        task.isDirty = true
        task.lastModifiedDate = now
    }

    @MainActor
    static func saveManualMove(_ displayed: [TaskItem], from source: IndexSet, to destination: Int,
                               ascending: Bool, in context: ModelContext,
                               matching descriptor: FetchDescriptor<TaskItem>,
                               errorState: ErrorState? = nil) -> Bool {
        guard !source.isEmpty, source.allSatisfy({ displayed.indices.contains($0) }),
              (0...displayed.count).contains(destination) else { return false }
        var scope = descriptor
        scope.includePendingChanges = true
        let live: Set<PersistentIdentifier>
        do {
            live = Set(try context.fetchIdentifiers(scope))
        } catch {
            ViewPersistence.report(error, to: errorState)
            return false
        }
        // A missing row invalidates the displayed offsets. Verify IDs before
        // reading any model attributes, which can fault after a sync deletion.
        guard displayed.allSatisfy({ live.contains($0.persistentModelID) }),
              displayed.allSatisfy({ $0.modelContext != nil && !$0.isDeletedLocally }) else { return false }
        var reordered = displayed
        reordered.move(fromOffsets: source, toOffset: destination)
        var assignments: [(task: TaskItem, rank: Int)] = []
        for completed in [false, true] {
            let before = displayed.filter { ($0.status == .completed) == completed }
            let after = reordered.filter { ($0.status == .completed) == completed }
            guard !before.elementsEqual(after, by: { $0 === $1 }) else { continue }
            assignments.append(contentsOf: manualOrderAssignments(after, ascending: ascending))
        }
        guard !assignments.isEmpty else { return false }
        do {
            try TaskWriteEligibility(writingIn: context).tasks(assignments.map(\.task))
        } catch {
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState)
            return false
        }
        let now = Date()
        for assignment in assignments {
            setManualRank(assignment.rank, on: assignment.task, now: now)
        }
        return ViewPersistence.saveOrReport(in: context, errorState: errorState)
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
    static func settlePendingMoves(beforeDeleting list: TaskList, in modelContext: ModelContext,
                                   sourceLookup: ((String) throws -> TaskList?)? = nil) throws {
        let listID = list.id
        let moved = try modelContext.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.taskList?.id == listID && $0.pendingMoveFromHref != nil }
        ))
        let lookup = sourceLookup ?? { sourceID in
            var descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == sourceID })
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).first
        }
        // Finish every fallible read before staging cleanup: a later source fetch
        // failure must not leave an earlier tombstone available to autosave/sync.
        let cleanup: [(task: TaskItem, href: String, source: TaskList)] = try moved.compactMap { task in
            guard let href = task.pendingMoveFromHref, let sourceID = task.pendingMoveFromListID,
                  let source = try lookup(sourceID) else { return nil }
            return (task, href, source)
        }
        let plans = try cleanup.map { entry in
            // Prepare photo ownership before staging any tombstone.
            try TaskMover.tombstonePlan(for: entry.task, href: entry.href, etag: nil,
                in: entry.source, context: modelContext)
        }
        let releaseCaptures = try cleanup.flatMap { entry in
            try [SyncResourceState.CaptureKind.moveSource, .currentResource].map {
                try SyncResourceState.prepareRemoveCapture(taskID: entry.task.id, kind: $0, in: modelContext)
            }
        }
        for plan in plans { plan() }
        for release in releaseCaptures { release() }
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
    static func cleanupDuplicateUIDs(in modelContext: ModelContext, listID: String? = nil) throws -> Int {
        let allTasks: [TaskItem]
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

        // Group by UID
        var uidGroups: [String: [TaskItem]] = [:]
        for task in allTasks {
            uidGroups[task.uid, default: []].append(task)
        }

        var duplicates: [TaskItem] = []
        for (_, group) in uidGroups where group.count > 1 {
            // Sort by lastModifiedDate descending — keep the first (newest)
            let sorted = group.sorted {
                ($0.lastModifiedDate ?? .distantPast) > ($1.lastModifiedDate ?? .distantPast)
            }
            for duplicate in sorted.dropFirst() {
                duplicates.append(duplicate)
            }
        }

        try VTODOOpaqueState.remove(tasks: duplicates, in: modelContext)
        try CalendarMirrorState.stagePurge(duplicates, in: modelContext)
        for duplicate in duplicates { modelContext.delete(duplicate) }
        return duplicates.count
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
