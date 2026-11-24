import Foundation

/// Bounds the entire property-list context, including control fields, not just task count.
enum WatchSnapshotBudget {
    static let maximumBytes = 60_000
    enum Failure: Error { case oversizedControlData }

    static func context(_ snapshot: WatchSnapshot, completionFailureID: String? = nil,
                        completionFailureUID: String? = nil) throws -> [String: Any] {
        // The latest legacy failure is optional. Omit the whole event if an imported
        // UID is oversized, keeping bounded UUID receipts available to current peers.
        let includeLegacyFailure = (completionFailureID?.utf8.count ?? 0) <= 64
            && (completionFailureUID?.utf8.count ?? 0) <= 2_048
        func dictionary(_ value: WatchSnapshot) throws -> [String: Any] {
            var result = try value.contextDictionary()
            if includeLegacyFailure, let completionFailureID, let completionFailureUID {
                result[WatchEditReply.completionFailureIDKey] = completionFailureID
                result[WatchEditReply.completionFailureUIDKey] = completionFailureUID
            }
            return result
        }
        func fits(_ value: WatchSnapshot) throws -> Bool {
            try PropertyListSerialization.data(fromPropertyList: dictionary(value), format: .binary, options: 0).count < maximumBytes
        }
        func value(lists: [WatchListMeta], tasks: [WatchTask], truncated: Bool) -> WatchSnapshot {
            WatchSnapshot(schemaVersion: snapshot.schemaVersion, isProUnlocked: snapshot.isProUnlocked,
                generatedAt: snapshot.generatedAt, lists: lists, tasks: tasks, truncated: truncated,
                defaultListID: snapshot.defaultListID, proAccessValidUntil: snapshot.proAccessValidUntil,
                testerProOverride: snapshot.testerProOverride,
                receipts: snapshot.receipts.map { Array($0.prefix(64)) })
        }
        var bounded = value(lists: [], tasks: [], truncated: true)
        guard try fits(bounded) else { throw Failure.oversizedControlData }
        var lists: [WatchListMeta] = []
        var tasks: [WatchTask] = []
        var truncated = snapshot.truncated
        for list in snapshot.lists {
            if try fits(value(lists: lists + [list], tasks: [], truncated: true)) { lists.append(list) }
            else { truncated = true }
        }
        for task in snapshot.tasks {
            if try fits(value(lists: lists, tasks: tasks + [task], truncated: true)) { tasks.append(task) }
            else { truncated = true }
        }
        bounded = value(lists: lists, tasks: tasks, truncated: truncated)
        return try dictionary(bounded)
    }
}
