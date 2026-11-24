import CryptoKit
import Foundation
import SwiftData

struct CalendarDestinationReceipt: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case prepared, owned, held }

    let version: Int
    let id: UUID
    let scope: AccountCredentialScope
    let home: URL
    let principal: URL?
    let collection: URL
    let creationToken: UUID
    /// The binding revision changes on proof, independently of the event inventory.
    var revision: Int
    var state: State
    var eventCount: Int

    var owned: Bool { state == .owned }
    var marker: String { "calendar-mirror-v1:\(creationToken.uuidString)" }

    init(scope: AccountCredentialScope, discovery: CalDAVDiscoveryResult) throws {
        version = 1
        id = UUID()
        self.scope = scope
        home = discovery.calendarHomeURL
        principal = discovery.principalURL
        collection = try NextcloudCalendarAddress.child(Self.childName(id), of: home, collection: true)
        creationToken = UUID()
        revision = 1
        state = .prepared
        eventCount = 0
    }

    func matches(_ discovery: CalDAVDiscoveryResult) -> Bool {
        CalDAVDiscovery.sameCollection(home, discovery.calendarHomeURL)
            && (principal == nil && discovery.principalURL == nil
                || principal.flatMap { stored in discovery.principalURL.map { CalDAVDiscovery.sameCollection(stored, $0) } } == true)
    }

    func matchesBinding(_ other: Self) -> Bool {
        id == other.id && scope == other.scope && revision == other.revision && state == other.state
            && home == other.home && principal == other.principal && collection == other.collection
            && creationToken == other.creationToken
    }

    func isValid(for scope: AccountCredentialScope) -> Bool {
        guard version == 1, self.scope == scope, scope.mode == .nextcloud,
              let origin = try? NextcloudServerAddress.parse(scope.serverBaseURL).baseURL,
              NextcloudServerAddress.sameOrigin(home, origin),
              principal.map({ NextcloudServerAddress.sameOrigin($0, origin) }) ?? true,
              let child = try? NextcloudCalendarAddress.child(Self.childName(id), of: home, collection: true),
              child.absoluteString.utf8.elementsEqual(collection.absoluteString.utf8),
              (0...CalendarReceiptStore.maximumEvents).contains(eventCount) else { return false }
        switch state {
        case .prepared: return revision == 1 && eventCount == 0
        case .owned: return revision == 2
        case .held: return revision == 2 && eventCount == 0
        }
    }

    private static func childName(_ id: UUID) -> String { "nowthis-mirror-\(id.uuidString.lowercased())" }

    static func isReserved(_ address: DAVDiscoveryAddress) -> Bool {
        guard let name = address.requestURL.path.split(separator: "/").last?.lowercased() else { return false }
        let prefix = "nowthis-mirror-"
        return name == "nowthis-calendar" || (name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil)
    }
}

struct CalendarEventAcknowledgement: Codable, Sendable, Equatable {
    let version: CalendarEventVersion
    let operation: UUID
    let bodyProof: String
    let contentProof: String
}

struct CalendarEventIntent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case create, update, remove }

    let kind: Kind
    let target: CalendarEventTarget
    let bindingID: UUID
    let bindingRevision: Int
    let receiptRevision: Int
    let operation: UUID
    let snapshot: CalendarTaskSnapshot
    let priorVersion: CalendarEventVersion?
    let stamp: Date
    let body: String?
    let bodyProof: String?
}

struct CalendarEventReceipt: Codable, Sendable, Equatable {
    let version: Int
    let bindingID: UUID
    let scope: AccountCredentialScope
    let taskID: String
    let sourceUID: String
    let originalSource: CalendarTaskSnapshot.Source
    let role: CalendarEventRole
    let eventID: UUID
    let target: CalendarEventTarget
    var revision: Int
    var acknowledged: CalendarEventAcknowledgement?
    var pending: CalendarEventIntent?
    var wasRemoved: Bool
    /// Original task/source identity survives task purge; older records remain readable but held for lifecycle work.
    var lifecycleOrigin: CalendarTaskSnapshot?
    /// Exact absence resolved an obsolete, never-acknowledged first creation.
    var cancelledFirstCreate: Bool?

    init(task: CalendarTaskSnapshot, destination: CalendarDestinationReceipt) throws {
        version = 1
        bindingID = destination.id
        scope = task.account
        taskID = task.id
        sourceUID = task.uid
        originalSource = task.source
        role = task.role
        eventID = UUID()
        target = try Self.target(for: eventID, in: destination.collection)
        revision = 0
        wasRemoved = false
        lifecycleOrigin = task.role == .managedMirror ? task : nil
    }

    fileprivate static func target(for id: UUID, in collection: URL) throws -> CalendarEventTarget {
        let uid = "nowthis-\(id.uuidString.lowercased())@nowthis.app"
        let url = try NextcloudCalendarAddress.child("\(uid).ics", of: collection, collection: false)
        return .init(href: url.absoluteString, uid: uid)
    }

    func isValid(task: CalendarTaskSnapshot, destination: CalendarDestinationReceipt) -> Bool {
        guard version == 1, destination.owned, bindingID == destination.id, scope == destination.scope,
              scope == task.account, taskID.utf8.elementsEqual(task.id.utf8), sourceUID.utf8.elementsEqual(task.uid.utf8),
              role == task.role, (1..<Int.max).contains(revision),
              (try? Self.target(for: eventID, in: destination.collection)) == target else { return false }
        if role == .managedMirror {
            if let origin = lifecycleOrigin {
                guard origin.hasConsistentMirrorIdentity, origin.source == originalSource,
                      origin.account == scope, origin.role == role, origin.id.utf8.elementsEqual(taskID.utf8),
                      origin.uid.utf8.elementsEqual(sourceUID.utf8), origin.legacyHref == nil,
                      origin.hasDueDate, !origin.deleted, CalendarReceiptKey.isDigest(origin.contentProof),
                      task.hasConsistentMirrorIdentity, task.mirrorIdentity == origin.mirrorIdentity else { return false }
            } else {
                // T7 receipts predate mirrorIdentity. Keep them usable through
                // the explicit, source-scoped route. A later pending snapshot
                // is not historical origin proof and generic inventory below
                // requires lifecycleOrigin itself.
                guard task.source == originalSource, task.legacyHref == nil,
                      CalendarReceiptKey.isDigest(task.contentProof) else { return false }
                if let pending {
                    let snapshot = pending.snapshot
                    guard snapshot.source == originalSource, snapshot.account == scope, snapshot.role == role,
                          snapshot.id.utf8.elementsEqual(taskID.utf8), snapshot.uid.utf8.elementsEqual(sourceUID.utf8),
                          snapshot.legacyHref == nil, CalendarReceiptKey.isDigest(snapshot.contentProof) else { return false }
                    if pending.kind != .remove {
                        guard snapshot.hasDueDate, !snapshot.deleted, task.hasDueDate, !task.deleted else { return false }
                    }
                } else {
                    guard acknowledged != nil || wasRemoved else { return false }
                }
            }
        } else if let origin = lifecycleOrigin {
            guard origin.source == originalSource, origin.account == scope, origin.role == role,
                  origin.id.utf8.elementsEqual(taskID.utf8), origin.uid.utf8.elementsEqual(sourceUID.utf8),
                  origin.legacyHref == nil, origin.hasDueDate, !origin.deleted,
                  CalendarReceiptKey.isDigest(origin.contentProof) else { return false }
        }
        guard revision.isMultiple(of: 2) == (pending == nil),
              !wasRemoved || (role == .managedMirror && (revision >= 4 || cancelledFirstCreate == true)) else { return false }
        if cancelledFirstCreate == true {
            guard wasRemoved, acknowledged == nil, (2...3).contains(revision),
                  pending == nil || pending?.kind == .create else { return false }
        }
        if let acknowledged {
            guard revision >= 2, !wasRemoved, target.version(acknowledged.version.etag) == acknowledged.version,
                  CalendarReceiptKey.isDigest(acknowledged.bodyProof),
                  CalendarReceiptKey.isDigest(acknowledged.contentProof) else { return false }
        }
        guard let pending else { return acknowledged != nil || wasRemoved }
        guard pending.bindingID == bindingID, pending.bindingRevision == destination.revision,
              pending.receiptRevision == revision - 1, pending.target == target,
              pending.snapshot.role == role, pending.snapshot.account == scope,
              pending.snapshot.id.utf8.elementsEqual(taskID.utf8), pending.snapshot.uid.utf8.elementsEqual(sourceUID.utf8),
              pending.snapshot.legacyHref == nil, CalendarReceiptKey.isDigest(pending.snapshot.contentProof),
              pending.priorVersion == acknowledged?.version, pending.operation != acknowledged?.operation else { return false }
        switch pending.kind {
        case .remove:
            return role == .managedMirror && acknowledged != nil && pending.body == nil && pending.bodyProof == nil
        case .create, .update:
            guard (pending.kind == .create) == (acknowledged == nil), pending.snapshot.hasDueDate,
                  !pending.snapshot.deleted, let body = pending.body,
                  let evidence = NextcloudEventBody.evidence(body, uid: target.uid) else { return false }
            if pending.kind == .create && !wasRemoved && revision != 1 { return false }
            return evidence.operation == pending.operation && evidence.proof == pending.bodyProof
        }
    }
}

enum CalendarReceiptKey {
    private static let prefix = "calendar-nextcloud-v1:"

    static var destinationPrefix: String { prefix + "destination:" }
    static var eventPrefix: String { prefix + "event:" }
    static var claimPrefix: String { prefix + "claim:" }

    static func destinations(_ account: String) -> String { prefix + "destination:" + digest(Data(account.utf8)) + ":" }
    static func events(_ account: String) -> String { prefix + "event:" + digest(Data(account.utf8)) + ":" }
    static func claims(_ account: String) -> String { prefix + "claim:" + digest(Data(account.utf8)) + ":" }

    static func destination(_ value: CalendarDestinationReceipt) throws -> String {
        let scope = value.scope
        return try destinations(scope.id) + tuple([scope.id, scope.serverBaseURL, scope.username, scope.mode.rawValue, value.id.uuidString])
    }

    static func event(task: CalendarTaskSnapshot, binding: UUID) throws -> String {
        try event(taskID: task.id, binding: binding, role: task.role, scope: task.account.id)
    }

    static func event(taskID: String, binding: UUID, role: CalendarEventRole, scope: String) throws -> String {
        try events(scope) + tuple([taskID, binding.uuidString, role.rawValue])
    }

    static func claim(_ event: CalendarEventReceipt) throws -> String {
        try claims(event.scope.id) + tuple([event.bindingID.uuidString, event.target.href])
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func tuple(_ values: [String]) throws -> String { digest(try JSONEncoder().encode(values)) }
}

/// The extra claim survives a missing event receipt. Destination counts catch the loss of both rows.
@MainActor
enum CalendarReceiptStore {
    nonisolated static let maximumEvents = 10_000
    private static let maximumRecordBytes = 768 * 1_024

    struct Held: Error {}

    /// Retained across one account invocation. Existing receipts always use targeted reads.
    struct Inventory {
        var loaded = false
        var verifiedCount: Int?
        var observed = Set<String>()
        var holdsCreation = false
    }

    struct DestinationInventory {
        var scopes: [AccountCredentialScope] = []
        var hasUnmatchedEvidence = false
        var held = false
    }

    struct ManagedTaskInventory {
        var taskIDs = Set<String>()
        var held = false
    }

    static func destinationInventory(in context: ModelContext) throws -> DestinationInventory {
        let prefix = CalendarReceiptKey.destinationPrefix
        var query = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: prefix) })
        query.fetchLimit = 1_001
        let rows = try context.fetch(query)
        var inventory = DestinationInventory()
        inventory.held = rows.count > 1_000
        var ids = Set<String>()
        for row in rows.prefix(1_000) {
            guard let receipt: CalendarDestinationReceipt = decode(row), receipt.isValid(for: receipt.scope),
                  try CalendarReceiptKey.destination(receipt) == row.id else { inventory.held = true; continue }
            guard ids.insert(receipt.scope.id).inserted else { inventory.held = true; continue }
            inventory.scopes.append(receipt.scope)
        }
        // A destination row can disappear while its event and claim records survive.
        // Check scopes from the actual account store so those leftovers cannot make a
        // purge ticket look complete merely because the destination inventory omitted it.
        let physicalEvents = try count(prefix: CalendarReceiptKey.eventPrefix, in: context)
        let physicalClaims = try count(prefix: CalendarReceiptKey.claimPrefix, in: context)
        let knownEvents = try inventory.scopes.reduce(into: 0) { total, scope in
            total += try count(prefix: CalendarReceiptKey.events(scope.id), in: context)
        }
        let knownClaims = try inventory.scopes.reduce(into: 0) { total, scope in
            total += try count(prefix: CalendarReceiptKey.claims(scope.id), in: context)
        }
        if physicalEvents != knownEvents || physicalClaims != knownClaims {
            inventory.held = true
            inventory.hasUnmatchedEvidence = true
        }
        return inventory
    }

    static func managedTaskIDs(for scope: AccountCredentialScope, in context: ModelContext) throws -> Set<String> {
        try managedTaskInventory(for: scope, in: context).taskIDs
    }

    /// A damaged peer receipt is held individually so it cannot starve verified
    /// obligations in the same destination. Global inventory loss is still reported.
    static func managedTaskInventory(for scope: AccountCredentialScope, in context: ModelContext) throws -> ManagedTaskInventory {
        guard let destination = try destination(for: scope, in: context) else { return ManagedTaskInventory() }
        var inventory = ManagedTaskInventory()
        for key in try eventKeys(for: destination, in: context) {
            do {
                guard let row = try exact(key, in: context), let event: CalendarEventReceipt = decode(row),
                      event.scope == scope, event.bindingID == destination.id,
                      try CalendarReceiptKey.event(taskID: event.taskID, binding: destination.id,
                          role: event.role, scope: event.scope.id) == key,
                      try validClaim(for: event, eventKey: key, in: context) else { throw Held() }
                if event.role == .managedMirror {
                    guard let origin = event.lifecycleOrigin,
                          origin.mirrorIdentity != nil,
                          try self.event(for: origin, destination: destination, in: context) == event else { throw Held() }
                    if !event.wasRemoved || event.pending != nil { inventory.taskIDs.insert(event.taskID) }
                } else {
                    guard event.role == .manualExport, validManualReceipt(event, destination: destination) else { throw Held() }
                }
            } catch {
                inventory.held = true
            }
        }
        let countInventory = try Self.inventory(for: destination, in: context)
        inventory.held = inventory.held || countInventory.holdsCreation
        return inventory
    }

    /// Inventory keys only; each payload and its exact claim are checked just before use.
    static func eventKeys(for destination: CalendarDestinationReceipt, in context: ModelContext) throws -> [String] {
        let prefix = CalendarReceiptKey.events(destination.scope.id)
        var query = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: prefix) },
                                                 sortBy: [SortDescriptor(\SyncMetadata.id)])
        query.propertiesToFetch = [\SyncMetadata.id]
        query.fetchLimit = maximumEvents + 1
        let keys = try context.fetch(query).map(\.id)
        guard keys.count <= maximumEvents, Set(keys).count == keys.count else { throw Held() }
        return keys
    }

    static func managedEvent(key: String, destination: CalendarDestinationReceipt, taskIDs: Set<String>? = nil,
                             in context: ModelContext) throws -> CalendarEventReceipt? {
        guard let row = try exact(key, in: context), let receipt: CalendarEventReceipt = decode(row) else { throw Held() }
        guard receipt.role == .managedMirror, taskIDs?.contains(receipt.taskID) != false else { return nil }
        guard let origin = receipt.lifecycleOrigin,
              origin.mirrorIdentity != nil,
              try CalendarReceiptKey.event(task: origin, binding: destination.id) == key,
              let checked = try event(for: origin, destination: destination, in: context), checked == receipt else { throw Held() }
        return receipt
    }

    static func destination(for scope: AccountCredentialScope, in context: ModelContext) throws -> CalendarDestinationReceipt? {
        let rows = try fetch(prefix: CalendarReceiptKey.destinations(scope.id), in: context)
        if rows.isEmpty {
            try requireNoEventEvidence(for: scope, in: context)
            return nil
        }
        guard rows.count == 1, let row = rows.first,
              let receipt: CalendarDestinationReceipt = decode(row), receipt.isValid(for: scope),
              try CalendarReceiptKey.destination(receipt) == row.id else { throw Held() }
        return receipt
    }

    static func requireNoEventEvidence(for scope: AccountCredentialScope, in context: ModelContext) throws {
        guard try fetch(prefix: CalendarReceiptKey.events(scope.id), in: context).isEmpty,
              try fetch(prefix: CalendarReceiptKey.claims(scope.id), in: context).isEmpty else { throw Held() }
    }

    static func event(for task: CalendarTaskSnapshot, destination: CalendarDestinationReceipt,
                      in context: ModelContext) throws -> CalendarEventReceipt? {
        let key = try CalendarReceiptKey.event(task: task, binding: destination.id)
        guard let row = try exact(key, in: context) else { return nil }
        let claims = try claims(eventKey: key, accountID: task.account.id, in: context)
        guard let receipt: CalendarEventReceipt = decode(row), receipt.isValid(task: task, destination: destination),
              claims.count == 1, let claim = claims.first, claim.collectionPath.isEmpty,
              try claim.id == CalendarReceiptKey.claim(receipt),
              claim.syncToken?.utf8.elementsEqual(receipt.target.href.utf8) == true else { throw Held() }
        return receipt
    }

    static func store(_ destination: CalendarDestinationReceipt, in context: ModelContext) throws {
        guard destination.isValid(for: destination.scope) else { throw Held() }
        try store(destination, key: CalendarReceiptKey.destination(destination), in: context)
    }

    static func store(_ event: CalendarEventReceipt, task: CalendarTaskSnapshot, destination: CalendarDestinationReceipt,
                      in context: ModelContext) throws {
        guard event.isValid(task: task, destination: destination) else { throw Held() }
        try store(event, key: CalendarReceiptKey.event(task: task, binding: destination.id), in: context)
    }

    static func add(_ event: CalendarEventReceipt, task: CalendarTaskSnapshot, destination: CalendarDestinationReceipt,
                    inventory: inout Inventory, in context: ModelContext) throws {
        let key = try CalendarReceiptKey.event(task: task, binding: destination.id)
        let claimKey = try CalendarReceiptKey.claim(event)
        guard !inventory.holdsCreation, destination.eventCount < maximumEvents, !inventory.observed.contains(key),
              try exact(key, in: context) == nil, try exact(claimKey, in: context) == nil,
              try claims(eventKey: key, accountID: task.account.id, in: context).isEmpty else { throw Held() }
        if inventory.verifiedCount != destination.eventCount {
            let eventCount = try count(prefix: CalendarReceiptKey.events(task.account.id), in: context)
            let claimCount = try count(prefix: CalendarReceiptKey.claims(task.account.id), in: context)
            guard eventCount == destination.eventCount, claimCount == eventCount else { throw Held() }
        }
        var updated = destination
        updated.eventCount += 1
        try store(updated, in: context)
        try store(event, task: task, destination: destination, in: context)
        let claim = SyncMetadata(id: claimKey, collectionPath: "")
        claim.lastCTag = key
        claim.syncToken = event.target.href
        context.insert(claim)
        try context.save()
        inventory.verifiedCount = updated.eventCount
        inventory.observed.insert(key)
    }

    /// Remember prior event keys across suspension without decoding peer payloads.
    /// An inconsistent inventory prevents new allocations, while a targeted owned receipt can still be used.
    static func inventory(for destination: CalendarDestinationReceipt, in context: ModelContext) throws -> Inventory {
        let prefix = CalendarReceiptKey.events(destination.scope.id)
        var descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: prefix) })
        descriptor.fetchLimit = maximumEvents + 1
        descriptor.propertiesToFetch = [\SyncMetadata.id]
        let keys = try context.fetch(descriptor).map(\.id)
        let observed = Set(keys)
        let claimCount = try count(prefix: CalendarReceiptKey.claims(destination.scope.id), in: context)
        let valid = keys.count == destination.eventCount && observed.count == keys.count && claimCount == keys.count
            && keys.allSatisfy { CalendarReceiptKey.isDigest(String($0.dropFirst(prefix.count))) }
        return Inventory(loaded: true, verifiedCount: valid ? destination.eventCount : nil,
                         observed: observed, holdsCreation: !valid)
    }

    private static func claims(eventKey: String, accountID: String, in context: ModelContext) throws -> [SyncMetadata] {
        let prefix = CalendarReceiptKey.claims(accountID)
        var descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate {
            $0.id.starts(with: prefix) && $0.lastCTag == eventKey
        })
        descriptor.fetchLimit = 2
        return try context.fetch(descriptor)
    }

    private static func validClaim(for event: CalendarEventReceipt, eventKey: String, in context: ModelContext) throws -> Bool {
        let key = try CalendarReceiptKey.claim(event)
        guard let claim = try exact(key, in: context) else { return false }
        let rows = try claims(eventKey: eventKey, accountID: event.scope.id, in: context)
        return rows.count == 1 && rows.first?.id == key && claim.collectionPath.isEmpty
            && claim.lastCTag == eventKey
            && claim.syncToken?.utf8.elementsEqual(event.target.href.utf8) == true
    }

    private static func validManualReceipt(_ event: CalendarEventReceipt, destination: CalendarDestinationReceipt) -> Bool {
        guard event.version == 1, event.role == .manualExport, event.scope == destination.scope,
              destination.owned, event.bindingID == destination.id, event.revision > 0,
              !event.wasRemoved, event.cancelledFirstCreate == nil,
              event.revision.isMultiple(of: 2) == (event.pending == nil),
              (try? CalendarEventReceipt.target(for: event.eventID, in: destination.collection)) == event.target else { return false }
        if let acknowledged = event.acknowledged {
            guard event.revision >= 2, event.target.version(acknowledged.version.etag) == acknowledged.version,
                  CalendarReceiptKey.isDigest(acknowledged.bodyProof), CalendarReceiptKey.isDigest(acknowledged.contentProof) else { return false }
        }
        if let pending = event.pending {
            guard pending.bindingID == event.bindingID, pending.bindingRevision == destination.revision,
                  pending.receiptRevision == event.revision - 1, pending.target == event.target,
                  pending.snapshot.role == .manualExport, pending.snapshot.account == event.scope,
                  pending.snapshot.id == event.taskID, pending.snapshot.uid == event.sourceUID,
                  pending.snapshot.hasDueDate, !pending.snapshot.deleted,
                  pending.priorVersion == event.acknowledged?.version,
                  pending.operation != event.acknowledged?.operation else { return false }
            switch pending.kind {
            case .create:
                guard event.acknowledged == nil, let body = pending.body,
                      let proof = NextcloudEventBody.evidence(body, uid: event.target.uid),
                      proof.operation == pending.operation, proof.proof == pending.bodyProof else { return false }
            case .update:
                guard event.acknowledged != nil, let body = pending.body,
                      let proof = NextcloudEventBody.evidence(body, uid: event.target.uid),
                      proof.operation == pending.operation, proof.proof == pending.bodyProof else { return false }
            case .remove: return false
            }
        } else if event.acknowledged == nil { return false }
        return true
    }

    private static func count(prefix: String, in context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: prefix) }))
    }

    private static func fetch(prefix: String, in context: ModelContext) throws -> [SyncMetadata] {
        var descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: prefix) })
        descriptor.fetchLimit = 2
        return try context.fetch(descriptor)
    }

    private static func exact(_ id: String, in context: ModelContext) throws -> SyncMetadata? {
        var descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 2
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else { throw Held() }
        return matches.first
    }

    private static func decode<Value: Decodable>(_ row: SyncMetadata) -> Value? {
        guard row.collectionPath.isEmpty, let json = row.syncToken, json.utf8.count <= maximumRecordBytes else { return nil }
        return try? JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }

    private static func store<Value: Encodable>(_ value: Value, key: String, in context: ModelContext) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumRecordBytes else { throw Held() }
        let row = try exact(key, in: context) ?? SyncMetadata(id: key, collectionPath: "")
        if row.modelContext == nil { context.insert(row) }
        row.syncToken = String(decoding: data, as: UTF8.self)
    }
}
