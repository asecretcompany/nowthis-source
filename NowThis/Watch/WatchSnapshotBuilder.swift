import Foundation
import SwiftData
import os

/// Compatibility entry point for callers and tests that already hold live SwiftData arrays.
enum WatchSnapshotBuilder {
    /// Hard ceiling on `WatchSnapshot.tasks.count` to bound WatchConnectivity payload size.
    static let taskCap = 400

    /// Per-list browse allowance for active tasks outside the due window.
    static let perListHead = 50

    /// Existing Model-array API, kept for current callers and tests. Only value records reach
    /// the pure projection, so SwiftData models never cross into worker code.
    static func build(
        tasks: [TaskItem],
        lists: [TaskList],
        isProUnlocked: Bool,
        defaultListID: String?,
        now: Date,
        calendar: Calendar,
        proAccessValidUntil: Date? = nil,
        testerProOverride: Bool? = nil
    ) -> WatchSnapshot {
        let liveTasks = tasks.filter { $0.modelContext != nil }.map { WatchTaskInput($0, isLive: true) }
        let liveLists = lists.filter { $0.modelContext != nil }.map { WatchListInput($0, isLive: true) }
        return WatchSnapshotValueBuilder.build(
            tasks: liveTasks,
            lists: liveLists,
            isProUnlocked: isProUnlocked,
            defaultListID: defaultListID,
            now: now,
            calendar: calendar,
            proAccessValidUntil: proAccessValidUntil,
            testerProOverride: testerProOverride
        )
    }
}

/// Pure value projection shared by the legacy builder API and the background Watch worker.
enum WatchSnapshotValueBuilder {
    private static let log = Logger(subsystem: "com.asecretcompany.nowthis", category: "WatchSnapshotBuilder")

    static func build(
        tasks: [WatchTaskInput],
        lists: [WatchListInput],
        isProUnlocked: Bool,
        defaultListID: String?,
        now: Date,
        calendar: Calendar,
        proAccessValidUntil: Date? = nil,
        testerProOverride: Bool? = nil
    ) -> WatchSnapshot {
        let liveTasks = tasks.filter(\.isLive)
        let liveLists = lists.filter(\.isLive)
        let active = liveTasks.filter { !$0.isCompleted && !$0.isDeletedLocally }
        let activeByListID = Dictionary(grouping: active, by: \.listID)
        let windowEnd = calendar.date(byAdding: .day, value: 7, to: now) ?? now

        func deadline(for task: WatchTaskInput) -> Date? {
            guard let due = task.dueDate else { return nil }
            return DueDateHelper.effectiveDeadline(for: due, isDateOnly: task.isDueDateOnly)
        }

        func isOverdue(_ task: WatchTaskInput) -> Bool {
            guard let deadline = deadline(for: task) else { return false }
            return now >= deadline
        }

        let windowed = active.filter { task in
            guard let deadline = deadline(for: task) else { return false }
            return deadline < windowEnd
        }

        var perListPicks: [WatchTaskInput] = []
        for list in liveLists {
            let head = (activeByListID[list.id] ?? [])
                .sorted { $0.effectiveSortOrder < $1.effectiveSortOrder }
                .prefix(WatchSnapshotBuilder.perListHead)
            perListPicks.append(contentsOf: head)
        }

        var seenUIDs = Set<String>()
        let deduped = (windowed + perListPicks).filter { seenUIDs.insert($0.uid).inserted }

        func rank(_ task: WatchTaskInput) -> Int {
            guard task.dueDate != nil else { return 2 }
            return isOverdue(task) ? 0 : 1
        }
        let ordered = deduped.sorted { lhs, rhs in
            let lhsRank = rank(lhs)
            let rhsRank = rank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            switch lhsRank {
            case 0, 1:
                return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
            default:
                return lhs.effectiveSortOrder < rhs.effectiveSortOrder
            }
        }

        let truncated = ordered.count > WatchSnapshotBuilder.taskCap
        if truncated {
            log.warning("Watch snapshot truncated: \(ordered.count, privacy: .public) tasks → \(WatchSnapshotBuilder.taskCap, privacy: .public)")
        }

        let watchLists = liveLists.map { list in
            WatchListMeta(
                id: list.id,
                name: list.name,
                colorHex: list.colorHex,
                activeTaskCount: (activeByListID[list.id] ?? []).count
            )
        }
        let watchTasks = ordered.prefix(WatchSnapshotBuilder.taskCap).map { task in
            WatchTask(
                id: task.id,
                uid: task.uid,
                title: task.title,
                dueDate: task.dueDate,
                isDueDateOnly: task.isDueDateOnly,
                priorityRaw: task.priorityRaw,
                isCompleted: task.isCompleted,
                listID: task.listID ?? "",
                parentUID: task.parentUID
            )
        }

        return WatchSnapshot(
            schemaVersion: WatchSnapshot.currentSchemaVersion,
            isProUnlocked: isProUnlocked,
            generatedAt: now,
            lists: watchLists,
            tasks: watchTasks,
            truncated: truncated,
            defaultListID: defaultListID,
            proAccessValidUntil: proAccessValidUntil,
            testerProOverride: testerProOverride
        )
    }
}
