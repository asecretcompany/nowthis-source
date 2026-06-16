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
