import Foundation
import SwiftData

/// A bounded preview owned by a task. Originals live in an opaque local Files cache.
@Model
final class TaskPhoto {
    @Attribute(.unique) var id: String
    /// Wire UUID may occur in multiple accounts; only local id is globally unique.
    var photoID: String
    @Attribute(.externalStorage) var previewData: Data
    var sortOrder: Int = 0
    var originalRequested: Bool = false
    var originalFileID: String?
    var folderFileID: String?
    var originalContentType: String?
    /// nil = acknowledged; add/remove persist until the VTODO operation is acknowledged.
    var pendingOperation: String?
    var originalStatus: String?
    var previousOriginalFolderID: String?
    var previousOriginalFileID: String?
    var previousOriginalAccountID: String?
    var previousOriginalListID: String?
    var task: TaskItem?

    init(id: String = UUID().uuidString, photoID: String = UUID().uuidString, previewData: Data, sortOrder: Int = 0) {
        self.id = id
        self.photoID = photoID
        self.previewData = previewData
        self.sortOrder = sortOrder
    }
    var attachment: TaskPhotoAttachment {
        TaskPhotoAttachment(id: photoID, previewData: previewData,
            originalFileID: originalFileID, folderFileID: folderFileID,
            originalRequested: originalRequested)
    }

}

/// Persisted protocol states stay stable and are never displayed without localized copy.
enum TaskPhotoOperation: String { case add, remove }
enum TaskPhotoOriginalStatus: String { case pending, waiting, available, unavailable, local }
