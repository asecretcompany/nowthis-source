import Foundation
import SwiftData

protocol TaskPhotoFilesTransport: Sendable {
    func setRunDeadline(_ deadline: Date?) async
    func inspectCalendar(calendarHref: String, access: PhotoServerAccess) async throws -> PhotoCalendarAccess
    func prepareFolder(calendarHref: String, access: PhotoServerAccess) async throws -> PhotoFolder
    func resolveFolder(fileID: String, access: PhotoServerAccess) async throws -> PhotoFolder
    func resolveFolder(fileID: String, calendarHref: String, access: PhotoServerAccess) async throws -> PhotoFolder
    func upload(data: Data, contentType: String, photoID: String, folder: PhotoFolder, access: PhotoServerAccess) async throws -> String
    func download(fileID: String, access: PhotoServerAccess) async throws -> Data
    func download(fileID: String, folderFileID: String, calendarHref: String, access: PhotoServerAccess) async throws -> Data
    func delete(fileID: String, folderFileID: String, calendarHref: String, access: PhotoServerAccess) async throws
    func delete(fileID: String, access: PhotoServerAccess) async throws
}
extension NextcloudPhotoClient: TaskPhotoFilesTransport {}
extension TaskPhotoFilesTransport {
    func setRunDeadline(_ deadline: Date?) async {}
    func delete(fileID: String, folderFileID: String, calendarHref: String, access: PhotoServerAccess) async throws {
        throw TaskPhotoOriginalError.unavailable
    }
    func resolveFolder(fileID: String, calendarHref: String, access: PhotoServerAccess) async throws -> PhotoFolder {
        throw TaskPhotoOriginalError.unavailable
    }
    func download(fileID: String, folderFileID: String, calendarHref: String, access: PhotoServerAccess) async throws -> Data {
        throw TaskPhotoOriginalError.unavailable
    }
}

/// Original transfers operate on values, then recheck live models after every network await.
actor TaskPhotoSync {
    private let files: any TaskPhotoFilesTransport
    private let cache: TaskPhotoCache
    init(files: any TaskPhotoFilesTransport = NextcloudPhotoClient(), cache: TaskPhotoCache = TaskPhotoOriginals.cache) {
        self.files = files; self.cache = cache
    }

    struct Photo: Sendable {
        let id: String
        let photoID: String
        let taskID: String
        let originalFileID: String?
        let folderFileID: String?
        let contentType: String?
        let previousFolderID: String?
        let previousCalendarHref: String?
        let previousFileID: String?
        let previousAccountID: String?
    }
    struct List: Sendable {
        let href: String
        let accountID: String
        let readOnly: Bool
        let knownFolderID: String?
        let photos: [Photo]
    }

    func synchronize(listID: String, access: PhotoServerAccess, container: ModelContainer, uploadOriginals: Bool = true, deadline: Date? = nil) async throws -> Set<String> {
        guard let list = try await Self.snapshot(listID: listID, container: container) else { return [] }
        await files.setRunDeadline(deadline ?? Date().addingTimeInterval(uploadOriginals ? 300 : 15))
        var changed = Set<String>()
        let folder: PhotoFolder
        do {
            let membership = try await files.inspectCalendar(calendarHref: list.href, access: access)
            if membership.ownerID == access.username {
                folder = try await files.prepareFolder(calendarHref: list.href, access: access)
                try await Self.remember(folder: folder, listID: listID, accountID: list.accountID, container: container)
            } else if let id = list.photos.compactMap(\.folderFileID).first ?? list.knownFolderID {
                folder = try await files.resolveFolder(fileID: id, calendarHref: list.href, access: access)
            } else {
                for photo in list.photos {
                    if let id = try await Self.commit(photo, listID: listID, folderID: nil, originalID: nil,
                        status: "waiting", container: container) { changed.insert(id) }
                }
                return changed
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            for photo in list.photos {
                if let id = try await Self.commit(photo, listID: listID, folderID: nil, originalID: nil,
                    status: "unavailable", container: container) { changed.insert(id) }
            }
            return changed
        }
        guard uploadOriginals else { return changed }
        for photo in list.photos {
            try Task.checkCancellation()
            // Never copy an arbitrary remote link into a newly shared folder. Copies
            // require an explicit local task move with its retained source identity.
            if photo.originalFileID != nil { continue }
            guard !list.readOnly else { continue }
            do {
                var bytes = try await cache.load(photoID: photo.id)
                if bytes == nil, let sourceID = photo.previousFileID {
                    guard let sourceFolder = photo.previousFolderID, let sourceHref = photo.previousCalendarHref,
                          let sourceAccount = photo.previousAccountID else { throw TaskPhotoOriginalError.unavailable }
                    let source = try await Self.sourceAccess(accountID: sourceAccount, fallback: access, container: container)
                    bytes = try await files.download(fileID: sourceID, folderFileID: sourceFolder,
                        calendarHref: sourceHref, access: source)
                    if let bytes { try await cache.store(bytes, photoID: photo.id) }
                }
                guard let bytes else {
                    // This owner can provision a recipient's pending request even without its bytes.
                    if let id = try await Self.commit(photo, listID: listID, folderID: folder.fileID,
                        originalID: nil, status: "pending", container: container) { changed.insert(id) }
                    continue
                }
                let contentType: String
                if let type = photo.contentType { contentType = type }
                else {
                    guard let type = try TaskPhotoProcessor.process(bytes, keepOriginal: true).originalContentType else {
                        throw TaskPhotoOriginalError.unavailable
                    }
                    contentType = type
                }
                let fileID = try await files.upload(data: bytes, contentType: contentType,
                    photoID: photo.photoID, folder: folder, access: access)
                if let id = try await Self.commit(photo, listID: listID, folderID: folder.fileID,
                    originalID: fileID, status: "pending", container: container) { changed.insert(id) }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let id = try await Self.commit(photo, listID: listID, folderID: nil, originalID: nil,
                    status: "unavailable", container: container) { changed.insert(id) }
            }
        }
        return changed
    }

    @MainActor
    private static func snapshot(listID: String, container: ModelContainer) throws -> List? {
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let list = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first,
              let account = list.account, account.mode != .vault else { return nil }
        let key = folderKey(accountID: account.id, listID: listID)
        let known = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first?.syncToken
        let originals = FetchDescriptor<TaskPhoto>(predicate: #Predicate { $0.originalRequested })
        // The default optimized-only path should not walk large lists just to find no originals.
        if try context.fetchCount(originals) == 0 {
            guard known != nil else { return nil }
            return List(href: list.serverURL, accountID: account.id, readOnly: list.isReadOnly, knownFolderID: known, photos: [])
        }
        // Avoid nested optional predicates unsupported by older SwiftData runtimes.
        var tasks = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.taskList?.id == listID })
        tasks.relationshipKeyPathsForPrefetching = [\.photos]
        let photos = try context.fetch(tasks).flatMap(\.photos)
            .filter { $0.originalRequested && $0.pendingOperation != "remove" && $0.task?.isDeletedLocally == false }.compactMap { photo -> Photo? in
            guard let task = photo.task else { return nil }
            return Photo(id: photo.id, photoID: photo.photoID, taskID: task.id,
                originalFileID: photo.originalFileID, folderFileID: photo.folderFileID,
                contentType: photo.originalContentType, previousFolderID: photo.previousOriginalFolderID,
                previousCalendarHref: photo.previousOriginalListID.flatMap { sourceID in
                    (try? context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == sourceID })).first)?.serverURL
                }, previousFileID: photo.previousOriginalFileID, previousAccountID: photo.previousOriginalAccountID)
        }
        guard !photos.isEmpty || known != nil else { return nil }
        return List(href: list.serverURL, accountID: account.id, readOnly: list.isReadOnly, knownFolderID: known, photos: photos)
    }

    @MainActor
    private static func commit(_ photo: Photo, listID: String, folderID: String?, originalID: String?,
                               status: String, container: ModelContainer) throws -> String? {
        let id = photo.id
        let predicate = #Predicate<TaskPhoto> { $0.id == id }
        guard let current = try container.mainContext.fetch(FetchDescriptor(predicate: predicate)).first,
              let task = current.task, task.modelContext != nil, !task.isDeletedLocally,
              task.taskList?.id == listID, current.pendingOperation != "remove",
              current.originalFileID == photo.originalFileID,
              current.previousOriginalFileID == photo.previousFileID,
              current.previousOriginalFolderID == photo.previousFolderID,
              !SyncPushAcknowledgement.hasPendingChange(task, in: container.mainContext) else { return nil }
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              let storedTask = stored.task, storedTask.taskList?.id == listID,
              stored.originalFileID == photo.originalFileID, stored.pendingOperation != "remove" else { return nil }
        var payloadChanged = false
        if let originalID, originalID != stored.originalFileID {
            if stored.previousOriginalFileID == nil, let previous = stored.originalFileID {
                stored.previousOriginalFileID = previous
                stored.previousOriginalAccountID = storedTask.taskList?.account?.id
                stored.previousOriginalListID = listID
            }
            stored.originalFileID = originalID; payloadChanged = true
        }
        if let folderID, folderID != stored.folderFileID, stored.originalFileID == nil || originalID != nil {
            stored.folderFileID = folderID; payloadChanged = true
        }
        guard payloadChanged || stored.originalStatus != status else { return nil }
        stored.originalStatus = status
        if payloadChanged {
            stored.pendingOperation = "add"; storedTask.isDirty = true; storedTask.lastModifiedDate = Date()
        }
        try context.save()
        return storedTask.id
    }

    @MainActor
    private static func remember(folder: PhotoFolder, listID: String, accountID: String, container: ModelContainer) throws {
        let context = ModelContext(container); context.autosaveEnabled = false
        guard try context.fetchCount(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })) > 0 else { return }
        let key = folderKey(accountID: accountID, listID: listID)
        let row = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first
            ?? SyncMetadata(id: key, collectionPath: "")
        if row.modelContext == nil { context.insert(row) }
        guard row.syncToken != folder.fileID else { return }
        row.syncToken = folder.fileID; try context.save()
    }

    private static func folderKey(accountID: String, listID: String) -> String { "taskPhotoFolder:" + accountID + ":" + listID }

    static func sourceAccess(accountID: String, fallback: PhotoServerAccess, container: ModelContainer) async throws -> PhotoServerAccess {
        let value = try await MainActor.run { () throws -> (String, String)? in
            let context = ModelContext(container)
            guard let account = try context.fetch(FetchDescriptor<ServerAccount>(predicate: #Predicate { $0.id == accountID })).first else { return nil }
            return (account.serverBaseURL, account.username)
        }
        guard let value else { throw TaskPhotoOriginalError.unavailable }
        if value.0 == fallback.baseURL && value.1 == fallback.username { return fallback }
        guard let password = try await KeychainManager().retrieve(for: accountID) else { throw TaskPhotoOriginalError.unavailable }
        return PhotoServerAccess(baseURL: value.0, username: value.1, password: password)
    }
}
