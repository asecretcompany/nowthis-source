import Foundation
import CryptoKit
import SwiftData

/// Committed work only. These tickets never establish external event ownership.
enum CalendarMirrorState {
    static let didCommit = Notification.Name("CalendarMirrorCommittedTaskChanges")
    private static let taskChangesKey = "taskChanges"

    static func storeKey(_ container: ModelContainer) -> String {
        if container.configurations.allSatisfy(\.isStoredInMemoryOnly) { return String(describing: ObjectIdentifier(container)) }
        return container.configurations.map { $0.url.standardizedFileURL.absoluteString }.sorted().joined(separator: "\u{0}")
    }

    static func publishCommit(in container: ModelContainer, includesTaskChanges: Bool) {
        NotificationCenter.default.post(name: didCommit, object: storeKey(container),
                                        userInfo: [taskChangesKey: includesTaskChanges])
    }

    static func commitIncludesTaskChanges(_ notification: Notification) -> Bool {
        notification.userInfo?[taskChangesKey] as? Bool == true
    }

    static let prefix = "calendar-mirror-work-v1:"
    private static let attributedPrefix = prefix + "task-v2:"
    private static let purgeKeyspace = attributedPrefix + "purge:"
    private static let advisoryKeyspace = attributedPrefix + "advisory:"
    static let maximumRecordBytes = 16_384
    private static let maximumPurgeTickets = 1_000
    enum Held: Error { case invalidRecord, ambiguousIdentity }

    struct Identity: Codable, Sendable, Equatable {
        let taskID: String
        let uid: String
        let created: Date
        let listID: String?
        let server: String?
        let collection: String?
        let accountID: String?
        let accountServer: String?
        let username: String?
        let mode: String?

        init(_ task: TaskItem) {
            taskID = task.id; uid = task.uid; created = task.createdDate
            listID = task.taskList?.id; server = task.taskList?.serverURL
            collection = task.taskList?.calendarPath
            let account = task.taskList?.account
            accountID = account?.id; accountServer = account?.serverBaseURL
            username = account?.username; mode = account?.mode.rawValue
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.created == rhs.created && lhs.strings.map { $0.map { Data($0.utf8) } }
                == rhs.strings.map { $0.map { Data($0.utf8) } }
        }
        private var strings: [String?] {
            [taskID, uid, listID, server, collection, accountID, accountServer, username, mode]
        }
        var isRecordSafe: Bool {
            !taskID.isEmpty && created.timeIntervalSince1970.isFinite
                && strings.allSatisfy { ($0?.utf8.count ?? 0) <= CalendarMirrorState.maximumRecordBytes }
        }
        var isValid: Bool {
            !taskID.isEmpty && !uid.isEmpty && created.timeIntervalSince1970.isFinite
                && strings.allSatisfy { ($0?.utf8.count ?? 0) <= 2_048 }
        }
        var isValidOrHeldMarker: Bool {
            isValid || (!taskID.isEmpty && uid.isEmpty && created.timeIntervalSince1970.isFinite
                && listID == nil && server == nil && collection == nil && accountID == nil
                && accountServer == nil && username == nil && mode == nil)
        }

        static func heldMarker(for identity: Self) -> Self {
            Self(taskID: identity.taskID, uid: "", created: identity.created,
                 listID: nil, server: nil, collection: nil, accountID: nil,
                 accountServer: nil, username: nil, mode: nil)
        }

        private init(taskID: String, uid: String, created: Date, listID: String?, server: String?,
                     collection: String?, accountID: String?, accountServer: String?, username: String?, mode: String?) {
            self.taskID = taskID; self.uid = uid; self.created = created
            self.listID = listID; self.server = server; self.collection = collection
            self.accountID = accountID; self.accountServer = accountServer
            self.username = username; self.mode = mode
        }
    }

    struct Ticket: Codable, Sendable, Equatable {
        var version = 1
        let id: String
        let identity: Identity
        let purged: Bool
        var taskID: String { identity.taskID }
    }

    struct PendingPage {
        let tickets: [Ticket]
        let hasUnidentifiedRecord: Bool
        let hasMore: Bool
        let nextCursor: String?
        let scannedIDs: [String]
    }

    private struct StageKey: Hashable {
        let identity: Data
        let purged: Bool
    }

    static func attributedTicketID(identity: Identity, purged: Bool, operationID: UUID = UUID()) -> String {
        attributedTicketPrefix(identity.taskID, purged: purged) + operationID.uuidString
    }

    private static func attributedTicketPrefix(_ taskID: String, purged: Bool) -> String {
        let keyspace = purged ? purgeKeyspace : advisoryKeyspace
        return keyspace + digest(Data(taskID.utf8)) + ":"
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Called before deletion invalidates relationships, and before the caller's save.
    static func stagePurge(_ tasks: [TaskItem], in context: ModelContext) throws {
        guard ReminderSchedulingJournal.isAvailable(in: context.container) else { return }
        var staged = try stageKeys(in: context)
        for task in tasks { try stage(Identity(task), purged: true, in: context, staged: &staged) }
    }

    static func enqueueTaskChanges(in context: ModelContext, retireAdvisory: Bool = true) throws {
        guard ReminderSchedulingJournal.isAvailable(in: context.container) else { return }
        var staged = try stageKeys(in: context)
        let deleted = context.deletedModelsArray.compactMap { $0 as? TaskItem }
        for task in deleted { try stage(Identity(task), purged: true, in: context, staged: &staged) }
        for case let task as TaskItem in context.insertedModelsArray {
            try stage(Identity(task), purged: false, retireAdvisory: false, in: context, staged: &staged)
        }
        for case let task as TaskItem in context.changedModelsArray {
            try stage(Identity(task), purged: false, retireAdvisory: retireAdvisory, in: context, staged: &staged)
        }
    }

    private static func stage(_ identity: Identity, purged: Bool, retireAdvisory: Bool = false, in context: ModelContext,
                              staged: inout Set<StageKey>) throws {
        // Invalid identities get a bounded marker. It retains work and blocks an
        // older valid purge ticket from proving a later deletion, but cannot match
        // a receipt or authorize an external write.
        var storedIdentity = identity.isValid ? identity : Identity.heldMarker(for: identity)
        guard storedIdentity.isRecordSafe else { return }
        var identityData = try encodedIdentity(storedIdentity)
        var key = StageKey(identity: identityData, purged: purged)
        if staged.contains(StageKey(identity: identityData, purged: true)) || (!purged && staged.contains(key)) { return }
        if !purged && retireAdvisory { retireAdvisoryTickets(taskID: identity.taskID, in: context) }
        var ticket = Ticket(version: 2, id: attributedTicketID(identity: storedIdentity, purged: purged),
                            identity: storedIdentity, purged: purged)
        var data = try JSONEncoder().encode(ticket)
        if data.count > maximumRecordBytes {
            storedIdentity = Identity.heldMarker(for: identity)
            identityData = try encodedIdentity(storedIdentity)
            key = StageKey(identity: identityData, purged: purged)
            if staged.contains(StageKey(identity: identityData, purged: true)) || (!purged && staged.contains(key)) { return }
            ticket = Ticket(version: 2, id: ticket.id, identity: storedIdentity, purged: purged)
            data = try JSONEncoder().encode(ticket)
        }
        guard data.count <= maximumRecordBytes else { return }
        let row = SyncMetadata(id: ticket.id, collectionPath: "")
        // Task ID is an index, not proof; decode compares it with the stored identity.
        row.lastCTag = storedIdentity.taskID
        row.syncToken = String(decoding: data, as: UTF8.self)
        context.insert(row)
        staged.insert(key)
    }

    private static func stageKeys(in context: ModelContext) throws -> Set<StageKey> {
        var staged = Set<StageKey>()
        for case let row as SyncMetadata in context.insertedModelsArray where row.id.hasPrefix(prefix) {
            let ticket = try decode(row)
            staged.insert(StageKey(identity: try encodedIdentity(ticket.identity), purged: ticket.purged))
        }
        return staged
    }

    /// Edit tickets are wake hints. A later committed save supersedes earlier hints
    /// for the same task; purge tickets remain complete independent evidence.
    private static func retireAdvisoryTickets(taskID: String, in context: ModelContext) {
        let keyPrefix = attributedTicketPrefix(taskID, purged: false)
        var descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: keyPrefix) },
                                                        sortBy: [SortDescriptor(\.id)])
        descriptor.fetchLimit = maximumPurgeTickets + 1
        guard let rows = try? context.fetch(descriptor), rows.count <= maximumPurgeTickets else { return }
        for row in rows {
            guard let ticket = try? decode(row), !ticket.purged else { continue }
            context.delete(row)
        }
    }

    private static func encodedIdentity(_ identity: Identity) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(identity)
    }

    static func pending(in context: ModelContext, taskID: String? = nil, excluding: Set<String> = [],
                        limit: Int = 1_000, requireComplete: Bool = false) throws -> [Ticket] {
        let page = try pendingPage(in: context, taskID: taskID, excluding: excluding, limit: limit)
        guard !page.hasUnidentifiedRecord, !(requireComplete && page.hasMore) else { throw Held.invalidRecord }
        return page.tickets
    }

    static func pendingPage(in context: ModelContext, taskID: String? = nil, excluding: Set<String> = [],
                            afterID: String? = nil, limit: Int = 1_000) throws -> PendingPage {
        let excluded = Array(excluding)
        let prefix = prefix
        let cursor = afterID ?? ""
        let descriptor: FetchDescriptor<SyncMetadata>
        if let taskID {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.id.starts(with: prefix) && $0.id > cursor && $0.lastCTag == taskID && !excluded.contains($0.id) },
                                         sortBy: [SortDescriptor(\SyncMetadata.id)])
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.id.starts(with: prefix) && $0.id > cursor && !excluded.contains($0.id) },
                                         sortBy: [SortDescriptor(\SyncMetadata.id)])
        }
        var bounded = descriptor
        let maximum = min(max(limit, 1), 1_000)
        // Read one past the cap so a truncated history can never masquerade as a
        // complete identity history (particularly at the purge boundary).
        bounded.fetchLimit = maximum + 1
        let rows = try context.fetch(bounded)
        guard Set(rows.map(\.id)).count == rows.count else { throw Held.invalidRecord }
        var tickets: [Ticket] = []
        var hasUnidentifiedRecord = false
        for row in rows.prefix(maximum) {
            do { tickets.append(try decode(row)) }
            catch { hasUnidentifiedRecord = true }
        }
        return PendingPage(tickets: tickets, hasUnidentifiedRecord: hasUnidentifiedRecord,
                           hasMore: rows.count > maximum, nextCursor: rows.prefix(maximum).last?.id,
                           scannedIDs: rows.prefix(maximum).map(\.id))
    }

    static func purge(for identity: Identity, in context: ModelContext) throws -> Ticket? {
        let tickets = try purgeEvidence(for: identity.taskID, in: context)
        guard tickets.allSatisfy({ $0.identity.isValid && $0.identity == identity }) else { throw Held.ambiguousIdentity }
        return tickets.first
    }

    static func purgeEvidence(for taskID: String, in context: ModelContext) throws -> [Ticket] {
        // Legacy work and unrecognized kinds have no reliable task attribution.
        let journalPrefix = prefix
        let purgeKeyspace = purgeKeyspace
        let advisoryKeyspace = advisoryKeyspace
        var unattributed = FetchDescriptor<SyncMetadata>(predicate: #Predicate {
            $0.id.starts(with: journalPrefix)
                && !$0.id.starts(with: purgeKeyspace) && !$0.id.starts(with: advisoryKeyspace)
        })
        unattributed.fetchLimit = 1
        guard try context.fetchIdentifiers(unattributed).isEmpty else { throw Held.invalidRecord }

        let keyPrefix = attributedTicketPrefix(taskID, purged: true)
        let advisoryPrefix = attributedTicketPrefix(taskID, purged: false)
        // The surviving index can veto proof when a key's digest changed.
        var misattributed = FetchDescriptor<SyncMetadata>(predicate: #Predicate {
            $0.lastCTag == taskID && $0.id.starts(with: journalPrefix) && !$0.id.starts(with: keyPrefix)
                && !$0.id.starts(with: advisoryPrefix)
        })
        misattributed.fetchLimit = 1
        guard try context.fetchIdentifiers(misattributed).isEmpty else { throw Held.invalidRecord }

        // An advisory-shaped key may still carry its original purge ID. Unicode
        // escapes can hide the prefix, so include those payloads when validating
        // possible contradictions among this task's indexed advisory rows.
        let unicodeEscape = "\\u"
        var advisoryCandidates = FetchDescriptor<SyncMetadata>(predicate: #Predicate {
            $0.lastCTag == taskID && $0.id.starts(with: advisoryPrefix)
                && ($0.syncToken?.contains(keyPrefix) == true || $0.syncToken?.contains(unicodeEscape) == true)
        })
        advisoryCandidates.fetchLimit = maximumPurgeTickets + 1
        let candidates = try context.fetch(advisoryCandidates)
        guard candidates.count <= maximumPurgeTickets else { throw Held.invalidRecord }
        for row in candidates { _ = try decode(row) }

        var descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: keyPrefix) },
                                                       sortBy: [SortDescriptor(\.id)])
        descriptor.fetchLimit = maximumPurgeTickets + 1
        let rows = try context.fetch(descriptor)
        guard rows.count <= maximumPurgeTickets else { throw Held.invalidRecord }
        var purges: [Ticket] = []
        for row in rows {
            let ticket = try decode(row)
            guard ticket.version == 2, ticket.purged, ticket.taskID == taskID else { throw Held.invalidRecord }
            purges.append(ticket)
        }
        return purges
    }

    /// The worker may acknowledge only the exact captured tickets, never a newer producer's work.
    static func acknowledge(_ tickets: [Ticket], in context: ModelContext) throws {
        for ticket in tickets {
            let id = ticket.id
            var query = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == id })
            query.fetchLimit = 2
            let rows = try context.fetch(query)
            guard rows.count <= 1 else { throw Held.invalidRecord }
            if let row = rows.first {
                guard try decode(row) == ticket else { throw Held.invalidRecord }
                context.delete(row)
            }
        }
    }

    private static func decode(_ row: SyncMetadata) throws -> Ticket {
        guard row.collectionPath.isEmpty, let raw = row.syncToken, raw.utf8.count <= maximumRecordBytes,
              let ticket = try? JSONDecoder().decode(Ticket.self, from: Data(raw.utf8)),
              ticket.id == row.id, ticket.id.hasPrefix(prefix),
              ticket.identity.isRecordSafe, ticket.identity.isValidOrHeldMarker,
              row.lastCTag == ticket.taskID else { throw Held.invalidRecord }
        if ticket.version == 1 {
            guard !ticket.id.hasPrefix(attributedPrefix),
                  UUID(uuidString: String(ticket.id.dropFirst(prefix.count))) != nil else { throw Held.invalidRecord }
        } else {
            let expectedPrefix = attributedTicketPrefix(ticket.taskID, purged: ticket.purged)
            guard ticket.version == 2, ticket.id.hasPrefix(expectedPrefix),
                  let uuid = UUID(uuidString: String(ticket.id.dropFirst(expectedPrefix.count))),
                  ticket.id == expectedPrefix + uuid.uuidString else { throw Held.invalidRecord }
        }
        return ticket
    }
}
