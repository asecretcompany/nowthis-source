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
    static func orderedSubtasks(
        of parent: TaskItem,
        by option: TaskSortOption,
        ascending: Bool
    ) -> [TaskItem] {
        let active = parent.subtasks.filter { !$0.isDeletedLocally }
        return sortedWithCompletedLast(active, by: option, ascending: ascending)
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

    /// Removes duplicate TaskItems from the data store, keeping the newest per UID.
    ///
    /// Scans all non-deleted TaskItems, groups by `uid`, and for any UID with
    /// more than one TaskItem, deletes all but the one with the latest
    /// `lastModifiedDate`. The caller must save the context after calling this.
    ///
    /// - Parameter modelContext: The SwiftData model context to operate on.
    /// - Returns: The number of duplicate TaskItems removed.
    @discardableResult
    static func cleanupDuplicateUIDs(in modelContext: ModelContext) -> Int {
        let allTasks: [TaskItem]
        do {
            let predicate = #Predicate<TaskItem> { !$0.isDeletedLocally }
            allTasks = try modelContext.fetch(
                FetchDescriptor<TaskItem>(
                    predicate: predicate
                )
            )
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
}
