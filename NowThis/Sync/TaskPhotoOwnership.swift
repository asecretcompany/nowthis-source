import Foundation
import SwiftData

/// Exact accepted-writer provenance. This is retention state, never permission to delete a file.
struct TaskPhotoOwnership: Codable, Sendable, Equatable {
    static let prefix = "taskPhotoOwnership:"
    var version = 1
    let taskID: String
    let photoID: String
    var current: Binding?
    var retained: [Binding] = []

    /// Captured before an authenticated read; passed back with its response.
    /// T3/T4 may reuse this value without changing account replacement policy.
    struct Scope: Codable, Sendable, Equatable {
        let accountID: String
        let listID: String
        let collectionPath: String
        let serverBaseURL: String
        let username: String

        init(accountID: String, listID: String, collectionPath: String, serverBaseURL: String, username: String) {
            self.accountID = accountID; self.listID = listID; self.collectionPath = collectionPath
            self.serverBaseURL = serverBaseURL; self.username = username
        }

        init?(list: TaskList?) {
            guard let list, let account = list.account, account.mode == .nextcloud else { return nil }
            self.init(accountID: account.id, listID: list.id, collectionPath: list.serverURL,
                serverBaseURL: account.serverBaseURL, username: account.username)
        }

        func matches(_ list: TaskList?) -> Bool { Self(list: list) == self }

        func matchesExactScope(_ other: Self) -> Bool {
            accountID == other.accountID && listID == other.listID
                && collectionPath.utf8.elementsEqual(other.collectionPath.utf8)
                && serverBaseURL.utf8.elementsEqual(other.serverBaseURL.utf8)
                && username.utf8.elementsEqual(other.username.utf8)
        }

        func requireList(in context: ModelContext) throws -> TaskList {
            let id = listID
            let list = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == id })).first
            guard let list, let saved = Self(list: list), saved.matchesExactScope(self) else {
                throw CancellationError()
            }
            return list
        }
    }

    struct Binding: Codable, Sendable, Equatable {
        let fileID: String
        let folderID: String?
        let accountID: String
        let listID: String
        let collectionPath: String
        let serverBaseURL: String
        let username: String

        init(fileID: String, folderID: String?, list: TaskList) throws {
            guard let account = list.account, account.mode == .nextcloud else { throw Failure.missingOwner }
            self.fileID = fileID; self.folderID = folderID
            accountID = account.id; listID = list.id; collectionPath = list.serverURL
            serverBaseURL = account.serverBaseURL; username = account.username
            try validate()
        }

        func validate() throws {
            func numeric(_ value: String) -> Bool {
                !value.isEmpty && value.count <= 30 && value.utf8.allSatisfy { (48...57).contains($0) }
            }
            guard numeric(fileID), folderID.map(numeric) != false,
                  !accountID.isEmpty, !accountID.contains(":"), !listID.isEmpty, !listID.contains(":"),
                  !collectionPath.isEmpty, !serverBaseURL.isEmpty, !username.isEmpty else { throw Failure.malformed }
        }

        func matches(_ list: TaskList) -> Bool {
            list.id == listID && list.serverURL == collectionPath && list.account?.id == accountID
                && list.account?.mode == .nextcloud && list.account?.serverBaseURL == serverBaseURL
                && list.account?.username == username
        }
    }

    enum Failure: Error { case malformed, missingOwner, unsupportedVersion, contradictory }
    struct Reads {
        var row: (ModelContext, FetchDescriptor<SyncMetadata>) throws -> SyncMetadata? = { try $0.fetch($1).first }
        var list: (ModelContext, String) throws -> TaskList? = { context, id in
            try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == id })).first
        }
    }

    /// A fully prepared write has no remaining reads or encoding failures. Move preflight
    /// prepares every node before changing relationships, photo fields, or source markers.
    struct Update {
        let photo: TaskPhoto
        let row: SyncMetadata
        let state: TaskPhotoOwnership
        let json: String
        func apply(in context: ModelContext, normalize: Bool = false) {
            if row.modelContext == nil { context.insert(row) }
            row.syncToken = json
            if normalize {
                photo.originalFileID = state.current?.fileID; photo.folderFileID = state.current?.folderID
                photo.previousOriginalFileID = state.retained.first?.fileID
                photo.previousOriginalFolderID = state.retained.first?.folderID
                photo.previousOriginalAccountID = state.retained.first?.accountID
                photo.previousOriginalListID = state.retained.first?.listID
            }
        }
    }

    struct Record {
        let photo: TaskPhoto
        let row: SyncMetadata?
        var state: TaskPhotoOwnership
        func update(_ next: TaskPhotoOwnership) throws -> Update {
            try next.validate()
            return Update(photo: photo, row: row ?? SyncMetadata(id: prefix + photo.id, collectionPath: ""),
                state: next, json: String(decoding: try JSONEncoder().encode(next), as: UTF8.self))
        }
    }

    func validate() throws {
        guard version == 1 else { throw Failure.unsupportedVersion }
        guard UUID(uuidString: taskID) != nil, UUID(uuidString: photoID) != nil else { throw Failure.malformed }
        let all = [current].compactMap { $0 } + retained
        for binding in all { try binding.validate() }
        for (index, binding) in all.enumerated() {
            guard !all.prefix(index).contains(where: {
                $0.accountID == binding.accountID && $0.listID == binding.listID && $0.fileID == binding.fileID
            }) else { throw Failure.contradictory }
        }
    }

    static func read(_ photo: TaskPhoto, in context: ModelContext, reads: Reads = .init(),
                     acceptingCurrent: Bool = false) throws -> Record {
        guard let task = photo.task else { throw Failure.missingOwner }
        let key = prefix + photo.id
        let row = try reads.row(context, FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key }))
        var state = Self(taskID: task.id, photoID: photo.id)
        if let row {
            guard row.collectionPath.isEmpty, let json = row.syncToken, let bytes = json.data(using: .utf8) else {
                throw Failure.malformed
            }
            do { state = try JSONDecoder().decode(Self.self, from: bytes) }
            catch { throw Failure.malformed }
            try state.validate()
            guard state.taskID == task.id, state.photoID == photo.id else { throw Failure.contradictory }
        }
        if let file = photo.previousOriginalFileID {
            if row == nil {
                guard let listID = photo.previousOriginalListID, let accountID = photo.previousOriginalAccountID,
                      let list = try reads.list(context, listID), list.account?.id == accountID else { throw Failure.missingOwner }
                state.retained = [try Binding(fileID: file, folderID: photo.previousOriginalFolderID, list: list)]
            }
            guard let previous = state.retained.first, previous.fileID == file,
                  previous.folderID == photo.previousOriginalFolderID,
                  previous.accountID == photo.previousOriginalAccountID, previous.listID == photo.previousOriginalListID else {
                throw Failure.contradictory
            }
        } else if !state.retained.isEmpty || photo.previousOriginalFolderID != nil
                    || photo.previousOriginalAccountID != nil || photo.previousOriginalListID != nil {
            throw Failure.contradictory
        }
        if !acceptingCurrent || row != nil {
            guard state.current?.fileID == photo.originalFileID,
                  state.current == nil || state.current?.folderID == photo.folderFileID else { throw Failure.missingOwner }
        }
        for binding in [state.current].compactMap({ $0 }) + state.retained {
            guard let list = try reads.list(context, binding.listID), binding.matches(list) else { throw Failure.missingOwner }
        }
        return Record(photo: photo, row: row, state: state)
    }

    mutating func retain(_ binding: Binding?) throws {
        guard let binding else { return }
        if let existing = retained.first(where: {
            $0.accountID == binding.accountID && $0.listID == binding.listID && $0.fileID == binding.fileID
        }) {
            guard existing == binding else { throw Failure.contradictory }
        } else { retained.append(binding) }
    }

    static func accepted(_ photo: TaskPhoto, fileID: String?, folderID: String?, list: TaskList,
                         in context: ModelContext) throws -> Update {
        let record = try read(photo, in: context, acceptingCurrent: true)
        if record.row == nil, photo.originalFileID != nil {
            // A new response proves only its own tuple. It cannot erase a different,
            // unproven original retained from an older client.
            guard photo.originalFileID == fileID, photo.folderFileID == folderID else { throw Failure.missingOwner }
        }
        var next = record.state
        let binding = try fileID.map { try Binding(fileID: $0, folderID: folderID, list: list) }
        if next.current != binding { try next.retain(next.current) }
        next.current = binding
        // An authenticated attachment may reselect one of the retained originals.
        next.retained.removeAll { $0 == binding }
        return try record.update(next)
    }

    static func records(_ task: TaskItem, in context: ModelContext, reads: Reads = .init()) throws -> [Record] {
        try task.photos.sorted { $0.id < $1.id }.map { try read($0, in: context, reads: reads) }
    }

    static func retains(fileID: String, accountID: String, in context: ModelContext) throws -> Bool {
        let prefix = Self.prefix
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: prefix) }))
        let photos = try context.fetch(FetchDescriptor<TaskPhoto>())
        let liveKeys = Set(photos.map { prefix + $0.id })
        for row in rows where liveKeys.contains(row.id) {
            guard row.collectionPath.isEmpty, let json = row.syncToken,
                  let bytes = json.data(using: .utf8) else { throw Failure.malformed }
            let state = try JSONDecoder().decode(Self.self, from: bytes)
            try state.validate()
            guard row.id == prefix + state.photoID else { throw Failure.contradictory }
            if ([state.current].compactMap { $0 } + state.retained).contains(where: {
                $0.fileID == fileID && $0.accountID == accountID
            }) { return true }
        }
        return false
    }

    static func remove(_ task: TaskItem, in context: ModelContext) throws {
        let rows = try records(task, in: context).compactMap(\.row)
        for row in rows { context.delete(row) }
    }
}
