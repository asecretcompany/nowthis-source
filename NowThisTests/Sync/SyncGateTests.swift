import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Sync Gate Tests

@Suite("Sync Gate — Concurrent Sync Prevention")
struct SyncGateTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    @Test("SyncEngine.isSyncInProgress is false initially")
    func syncEngineNotRunningInitially() async {
        let engine = SyncEngine()
        let inProgress = await engine.isSyncInProgress
        #expect(!inProgress, "SyncEngine should not be running on init")
    }

    @Test("isSyncInProgress resets to false after sync completes (even on error)")
    func syncEngineResetsAfterFailure() async throws {
        let engine = SyncEngine()
        let container = try makeContainer()

        // Call performFullSync with a non-existent account — it will return
        // early (account not found), but the gate should still reset.
        try? await engine.performFullSync(
            accountID: "nonexistent-account",
            serverBaseURL: "https://invalid.example.com",
            credentials: CalDAVClient.Credentials(username: "x", password: "x"),
            modelContainer: container
        )

        let inProgress = await engine.isSyncInProgress
        #expect(!inProgress, "isSyncInProgress must reset to false after sync completes")
    }

    @Test("isSyncInProgress resets to false after background sync completes")
    func backgroundSyncResetsAfterCompletion() async throws {
        let engine = SyncEngine()
        let container = try makeContainer()

        try? await engine.performBackgroundSync(
            accountID: "nonexistent-account",
            serverBaseURL: "https://invalid.example.com",
            credentials: CalDAVClient.Credentials(username: "x", password: "x"),
            modelContainer: container
        )

        let inProgress = await engine.isSyncInProgress
        #expect(!inProgress, "isSyncInProgress must reset to false after background sync")
    }

    @Test("Second concurrent sync bails early when first is running")
    func concurrentSyncBailsEarly() async throws {
        let engine = SyncEngine()
        let container = try makeContainer()

        // Insert an account so the first sync gets past the account-fetch
        // and into the network phase (which will hang/fail).
        let context = ModelContext(container)
        let account = ServerAccount(
            id: "test-account",
            displayName: "Test",
            serverBaseURL: "https://invalid.example.com",
            username: "testuser",
            mode: .nextcloud
        )
        context.insert(account)
        try context.save()

        // Launch first sync — it will fail at the network layer but
        // isRunning should be true while it's in-flight.
        let firstSync = Task {
            try? await engine.performFullSync(
                accountID: "test-account",
                serverBaseURL: "https://invalid.example.com",
                credentials: CalDAVClient.Credentials(username: "x", password: "x"),
                modelContainer: container
            )
        }

        // Give the first sync a moment to enter the running state
        try await Task.sleep(for: .milliseconds(50))

        // The second sync should bail early (no-op) because the first is running
        try? await engine.performBackgroundSync(
            accountID: "test-account",
            serverBaseURL: "https://invalid.example.com",
            credentials: CalDAVClient.Credentials(username: "x", password: "x"),
            modelContainer: container
        )

        await firstSync.value

        // After both complete, gate must be clear
        let inProgress = await engine.isSyncInProgress
        #expect(!inProgress, "Gate must be clear after both syncs finish")
    }
}
