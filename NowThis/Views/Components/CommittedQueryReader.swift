import SwiftUI
import SwiftData

/// Replaces only a zero-size query reader. Navigation, row and editor state stay in the host.
struct CommittedQueryReader<Model: PersistentModel>: View {
    let descriptor: FetchDescriptor<Model>
    let revision: UInt64
    var scope = ""
    let onValues: ([Model]) -> Void

    var body: some View {
        QueryValues(descriptor: descriptor, onValues: onValues)
            .id(revision)
            .id(scope)
    }
}

private struct QueryValues<Model: PersistentModel>: View {
    @Query private var models: [Model]
    let onValues: ([Model]) -> Void

    init(descriptor: FetchDescriptor<Model>, onValues: @escaping ([Model]) -> Void) {
        var descriptor = descriptor
        descriptor.includePendingChanges = true
        _models = Query(descriptor)
        self.onValues = onValues
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { deliver() }
            .onChange(of: models.map(\.persistentModelID)) { _, _ in deliver() }
    }

    private func deliver() {
        guard _models.fetchError == nil else { return }
        onValues(models)
    }
}

/// Subscribes to sync publications at the data boundary, away from rendering rows.
struct InboundQueryReader<Model: PersistentModel>: View {
    let descriptor: FetchDescriptor<Model>
    var scope = ""
    var listID: String?
    let onValues: ([Model]) -> Void
    @EnvironmentObject private var syncScheduler: SyncScheduler

    var body: some View {
        CommittedQueryReader(descriptor: descriptor,
            revision: listID.map { syncScheduler.listRevisions[$0] ?? 0 }
                ?? syncScheduler.latestCommittedChange?.revision ?? 0,
            scope: scope, onValues: onValues)
            .id(syncScheduler.unscopedRefreshRevision)
    }
}
