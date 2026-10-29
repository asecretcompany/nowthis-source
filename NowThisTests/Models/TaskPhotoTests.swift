import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite(.serialized)
@MainActor
struct TaskPhotoTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(SchemaV2.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private let preview = TaskPhotoJPEGFixture.data

    @Test func addingPhotoMarksTaskDirtyAndRetainsPreview() throws {
        let c = try container(); let context = c.mainContext
        let task = TaskItem(title: "Check moon cheese"); context.insert(task)
        task.isDirty = false
        let photo = try TaskPhotoMutations.add(preview: preview, originalRequested: false,
            contentType: nil, to: task, in: context)
        try context.save()
        #expect(task.isDirty)
        #expect(task.photos.count == 1)
        #expect(photo.previewData == preview)
        #expect(photo.pendingOperation == "add")
    }
    @Test func sixthPhotoIsRefusedWithoutDiscardingFive() throws {
        let c = try container(); let task = TaskItem(title: "Inventory"); c.mainContext.insert(task)
        for _ in 0..<5 {
            _ = try TaskPhotoMutations.add(preview: preview, originalRequested: false,
                contentType: nil, to: task, in: c.mainContext)
        }
        #expect(throws: TaskPhotoMutationError.limit) {
            try TaskPhotoMutations.add(preview: preview, originalRequested: false,
                contentType: nil, to: task, in: c.mainContext)
        }
        #expect(task.photos.count == 5)
    }
    @Test func sharedReaderCannotAddOrRemove() throws {
        let c = try container(); let task = TaskItem(title: "Shared"); c.mainContext.insert(task)
        let list = TaskList(serverURL: "https://cloud.example.com/list/", name: "Team", colorHex: "#007AFF")
        list.isReadOnly = true; c.mainContext.insert(list); task.taskList = list
        let photo = TaskPhoto(previewData: preview); c.mainContext.insert(photo); photo.task = task
        #expect(throws: TaskPhotoMutationError.readOnly) {
            try TaskPhotoMutations.add(preview: preview, originalRequested: false,
                contentType: nil, to: task, in: c.mainContext)
        }
        #expect(throws: TaskPhotoMutationError.readOnly) {
            try TaskPhotoMutations.remove(photo, from: task, in: c.mainContext)
        }
        #expect(photo.pendingOperation == nil)
    }
    @Test func removalRetainsAcknowledgedPhotoUntilServerWrite() throws {
        let c = try container(); let task = TaskItem(title: "Shared"); c.mainContext.insert(task)
        let photo = TaskPhoto(previewData: preview); c.mainContext.insert(photo); photo.task = task
        try TaskPhotoMutations.remove(photo, from: task, in: c.mainContext)
        #expect(photo.pendingOperation == "remove")
        #expect(task.isDirty)
        #expect(task.photos.count == 1)
    }
    @Test func deletingTaskCascadesItsPhotos() throws {
        let c = try container(); let task = TaskItem(title: "Local"); c.mainContext.insert(task)
        let photo = TaskPhoto(previewData: preview); c.mainContext.insert(photo); photo.task = task
        try c.mainContext.save(); c.mainContext.delete(task); try c.mainContext.save()
        let fresh = ModelContext(c)
        #expect(try fresh.fetchCount(FetchDescriptor<TaskPhoto>()) == 0)
    }
    @Test func cachedOriginalCanBeViewedOffline() async throws {
        let c = try container(); let task = TaskItem(title: "Offline photo"); c.mainContext.insert(task)
        let photo = TaskPhoto(previewData: preview); photo.originalRequested = true
        c.mainContext.insert(photo); photo.task = task; try c.mainContext.save()
        let bytes = Data([1, 2, 3, 4])
        try await TaskPhotoOriginals.cache.store(bytes, photoID: photo.id)
        let result = try await TaskPhotoOriginals.load(photoID: photo.id, taskID: task.id, container: c)
        #expect(result == bytes)
        try await TaskPhotoOriginals.cache.remove(photoID: photo.id)
    }

    @Test func vaultRemovalReleasesPreviewAndOriginalAfterLocalSave() async throws {
        let c = try container()
        let account = ServerAccount(displayName: "Vault", serverBaseURL: "", username: "", mode: .vault)
        let list = TaskList(serverURL: "", name: "Local", colorHex: "#007AFF")
        let task = TaskItem(title: "Local")
        c.mainContext.insert(account); c.mainContext.insert(list); list.account = account
        c.mainContext.insert(task); task.taskList = list
        let photo = TaskPhoto(previewData: preview); c.mainContext.insert(photo); photo.task = task
        let photoID = photo.id; let taskID = task.id
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = TaskPhotoCache(directory: url)
        try await cache.store(Data([1, 2]), photoID: photoID)
        try TaskPhotoMutations.remove(photo, from: task, in: c.mainContext); try c.mainContext.save()
        #expect(try await TaskPhotoLocalCleanup.run(photoID: photoID, taskID: taskID, container: c, cache: cache))
        #expect(try ModelContext(c).fetchCount(FetchDescriptor<TaskPhoto>()) == 0)
        #expect(try await cache.load(photoID: photoID) == nil)
    }


    @Test func confirmedLostListAccessBlocksPhotoMutations() throws {
        let c = try container(); let list = TaskList(serverURL: "/shared/", name: "Shared", colorHex: "#007AFF")
        list.photoAccessRevoked = true; c.mainContext.insert(list)
        let task = TaskItem(title: "Shared"); c.mainContext.insert(task); task.taskList = list
        let photo = TaskPhoto(previewData: preview); c.mainContext.insert(photo); photo.task = task
        #expect(throws: TaskPhotoMutationError.readOnly) {
            try TaskPhotoMutations.add(preview: preview, originalRequested: false, contentType: nil, to: task, in: c.mainContext)
        }
        #expect(throws: TaskPhotoMutationError.readOnly) { try TaskPhotoMutations.remove(photo, from: task, in: c.mainContext) }
    }

}
