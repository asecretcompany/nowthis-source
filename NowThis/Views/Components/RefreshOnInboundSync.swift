import SwiftUI

/// Forces the modified view to re-create — and thus its `@Query` to re-fetch —
/// whenever a sync brings in new or changed tasks from the server.
///
/// A SwiftData `@Query` is bound to the main context and does **not** re-emit
/// when the `SyncEngine` commits inserts/updates on its background `ModelContext`
/// (the background context exists to keep heavy sync work off the main thread and
/// avoid watchdog kills). Keying the view's identity to
/// `SyncScheduler.dataRefreshToken` — which is bumped only on a real inbound
/// change — tears the subtree down and rebuilds it, so the fresh `@Query` reads
/// the just-committed rows from the shared store and the server-created tasks
/// finally appear.
///
/// Because the token changes only on genuine inbound changes, routine and
/// push-only syncs do not rebuild the view; the cost (losing scroll position,
/// expanded subtasks, and selection) is paid only when the list content actually
/// changed underneath the user.
private struct RefreshOnInboundSync: ViewModifier {
    @EnvironmentObject private var syncScheduler: SyncScheduler

    func body(content: Content) -> some View {
        content.id(syncScheduler.dataRefreshToken)
    }
}

extension View {
    /// Re-queries this view's `@Query` data when a sync imports server-side
    /// changes. Apply to a task-list presentation (Tasks, Board, Calendar,
    /// Matrix, Journal). See ``RefreshOnInboundSync``.
    func refreshOnInboundSync() -> some View {
        modifier(RefreshOnInboundSync())
    }
}
