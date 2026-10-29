import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - AccountManager Tests

@Suite("AccountManager")
struct AccountManagerTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self,
            configurations: config
        )
    }

    @Test("Create Vault account creates account with Vault mode")
    @MainActor
    func createVaultAccount() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let manager = AccountManager(modelContext: context)

        let account = try manager.createVaultAccount(displayName: "My Vault")

        #expect(account.mode == .vault)
        #expect(account.displayName == "My Vault")
        #expect(account.serverBaseURL.isEmpty)
        #expect(account.username.isEmpty)

        // Should also have created an Inbox list
        let lists = try context.fetch(FetchDescriptor<TaskList>())
        #expect(lists.count == 1)
        // `AccountManager` creates this list with `String(localized: "Inbox")`, so the literal
        // stops matching the moment a translation exists. Comparing against the same lookup keeps
        // the assertion locale-independent and still proves the default list was named rather
        // than left blank.
        #expect(lists.first?.name == String(localized: "Inbox"))
        #expect(lists.first?.name.isEmpty == false)
        #expect(lists.first?.account?.id == account.id)
    }

    @Test("Create Vault account with default name")
    @MainActor
    func createVaultDefaultName() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let manager = AccountManager(modelContext: context)

        let account = try manager.createVaultAccount()

        // Same reason as the Inbox list above: this default comes from the catalog.
        #expect(account.displayName == String(localized: "account.vault.defaultName",
                                              defaultValue: "Vault"))
        #expect(!account.displayName.isEmpty)
    }

    @Test("Remove account deletes account and cascades to lists")
    @MainActor
    func removeAccountCascade() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let manager = AccountManager(modelContext: context)

        let account = try manager.createVaultAccount()
        let accountID = account.id

        // Verify list exists
        let listsBefore = try context.fetch(FetchDescriptor<TaskList>())
        #expect(listsBefore.count == 1)

        // Remove
        try await manager.removeAccount(accountID: accountID)

        // All gone
        let accountsAfter = try context.fetch(FetchDescriptor<ServerAccount>())
        let listsAfter = try context.fetch(FetchDescriptor<TaskList>())
        #expect(accountsAfter.isEmpty)
        #expect(listsAfter.isEmpty)
        #expect(try !ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    @Test("Remove non-existent account is a no-op")
    @MainActor
    func removeNonExistentAccount() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let manager = AccountManager(modelContext: context)

        // Should not throw
        try await manager.removeAccount(accountID: "nonexistent-id")
    }

    @Test("Remove account preserves never-synced local tasks, deletes synced ones")
    @MainActor
    func removeAccountPreservesUnsyncedTasks() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let manager = AccountManager(modelContext: context)

        let account = try await manager.addNextcloudAccount(
            displayName: "Cloud",
            serverURL: "https://example.com",
            username: "alice",
            password: "pw",
            storeInKeychain: false
        )
        let list = TaskList(
            serverURL: "https://example.com/cal/",
            name: "Tasks",
            colorHex: "#007AFF"
        )
        list.account = account
        context.insert(list)

        let synced = TaskItem(title: "Synced task")
        synced.remoteHref = "https://example.com/cal/synced.ics" // exists on the server
        synced.taskList = list
        context.insert(synced)

        let unsynced = TaskItem(title: "Local only task") // remoteHref nil → never synced
        unsynced.taskList = list
        context.insert(unsynced)
        try context.save()

        try await manager.removeAccount(accountID: account.id)

        let remaining = try context.fetch(FetchDescriptor<TaskItem>())
        let titles = Set(remaining.map(\.title))
        // Never-synced task survives; the server-backed one is removed with the account.
        #expect(titles.contains("Local only task"))
        #expect(!titles.contains("Synced task"))

        // The survivor was moved under a Vault account so it stays visible.
        let survivor = remaining.first { $0.title == "Local only task" }
        #expect(survivor?.taskList?.account?.mode == .vault)

        // The Nextcloud account is gone; a Vault now holds the recovered task.
        let accounts = try context.fetch(FetchDescriptor<ServerAccount>())
        #expect(!accounts.contains { $0.id == account.id })
        #expect(accounts.contains { $0.mode == .vault })
    }

    @Test("Removing an account keeps the DELETE a task moved into it owes another account")
    @MainActor
    func removeAccountKeepsOwedMoveDeletes() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let manager = AccountManager(modelContext: context)

        let staying = try await manager.addNextcloudAccount(
            displayName: "Work cloud", serverURL: "https://work.example.com",
            username: "alice", password: "pw", storeInKeychain: false
        )
        let leaving = try await manager.addNextcloudAccount(
            displayName: "Home cloud", serverURL: "https://home.example.com",
            username: "alice", password: "pw", storeInKeychain: false
        )
        let work = TaskList(serverURL: "/cal/work/", name: "Work", colorHex: "#007AFF")
        let home = TaskList(serverURL: "/cal/home/", name: "Home", colorHex: "#FF9500")
        work.account = staying
        home.account = leaving
        context.insert(work)
        context.insert(home)

        let task = TaskItem(uid: "uid-moved", title: "Renew passport")
        task.remoteHref = "/cal/work/uid-moved.ics"
        task.isLocalOnly = false
        task.taskList = work
        context.insert(task)
        try context.save()

        TaskMover.move(task, to: home, in: context)
        task.remoteHref = "/cal/home/uid-moved.ics" // the PUT into Home landed
        try context.save()

        try await manager.removeAccount(accountID: leaving.id)

        let remaining = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(remaining.count == 1, "examined \(remaining.count) tasks")
        #expect(remaining.first?.isDeletedLocally == true)
        #expect(remaining.first?.taskList?.id == work.id)
        #expect(remaining.first?.remoteHref == "/cal/work/uid-moved.ics")
    }
}

// MARK: - ServerURLValidator Tests

@Suite("ServerURLValidator")
struct ServerURLValidatorTests {

    @Test("Empty input is invalid")
    func emptyInput() {
        let result = ServerURLValidator.validate("")
        #expect(!result.isValid)
        #expect(result.errorMessage != nil)
    }

    @Test("Whitespace-only input is invalid")
    func whitespaceOnly() {
        let result = ServerURLValidator.validate("   ")
        #expect(!result.isValid)
    }

    @Test("Bare hostname gets https:// prepended")
    func bareHostname() {
        let result = ServerURLValidator.validate("cloud.example.com")
        #expect(result.isValid)
        #expect(result.normalizedURL == "https://cloud.example.com")
        #expect(result.isHTTPS)
    }

    @Test("Bare hostname with path")
    func bareHostnamePath() {
        let result = ServerURLValidator.validate("cloud.example.com/nextcloud")
        #expect(result.isValid)
        #expect(result.normalizedURL == "https://cloud.example.com/nextcloud")
        #expect(result.isHTTPS)
    }

    @Test("https:// URL passes validation")
    func httpsURL() {
        let result = ServerURLValidator.validate("https://cloud.example.com")
        #expect(result.isValid)
        #expect(result.isHTTPS)
        #expect(result.normalizedURL == "https://cloud.example.com")
    }

    @Test("http:// URL is rejected — HTTPS is required")
    func httpURL() {
        // The app has no App Transport Security exception, so iOS blocks
        // cleartext HTTP. The validator rejects http:// up front with a clear
        // message instead of letting it fail later as an opaque ATS error.
        let result = ServerURLValidator.validate("http://192.168.1.100")
        #expect(!result.isValid)
        #expect(!result.isHTTPS)
        #expect(result.errorMessage != nil)
    }

    @Test("Trailing slashes are stripped")
    func trailingSlashes() {
        let result = ServerURLValidator.validate("https://cloud.example.com///")
        #expect(result.normalizedURL == "https://cloud.example.com")
    }

    @Test("Whitespace around URL is trimmed")
    func whitespaceTrimming() {
        let result = ServerURLValidator.validate("  https://cloud.example.com  ")
        #expect(result.isValid)
        #expect(result.normalizedURL == "https://cloud.example.com")
    }

    @Test("FTP scheme is rejected")
    func ftpRejected() {
        let result = ServerURLValidator.validate("ftp://server.example.com")
        #expect(!result.isValid)
        #expect(result.errorMessage != nil)
    }

    @Test("URL with port number")
    func urlWithPort() {
        let result = ServerURLValidator.validate("https://cloud.example.com:8443")
        #expect(result.isValid)
        #expect(result.isHTTPS)
    }

    @Test("IP address over http is rejected — HTTPS is required")
    func ipAddressURL() {
        let result = ServerURLValidator.validate("http://192.168.1.50:8080")
        #expect(!result.isValid)
        #expect(!result.isHTTPS)
    }

    @Test("IP address over https is accepted")
    func ipAddressHTTPSURL() {
        let result = ServerURLValidator.validate("https://192.168.1.50:8080")
        #expect(result.isValid)
        #expect(result.isHTTPS)
    }
}
