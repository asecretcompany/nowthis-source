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
        PerformanceTrace.record(.otherScopePrune, rows: rows.count)
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
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key }))
        PerformanceTrace.record(.checkpointRead, rows: rows.count, keys: 1)
        guard let metadata = rows.first else { return nil }
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
        PerformanceTrace.record(.receiptInventory, rows: rows.count)
        return Dictionary(rows.compactMap { row in row.lastCTag.map { (row.collectionPath, $0) } }, uniquingKeysWith: { _, last in last })
    }

    static func accountedETags(id: String, hrefs: [String], in context: ModelContext) throws -> [String: String] {
        guard !hrefs.isEmpty else { return [:] }
        let hrefsByID = Dictionary(hrefs.map { (receiptID(scope: id, href: $0), $0) },
                                   uniquingKeysWith: { first, _ in first })
        let keys = Array(hrefsByID.keys)
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { keys.contains($0.id) }))
        PerformanceTrace.record(.matchingReceiptLookup, rows: rows.count, keys: keys.count)
        return Dictionary(rows.compactMap { row in
            guard let href = hrefsByID[row.id], row.collectionPath == href, let etag = row.lastCTag else { return nil }
            return (href, etag)
        }, uniquingKeysWith: { first, _ in first })
    }
    static func markAccounted(_ resources: [CalDAVClient.RemoteTask], id: String, container: ModelContainer) throws {
        let context = ModelContext(container); context.autosaveEnabled = false
        try updateReceiptRows(
            resources,
            receiptID: { (resource: CalDAVClient.RemoteTask) -> String in
                receiptID(scope: id, href: resource.href)
            },
            fetchExisting: { (ids: [String]) throws -> [String: SyncMetadata] in
                let rows = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { ids.contains($0.id) }))
                PerformanceTrace.record(.receiptWriteLookup, rows: rows.count, keys: ids.count)
                return Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            },
            makeRow: { (resource: CalDAVClient.RemoteTask, key: String) -> SyncMetadata in
                let row = SyncMetadata(id: key, collectionPath: resource.href)
                context.insert(row)
                return row
            },
            updateRow: { (row: SyncMetadata, resource: CalDAVClient.RemoteTask) in row.lastCTag = resource.etag }
        )
        if context.hasChanges { try context.save() }
    }

    /// Applies receipt updates after looking up the IDs needed by one bounded resource batch.
    /// Keeping the fetch boundary injectable lets tests count actual batch lookups without
    /// adding instrumentation that is only used by tests.
    static func updateReceiptRows<Resource, Row>(
        _ resources: [Resource],
        receiptID: (Resource) -> String,
        fetchExisting: ([String]) throws -> [String: Row],
        makeRow: (Resource, String) -> Row,
        updateRow: (Row, Resource) -> Void
    ) throws {
        guard !resources.isEmpty else { return }
        let ids = Array(Set(resources.map(receiptID))).sorted()
        var rowsByID = try fetchExisting(ids)
        for resource in resources {
            let key = receiptID(resource)
            let row: Row
            if let existing = rowsByID[key] {
                row = existing
            } else {
                row = makeRow(resource, key)
                rowsByID[key] = row
            }
            updateRow(row, resource)
        }
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
        PerformanceTrace.record(.checkpointCommit, rows: 1, keys: 1)
    }
}
