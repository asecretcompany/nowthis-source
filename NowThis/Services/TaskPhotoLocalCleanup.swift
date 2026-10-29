import Foundation
import SwiftData

/// Confirmed local removal has no CalDAV acknowledgement to wait for.
enum TaskPhotoLocalCleanup {
    @MainActor
    static func run(photoID: String, taskID: String, container: ModelContainer,
                    cache: TaskPhotoCache = TaskPhotoOriginals.cache) async throws -> Bool {
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let photo = try context.fetch(FetchDescriptor<TaskPhoto>(predicate: #Predicate { $0.id == photoID })).first,
              photo.pendingOperation == TaskPhotoOperation.remove.rawValue,
              let task = photo.task, task.id == taskID, task.taskList?.account?.mode == .vault,
              task.pendingMoveFromHref == nil else { return false }
        context.delete(photo); try context.save()
        try await cache.remove(photoID: photoID)
        return true
    }
}
