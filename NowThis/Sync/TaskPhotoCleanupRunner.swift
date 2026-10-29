import Foundation
import SwiftData

/// Only acknowledged, scoped work whose grace period has elapsed can be swept.
/// Every SwiftData read and write is confined to a synchronous context owner.
actor TaskPhotoCleanupRunner {
    private let files: any TaskPhotoFilesTransport
    private var activeAccounts: Set<String> = []
    private static let maximumWork = 100

    init(files: any TaskPhotoFilesTransport = NextcloudPhotoClient()) {
        self.files = files
    }

    private struct Work: Sendable {
        let persistentID: PersistentIdentifier
        let id: String
        let accountID: String
        let calendarHref: String
        let fileID: String
        let folderID: String
        let notBefore: Date

        @MainActor
        init?(_ row: SyncMetadata, accountID: String, now: Date) {
            let prefix = TaskPhotoCleanupQueue.prefix + accountID + ":"
            guard row.id.hasPrefix(prefix), row.lastCTag == accountID,
                  let fileID = row.syncToken, Self.validFileID(fileID),
                  let folderID = row.photoFolderID, Self.validFileID(folderID),
                  let notBefore = row.lastFullSync, notBefore <= now,
                  !row.collectionPath.isEmpty else { return nil }
            let remainder = String(row.id.dropFirst(prefix.count))
            let suffix = ":" + fileID
            guard remainder.hasSuffix(suffix) else { return nil }
            let listID = remainder.dropLast(suffix.count)
            guard !listID.isEmpty, !listID.contains(":") else { return nil }
            persistentID = row.persistentModelID
            id = row.id
            self.accountID = accountID
            calendarHref = row.collectionPath
            self.fileID = fileID
            self.folderID = folderID
            self.notBefore = notBefore
        }

        @MainActor
        func matches(_ row: SyncMetadata) -> Bool {
            row.persistentModelID == persistentID && row.id == id
                && row.lastCTag == accountID && row.collectionPath == calendarHref
                && row.syncToken == fileID && row.photoFolderID == folderID
                && row.lastFullSync == notBefore
        }

        private static func validFileID(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 30 && value.utf8.allSatisfy { (48...57).contains($0) }
        }
    }

    func run(
        accountID: String,
        access: PhotoServerAccess,
        container: ModelContainer,
        now: Date = Date(),
        references: @Sendable (String) async throws -> Set<String>
    ) async throws -> Set<String> {
        try Task.checkCancellation()
        // Actors are reentrant during scans and HTTP requests. A second run for
        // this account must not issue a duplicate DELETE for the same queue row.
        guard activeAccounts.insert(accountID).inserted else { return [] }
        defer { activeAccounts.remove(accountID) }

        let work = try await Self.snapshot(accountID: accountID, container: container, now: now)
        try Task.checkCancellation()
        guard !work.isEmpty else { return [] }

        // The callback scans the entire accessible account, including this source
        // calendar. Finish every selected scope before the first remote mutation.
        var referenced = Set<String>()
        for path in Set(work.map(\.calendarHref)).sorted() {
            try Task.checkCancellation()
            referenced.formUnion(try await references(path))
            try Task.checkCancellation()
        }

        var deleted = Set<String>()
        for item in work {
            try Task.checkCancellation()
            guard !referenced.contains(item.fileID),
                  try await Self.canDelete(item, container: container) else { continue }
            try Task.checkCancellation()
            do {
                // An ATTACH file ID alone never authorizes a DELETE. The Files
                // transport verifies this calendar's owned folder and direct child.
                try await files.delete(fileID: item.fileID, folderFileID: item.folderID,
                    calendarHref: item.calendarHref, access: access)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // Permission, transport and other per-file errors remain durable
                // for a later sync without blocking unrelated cleanup candidates.
                continue
            }
            try Task.checkCancellation()
            deleted.insert(item.fileID)
            try await Self.acknowledge(item, container: container)
            try Task.checkCancellation()
        }
        return deleted
    }

    @MainActor
    private static func snapshot(accountID: String, container: ModelContainer, now: Date) throws -> [Work] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let prefix = TaskPhotoCleanupQueue.prefix + accountID + ":"
        let future = Date.distantFuture
        var descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate {
            $0.id.starts(with: prefix) && $0.lastCTag == accountID
                && $0.photoFolderID != nil && $0.lastFullSync != nil
                && ($0.lastFullSync ?? future) <= now
        }, sortBy: [SortDescriptor(\SyncMetadata.id)])
        descriptor.fetchLimit = maximumWork
        return try context.fetch(descriptor).compactMap { Work($0, accountID: accountID, now: now) }
    }

    @MainActor
    private static func canDelete(_ work: Work, container: ModelContainer) throws -> Bool {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return try matchedUnreferencedRow(work, context: context, container: container) != nil
    }

    @MainActor
    private static func acknowledge(_ work: Work, container: ModelContainer) throws {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let row = try matchedUnreferencedRow(work, context: context, container: container) else { return }
        try Task.checkCancellation()
        context.delete(row)
        try context.save()
    }

    @MainActor
    private static func matchedUnreferencedRow(_ work: Work, context: ModelContext,
                                               container: ModelContainer) throws -> SyncMetadata? {
        let main = container.mainContext
        let pending = main.insertedModelsArray + main.changedModelsArray + main.deletedModelsArray
        // Never acknowledge or act on an editor's pending replacement/removal of
        // the queue row, even if the persisted copy still matches the snapshot.
        guard !pending.contains(where: { model in
            guard let row = model as? SyncMetadata else { return false }
            return row.persistentModelID == work.persistentID || row.id == work.id
        }) else { return nil }

        let key = work.id
        guard let row = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first,
              work.matches(row),
              try !hasReference(work, in: context),
              try !hasReference(work, in: main) else { return nil }

        // Include pending models explicitly: an unsaved insertion or relationship
        // change may not have participated in a persistent-store fetch yet.
        for model in pending {
            if let photo = model as? TaskPhoto, protects(photo, work: work) { return nil }
            if let task = model as? TaskItem,
               task.photos.contains(where: { protects($0, work: work) }) { return nil }
        }
        return row
    }

    @MainActor
    private static func hasReference(_ work: Work, in context: ModelContext) throws -> Bool {
        let fileID = work.fileID
        let descriptor = FetchDescriptor<TaskPhoto>(predicate: #Predicate {
            $0.originalFileID == fileID || $0.previousOriginalFileID == fileID
        })
        return try context.fetch(descriptor).contains { protects($0, work: work) }
    }

    @MainActor
    private static func protects(_ photo: TaskPhoto, work: Work) -> Bool {
        let currentAccount = photo.task?.taskList?.account?.id
        if photo.originalFileID == work.fileID,
           currentAccount == nil || currentAccount == work.accountID { return true }
        // A move retains its source account even after the task enters another
        // list/account. Missing account identity is uncertain, so retain the work.
        if photo.previousOriginalFileID == work.fileID,
           photo.previousOriginalAccountID == nil || photo.previousOriginalAccountID == work.accountID { return true }
        return false
    }
}

/// Proves completeness with an ETag manifest, bounded bodies, and a final
/// unchanged manifest. This scans one calendar; the caller unions the account.
enum TaskPhotoReferenceScanner {
    static func scan(
        client: CalDAVClient,
        baseURL: String,
        calendarPath: String,
        credentials: CalDAVClient.Credentials
    ) async throws -> Set<String> {
        try Task.checkCancellation()
        let manifest = try await client.fetchTaskManifest(baseURL: baseURL,
            calendarPath: calendarPath, credentials: credentials)
        try Task.checkCancellation()
        let initial = try index(manifest)
        let formatterCache = ICalendarParser.FormatterCache()
        var references = Set<String>()
        for offset in stride(from: 0, to: manifest.count, by: 100) {
            let batch = Array(manifest[offset..<min(offset + 100, manifest.count)])
            references.formUnion(try await scanBatch(batch, client: client, baseURL: baseURL,
                calendarPath: calendarPath, credentials: credentials, formatterCache: formatterCache))
        }
        try Task.checkCancellation()
        let final = try await client.fetchTaskManifest(baseURL: baseURL,
            calendarPath: calendarPath, credentials: credentials)
        try Task.checkCancellation()
        guard try index(final) == initial else { throw CalDAVError.invalidResponse }
        return references
    }

    private static func scanBatch(_ resources: [CalDAVClient.RemoteResource], client: CalDAVClient,
                                  baseURL: String, calendarPath: String,
                                  credentials: CalDAVClient.Credentials,
                                  formatterCache: ICalendarParser.FormatterCache) async throws -> Set<String> {
        try Task.checkCancellation()
        let bodies: [CalDAVClient.RemoteTask]
        do {
            bodies = try await client.fetchTaskBatch(baseURL: baseURL, calendarPath: calendarPath,
                hrefs: resources.map(\.href), credentials: credentials)
        } catch {
            try Task.checkCancellation()
            guard resources.count > 1, isBatchLimit(error) else { throw error }
            let middle = resources.count / 2
            var references = try await scanBatch(Array(resources[..<middle]), client: client,
                baseURL: baseURL, calendarPath: calendarPath, credentials: credentials,
                formatterCache: formatterCache)
            references.formUnion(try await scanBatch(Array(resources[middle...]), client: client,
                baseURL: baseURL, calendarPath: calendarPath, credentials: credentials,
                formatterCache: formatterCache))
            return references
        }
        try Task.checkCancellation()
        let expected = try index(resources)
        guard bodies.count == resources.count else { throw CalDAVError.invalidResponse }
        var seen = Set<String>()
        var references = Set<String>()
        for body in bodies {
            try Task.checkCancellation()
            guard expected[body.href] == body.etag, seen.insert(body.href).inserted,
                  !body.icsData.isEmpty else { throw CalDAVError.invalidResponse }
            references.formUnion(try originalIDs(in: body, formatterCache: formatterCache))
        }
        guard seen == Set(expected.keys) else { throw CalDAVError.invalidResponse }
        return references
    }

    private static func originalIDs(in resource: CalDAVClient.RemoteTask,
                                    formatterCache: ICalendarParser.FormatterCache) throws -> Set<String> {
        // Shared structural validation rejects truncated components, HTML, and
        // malformed supported photos before any absence can authorize deletion.
        let parsed = try SyncBodyValidation.parse(resource, using: formatterCache)
        guard parsed.todo != nil else { throw CalDAVError.invalidResponse }
        let unfolded = ICalendarParser.unfoldLines(resource.icsData)
        let componentCount = unfolded.components(separatedBy: .newlines).filter {
            $0.trimmingCharacters(in: .whitespaces) == "BEGIN:VTODO"
        }.count
        let todos = try ICalendarParser.parseVTODOs(from: unfolded, using: formatterCache)
        // The parser skips UID-less components. Such a partial parse is unsafe
        // here; recurrence resources can have multiple VTODOs, all accounted for.
        guard componentCount > 0, todos.count == componentCount,
              todos.allSatisfy({ !$0.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CalDAVError.invalidResponse
        }
        return Set(todos.flatMap { $0.photos.compactMap(\.originalFileID) })
    }

    private static func index(_ resources: [CalDAVClient.RemoteResource]) throws -> [String: String] {
        var result: [String: String] = [:]
        for resource in resources {
            guard !resource.href.isEmpty, !resource.etag.isEmpty,
                  result.updateValue(resource.etag, forKey: resource.href) == nil else {
                throw CalDAVError.invalidResponse
            }
        }
        return result
    }

    private static func isBatchLimit(_ error: any Error) -> Bool {
        if error is DAVResponseLimitError { return true }
        if case CalDAVError.serverError(statusCode: 507) = error { return true }
        if let error = error as? HTTPRetryError { return error.statusCode == 507 }
        return false
    }
}
