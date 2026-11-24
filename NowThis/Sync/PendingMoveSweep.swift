import Foundation
import SwiftData

/// DELETEs the copies that moves left behind in their source lists.
///
/// Runs after the pushes so live moved tasks keep a server copy. Source
/// acknowledgement keeps the local row, including a tombstone that still
/// needs to finish destination deletion.
enum PendingMoveSweep {

    /// Moves out of `sourceListIDs` whose old copy may be deleted now, deepest first.
    ///
    /// Queried by the *source* list, not `taskList` as every per-list query is: a
    /// task moved into the Vault belongs to no synced list and would otherwise be
    /// visited by nothing. A move is ready once its destination copy exists — the
    /// PUT has landed, so `remoteHref` is set — or when the destination never
    /// syncs. An explicitly deleted task can finish source cleanup without a
    /// destination copy once its attachment and opaque state checks pass.
    static func candidates(sourceListIDs: Set<String>, in context: ModelContext, requiringReady: Bool = true) -> [TaskItem] {
        // No #Predicate here matches a field against a set; filter in Swift.
        let pending = (try? context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.pendingMoveFromHref != nil }
        ))) ?? []
        return pending
            .filter { task in
                guard let source = task.pendingMoveFromListID, sourceListIDs.contains(source) else { return false }
                return !requiringReady || isReady(task)
            }
            .sorted { TaskListHelpers.depth(of: $0) > TaskListHelpers.depth(of: $1) }
    }

    static func isReady(_ task: TaskItem) -> Bool {
        // A tombstone needs known attachment ownership for cleanup. Its
        // snapshot still validates opaque state before a source DELETE.
        if task.isDeletedLocally { return task.attachmentStateKnown == true }
        guard !task.photos.contains(where: {
            $0.pendingOperation != "remove" && $0.originalRequested && $0.previousOriginalFileID != nil
                && $0.originalStatus != "local" && ($0.originalFileID == nil || $0.pendingOperation != nil)
        }) else { return false }
        if let account = task.taskList?.account, account.mode != .vault,
           let context = task.modelContext {
            do {
                if try VTODOOpaqueState.load(taskID: task.id, in: context)?.destinationRepairPending == true { return false }
            } catch { return false }
        }
        if let href = task.remoteHref, !href.isEmpty { return true }
        guard let account = task.taskList?.account else { return true }
        return account.mode == .vault
    }

    /// DELETEs each candidate's old copy through `delete`.
    ///
    /// Success, or a 404 the client already reports as success, ends the move. A
    /// 403 rolls it back only while its original local payload and scope remain
    /// unchanged and the moved task is still live. Other failures leave the
    /// source cleanup pending for the next sync.
    ///
    /// Snapshots are captured before the first await. No SwiftData model from the
    /// sync context is accessed after a DELETE; acknowledgements use a fresh
    /// main-actor context so edits made while the request was in flight survive.
    ///
    /// - Returns: Whether any DELETE was refused for lack of permission.
    static func run(
        _ candidates: [TaskItem],
        in context: ModelContext,
        expectedSourceAccountID: String? = nil,
        isolation: isolated (any Actor)? = #isolation,
        onCommit: ((SyncChange) -> Void)? = nil,
        onFailure: ((any Error) throws -> Void)? = nil,
        delete: (SyncMoveSnapshot) async throws -> Void
    ) async -> Bool {
        let container = context.container
        var snapshots: [SyncMoveSnapshot] = []
        for task in candidates {
            do { if let snapshot = try SyncMoveSnapshot(task: task) { snapshots.append(snapshot) } }
            catch { do { try onFailure?(error) } catch { return false } }
        }
        var denied = false

        for candidate in snapshots {
            guard !Task.isCancelled else { break }
            var sent = candidate
            do {
                guard let snapshot = try await SyncMoveAcknowledgement.deletionSnapshot(candidate, container: container,
                    expectedSourceAccountID: expectedSourceAccountID) else { continue }
                sent = snapshot
                try await delete(snapshot)
                guard !Task.isCancelled else { break }
                if let change = try await SyncMoveAcknowledgement.acknowledgeDelete(snapshot, container: container) { onCommit?(change) }
            } catch is SupersededTaskDeletion {
                continue
            } catch CalDAVError.forbidden {
                guard !Task.isCancelled else { break }
                denied = true
                if sent.isDeletedLocally {
                    do { try onFailure?(CalDAVError.forbidden) } catch { break }
                } else if let change = try? await SyncMoveAcknowledgement.rollBackRefusedDelete(sent, container: container) {
                    onCommit?(change)
                }
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
    /// - Returns: The number of moves abandoned after both store reads succeed.
    @discardableResult
    static func clearOrphans(
        in context: ModelContext,
        fetchLists: (() throws -> [TaskList])? = nil
    ) throws -> Int {
        let pending = try context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.pendingMoveFromListID != nil }
        ))
        guard !pending.isEmpty else { return 0 }
        let fetchLists = fetchLists ?? { try context.fetch(FetchDescriptor<TaskList>()) }
        let listIDs = Set(try fetchLists().map(\.id))
        let orphans = pending.filter {
            !listIDs.contains($0.pendingMoveFromListID ?? "")
                && !($0.isDeletedLocally && TaskPhotoCleanupQueue.hasAmbiguousPendingRemoval(in: $0))
        }
        let releases = try orphans.map { try SyncResourceState.prepareRemoveCapture(taskID: $0.id, in: context) }
        for (task, release) in zip(orphans, releases) {
            release()
            task.pendingMoveFromHref = nil
            task.pendingMoveFromListID = nil
        }
        let cleared = orphans.count
        return cleared
    }
}
