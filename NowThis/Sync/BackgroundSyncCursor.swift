import Foundation
import SwiftData

/// Advisory starting positions, separate from authoritative collection import state.
enum BackgroundSyncCursor {
    private static let prefix = "background-cursor-v1:"

    /// Discovery/fetch order is not stable. Missing positions safely start at the first ID.
    static func rotated(_ ids: [String], after cursor: String?) -> [String] {
        let ordered = Array(Set(ids)).sorted()
        guard let cursor, let index = ordered.firstIndex(of: cursor) else { return ordered }
        return Array(ordered.dropFirst(index + 1)) + Array(ordered.prefix(index + 1))
    }

    static func load(scope: String, in context: ModelContext) throws -> String? {
        try BackgroundRunBudget.protectingCurrent {
            let key = prefix + scope
            var descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first?.syncToken
        }
    }

    /// Save before attempting remote work, including attempts that fail or exhaust the budget.
    /// The reserved row's syncToken is an advisory ID, never a collection page token.
    static func recordAttempt(id: String, scope: String, in context: ModelContext) throws {
        try BackgroundRunBudget.protectingCurrent {
            let key = prefix + scope
            var descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })
            descriptor.fetchLimit = 1
            let row = try context.fetch(descriptor).first
                ?? SyncMetadata(id: key, collectionPath: "")
            if row.modelContext == nil { context.insert(row) }
            row.syncToken = id
            try context.save()
        }
    }
}
