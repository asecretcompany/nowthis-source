import Foundation
import SwiftData

enum CalendarEventRole: String, Codable, Sendable {
    case managedMirror, manualExport
}

/// The committed source and content that one pending operation may acknowledge.
struct CalendarTaskSnapshot: Codable, Sendable, Equatable {
    let account: AccountCredentialScope
    let role: CalendarEventRole
    let id: String
    let uid: String
    let created: Date
    let source: Source
    let legacyHref: String?
    let modified: Date?
    let deleted: Bool
    let hasDueDate: Bool
    let contentProof: String
    let mirrorIdentity: CalendarMirrorState.Identity?

    struct Source: Codable, Sendable, Equatable {
        let listID: String?
        let server: String?
        let collection: String?
        let taskHref: String?
        let account: AccountCredentialScope?

        init(_ task: TaskItem) {
            let list = task.taskList
            listID = list?.id
            server = list?.serverURL
            collection = list?.calendarPath
            taskHref = task.remoteHref
            account = list?.account.map(AccountCredentialScope.init)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.account == rhs.account && raw(lhs.listID) == raw(rhs.listID) && raw(lhs.server) == raw(rhs.server)
                && raw(lhs.collection) == raw(rhs.collection) && raw(lhs.taskHref) == raw(rhs.taskHref)
        }

        private static func raw(_ value: String?) -> Data? { value.map { Data($0.utf8) } }
    }

    // Include content when there is no due date and thus no VEVENT payload.
    private struct Content: Encodable {
        let title: String
        let description: String?
        let status: String
        let priority: Int
        let due: Date?
        let start: Date?
        let location: String?
        let url: String?

        init(_ task: TaskItem) {
            title = task.title
            description = task.descriptionText
            status = task.status.rawValue
            priority = task.priority.rawValue
            due = task.dueDate
            start = task.startDate
            location = task.locationName
            url = task.url
        }
    }

    init(_ task: TaskItem, account: AccountCredentialScope, role: CalendarEventRole) throws {
        mirrorIdentity = CalendarMirrorState.Identity(task)
        self.account = account
        self.role = role
        id = task.id
        uid = task.uid
        created = task.createdDate
        source = Source(task)
        legacyHref = task.calendarEventHref
        modified = task.lastModifiedDate
        deleted = task.isDeletedLocally
        hasDueDate = task.dueDate != nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        contentProof = CalendarReceiptKey.digest(try encoder.encode(Content(task)))
    }

    var hasConsistentMirrorIdentity: Bool {
        guard let identity = mirrorIdentity, identity.isValid, identity.created == created else { return false }
        let expected: [String?] = [id, uid, source.listID, source.server, source.collection,
            source.account?.id, source.account?.serverBaseURL, source.account?.username, source.account?.mode.rawValue]
        let actual: [String?] = [identity.taskID, identity.uid, identity.listID, identity.server, identity.collection,
            identity.accountID, identity.accountServer, identity.username, identity.mode]
        return expected.map { $0.map { Data($0.utf8) } } == actual.map { $0.map { Data($0.utf8) } }
    }

    func matches(_ task: TaskItem) throws -> Bool {
        try Self(task, account: account, role: role) == self
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.account == rhs.account && lhs.role == rhs.role && lhs.id.utf8.elementsEqual(rhs.id.utf8)
            && lhs.uid.utf8.elementsEqual(rhs.uid.utf8) && lhs.created == rhs.created && lhs.source == rhs.source
            && lhs.legacyHref.map { Array($0.utf8) } == rhs.legacyHref.map { Array($0.utf8) }
            && lhs.modified == rhs.modified && lhs.deleted == rhs.deleted && lhs.hasDueDate == rhs.hasDueDate
            && lhs.contentProof == rhs.contentProof
    }
}

struct CalendarSyncBatch: Sendable {
    let account: AccountCredentialScope
    let discovery: NextcloudDiscoverySeed.Selection
    let tasks: [CalendarTaskSnapshot]
}

/// This actor owns every model it reads; no context or model leaves this method.
actor CalendarSnapshotReader {
    func read(accountID: String, taskID: String? = nil, includeDeleted: Bool = false, role: CalendarEventRole,
              container: ModelContainer) throws -> CalendarSyncBatch? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let account = try context.fetch(FetchDescriptor<ServerAccount>(
            predicate: #Predicate { $0.id == accountID })).first,
              account.mode != .vault else { return nil }
        let target = AccountCredentialScope(account)
        let tasks: [TaskItem]
        if let taskID {
            tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID }))
        } else {
            // Preserve existing calendar behavior: every active task is mirrored
            // into each selected account, regardless of its list's account.
            tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isDeletedLocally }))
        }
        let snapshots = try tasks.filter { includeDeleted || !$0.isDeletedLocally }
            .map { try CalendarTaskSnapshot($0, account: target, role: role) }
        guard !snapshots.isEmpty, role != .manualExport || snapshots.contains(where: \.hasDueDate) else { return nil }
        let discovery = try NextcloudDiscoverySeed.capture(accountID: target.id, serverURL: target.serverBaseURL, in: context)
        return CalendarSyncBatch(account: target, discovery: discovery, tasks: snapshots)
    }
}
