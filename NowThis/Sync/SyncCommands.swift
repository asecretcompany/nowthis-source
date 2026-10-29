import SwiftUI
import SwiftData

/// Commands do not publish progress to every task row.
struct SyncCommands: Sendable {
    var syncAfterChange: @MainActor @Sendable (ModelContext) -> Void = { _ in }
    var syncAfterAccountAdded: @MainActor @Sendable (ModelContext) -> Void = { _ in }
    var syncNow: @MainActor @Sendable (ModelContext) async -> Void = { _ in }
}

private struct SyncCommandsKey: EnvironmentKey {
    static let defaultValue = SyncCommands()
}

extension EnvironmentValues {
    var syncCommands: SyncCommands {
        get { self[SyncCommandsKey.self] }
        set { self[SyncCommandsKey.self] = newValue }
    }
}

extension SyncScheduler {
    var commands: SyncCommands {
        SyncCommands(syncAfterChange: { [weak self] context in
            self?.syncAfterChange(modelContext: context)
        }, syncAfterAccountAdded: { [weak self] context in
            self?.syncAfterAccountAdded(modelContext: context)
        }, syncNow: { [weak self] context in
            await self?.syncNow(modelContext: context)
        })
    }
}
