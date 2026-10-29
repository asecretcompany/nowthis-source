import Foundation
import SwiftData

/// DELETEs the copies that moves left behind in their source lists.
///
/// Runs after the pushes, so the server holds at least one copy of a moved task
/// at every instant. Deliberately not `SyncEngine.pushDeletion`, which hard-deletes
/// the row on success — here the row is the task the user just moved.
enum PendingMoveSweep {

    /// Moves out of `sourceListIDs` whose old copy may be deleted now, deepest first.
    ///
    /// Queried by the *source* list, not `taskList` as every per-list query is: a
    /// task moved into the Vault belongs to no synced list and would otherwise be
    /// visited by nothing. A move is ready once its destination copy exists — the
    /// PUT has landed, so `remoteHref` is set — or when the destination never
    /// syncs. Deleting sooner would leave the server with no copy at all.
    static func candidates(sourceListIDs: Set<String>, in context: ModelContext) -> [TaskItem] {
        // No #Predicate here matches a field against a set; filter in Swift.
        let pending = (try? context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.pendingMoveFromHref != nil }
        ))) ?? []
        return pending
            .filter { task in
                guard let source = task.pendingMoveFromListID, sourceListIDs.contains(source) else { return false }
                return isReady(task)
            }
            .sorted { TaskListHelpers.depth(of: $0) > TaskListHelpers.depth(of: $1) }
    }

    static func isReady(_ task: TaskItem) -> Bool {
        guard !task.photos.contains(where: {
            $0.pendingOperation != "remove" && $0.originalRequested && $0.previousOriginalFileID != nil
                && $0.originalStatus != "local" && ($0.originalFileID == nil || $0.pendingOperation != nil)
        }) else { return false }
        if let href = task.remoteHref, !href.isEmpty { return true }
        guard let account = task.taskList?.account else { return true }
        return account.mode == .vault
    }

    /// DELETEs each candidate's old copy through `delete`.
    ///
    /// Success, or a 404 the client already reports as success, ends the move. A
    /// 403 rolls it back only while its original local payload and scope remain
    /// unchanged. Anything else leaves the move pending for the next sync.
    ///
    /// Snapshots are captured before the first await. No SwiftData model from the
    /// sync context is accessed after a DELETE; acknowledgements use a fresh
    /// main-actor context so edits made while the request was in flight survive.
    ///
    /// - Returns: Whether any DELETE was refused for lack of permission.
    static func run(
        _ candidates: [TaskItem],
        in context: ModelContext,
        isolation: isolated (any Actor)? = #isolation,
        onCommit: ((SyncChange) -> Void)? = nil,
        onFailure: ((any Error) throws -> Void)? = nil,
        delete: (String) async throws -> Void
    ) async -> Bool {
        let container = context.container
        let snapshots = candidates.compactMap(SyncMoveSnapshot.init)
        var denied = false

        for candidate in snapshots {
            guard !Task.isCancelled else { break }
            var sent = candidate
            do {
                guard let snapshot = try await SyncMoveAcknowledgement.deletionSnapshot(candidate, container: container) else { continue }
                sent = snapshot
                try await delete(snapshot.sourceHref)
                guard !Task.isCancelled else { break }
                if let change = try await SyncMoveAcknowledgement.acknowledgeDelete(snapshot, container: container) { onCommit?(change) }
            } catch CalDAVError.forbidden {
                guard !Task.isCancelled else { break }
                if let change = try? await SyncMoveAcknowledgement.rollBackRefusedDelete(sent, container: container) { onCommit?(change) }
                denied = true
            } catch {
                // Retried on the next sync; the pull guard hides the stale copy meanwhile.
                do { try onFailure?(error) } catch { break }
            }
        }
        return denied
    }

    /// Abandons moves whose source list no longer exists — deleted, or removed
    /// with its account. Nothing will ever sync that list again, so the DELETE
    /// can never be sent, and the pending fields would otherwise stay forever.
    ///
    /// - Returns: The number of moves abandoned.
    @discardableResult
    static func clearOrphans(in context: ModelContext) -> Int {
        let pending = (try? context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.pendingMoveFromListID != nil }
        ))) ?? []
        guard !pending.isEmpty else { return 0 }
        let listIDs = Set(((try? context.fetch(FetchDescriptor<TaskList>())) ?? []).map(\.id))
        var cleared = 0
        for task in pending where !listIDs.contains(task.pendingMoveFromListID ?? "") {
            task.pendingMoveFromHref = nil
            task.pendingMoveFromListID = nil
            cleared += 1
        }
        return cleared
    }
}
