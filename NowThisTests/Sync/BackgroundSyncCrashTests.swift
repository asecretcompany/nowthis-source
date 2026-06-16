import Testing
import Foundation
import SwiftData

@testable import NowThis

@Suite("Background Sync Crash Fix")
struct BackgroundSyncCrashTests {

    /// Creates an in-memory ModelContainer matching the app schema.
    private func makeTestContainer() throws -> ModelContainer {
        let schema = Schema([
            TaskItem.self,
            TaskList.self,
            JournalEntry.self,
            Tag.self,
            ServerAccount.self,
            SyncMetadata.self,
            SavedFilter.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("BackgroundSyncManager uses detached task, not MainActor")
    func backgroundSyncUsesDetachedTask() async throws {
        // The handleBackgroundSync method should create a background ModelContext
        // and run sync off the main actor. We verify this by checking that
        // BackgroundSyncManager.usesBackgroundContext is true (a testable flag).
        let manager = BackgroundSyncManager()
        #expect(
            manager.usesBackgroundContext,
            "BackgroundSyncManager must use a background ModelContext, not mainContext"
        )
    }

    @Test("SyncEngine exposes a non-MainActor background sync method")
    func syncEngineHasBackgroundSyncMethod() async throws {
        // Verify that SyncEngine has a performBackgroundSync method
        // that can be called from a non-MainActor context.
        let container = try makeTestContainer()
        let context = ModelContext(container)

        let account = ServerAccount(
            displayName: "Test",
            serverBaseURL: "https://example.com",
            username: "user"
        )
        context.insert(account)
        try context.save()

        let engine = SyncEngine()

        // This should compile and run without requiring @MainActor.
        // The method should exist and be callable from a non-isolated context.
        // It will throw because there's no real server, but it shouldn't crash.
        do {
            try await engine.performBackgroundSync(
                accountID: account.id,
                serverBaseURL: "https://example.com",
                credentials: CalDAVClient.Credentials(username: "user", password: "pass"),
                modelContainer: container
            )
        } catch {
            // Expected — no real server. The point is it compiles without @MainActor.
        }
    }
}
