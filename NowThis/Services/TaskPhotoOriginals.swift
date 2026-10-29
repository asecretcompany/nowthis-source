import Foundation
import SwiftData

/// Local originals use local UUIDs, keeping caches separate for each account's model rows.
enum TaskPhotoOriginals {
    static let cache: TaskPhotoCache = {
        let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return TaskPhotoCache(directory: root.appendingPathComponent("Application Support/TaskPhotoOriginals", isDirectory: true))
    }()

    @MainActor
    static func load(photoID: String, taskID: String, container: ModelContainer) async throws -> Data {
        let before = try read(photoID: photoID, taskID: taskID, container: container)
        if let data = try await cache.load(photoID: photoID) {
            try Task.checkCancellation()
            guard try read(photoID: photoID, taskID: taskID, container: container) == before else {
                throw TaskPhotoOriginalError.unavailable
            }
            return data
        }
        do {
            guard let fileID = before.fileID, let folderID = before.folderID,
                  let accountID = before.accountID, let baseURL = before.baseURL,
                  let username = before.username, let href = before.calendarHref,
                  let password = try await KeychainManager().retrieve(for: accountID) else {
                throw TaskPhotoOriginalError.unavailable
            }
            let access = PhotoServerAccess(baseURL: baseURL, username: username, password: password)
            let data = try await NextcloudPhotoClient().download(fileID: fileID, folderFileID: folderID,
                calendarHref: href, access: access)
            try Task.checkCancellation()
            guard try read(photoID: photoID, taskID: taskID, container: container) == before else {
                throw TaskPhotoOriginalError.unavailable
            }
            try await cache.store(data, photoID: photoID)
            guard try read(photoID: photoID, taskID: taskID, container: container) == before else {
                try? await cache.remove(photoID: photoID)
                throw TaskPhotoOriginalError.unavailable
            }
            try markStatus(TaskPhotoOriginalStatus.available.rawValue, photoID: photoID, container: container)
            return data
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            try? markStatus(TaskPhotoOriginalStatus.unavailable.rawValue, photoID: photoID, container: container)
            throw error
        }
    }

    private struct Read: Sendable, Equatable {
        let fileID: String?
        let folderID: String?
        let accountID: String?
        let baseURL: String?
        let username: String?
        let calendarHref: String?
    }

    @MainActor
    private static func read(photoID: String, taskID: String, container: ModelContainer) throws -> Read {
        guard let task = try container.mainContext.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first,
              task.modelContext != nil, !task.isDeletedLocally, task.taskList?.photoAccessRevoked != true,
              let photo = task.photos.first(where: { $0.modelContext != nil && $0.id == photoID && $0.pendingOperation != TaskPhotoOperation.remove.rawValue }),
              photo.originalRequested else { throw TaskPhotoOriginalError.unavailable }
        guard try TaskPhotoAccessMaintenance.canView(task: task, container: container) else {
            throw TaskPhotoOriginalError.unavailable
        }
        let account = task.taskList?.account
        return Read(fileID: photo.originalFileID, folderID: photo.folderFileID, accountID: account?.id,
            baseURL: account?.serverBaseURL, username: account?.username, calendarHref: task.taskList?.serverURL)
    }

    @MainActor
    private static func markStatus(_ status: String, photoID: String, container: ModelContainer) throws {
        let context = ModelContext(container); context.autosaveEnabled = false
        let predicate = #Predicate<TaskPhoto> { $0.id == photoID }
        guard let photo = try context.fetch(FetchDescriptor(predicate: predicate)).first,
              photo.pendingOperation != TaskPhotoOperation.remove.rawValue, photo.task?.isDeletedLocally == false else { return }
        photo.originalStatus = status; try context.save()
    }
}

enum TaskPhotoOriginalError: Error { case unavailable }
