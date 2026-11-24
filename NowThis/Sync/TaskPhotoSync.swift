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
    private let keychainManager: KeychainManager
    init(files: any TaskPhotoFilesTransport = NextcloudPhotoClient(), cache: TaskPhotoCache = TaskPhotoOriginals.cache,
         keychainManager: KeychainManager = KeychainManager()) {
        self.files = files
        self.cache = cache
        self.keychainManager = keychainManager
    }

    struct Photo: Sendable {
        let id: String
        let photoID: String
        let taskID: String
        let originalFileID: String?
        let folderFileID: String?
        let contentType: String?
        let previousFolderID: String?
        let previousFileID: String?
        let retainedSource: TaskPhotoOwnership.Binding?
        let accountID: String
        let serverBaseURL: String
        let username: String
        let calendarHref: String
    }
    struct List: Sendable {
        let href: String
        let accountID: String
        let readOnly: Bool
        let knownFolderID: String?
        let serverBaseURL: String
        let username: String
        let photos: [Photo]
    }

    struct Outcome: Sendable {
        var changedTaskIDs: Set<String> = []
        var credentialsDeferred = false
    }

    func synchronize(listID: String, access: PhotoServerAccess, container: ModelContainer,
                     uploadOriginals: Bool = true, deadline: Date? = nil) async throws -> Outcome {
        var outcome = Outcome()
        guard let list = try await Self.snapshot(listID: listID, container: container) else { return outcome }
        guard list.serverBaseURL == access.baseURL, list.username == access.username else { throw TaskPhotoOwnership.Failure.missingOwner }
        await files.setRunDeadline(deadline ?? Date().addingTimeInterval(uploadOriginals ? 300 : 15))
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
                        status: "waiting", container: container) { outcome.changedTaskIDs.insert(id) }
                }
                return outcome
            }
        } catch let deferral as RetryDeferredError {
            throw deferral
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            for photo in list.photos {
                if let id = try await Self.commit(photo, listID: listID, folderID: nil, originalID: nil,
                    status: "unavailable", container: container) { outcome.changedTaskIDs.insert(id) }
            }
            return outcome
        }
        guard uploadOriginals else { return outcome }
        for photo in list.photos {
            try Task.checkCancellation()
            // Never copy an arbitrary remote link into a newly shared folder. Copies
            // require an explicit local task move with its retained source identity.
            if photo.originalFileID != nil { continue }
            guard !list.readOnly else { continue }
            do {
                var bytes = try await cache.load(photoID: photo.id)
                if photo.previousFileID != nil, photo.retainedSource == nil {
                    throw AccountCredentialDeferral.staleAccount
                }
                if bytes == nil, let binding = photo.retainedSource {
                    guard let sourceFolder = binding.folderID else { throw TaskPhotoOriginalError.unavailable }
                    let sourceAccount = binding.accountID
                    let admission = ServerRetryAdmission.current?.forAccount(sourceAccount)
                    do {
                        try await admission?.check()
                        let source = try await sourceAccess(accountID: sourceAccount, expected: binding.credentialScope,
                                                            container: container)
                        try await Self.requireRetainedSource(binding, photoID: photo.id, container: container)
                        bytes = try await ServerRetryAdmission.$current.withValue(admission) {
                            try await files.download(fileID: binding.fileID, folderFileID: sourceFolder,
                                calendarHref: binding.collectionPath, access: source)
                        }
                    } catch is RetryDeferredError where sourceAccount != list.accountID {
                        try Task.checkCancellation()
                        // The source account will be retried separately. Keep the
                        // original pending and allow other destination work.
                        continue
                    }
                    if let bytes {
                        try await Self.requireRetainedSource(binding, photoID: photo.id, container: container)
                        try await cache.store(bytes, photoID: photo.id)
                    }
                }
                guard let bytes else {
                    // This owner can provision a recipient's pending request even without its bytes.
                    if let id = try await Self.commit(photo, listID: listID, folderID: folder.fileID,
                        originalID: nil, status: "pending", container: container) { outcome.changedTaskIDs.insert(id) }
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
                if let binding = photo.retainedSource {
                    try await Self.requireRetainedSource(binding, photoID: photo.id, container: container)
                }
                let fileID = try await files.upload(data: bytes, contentType: contentType,
                    photoID: photo.photoID, folder: folder, access: access)
                if let id = try await Self.commit(photo, listID: listID, folderID: folder.fileID,
                    originalID: fileID, status: "pending", container: container) { outcome.changedTaskIDs.insert(id) }
            } catch is AccountCredentialDeferral {
                try Task.checkCancellation()
                outcome.credentialsDeferred = true
            } catch let deferral as RetryDeferredError {
                throw deferral
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let id = try await Self.commit(photo, listID: listID, folderID: nil, originalID: nil,
                    status: "unavailable", container: container) { outcome.changedTaskIDs.insert(id) }
            }
        }
        return outcome
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
            return List(href: list.serverURL, accountID: account.id, readOnly: list.isReadOnly, knownFolderID: known, serverBaseURL: account.serverBaseURL, username: account.username, photos: [])
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
                previousFileID: photo.previousOriginalFileID, retainedSource: retainedSource(for: photo, in: context),
                accountID: account.id, serverBaseURL: account.serverBaseURL, username: account.username, calendarHref: list.serverURL)
        }
        guard !photos.isEmpty || known != nil else { return nil }
        return List(href: list.serverURL, accountID: account.id, readOnly: list.isReadOnly, knownFolderID: known, serverBaseURL: account.serverBaseURL, username: account.username, photos: photos)
    }

    @MainActor
    private static func retainedSource(for photo: TaskPhoto, in context: ModelContext) -> TaskPhotoOwnership.Binding? {
        guard photo.originalFileID == nil, photo.previousOriginalFileID != nil else { return nil }
        return try? TaskPhotoOwnership.read(photo, in: context).state.retained.first
    }

    @MainActor
    private static func requireRetainedSource(
        _ expected: TaskPhotoOwnership.Binding, photoID: String, container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let sourceID = expected.listID
        guard let photo = try context.fetch(FetchDescriptor<TaskPhoto>(predicate: #Predicate { $0.id == photoID })).first,
              photo.pendingOperation != "remove", photo.task?.isDeletedLocally == false,
              retainedSource(for: photo, in: context) == expected,
              let list = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == sourceID })).first,
              let account = list.account, AccountCredentialScope(account) == expected.credentialScope,
              list.serverURL.utf8.elementsEqual(expected.collectionPath.utf8) else {
            throw AccountCredentialDeferral.staleAccount
        }
    }

    @MainActor
    private static func commit(_ photo: Photo, listID: String, folderID: String?, originalID: String?,
                               status: String, container: ModelContainer) throws -> String? {
        let id = photo.id
        let predicate = #Predicate<TaskPhoto> { $0.id == id }
        guard let current = try container.mainContext.fetch(FetchDescriptor(predicate: predicate)).first,
              let task = current.task, task.modelContext != nil, !task.isDeletedLocally,
              task.taskList?.id == listID, task.taskList?.account?.id == photo.accountID,
              task.taskList?.account?.serverBaseURL == photo.serverBaseURL, task.taskList?.account?.username == photo.username,
              task.taskList?.serverURL == photo.calendarHref, current.pendingOperation != "remove",
              current.originalFileID == photo.originalFileID,
              current.previousOriginalFileID == photo.previousFileID,
              current.previousOriginalFolderID == photo.previousFolderID,
              !SyncPushAcknowledgement.hasPendingChange(task, in: container.mainContext) else { return nil }
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let stored = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              let storedTask = stored.task, let list = storedTask.taskList, list.id == listID,
              list.account?.id == photo.accountID, list.account?.serverBaseURL == photo.serverBaseURL,
              list.account?.username == photo.username, list.serverURL == photo.calendarHref,
              stored.originalFileID == photo.originalFileID, stored.pendingOperation != "remove" else { return nil }
        var payloadChanged = false
        if let originalID, originalID != stored.originalFileID {
            let update = try TaskPhotoOwnership.accepted(stored, fileID: originalID, folderID: folderID,
                list: list, in: context)
            update.apply(in: context, normalize: true)
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

    func sourceAccess(
        accountID: String, expected: AccountCredentialScope, container: ModelContainer
    ) async throws -> PhotoServerAccess {
        switch try await AccountManager.admitCredentials(accountID: accountID, expected: expected,
                                                        container: container, keychainManager: keychainManager) {
        case .available(let credentials):
            return PhotoServerAccess(baseURL: credentials.scope.serverBaseURL,
                                     username: credentials.scope.username, password: credentials.password)
        case .missing:
            throw TaskPhotoOriginalError.unavailable
        case .deferred(let reason):
            throw reason
        }
    }
}

private extension TaskPhotoOwnership.Binding {
    var credentialScope: AccountCredentialScope {
        AccountCredentialScope(id: accountID, serverBaseURL: serverBaseURL, username: username)
    }
}
