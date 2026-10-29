import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite(.serialized) @MainActor
struct TaskPhotoAccessMaintenanceTests {
    @Test func revokedAccessHidesPhotosAndPurgesOriginalCacheButKeepsSavedAndUnsentWork() async throws {
        let c = try ModelContainer(for: Schema(SchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let account = ServerAccount(displayName: "Cloud", serverBaseURL: "https://example.com", username: "alice")
        let list = TaskList(serverURL: "/remote.php/dav/calendars/alice/shared/", name: "Shared", colorHex: "#007AFF")
        let task = TaskItem(title: "Keep my title")
        c.mainContext.insert(account); c.mainContext.insert(list); list.account = account
        c.mainContext.insert(task); task.taskList = list
        let remote = TaskPhoto(previewData: TaskPhotoJPEGFixture.data)
        remote.originalRequested = true; remote.originalFileID = "901"; remote.folderFileID = "900"
        let pending = TaskPhoto(previewData: TaskPhotoJPEGFixture.data); pending.pendingOperation = "add"
        c.mainContext.insert(remote); remote.task = task; c.mainContext.insert(pending); pending.task = task
        let remoteID = remote.id; let pendingID = pending.id; let listID = list.id
        try c.mainContext.save()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = TaskPhotoCache(directory: url)
        try await cache.store(Data([1]), photoID: remoteID); try await cache.store(Data([2]), photoID: pendingID)
        let change = try await TaskPhotoAccessMaintenance.revoke(listID: listID, container: c, cache: cache)
        let fresh = ModelContext(c)
        let stored = try #require(try fresh.fetch(FetchDescriptor<TaskList>()).first)
        #expect(stored.photoAccessRevoked == true)
        #expect(try !TaskPhotoAccessMaintenance.canView(task: task, container: c))
        #expect(Set(try fresh.fetch(FetchDescriptor<TaskPhoto>()).map(\.id)) == [remoteID, pendingID])
        #expect(try await cache.load(photoID: remoteID) == nil)
        #expect(try await cache.load(photoID: pendingID) == Data([2]))
        #expect(change?.changedIDs.contains(task.id) == true)
        #expect(stored.tasks.first?.title == "Keep my title")
        _ = try TaskPhotoAccessMaintenance.restore(listID: listID, container: c)
        let reopened = ModelContext(c)
        #expect(try reopened.fetch(FetchDescriptor<TaskList>()).first?.photoAccessRevoked == false)
    }

    @Test func deletingListInAnotherContextBlocksStaleEditorPhotoAccess() throws {
        let c = try ModelContainer(for: Schema(SchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let list = TaskList(serverURL: "/shared/", name: "Shared", colorHex: "#007AFF")
        let task = TaskItem(title: "Stale editor")
        c.mainContext.insert(list); c.mainContext.insert(task); task.taskList = list
        try c.mainContext.save()
        let worker = ModelContext(c)
        let storedList = try #require(try worker.fetch(FetchDescriptor<TaskList>()).first)
        worker.delete(storedList); try worker.save()
        #expect(try !TaskPhotoAccessMaintenance.canView(task: task, container: c))
        #expect(throws: TaskPhotoMutationError.readOnly) {
            try TaskPhotoMutations.add(preview: TaskPhotoJPEGFixture.data, originalRequested: false,
                contentType: nil, to: task, in: c.mainContext)
        }
    }

    @Test func newlyInsertedLocalListCanAcceptPhotosBeforeItsFirstSave() throws {
        let c = try ModelContainer(for: Schema(SchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let list = TaskList(serverURL: "", name: "New local list", colorHex: "#007AFF")
        let task = TaskItem(title: "New task")
        c.mainContext.insert(list); c.mainContext.insert(task); task.taskList = list
        #expect(try TaskPhotoAccessMaintenance.canView(task: task, container: c))
        _ = try TaskPhotoMutations.add(preview: TaskPhotoJPEGFixture.data, originalRequested: false,
            contentType: nil, to: task, in: c.mainContext)
        #expect(task.photos.count == 1)
    }

}
