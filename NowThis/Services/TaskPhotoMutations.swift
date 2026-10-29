import Foundation
import SwiftData

enum TaskPhotoMutationError: Error, Equatable { case readOnly, limit, invalidPreview }

/// Mutations stay on the editor context, with operations durable until CalDAV acknowledgement.
@MainActor
enum TaskPhotoMutations {
    static func add(preview: Data, originalRequested: Bool, contentType: String?,
                    to task: TaskItem, in context: ModelContext, id: String = UUID().uuidString) throws -> TaskPhoto {
        guard task.taskList?.photoAccessRevoked != true, try TaskPhotoAccessMaintenance.canEdit(task: task, container: context.container) else { throw TaskPhotoMutationError.readOnly }
        guard task.photos.filter({ $0.pendingOperation != TaskPhotoOperation.remove.rawValue }).count < 5 else { throw TaskPhotoMutationError.limit }
        guard task.modelContext != nil, UUID(uuidString: id) != nil,
              TaskPhotoAttachment.validPreview(preview) else { throw TaskPhotoMutationError.invalidPreview }
        let photo = TaskPhoto(id: id, previewData: preview,
            sortOrder: (task.photos.map(\.sortOrder).max() ?? -1) + 1)
        photo.originalRequested = originalRequested
        photo.originalContentType = contentType
        photo.pendingOperation = TaskPhotoOperation.add.rawValue
        photo.originalStatus = originalRequested ? TaskPhotoOriginalStatus.pending.rawValue : nil
        context.insert(photo); photo.task = task
        task.lastModifiedDate = Date(); task.isDirty = true
        return photo
    }

    static func remove(_ photo: TaskPhoto, from task: TaskItem, in context: ModelContext) throws {
        guard task.taskList?.photoAccessRevoked != true, try TaskPhotoAccessMaintenance.canEdit(task: task, container: context.container) else { throw TaskPhotoMutationError.readOnly }
        guard photo.task?.id == task.id else { return }
        photo.pendingOperation = TaskPhotoOperation.remove.rawValue
        task.lastModifiedDate = Date(); task.isDirty = true
    }
}
