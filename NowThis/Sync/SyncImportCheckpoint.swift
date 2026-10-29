import Foundation
import SwiftData
import CryptoKit

/// Reuses the shipped SyncMetadata schema. Old path-only rows are deliberately not adopted:
/// a token is valid only for this account, list, server identity and history baseline.
enum SyncImportCheckpoint {
    static func identity(accountID: String, listID: String, baseURL: String, username: String, months: Int) -> String {
        accountPrefix(accountID) + hash(listID) + ":" + hash([baseURL, username, String(months)].map { "\($0.utf8.count):\($0)" }.joined())
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func accountPrefix(_ id: String) -> String { "collection-v1:" + hash(id) + ":" }
    static func removeAccount(_ accountID: String, in context: ModelContext) throws {
        let prefix = accountPrefix(accountID)
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: prefix) }))
        rows.forEach(context.delete)
    }
    static func removeList(accountID: String, listID: String, in context: ModelContext) throws {
        let prefix = accountPrefix(accountID) + hash(listID) + ":"
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: prefix) }))
        rows.forEach(context.delete)
    }
    static func pruneOtherScopes(accountID: String, listID: String, keeping id: String, container: ModelContainer) throws {
        let context = ModelContext(container); context.autosaveEnabled = false
        let prefix = accountPrefix(accountID) + hash(listID) + ":"
        let retained = id
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate {
            $0.id.starts(with: prefix) && !$0.id.starts(with: retained)
        }))
        rows.forEach(context.delete)
        if context.hasChanges { try context.save() }
    }

    static func hierarchyPending(id: String, in context: ModelContext) throws -> Bool {
        let key = id + ":hierarchy-pending"
        return try context.fetchCount(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })) > 0
    }

    /// Written in the same transaction as raw parent UID changes, before resource receipts.
    static func markHierarchyPending(id: String, in context: ModelContext) throws {
        guard try !hierarchyPending(id: id, in: context) else { return }
        context.insert(SyncMetadata(id: id + ":hierarchy-pending", collectionPath: ""))
    }

    static func clearHierarchyPending(id: String, in context: ModelContext) throws {
        let key = id + ":hierarchy-pending"
        for row in try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })) {
            context.delete(row)
        }
    }

    static func read(id: String, scope: SyncCollectionPuller.Scope, in context: ModelContext) throws -> SyncCollectionPuller.Checkpoint? {
        let key = id
        guard let metadata = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first else { return nil }
        return SyncCollectionPuller.Checkpoint(scope: scope, token: metadata.syncToken,
            ctag: metadata.lastCTag, lastIntegrity: metadata.lastFullSync,
            hasCompletedBaseline: metadata.lastFullSync != nil)
    }

    /// Durable resource receipts include bodies deliberately excluded by history policy.
    /// Receipt rows use the existing schema and a reserved scoped ID; they are never TaskItems.
    static func accountedETags(id: String, container: ModelContainer) throws -> [String: String] {
        let context = ModelContext(container)
        let prefix = id + ":resource:"
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: prefix) }))
        return Dictionary(rows.compactMap { row in row.lastCTag.map { (row.collectionPath, $0) } }, uniquingKeysWith: { _, last in last })
    }
    static func markAccounted(_ resources: [CalDAVClient.RemoteTask], id: String, container: ModelContainer) throws {
        let context = ModelContext(container); context.autosaveEnabled = false
        for resource in resources {
            let key = receiptID(scope: id, href: resource.href)
            let row = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first
                ?? SyncMetadata(id: key, collectionPath: resource.href)
            if row.modelContext == nil { context.insert(row) }
            row.lastCTag = resource.etag
        }
        if context.hasChanges { try context.save() }
    }
    static func removeAccounted(_ hrefs: [String], id: String, container: ModelContainer) throws {
        let context = ModelContext(container); context.autosaveEnabled = false
        for href in hrefs {
            let key = receiptID(scope: id, href: href)
            if let row = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first { context.delete(row) }
        }
        if context.hasChanges { try context.save() }
    }
    private static func receiptID(scope: String, href: String) -> String {
        scope + ":resource:" + SHA256.hash(data: Data(href.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Invoked only after all associated model transactions have succeeded. If this save
    /// fails, the previous token remains the retry boundary and those changes can replay.
    static func commit(_ checkpoint: SyncCollectionPuller.Checkpoint, id: String, collectionPath: String,
                       container: ModelContainer) throws {
        let context = ModelContext(container); context.autosaveEnabled = false
        let key = id
        let metadata = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first
            ?? SyncMetadata(id: id, collectionPath: collectionPath)
        if metadata.modelContext == nil { context.insert(metadata) }
        metadata.syncToken = checkpoint.token
        metadata.lastCTag = checkpoint.ctag
        metadata.lastFullSync = checkpoint.lastIntegrity
        try context.save()
    }
}
