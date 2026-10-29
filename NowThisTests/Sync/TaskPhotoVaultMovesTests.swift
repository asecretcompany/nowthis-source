import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite(.serialized)
@MainActor
struct TaskPhotoVaultMovesTests {
    private let access = PhotoServerAccess(baseURL: "https://vault-move.invalid", username: "alice", password: "test")
    private let fullOriginal = Data([0, 1, 2, 3, 254, 255])

    private struct Fixture: Sendable {
        let container: ModelContainer
        let cache: TaskPhotoCache
        let directory: URL
        let accountID: String
        let sourceListID: String
        let vaultListID: String
        let taskID: String
        let photoID: String
    }

    private func fixture() throws -> Fixture {
        let container = try ModelContainer(for: Schema(SchemaV2.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        let context = container.mainContext
        let sourceAccount = ServerAccount(displayName: "Cloud", serverBaseURL: access.baseURL, username: access.username)
        let vaultAccount = ServerAccount(vaultDisplayName: "Vault")
        let source = TaskList(serverURL: "/remote.php/dav/calendars/alice/source/", name: "Source", colorHex: "#007AFF")
        let vault = TaskList(serverURL: "", name: "Vault", colorHex: "#007AFF")
        context.insert(sourceAccount)
        context.insert(vaultAccount)
        context.insert(source)
        context.insert(vault)
        source.account = sourceAccount
        vault.account = vaultAccount
        let task = TaskItem(uid: "vault-photo-task", title: "Keep original")
        context.insert(task)
        task.taskList = source
        task.remoteHref = "/remote.php/dav/calendars/alice/source/vault-photo-task.ics"
        task.isLocalOnly = false
        task.attachmentStateKnown = true
        let photo = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        context.insert(photo)
        photo.task = task
        photo.originalRequested = true
        photo.originalFileID = "903"
        photo.folderFileID = "899"
        photo.originalContentType = "image/jpeg"
        photo.originalStatus = "available"
        TaskMover.move(task, to: vault, in: context)
        try context.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return Fixture(container: container, cache: TaskPhotoCache(directory: directory), directory: directory,
            accountID: sourceAccount.id, sourceListID: source.id, vaultListID: vault.id,
            taskID: task.id, photoID: photo.id)
    }

    private static func photo(_ fixture: Fixture, in context: ModelContext) throws -> TaskPhoto {
        let id = fixture.photoID
        return try #require(try context.fetch(FetchDescriptor<TaskPhoto>(predicate: #Predicate { $0.id == id })).first)
    }

    private static func task(_ fixture: Fixture, in context: ModelContext) throws -> TaskItem {
        let id = fixture.taskID
        return try #require(try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
    }

    private func expectRetainedSource(_ fixture: Fixture, status: String, changes: Set<String>) throws {
        let context = ModelContext(fixture.container)
        let stored = try Self.photo(fixture, in: context)
        let task = try Self.task(fixture, in: context)
        #expect(stored.originalStatus == status)
        #expect(stored.originalFileID == nil)
        #expect(stored.folderFileID == nil)
        #expect(stored.previousOriginalFileID == "903")
        #expect(stored.previousOriginalFolderID == "899")
        #expect(stored.previousOriginalAccountID == fixture.accountID)
        #expect(stored.previousOriginalListID == fixture.sourceListID)
        #expect(stored.pendingOperation == "add")
        #expect(task.pendingMoveFromHref == "/remote.php/dav/calendars/alice/source/vault-photo-task.ics")
        #expect(task.pendingMoveFromListID == fixture.sourceListID)
        #expect(task.taskList?.id == fixture.vaultListID)
        #expect(task.isDirty)
        #expect(changes == [fixture.taskID])
    }

    @Test func uncachedOriginalIsCopiedUsingAuthenticatedSourceScopeBeforeMarkingLocal() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let files = VaultMoveFiles(original: fullOriginal)
        let started = Date()
        let changes = try await TaskPhotoVaultMoves(files: files, cache: f.cache)
            .prepare(accountID: f.accountID, access: access, container: f.container)
        #expect(try await f.cache.load(photoID: f.photoID) == fullOriginal)
        try expectRetainedSource(f, status: "local", changes: changes)
        #expect(await files.scopedDownloads == ["903|899|/remote.php/dav/calendars/alice/source/|https://vault-move.invalid|alice|test"])
        #expect(await files.unscopedDownloads.isEmpty)
        #expect(await files.deletes.isEmpty)
        let deadline = try #require(await files.deadline)
        #expect(deadline.timeIntervalSince(started) >= 299)
        #expect(deadline.timeIntervalSince(started) < 310)
        #expect(await files.hadDeadlineAtDownload)
        let repeated = try await TaskPhotoVaultMoves(files: files, cache: f.cache)
            .prepare(accountID: f.accountID, access: access, container: f.container)
        #expect(repeated.isEmpty)
        #expect(await files.scopedDownloads.count == 1)
    }

    @Test func failedCopyKeepsSourceBindingsAndPendingMoveWithoutAcknowledgingLocal() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let files = VaultMoveFiles(failure: .unavailable)
        let changes = try await TaskPhotoVaultMoves(files: files, cache: f.cache)
            .prepare(accountID: f.accountID, access: access, container: f.container)
        #expect(try await f.cache.load(photoID: f.photoID) == nil)
        try expectRetainedSource(f, status: "unavailable", changes: changes)
        #expect(await files.deletes.isEmpty)
    }

    @Test func cachedOriginalCanBecomeLocalWhileSourceIsOffline() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await f.cache.store(fullOriginal, photoID: f.photoID)
        let files = VaultMoveFiles(failure: .unavailable)
        let changes = try await TaskPhotoVaultMoves(files: files, cache: f.cache)
            .prepare(accountID: f.accountID, access: access, container: f.container)
        #expect(try await f.cache.load(photoID: f.photoID) == fullOriginal)
        try expectRetainedSource(f, status: "local", changes: changes)
        #expect(await files.scopedDownloads.isEmpty)
        #expect(await files.unscopedDownloads.isEmpty)
    }

    @Test func cacheWriteFailureDoesNotAcknowledgeAnUnavailableOriginal() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try Data([7]).write(to: f.directory)
        let files = VaultMoveFiles(original: fullOriginal)
        let changes = try await TaskPhotoVaultMoves(files: files, cache: f.cache)
            .prepare(accountID: f.accountID, access: access, container: f.container)
        try expectRetainedSource(f, status: "unavailable", changes: changes)
    }

    @Test func missingSourceFolderNeverFallsBackToAnUnscopedDownload() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let photo = try Self.photo(f, in: f.container.mainContext)
        photo.previousOriginalFolderID = nil
        try f.container.mainContext.save()
        let files = VaultMoveFiles(original: fullOriginal)
        _ = try await TaskPhotoVaultMoves(files: files, cache: f.cache)
            .prepare(accountID: f.accountID, access: access, container: f.container)
        let stored = try Self.photo(f, in: ModelContext(f.container))
        #expect(stored.originalStatus == "unavailable")
        #expect(stored.previousOriginalFileID == "903")
        #expect(stored.task?.pendingMoveFromHref != nil)
        #expect(try await f.cache.load(photoID: f.photoID) == nil)
        #expect(await files.scopedDownloads.isEmpty)
        #expect(await files.unscopedDownloads.isEmpty)
    }

    @Test func anotherSourceAccountIsNotCopiedOrMarkedLocal() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await f.cache.store(fullOriginal, photoID: f.photoID)
        let files = VaultMoveFiles(original: fullOriginal)
        let changes = try await TaskPhotoVaultMoves(files: files, cache: f.cache)
            .prepare(accountID: "another-account", access: access, container: f.container)
        #expect(changes.isEmpty)
        #expect(try Self.photo(f, in: ModelContext(f.container)).originalStatus == "pending")
        #expect(await files.scopedDownloads.isEmpty)
    }

    @Test func cancellationDuringDownloadPropagatesAndKeepsMovePending() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let files = VaultMoveFiles(failure: .cancelled)
        do {
            _ = try await TaskPhotoVaultMoves(files: files, cache: f.cache)
                .prepare(accountID: f.accountID, access: access, container: f.container)
            Issue.record("Cancellation must propagate to the caller")
        } catch is CancellationError {
            #expect(try Self.photo(f, in: ModelContext(f.container)).originalStatus == "pending")
            #expect(try Self.task(f, in: ModelContext(f.container)).pendingMoveFromHref != nil)
            #expect(try await f.cache.load(photoID: f.photoID) == nil)
        }
    }

    enum ConcurrentChange: String, Sendable, CaseIterable {
        case unsavedPhotoEdit, unsavedTaskEdit, savedPhotoEdit, movedTask, changedSourceBinding, deletedPhoto, deletedTask
    }

    @Test(arguments: ConcurrentChange.allCases)
    func staleDownloadNeverAcknowledgesLocalOrOverwritesAnotherContextsCache(change: ConcurrentChange) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let replacement = Data([9, 8, 7, 6])
        let files = VaultMoveFiles(original: fullOriginal, duringDownload: {
            try await f.cache.store(replacement, photoID: f.photoID)
            try await Self.make(change, in: f)
        })
        let changes = try await TaskPhotoVaultMoves(files: files, cache: f.cache)
            .prepare(accountID: f.accountID, access: access, container: f.container)
        #expect(changes.isEmpty)
        #expect(try await f.cache.load(photoID: f.photoID) == replacement)
        let fresh = ModelContext(f.container)
        let photos = try fresh.fetch(FetchDescriptor<TaskPhoto>())
        #expect(photos.allSatisfy { $0.originalStatus != "local" })
        let tasks = try fresh.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.allSatisfy { $0.pendingMoveFromHref != nil })
        #expect(await files.deletes.isEmpty)
        if change == .unsavedPhotoEdit {
            #expect(try Self.photo(f, in: f.container.mainContext).originalRequested == false)
            #expect(try Self.photo(f, in: fresh).originalRequested)
        }
        if change == .unsavedTaskEdit {
            #expect(try Self.task(f, in: f.container.mainContext).title == "Still editing")
            #expect(try Self.task(f, in: fresh).title == "Keep original")
        }
    }

    private static func make(_ change: ConcurrentChange, in f: Fixture) throws {
        if change == .unsavedPhotoEdit {
            try photo(f, in: f.container.mainContext).originalRequested = false
            return
        }
        if change == .unsavedTaskEdit {
            try task(f, in: f.container.mainContext).title = "Still editing"
            return
        }
        let context = ModelContext(f.container)
        context.autosaveEnabled = false
        let stored = try photo(f, in: context)
        switch change {
        case .savedPhotoEdit:
            stored.originalRequested = false
        case .movedTask:
            let destination = TaskList(serverURL: "", name: "Another Vault", colorHex: "#007AFF")
            context.insert(destination)
            destination.account = stored.task?.taskList?.account
            TaskMover.move(try #require(stored.task), to: destination, in: context)
        case .changedSourceBinding:
            stored.previousOriginalFileID = "different-original"
        case .deletedPhoto:
            context.delete(stored)
        case .deletedTask:
            context.delete(try #require(stored.task))
        case .unsavedPhotoEdit, .unsavedTaskEdit:
            break
        }
        try context.save()
    }
}

/// Exercises real cache and persistence while controlling the external Files boundary.
private actor VaultMoveFiles: TaskPhotoFilesTransport {
    enum Failure: Sendable { case unavailable, cancelled }
    private let original: Data
    private let failure: Failure?
    private let duringDownload: (@Sendable () async throws -> Void)?
    private(set) var scopedDownloads: [String] = []
    private(set) var unscopedDownloads: [String] = []
    private(set) var deletes: [String] = []
    private(set) var deadline: Date?
    private(set) var hadDeadlineAtDownload = false

    init(original: Data = Data(), failure: Failure? = nil, duringDownload: (@Sendable () async throws -> Void)? = nil) {
        self.original = original
        self.failure = failure
        self.duringDownload = duringDownload
    }

    func setRunDeadline(_ deadline: Date?) { self.deadline = deadline }

    func download(fileID: String, folderFileID: String, calendarHref: String, access: PhotoServerAccess) async throws -> Data {
        scopedDownloads.append([fileID, folderFileID, calendarHref, access.baseURL, access.username, access.password].joined(separator: "|"))
        hadDeadlineAtDownload = deadline != nil
        try await duringDownload?()
        switch failure {
        case .unavailable: throw TaskPhotoOriginalError.unavailable
        case .cancelled: throw CancellationError()
        case nil: return original
        }
    }

    func download(fileID: String, access: PhotoServerAccess) throws -> Data {
        unscopedDownloads.append(fileID)
        throw TaskPhotoOriginalError.unavailable
    }

    func delete(fileID: String, access: PhotoServerAccess) throws {
        deletes.append(fileID)
        throw TaskPhotoOriginalError.unavailable
    }

    func delete(fileID: String, folderFileID: String, calendarHref: String, access: PhotoServerAccess) throws {
        deletes.append(fileID)
        throw TaskPhotoOriginalError.unavailable
    }

    func inspectCalendar(calendarHref: String, access: PhotoServerAccess) throws -> PhotoCalendarAccess {
        throw TaskPhotoOriginalError.unavailable
    }

    func prepareFolder(calendarHref: String, access: PhotoServerAccess) throws -> PhotoFolder {
        throw TaskPhotoOriginalError.unavailable
    }

    func resolveFolder(fileID: String, access: PhotoServerAccess) throws -> PhotoFolder {
        throw TaskPhotoOriginalError.unavailable
    }

    func upload(data: Data, contentType: String, photoID: String, folder: PhotoFolder, access: PhotoServerAccess) throws -> String {
        throw TaskPhotoOriginalError.unavailable
    }
}
