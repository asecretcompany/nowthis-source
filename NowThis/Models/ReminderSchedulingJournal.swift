import Foundation
import SwiftData

/// Pending notification work shares the existing metadata schema and task transaction.
enum ReminderSchedulingJournal {
    enum Failure: Error, Equatable { case unsavedChanges }
    static let ticketPrefix = "reminder-ticket-v1:"
    static let outcomeID = "reminder-outcome-v1"

    private struct StoredOutcome: Encodable {
        let version = 1
        let planDigest: String
        let deferredTaskIDs: [String]
        let earliestDeferredFireDate: Date?
    }

    static func isAvailable(in container: ModelContainer) -> Bool {
        container.schema.entities.contains { $0.name == "SyncMetadata" }
    }

    @discardableResult
    static func enqueue(in context: ModelContext) -> String {
        let id = ticketPrefix + UUID().uuidString
        context.insert(SyncMetadata(id: id, collectionPath: ""))
        return id
    }

    /// Called before task saves. Coalesce within a transaction, never across processes.
    @discardableResult
    static func enqueueTaskChanges(in context: ModelContext) -> String? {
        guard isAvailable(in: context.container) else { return nil }
        let pending = context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray
        guard pending.contains(where: { $0 is TaskItem }) else { return nil }
        if let ticket = context.insertedModelsArray.compactMap({ $0 as? SyncMetadata })
            .first(where: { $0.id.hasPrefix(ticketPrefix) }) { return ticket.id }
        return enqueue(in: context)
    }

    /// The injectable save keeps task edits and recovery intent in one transaction.
    static func saveTaskChanges(in context: ModelContext,
                                needsRecovery: Bool = false,
                                save: (() throws -> Void)? = nil) throws {
        if needsRecovery, isAvailable(in: context.container) {
            enqueue(in: context)
        } else {
            enqueueTaskChanges(in: context)
        }
        if let save { try save() } else { try context.save() }
    }

    static func capture(in context: ModelContext) throws -> Set<String> {
        let prefix = ticketPrefix
        return Set(try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate {
            $0.id.starts(with: prefix)
        })).map(\.id))
    }

    static func acknowledge(_ ticketIDs: Set<String>, planDigest: String,
                            deferredTaskIDs: Set<String>, earliestDeferredFireDate: Date?,
                            in context: ModelContext) throws {
        let pending = context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray
        guard !pending.contains(where: { $0 is TaskItem }) else { throw Failure.unsavedChanges }
        let ids = Array(ticketIDs.filter { $0.hasPrefix(ticketPrefix) })
        let tickets = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate {
            ids.contains($0.id)
        }))
        let key = outcomeID
        let row = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first
            ?? SyncMetadata(id: key, collectionPath: "")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(StoredOutcome(planDigest: planDigest,
            deferredTaskIDs: deferredTaskIDs.sorted(), earliestDeferredFireDate: earliestDeferredFireDate))
        if row.modelContext == nil { context.insert(row) }
        row.syncToken = String(decoding: data, as: UTF8.self)
        tickets.forEach(context.delete)
        // The caller saves acknowledgment and its outcome atomically in a fresh context.
    }
}
