import CryptoKit
import Foundation
import Security
import SwiftData

/// Device-only evidence is deliberately separate from the shareable task store.
@MainActor
struct AppleCalendarAnchor {
    var read: (_ storeSelector: String, _ createIfMissing: Bool) throws -> Data?

    struct KeychainOperations {
        var read: (CFDictionary) -> (OSStatus, AnyObject?) = { query in
            var value: AnyObject?
            let status = SecItemCopyMatching(query, &value)
            return (status, value)
        }
        var add: (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
    }

    static let keychain = keychain(operations: KeychainOperations())

    static func keychain(operations: KeychainOperations) -> AppleCalendarAnchor {
        AppleCalendarAnchor { selector, create in
            try readKeychain(selector: selector, create: create, operations: operations)
        }
    }

    private static func readKeychain(selector: String, create: Bool, operations: KeychainOperations) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.asecretcompany.nowthis.calendar-ownership",
            kSecAttrAccount as String: selector,
            kSecAttrSynchronizable as String: false
        ]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = operations.read(read as CFDictionary)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else { throw CalendarSyncError.ownershipUncertain }
            return data
        }
        guard status == errSecItemNotFound else { throw CalendarSyncError.ownershipUncertain }
        guard create else { return nil }
        var data = Data(count: 32)
        let randomStatus = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw CalendarSyncError.ownershipUncertain }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = operations.add(add as CFDictionary)
        if added == errSecDuplicateItem { return try readKeychain(selector: selector, create: false, operations: operations) }
        guard added == errSecSuccess else { throw CalendarSyncError.ownershipUncertain }
        return data
    }

    /// Paths are relative to the stable app group, not its installation UUID.
    /// Nonproduction stores must supply their own explicit local configuration.
    static func selector(for container: ModelContainer) throws -> String {
        guard container.configurations.count == 1,
              let configuration = container.configurations.first,
              !configuration.isStoredInMemoryOnly,
              let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID) else {
            throw CalendarSyncError.ownershipUncertain
        }
        let root = group.standardizedFileURL.path + "/"
        let path = configuration.url.standardizedFileURL.path
        guard path.hasPrefix(root) else { throw CalendarSyncError.ownershipUncertain }
        return AppConstants.appGroupID + "/" + String(path.dropFirst(root.count))
    }
}

/// Read-only aggregate for diagnostics. Persistence uses independent bounded rows.
struct AppleCalendarOwnership {
    static let prefix = "apple-calendar-mirror-v1:"
    static let maximumRecordBytes = 8_192
    static let maximumLinks = 10_000
    var scope: String
    var destination: Destination?
    var links: [String: Link] = [:]

    struct Destination: Codable, Equatable {
        var version = 1
        var scope: String
        var revision = 0
        var generation = UUID()
        var eventStoreID: String
        var binding: AppleCalendarBinding?
        var acknowledged = false
        var linkCount = 0

        func validate() throws {
            guard version == 1, validScope(scope), validRevision(revision), bounded(eventStoreID),
                  (0...maximumLinks).contains(linkCount),
                  acknowledged || linkCount == 0, !acknowledged || binding != nil else { throw CalendarSyncError.ownershipUncertain }
            if let binding, !validBinding(binding) { throw CalendarSyncError.ownershipUncertain }
        }
    }
    struct Pending: Codable, Equatable {
        enum Action: String, Codable { case create, update, remove }
        var id = UUID()
        var action: Action
        /// Digest of the requested mirror-owned fields, never the user's event URL.
        var fingerprint: String?
        /// A retry may use newer committed task fields. Keep the original intent
        /// until the latest retry's actual receipt proves its result.
        var retryFingerprint: String?
        var expectedFingerprint: String? { retryFingerprint ?? fingerprint }
    }
    struct Link: Codable, Equatable {
        var version = 1
        var scope: String
        var revision = 0
        var identity = UUID()
        var taskID: String
        var taskIdentity: CalendarMirrorState.Identity?
        var destinationGeneration: UUID
        var event: AppleEventIdentity?
        var pending: Pending?

        func validate(destination: Destination) throws {
            if let taskIdentity {
                guard taskIdentity.isValid, taskIdentity.taskID.utf8.elementsEqual(taskID.utf8) else { throw CalendarSyncError.linkUncertain }
            }
            guard version == 1, scope == destination.scope, validRevision(revision), bounded(taskID),
                  destination.acknowledged, destinationGeneration == destination.generation,
                  event != nil || pending?.action == .create else { throw CalendarSyncError.linkUncertain }
            if let event {
                guard bounded(event.itemID), bounded(event.id, allowEmpty: true),
                      event.calendar == destination.binding else { throw CalendarSyncError.linkUncertain }
            }
            if let pending {
                switch pending.action {
                case .create:
                    guard validDigest(pending.fingerprint), pending.retryFingerprint == nil else { throw CalendarSyncError.linkUncertain }
                case .update:
                    guard event != nil, validDigest(pending.fingerprint),
                          pending.retryFingerprint == nil || validDigest(pending.retryFingerprint) else { throw CalendarSyncError.linkUncertain }
                case .remove:
                    guard event != nil, pending.fingerprint == nil, pending.retryFingerprint == nil else { throw CalendarSyncError.linkUncertain }
                }
            }
        }
    }

    static func validRevision(_ value: Int) -> Bool { value >= 0 && value < Int.max }
    static func validScope(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit } }
    static func validDigest(_ value: String?) -> Bool { value.map(validScope) == true }
    static func bounded(_ value: String, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !value.isEmpty) && value.utf8.count <= 1_024
    }
    static func validBinding(_ value: AppleCalendarBinding) -> Bool {
        bounded(value.id) && bounded(value.sourceID) && (0...5).contains(value.sourceType)
    }
}

extension AppleEventContent {
    func ownershipFingerprint() throws -> String {
        var fields = self
        fields.url = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(fields)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Main-actor writers are serialized within this process. Revisions reject stale
/// receipts defensively; SwiftData fetch/compare/save is not a storage-level CAS.
@MainActor
final class AppleCalendarOwnershipJournal {
    let container: ModelContainer
    private let anchor: AppleCalendarAnchor
    private let selector: String?
    private let save: (ModelContext) throws -> Void
    private let linkLimit: Int
    private var selectedScope: String?
    private var verifiedInventoryRevision: Int?
    private var inventoriedTaskIDs = Set<String>()

    private struct ItemClaim: Codable, Equatable {
        var version = 1
        var taskID: String
        var linkIdentity: UUID
        var itemID: String
    }

    init(container: ModelContainer, anchor: AppleCalendarAnchor = .keychain, selector: String? = nil,
         linkLimit: Int = AppleCalendarOwnership.maximumLinks,
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.container = container
        self.anchor = anchor
        self.selector = selector
        self.linkLimit = min(max(1, linkLimit), AppleCalendarOwnership.maximumLinks)
        self.save = save
    }

    /// Check physical keys so malformed and unsupported rows also count as evidence.
    func hasOwnershipEvidence() throws -> Bool {
        let prefix = AppleCalendarOwnership.prefix
        var descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: prefix) })
        descriptor.fetchLimit = 1
        return try !context().fetchIdentifiers(descriptor).isEmpty
    }

    func scope() throws -> String {
        if let selectedScope { return selectedScope }
        let selector = try selector ?? AppleCalendarAnchor.selector(for: container)
        var token = try anchor.read(selector, false)
        if token == nil {
            guard try !hasOwnershipEvidence() else { throw CalendarSyncError.ownershipUncertain }
            token = try anchor.read(selector, true)
        }
        guard let token, token.count == 32 else { throw CalendarSyncError.ownershipUncertain }
        let scope = SHA256.hash(data: token).map { String(format: "%02x", $0) }.joined()
        selectedScope = scope
        return scope
    }

    func loadDestination() throws -> AppleCalendarOwnership.Destination? {
        try destination(in: context())
    }

    func loadLink(taskID: String) throws -> AppleCalendarOwnership.Link? {
        let context = context()
        guard let destination = try destination(in: context) else { return nil }
        let value = try link(taskID: taskID, destination: destination, in: context)
        if value != nil { inventoriedTaskIDs.insert(taskID) }
        else if inventoriedTaskIDs.contains(taskID) { throw CalendarSyncError.ownershipUncertain }
        return value
    }

    /// Enumerate only the selected local scope once per bulk pass. Payloads from
    /// other devices are never decoded. The cap prevents an unbounded inventory.
    func taskIDs() throws -> [String] {
        let scope = try scope()
        let root = AppleCalendarOwnership.prefix + scope + ":"
        let destinationID = root + "destination"
        let linkPrefix = root + "link:"
        let itemPrefix = root + "item:"
        var descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: root) })
        descriptor.fetchLimit = 2 * AppleCalendarOwnership.maximumLinks + 2
        let context = context()
        let destination = try destination(in: context)
        let rows = try context.fetch(descriptor)
        guard rows.count <= 2 * AppleCalendarOwnership.maximumLinks + 1 else { throw CalendarSyncError.ownershipUncertain }
        var ids = Set<String>()
        var tasks = Set<String>()
        var claimCount = 0
        for row in rows {
            guard ids.insert(row.id).inserted else { throw CalendarSyncError.ownershipUncertain }
            if row.id == destinationID { continue }
            if row.id.hasPrefix(itemPrefix) {
                claimCount += 1
                guard AppleCalendarOwnership.validDigest(String(row.id.dropFirst(itemPrefix.count))) else {
                    throw CalendarSyncError.ownershipUncertain
                }
                continue
            }
            guard row.id.hasPrefix(linkPrefix),
                  let data = Data(base64Encoded: String(row.id.dropFirst(linkPrefix.count))),
                  let taskID = String(data: data, encoding: .utf8), AppleCalendarOwnership.bounded(taskID),
                  row.id == linkPrefix + Data(taskID.utf8).base64EncodedString(),
                  tasks.insert(taskID).inserted else { throw CalendarSyncError.ownershipUncertain }
        }
        guard tasks.count <= AppleCalendarOwnership.maximumLinks else { throw CalendarSyncError.ownershipUncertain }
        guard tasks.count == (destination?.linkCount ?? 0), claimCount <= tasks.count else { throw CalendarSyncError.ownershipUncertain }
        // This inventory is reused only while its destination revision remains current.
        // A formerly present task never becomes new merely because its row disappears.
        verifiedInventoryRevision = destination?.revision
        inventoriedTaskIDs = tasks
        return tasks.sorted()
    }

    func load() throws -> AppleCalendarOwnership {
        var state = AppleCalendarOwnership(scope: try scope(), destination: try loadDestination())
        for id in try taskIDs() { state.links[id] = try loadLink(taskID: id) }
        return state
    }

    func persistDestination(_ value: inout AppleCalendarOwnership.Destination) throws {
        try value.validate()
        guard value.scope == (try scope()) else { throw CalendarSyncError.ownershipUncertain }
        let context = context()
        let old = try destination(in: context)
        guard (old?.revision ?? 0) == value.revision else { throw CalendarSyncError.ownershipUncertain }
        if old?.acknowledged == true, !value.acknowledged { throw CalendarSyncError.ownershipUncertain }
        var next = value
        let increment = next.revision.addingReportingOverflow(1)
        guard !increment.overflow else { throw CalendarSyncError.ownershipUncertain }
        next.revision = increment.partialValue
        try next.validate()
        try write(next, id: destinationID(next.scope), claimTaskID: nil, in: context)
        try save(context)
        value = next
    }

    func persistLink(_ value: inout AppleCalendarOwnership.Link) throws {
        let context = context()
        guard let destination = try destination(in: context) else { throw CalendarSyncError.ownershipUncertain }
        try value.validate(destination: destination)
        let old = try link(taskID: value.taskID, destination: destination, in: context)
        guard (old?.revision ?? 0) == value.revision else { throw CalendarSyncError.linkUncertain }
        if old == nil {
            try verifyAbsence(taskID: value.taskID, destination: destination, in: context)
            guard destination.linkCount < linkLimit else { throw CalendarSyncError.linkUncertain }
        }
        var next = value
        let increment = next.revision.addingReportingOverflow(1)
        guard !increment.overflow else { throw CalendarSyncError.linkUncertain }
        next.revision = increment.partialValue
        try next.validate(destination: destination)
        if let oldEvent = old?.event, oldEvent.itemID != next.event?.itemID {
            throw CalendarSyncError.linkUncertain
        }
        if let event = next.event {
            let claimID = itemID(scope: next.scope, item: event.itemID)
            if let row = try exact(claimID, in: context, failure: .linkUncertain) {
                try verifyClaim(row, link: next)
            } else {
                guard old?.event == nil else { throw CalendarSyncError.linkUncertain }
                let claim = ItemClaim(taskID: next.taskID, linkIdentity: next.identity, itemID: event.itemID)
                try write(claim, id: claimID, claimTaskID: next.taskID, in: context)
            }
        }
        try write(next, id: linkID(scope: next.scope, taskID: next.taskID), claimTaskID: nil, in: context)
        let counted = old == nil ? try changeLinkCount(destination, delta: 1, in: context) : nil
        try save(context)
        if let counted {
            verifiedInventoryRevision = counted.revision
            inventoriedTaskIDs.insert(next.taskID)
        }
        value = next
    }

    func removeLink(_ value: AppleCalendarOwnership.Link) throws {
        let context = context()
        guard let destination = try destination(in: context),
              let old = try link(taskID: value.taskID, destination: destination, in: context),
              old.revision == value.revision, old.pending?.id == value.pending?.id,
              old.pending?.action == .remove else { throw CalendarSyncError.linkUncertain }
        let id = linkID(scope: value.scope, taskID: value.taskID)
        guard let row = try exact(id, in: context, failure: .linkUncertain) else { throw CalendarSyncError.linkUncertain }
        if let event = old.event,
           let claim = try exact(itemID(scope: old.scope, item: event.itemID), in: context, failure: .linkUncertain) {
            try verifyClaim(claim, link: old)
            context.delete(claim)
        } else { throw CalendarSyncError.linkUncertain }
        context.delete(row)
        let counted = try changeLinkCount(destination, delta: -1, in: context)
        try save(context)
        if verifiedInventoryRevision == destination.revision { verifiedInventoryRevision = counted.revision }
        else { verifiedInventoryRevision = nil }
        inventoriedTaskIDs.remove(old.taskID)
    }

    private func changeLinkCount(_ destination: AppleCalendarOwnership.Destination, delta: Int,
                                 in context: ModelContext) throws -> AppleCalendarOwnership.Destination {
        var next = destination
        next.linkCount += delta
        let increment = next.revision.addingReportingOverflow(1)
        guard !increment.overflow else { throw CalendarSyncError.ownershipUncertain }
        next.revision = increment.partialValue
        try next.validate()
        try write(next, id: destinationID(next.scope), claimTaskID: nil, in: context)
        return next
    }

    /// A missing row is not positive evidence of initialization. Check residual
    /// claims for this task and scoped counts without loading any peer payloads.
    /// Bulk callers reuse their single inventory, subject to the current revision.
    private func verifyAbsence(taskID: String, destination: AppleCalendarOwnership.Destination,
                               in context: ModelContext) throws {
        guard !inventoriedTaskIDs.contains(taskID) else { throw CalendarSyncError.ownershipUncertain }
        let claimPrefix = localRoot(destination.scope) + "item:"
        var residual = FetchDescriptor<SyncMetadata>(predicate: #Predicate {
            $0.id.starts(with: claimPrefix) && $0.lastCTag == taskID
        })
        residual.fetchLimit = 1
        guard try context.fetch(residual).isEmpty else { throw CalendarSyncError.ownershipUncertain }
        if verifiedInventoryRevision != destination.revision {
            let linkPrefix = localRoot(destination.scope) + "link:"
            let links = try context.fetchCount(FetchDescriptor<SyncMetadata>(predicate: #Predicate {
                $0.id.starts(with: linkPrefix)
            }))
            let claims = try context.fetchCount(FetchDescriptor<SyncMetadata>(predicate: #Predicate {
                $0.id.starts(with: claimPrefix)
            }))
            guard links == destination.linkCount, claims <= links else { throw CalendarSyncError.ownershipUncertain }
            verifiedInventoryRevision = destination.revision
        }
    }

    private func destination(in context: ModelContext) throws -> AppleCalendarOwnership.Destination? {
        let scope = try scope()
        // Earlier interrupted/unsupported local representations remain held.
        let legacyID = AppleCalendarOwnership.prefix + scope
        guard try exact(legacyID, in: context, failure: .ownershipUncertain) == nil else { throw CalendarSyncError.ownershipUncertain }
        guard let row = try exact(destinationID(scope), in: context, failure: .ownershipUncertain) else {
            let root = localRoot(scope)
            var descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: root) })
            descriptor.fetchLimit = 1
            guard try context.fetch(descriptor).isEmpty else { throw CalendarSyncError.ownershipUncertain }
            return nil
        }
        let value: AppleCalendarOwnership.Destination = try decode(row, failure: .ownershipUncertain)
        guard value.scope == scope, row.lastCTag == nil else { throw CalendarSyncError.ownershipUncertain }
        try value.validate()
        if !value.acknowledged {
            let prefix = localRoot(scope) + "link:"
            var descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: prefix) })
            descriptor.fetchLimit = 1
            guard try context.fetch(descriptor).isEmpty else { throw CalendarSyncError.ownershipUncertain }
        }
        return value
    }

    private func link(taskID: String, destination: AppleCalendarOwnership.Destination,
                      in context: ModelContext) throws -> AppleCalendarOwnership.Link? {
        guard AppleCalendarOwnership.bounded(taskID) else { throw CalendarSyncError.linkUncertain }
        guard let row = try exact(linkID(scope: destination.scope, taskID: taskID), in: context, failure: .linkUncertain) else { return nil }
        let value: AppleCalendarOwnership.Link = try decode(row, failure: .linkUncertain)
        guard value.scope == destination.scope, value.taskID == taskID, row.lastCTag == nil else {
            throw CalendarSyncError.linkUncertain
        }
        try value.validate(destination: destination)
        try verifyUniqueItem(value, in: context)
        return value
    }

    private func verifyUniqueItem(_ link: AppleCalendarOwnership.Link, in context: ModelContext) throws {
        guard let event = link.event else { return }
        guard let row = try exact(itemID(scope: link.scope, item: event.itemID), in: context, failure: .linkUncertain) else {
            throw CalendarSyncError.linkUncertain
        }
        try verifyClaim(row, link: link)
    }

    private func verifyClaim(_ row: SyncMetadata, link: AppleCalendarOwnership.Link) throws {
        let claim: ItemClaim = try decode(row, failure: .linkUncertain)
        guard claim.version == 1, claim.taskID == link.taskID, claim.linkIdentity == link.identity,
              claim.itemID == link.event?.itemID, row.lastCTag == link.taskID else { throw CalendarSyncError.linkUncertain }
    }

    private func exact(_ id: String, in context: ModelContext, failure: CalendarSyncError) throws -> SyncMetadata? {
        var descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 2
        let rows = try context.fetch(descriptor)
        guard rows.count <= 1 else { throw failure }
        return rows.first
    }

    private func decode<T: Decodable>(_ row: SyncMetadata, failure: CalendarSyncError) throws -> T {
        guard row.collectionPath.isEmpty, row.photoFolderID == nil, row.lastFullSync == nil, let raw = row.syncToken,
              raw.utf8.count <= AppleCalendarOwnership.maximumRecordBytes,
              let value = try? JSONDecoder().decode(T.self, from: Data(raw.utf8)) else { throw failure }
        return value
    }

    private func write<T: Encodable>(_ value: T, id: String, claimTaskID: String?, in context: ModelContext) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= AppleCalendarOwnership.maximumRecordBytes else { throw CalendarSyncError.ownershipUncertain }
        let row = try exact(id, in: context, failure: .ownershipUncertain) ?? SyncMetadata(id: id, collectionPath: "")
        if row.modelContext == nil { context.insert(row) }
        row.syncToken = String(decoding: data, as: UTF8.self)
        // For item-claim rows only, retain a bounded task selector for absence admission.
        row.lastCTag = claimTaskID
    }

    private func localRoot(_ scope: String) -> String { AppleCalendarOwnership.prefix + scope + ":" }
    private func destinationID(_ scope: String) -> String { localRoot(scope) + "destination" }
    private func linkID(scope: String, taskID: String) -> String { localRoot(scope) + "link:" + Data(taskID.utf8).base64EncodedString() }
    private func itemID(scope: String, item: String) -> String {
        localRoot(scope) + "item:" + SHA256.hash(data: Data(item.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func context() -> ModelContext {
        let value = ModelContext(container)
        value.autosaveEnabled = false
        return value
    }
}
