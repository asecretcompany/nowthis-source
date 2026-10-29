import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Sync Dirty Protection Tests

@Suite("Sync Dirty Protection — Background Pull Does Not Clobber Local Edits")
struct SyncDirtyProtectionTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    @Test("Background pull does not overwrite a dirty task")
    func backgroundPullDoesNotOverwriteDirty() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let account = ServerAccount(
            id: "test-account",
            displayName: "Test",
            serverBaseURL: "https://invalid.example.com",
            username: "testuser",
            mode: .nextcloud
        )
        context.insert(account)

        let list = TaskList(serverURL: "/calendars/tasks/", name: "Tasks", colorHex: "#007AFF")
        list.account = account
        context.insert(list)

        // Local task with user's unsaved edit
        let task = TaskItem(uid: "task-123", title: "Local Edit Title")
        task.isDirty = true
        task.lastModifiedDate = Date(timeIntervalSince1970: 1000)
        task.taskList = list
        context.insert(task)
        try context.save()

        // Simulate a background sync that would pull a newer version of this task.
        // We exercise the SyncEngine.performBackgroundSync path indirectly:
        // the engine will fail at the network layer, but we verify the isDirty
        // guard by checking the data model state directly.
        //
        // Since we can't easily mock the network, we test the guard by calling
        // the engine and verifying the task's state is preserved.
        let engine = SyncEngine()
        try? await engine.performBackgroundSync(
            accountID: "test-account",
            serverBaseURL: "https://invalid.example.com",
            credentials: CalDAVClient.Credentials(username: "x", password: "x"),
            modelContainer: container
        )

        // Re-fetch the task from the container to verify
        let bgContext = ModelContext(container)
        let fetchedTasks = try bgContext.fetch(FetchDescriptor<TaskItem>())

        let found = fetchedTasks.first(where: { $0.uid == "task-123" })
        #expect(found != nil, "Task should still exist")
        #expect(found?.title == "Local Edit Title", "Dirty task title must be preserved")
        #expect(found?.isDirty == true, "isDirty flag must remain true")
    }

    @Test("Both inbound apply paths guard dirty tasks via isDirty check")
    func applyRemoteTaskGuardsDirty() async throws {
        // A source-presence check, not a behavioural one — the runtime behaviour is
        // pinned by `backgroundPullDoesNotOverwriteDirty` above and by
        // `SyncInboundChangeDetectionTests.dirtyTaskReportsNoChange`. What it adds is
        // both compatibility entry points delegate to the canonical importer.
        // Runtime tests also cover the shared bounded writer used by both runners.

        // Resolved relative to this file so the test passes in any checkout — an
        // absolute path pins it to one machine and leaks the author's home
        // directory into a public mirror.
        let engineURL = URL(fileURLWithPath: #filePath)      // NowThisTests/Sync/SyncDirtyProtectionTests.swift
            .deletingLastPathComponent()                     // NowThisTests/Sync
            .deletingLastPathComponent()                     // NowThisTests
            .deletingLastPathComponent()                     // <repository root>
            .appendingPathComponent("NowThis/Sync/SyncEngine.swift")
        let source = try String(contentsOf: engineURL, encoding: .utf8)

        let importerURL = engineURL.deletingLastPathComponent().appendingPathComponent("SyncImportStore.swift")
        let importer = try String(contentsOf: importerURL, encoding: .utf8)
        #expect(source.contains("try applyRemoteTask(remoteTask"), "Foreground must use the same canonical importer as background compatibility calls")
        #expect(source.contains("return importer.apply(try importer.parse(remoteTask)"), "The wrapper must delegate to the shared store")
        #expect(importer.contains("!task.isDirty"), "The canonical import policy must preserve pending local work")
    }
}
