import Foundation
import SwiftData
@testable import NowThis

enum TaskPhotoJPEGFixture {
    // Fixed 4×2 JPEG, independent from the production normalizer.
    static let data = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAASABIAAD/4QBARXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAABKADAAQAAAABAAAAAgAAAAD/wAARCAACAAQDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9sAQwACAgICAgIDAgIDBQMDAwUGBQUFBQYIBgYGBgYICggICAgICAoKCgoKCgoKDAwMDAwMDg4ODg4PDw8PDw8PDw8P/9sAQwECAgIEBAQHBAQHEAsJCxAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ/90ABAAB/9oADAMBAAIRAxEAPwD0Siiiv7MP4PP/2Q==")!
}

/// Represent a scoped attachment accepted from the remote resource, preserving pending UI operations.
func acceptPhotoOriginal(_ photo: TaskPhoto, fileID: String? = nil, folderID: String? = nil,
                         in context: ModelContext) throws {
    guard let task = photo.task else { preconditionFailure("Photo fixture requires a task") }
    let operation = photo.pendingOperation
    photo.pendingOperation = nil
    var attachments = task.photos.map(\.attachment)
    if let fileID, let index = attachments.firstIndex(where: { $0.id == photo.photoID }) {
        attachments[index] = TaskPhotoAttachment(id: photo.photoID, previewData: photo.previewData,
            originalFileID: fileID, folderFileID: folderID, originalRequested: photo.originalRequested)
    }
    try TaskPhotoSyncStore.apply(attachments, opaque: task.opaqueAttachments, to: task, in: context)
    photo.pendingOperation = operation
}
