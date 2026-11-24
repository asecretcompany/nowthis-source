import Foundation
import SwiftData

/// Atomic phone-side transaction in an owned context. The main context's pending
/// user edits are never saved or rolled back by a Watch operation.
@MainActor
enum WatchEditTransaction {
    static func apply(_ edit: WatchEdit, operationID: UUID?, container: ModelContainer,
                      isProUnlocked: Bool, now: Date = Date(),
                      fetchTags: (ModelContext) throws -> [Tag] = Tag.fetchAll(in:),
                      save: ((ModelContext) throws -> Void)? = nil,
                      reportRefusal: (WatchEditRefusalReason) -> Void = { _ in },
                      didCommit: () -> Void = {}) -> String {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            if let operationID, let existing = try WatchReceiptStore.find(operationID, in: context, now: now) {
                if existing.result == WatchEditReply.invalid,
                   let raw = existing.refusalReason,
                   let reason = WatchEditRefusalReason(rawValue: raw) {
                    reportRefusal(reason)
                }
                return existing.result
            }
            var preferenceChange: NewTaskDefaults.PreferenceChange?
            let outcome = WatchEditApplier.stage(edit, modelContext: context, isProUnlocked: isProUnlocked,
                now: now, fetchTags: fetchTags, onPreferenceChange: { preferenceChange = $0 })
            let result: String
            switch outcome {
            case .applied: result = WatchEditReply.applied
            case .rejectedLocked: result = WatchEditReply.locked
            case .invalid, .readOnlyList: result = WatchEditReply.invalid
            case .unknownTask: result = WatchEditReply.unknownTask
            case .unsupportedRecurrence: result = WatchEditReply.unsupportedRecurrence
            }
            let refusal: WatchEditRefusalReason? = outcome == .readOnlyList ? .readOnlyList : nil
            if let operationID {
                try WatchReceiptStore.record(WatchOperationReceipt(
                    id: operationID, result: result, refusalReason: refusal?.rawValue), in: context, now: now)
            }
            let saveChanges = { if let save { try save(context) } else { try context.save() } }
            if let refusal {
                // A denied edit commits only its terminal operation receipt.
                if operationID != nil { try saveChanges() }
                reportRefusal(refusal)
                return result
            }
            // Includes the recovery ticket, the mutation, receipt, and pruning in one save.
            try ReminderSchedulingJournal.saveTaskChanges(in: context, save: saveChanges)
            if outcome == .applied {
                preferenceChange?.commit()
                didCommit()
                ReminderScheduler.requestReconcile(modelContext: context)
            }
            return result
        } catch {
            context.rollback()
            // No terminal receipt was committed. A direct reply must not claim rejection
            // or success; queued peers discover absence through their read-only lookup.
            return WatchEditReply.unconfirmed
        }
    }
}

/// This namespace is disjoint from CalDAV collection metadata and opaque sidecars.
/// Duplicate detection lasts only while retained: newest 512 receipts, at most 30 days.
/// No app transport path replays edits. UUID lookups are read-only.
enum WatchReceiptStore {
    static let prefix = "watch-edit-receipt-v1:"
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    static let capacity = 512
    static let outgoingCapacity = 64

    private static func rows(in context: ModelContext) throws -> [SyncMetadata] {
        let prefix = prefix
        return try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: prefix) }))
    }

    private static func decode(_ row: SyncMetadata, now: Date) -> WatchOperationReceipt? {
        if let date = row.lastFullSync, date < now.addingTimeInterval(-retention) { return nil }
        guard let id = UUID(uuidString: String(row.id.dropFirst(prefix.count))) else { return nil }
        // A retained exact ID with damaged contents is evidence that this operation may
        // already have run. Keep a bounded unconfirmed tombstone; corruption is not absence.
        guard let raw = row.syncToken, let data = raw.data(using: .utf8),
              let receipt = try? JSONDecoder().decode(WatchOperationReceipt.self, from: data),
              receipt.id == id else {
            return WatchOperationReceipt(id: id, result: WatchEditReply.unconfirmed)
        }
        return receipt
    }

    static func find(_ id: UUID, in context: ModelContext, now: Date) throws -> WatchOperationReceipt? {
        let key = prefix + id.uuidString
        let row = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first
        return row.flatMap { decode($0, now: now) }
    }

    static func recent(in context: ModelContext, now: Date) throws -> [WatchOperationReceipt] {
        try rows(in: context).sorted { ($0.lastFullSync ?? .distantPast) > ($1.lastFullSync ?? .distantPast) }
            .compactMap { decode($0, now: now) }.prefix(outgoingCapacity).map { $0 }
    }

    static func lookup(_ ids: [UUID], in context: ModelContext, now: Date) throws -> [WatchOperationReceipt] {
        try ids.prefix(outgoingCapacity).map {
            try find($0, in: context, now: now) ?? WatchOperationReceipt(id: $0, result: WatchEditReply.unconfirmed)
        }
    }

    static func record(_ receipt: WatchOperationReceipt, in context: ModelContext, now: Date) throws {
        let existing = try rows(in: context).sorted {
            ($0.lastFullSync ?? .distantPast) > ($1.lastFullSync ?? .distantPast)
        }
        // Expired or capacity-evicted receipts no longer deduplicate. Unreadable retained
        // exact IDs stay protected as unconfirmed tombstones. Never prune collection
        // metadata or independently owned reminder recovery tickets.
        for (index, row) in existing.enumerated() {
            if index >= capacity - 1 || decode(row, now: now) == nil { context.delete(row) }
        }
        let key = prefix + receipt.id.uuidString
        // Replace an expired receipt with the same UUID without a unique-key upsert conflict.
        for row in existing where row.id == key { context.delete(row) }
        let row = SyncMetadata(id: key, collectionPath: "")
        row.lastFullSync = now
        row.syncToken = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        context.insert(row)
    }
}
