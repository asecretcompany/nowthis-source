import Foundation
import SwiftData

/// Raw persisted account identity for request admission. Authentication rejection
/// uses its own normalized scope; a saved-account check compares exact bytes.
struct AccountCredentialScope: Sendable, Codable, Equatable {
    let id: String
    let serverBaseURL: String
    let username: String
    let mode: AccountMode

    init(id: String, serverBaseURL: String, username: String, mode: AccountMode = .nextcloud) {
        self.id = id
        self.serverBaseURL = serverBaseURL
        self.username = username
        self.mode = mode
    }

    init(_ account: ServerAccount) {
        self.init(id: account.id, serverBaseURL: account.serverBaseURL,
                  username: account.username, mode: account.mode)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.mode == rhs.mode
            && lhs.serverBaseURL.utf8.elementsEqual(rhs.serverBaseURL.utf8)
            && lhs.username.utf8.elementsEqual(rhs.username.utf8)
    }
}

struct CommittedAccountCredentials: Sendable {
    let scope: AccountCredentialScope
    let password: String

    var davCredentials: CalDAVClient.Credentials {
        .init(username: scope.username, password: password)
    }
}

enum AccountCredentialDeferral: Error, Sendable {
    case busy, staleAccount, uncertainCredential
}

enum AccountCredentialAdmission: Sendable {
    case available(CommittedAccountCredentials)
    case missing
    case deferred(AccountCredentialDeferral)
}

/// Coordinates account lifecycle between SwiftData (metadata) and Keychain (credentials).
///
/// External Keychain operations and SwiftData saves can fail independently.
/// For Nextcloud accounts, it pairs a `ServerAccount` record in SwiftData with a password
/// entry in the Keychain. For Vault Mode accounts, no Keychain entry is created.
///
/// **Usage:**
/// ```swift
/// let manager = AccountManager(modelContext: context)
/// // Vault mode
/// try await manager.createVaultAccount()
/// // Nextcloud
/// try await manager.addNextcloudAccount(...)
/// // Promote vault → nextcloud
/// try await manager.promoteToNextcloud(accountID: ..., ...)
/// ```
@MainActor
final class AccountManager: Observable {

    private let modelContext: ModelContext
    private let keychainManager: KeychainManager
    private let deleteCredentials: (String) async throws -> Void
    private let preservationReads: PreservationReads
    private let saveAccount: (ModelContext) throws -> Void
    private static var accountOperations: [String: OperationSlot] = [:]
    private static var storeRemovals: [ObjectIdentifier: OperationSlot] = [:]
    private static var uncertainCredentialIDs: Set<String> = []

    /// Only the rescue-discovery reads are replaceable, so failures can be checked before
    /// any cascade or credential deletion. Live reads always propagate store errors.
    struct PreservationReads {
        var lists: (ModelContext, FetchDescriptor<TaskList>) throws -> [TaskList] = { try $0.fetch($1) }
        var tasks: (ModelContext, FetchDescriptor<TaskItem>) throws -> [TaskItem] = { try $0.fetch($1) }
        var accounts: (ModelContext) throws -> [ServerAccount] = { try $0.fetch(FetchDescriptor<ServerAccount>()) }
    }

    init(modelContext: ModelContext, keychainManager: KeychainManager = KeychainManager(),
         deleteCredentials: ((String) async throws -> Void)? = nil,
         preservationReads: PreservationReads = PreservationReads(),
         saveAccount: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.modelContext = modelContext
        self.keychainManager = keychainManager
        self.deleteCredentials = deleteCredentials ?? { try await keychainManager.delete(for: $0) }
        self.preservationReads = preservationReads
        self.saveAccount = saveAccount
    }

    // MARK: - Vault Mode

    /// Creates a local-only Vault Mode account with a default "Inbox" task list.
    ///
    /// No Keychain entry is created since Vault Mode requires no credentials.
    /// - Parameter displayName: The user-facing name for the vault. Defaults to "Vault".
    /// - Returns: The created `ServerAccount`.
    @discardableResult
    func createVaultAccount(
        displayName: String = String(
            localized: "account.vault.defaultName",
            defaultValue: "Vault",
            comment: "Default name of a local-only account, shown in Settings under Accounts. The feature is called Vault Mode, which is itself translated.")
    ) throws -> ServerAccount {
        let staged = stagingContext()
        let account = ServerAccount(vaultDisplayName: displayName)
        staged.insert(account)

        // Create a default "Inbox" list for the vault
        let inbox = TaskList(
            serverURL: "",
            name: String(localized: "Inbox"),
            colorHex: "#007AFF"
        )
        inbox.account = account
        staged.insert(inbox)

        try saveAccount(staged)
        return try savedAccountInCallerContext(account.id)
    }

    // MARK: - Nextcloud

    /// Creates a Nextcloud account with credentials stored in the Keychain.
    ///
    /// SwiftData changes stay isolated until the credential write succeeds.
    ///
    /// - Parameters:
    ///   - displayName: User-facing account name (e.g., "Work Cloud").
    ///   - serverURL: The base URL of the Nextcloud server.
    ///   - username: The Nextcloud username.
    ///   - password: The app-password for CalDAV authentication.
    ///   - storeInKeychain: Whether to persist the password in the Keychain. Defaults to `true`.
    /// - Returns: The created `ServerAccount`.
    @discardableResult
    func addNextcloudAccount(
        displayName: String,
        serverURL: String,
        username: String,
        password: String,
        storeInKeychain: Bool = true
    ) async throws -> ServerAccount {
        let address = try NextcloudServerAddress.parse(serverURL)
        let account = ServerAccount(
            displayName: displayName,
            serverBaseURL: address.baseURL.absoluteString,
            username: username,
            mode: .nextcloud
        )
        return try await add(account, address: address, seed: address.discoverySeed,
                             password: storeInKeychain ? password : nil)
    }

    /// Creates a Nextcloud account from Login Flow v2 credentials.
    ///
    /// The app password was generated by the server during the Login Flow,
    /// so the `authMethod` is set to `.loginFlow` for UI differentiation.
    ///
    /// - Parameters:
    ///   - serverURL: The base URL returned by the Login Flow.
    ///   - loginName: The username returned by the Login Flow.
    ///   - appPassword: The server-generated app password.
    /// - Returns: The created `ServerAccount`.
    @discardableResult
    func addNextcloudAccountViaLoginFlow(
        serverURL: String,
        loginName: String,
        appPassword: String,
        discoverySeed: URL? = nil
    ) async throws -> ServerAccount {
        let address = try NextcloudServerAddress.parse(serverURL)
        let account = ServerAccount(
            displayName: loginName,
            serverBaseURL: address.baseURL.absoluteString,
            username: loginName,
            mode: .nextcloud
        )
        account.storedAuthMethod = .loginFlow
        return try await add(account, address: address, seed: discoverySeed ?? address.discoverySeed,
                             password: appPassword)
    }

    private func add(
        _ account: ServerAccount, address: NextcloudServerAddress, seed: URL?, password: String?
    ) async throws -> ServerAccount {
        let accountID = account.id
        return try await withAccountOperation(accountID) { checkCurrent in
            let staged = stagingContext()
            try NextcloudDiscoverySeed.store(accountID: accountID, seed: seed, baseURL: address.baseURL, in: staged)
            staged.insert(account)
            try await commit(staged, accountID: accountID, password: password, checkCurrent: checkCurrent)
            return try savedAccountInCallerContext(accountID)
        }
    }

    /// Promotes a Vault Mode account to Nextcloud by adding server details and credentials.
    ///
    /// All existing local task lists and tasks are preserved and will begin syncing
    /// once the sync engine connects.
    ///
    /// - Parameters:
    ///   - accountID: The ID of the existing Vault account to promote.
    ///   - serverURL: The Nextcloud server base URL.
    ///   - username: The Nextcloud username.
    ///   - password: The app-password for CalDAV authentication.
    func promoteToNextcloud(
        accountID: String,
        serverURL: String,
        username: String,
        password: String
    ) async throws {
        try await withAccountOperation(accountID) { checkCurrent in
            try checkCurrent()
            let staged = stagingContext()
            guard let account = try Self.account(accountID, in: staged) else { return }
            let address = try NextcloudServerAddress.parse(serverURL)
            try NextcloudDiscoverySeed.store(accountID: accountID, seed: address.discoverySeed,
                                             baseURL: address.baseURL, in: staged)
            account.mode = .nextcloud
            account.serverBaseURL = address.baseURL.absoluteString
            account.username = username
            account.displayName = username
            try await commit(staged, accountID: accountID, password: password, checkCurrent: checkCurrent)
            refreshCommittedAccount(accountID)
        }
    }

    /// Updates an existing Nextcloud account's settings.
    ///
    /// Only non-nil parameters are applied, allowing partial updates.
    /// If a new password is provided, the Keychain entry is replaced.
    ///
    /// - Parameters:
    ///   - accountID: The ID of the account to update.
    ///   - displayName: Optional new display name.
    ///   - serverURL: Optional new server base URL.
    ///   - username: Optional new username.
    ///   - password: Optional new app-password (updates Keychain if provided).
    func updateNextcloudAccount(
        accountID: String,
        displayName: String? = nil,
        serverURL: String? = nil,
        username: String? = nil,
        password: String? = nil,
        expected: AccountCredentialScope? = nil
    ) async throws {
        try await withAccountOperation(accountID, deferIfBusy: expected != nil) { checkCurrent in
            try checkCurrent()
            let staged = stagingContext()
            let account = try Self.account(accountID, in: staged)
            if let expected, account.map(AccountCredentialScope.init) != expected {
                throw AccountCredentialDeferral.staleAccount
            }
            guard let account else { return }

            if let serverURL, serverURL != account.serverBaseURL {
                let address = try NextcloudServerAddress.parse(serverURL)
                let previous = try? NextcloudServerAddress.parse(account.serverBaseURL)
                if address.discoverySeed != nil || previous?.baseURL != address.baseURL {
                    try NextcloudDiscoverySeed.store(accountID: accountID, seed: address.discoverySeed,
                                                     baseURL: address.baseURL, in: staged)
                }
                account.serverBaseURL = address.baseURL.absoluteString
            }
            if let displayName { account.displayName = displayName }
            if let username { account.username = username }
            try await commit(staged, accountID: accountID, password: password, checkCurrent: checkCurrent)
            refreshCommittedAccount(accountID)
        }
    }

    func reauthenticateNextcloudAccount(
        account: AccountCredentialScope, returnedServer: String, loginName: String, appPassword: String
    ) async throws {
        // The login client validates the server response against its pinned
        // origin and returns the normalized base used when starting the flow.
        guard let loginBase = try? NextcloudServerAddress.parse(account.serverBaseURL).baseURL,
              loginBase.absoluteString.utf8.elementsEqual(returnedServer.utf8) else {
            throw LoginFlowError.serverMismatch
        }
        try await updateNextcloudAccount(accountID: account.id, username: loginName, password: appPassword,
                                         expected: account)
    }

    // MARK: - Staged account writes

    private func stagingContext() -> ModelContext {
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        return context
    }

    private static func account(_ accountID: String, in context: ModelContext) throws -> ServerAccount? {
        var descriptor = FetchDescriptor<ServerAccount>(predicate: #Predicate { $0.id == accountID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func savedAccountInCallerContext(_ accountID: String) throws -> ServerAccount {
        guard let account = try Self.account(accountID, in: modelContext) else { throw SyncError.noAccount }
        return account
    }

    private func refreshCommittedAccount(_ accountID: String) {
        // A targeted refetch refreshes a registered account and preserves pending
        // changes. This read follows the durable save, so it cannot trigger recovery.
        _ = try? Self.account(accountID, in: modelContext)
    }

    /// Holds the account slot through compensation. A newer request can supersede
    /// the save while Keychain is suspended, but cannot write until recovery ends.
    private func commit(
        _ staged: ModelContext, accountID: String, password: String?, checkCurrent: () throws -> Void
    ) async throws {
        try checkCurrent()
        guard let password else {
            try saveAccount(staged)
            return
        }

        let previousPassword = try await keychainManager.retrieve(for: accountID)
        try checkCurrent()
        try await keychainManager.save(password: password, for: accountID)
        do {
            try checkCurrent()
            try saveAccount(staged)
            Self.uncertainCredentialIDs.remove(accountID)
        } catch {
            let commitError = error
            do {
                if let previousPassword {
                    try await keychainManager.save(password: previousPassword, for: accountID)
                } else {
                    try await keychainManager.delete(for: accountID)
                }
            } catch {
                Self.uncertainCredentialIDs.insert(accountID)
                throw CredentialRecoveryFailure(commitError: commitError, recoveryError: error)
            }
            throw commitError
        }
    }

    private struct CredentialRecoveryFailure: LocalizedError {
        let commitError: any Error
        let recoveryError: any Error

        var errorDescription: String? { recoveryError.localizedDescription }
    }

    private func withAccountOperation<Result>(
        _ accountID: String, deferIfBusy: Bool = false,
        operation: @MainActor (() throws -> Void) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        // A login response is based on an earlier scope. It may not displace
        // an account operation already in progress when that response arrives.
        if deferIfBusy, Self.accountOperations[accountID] != nil { throw AccountCredentialDeferral.busy }
        let slot = Self.accountOperations[accountID] ?? OperationSlot()
        Self.accountOperations[accountID] = slot
        let generation = UUID()
        slot.latestGeneration = generation
        await slot.acquire()
        defer {
            if slot.release() { Self.accountOperations.removeValue(forKey: accountID) }
        }
        try Task.checkCancellation()
        return try await operation {
            try Task.checkCancellation()
            guard slot.latestGeneration == generation else { throw CancellationError() }
        }
    }

    /// A generation identifies the newest request. The slot also protects the
    /// prior credential until the active request has committed or compensated.
    @MainActor
    private final class OperationSlot {
        var latestGeneration: UUID?
        private var occupied = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !tryAcquire() {
                await withCheckedContinuation { waiters.append($0) }
            }
        }

        func tryAcquire() -> Bool {
            guard !occupied else { return false }
            occupied = true
            return true
        }

        /// Returns true once there is neither an owner nor a waiter.
        func release() -> Bool {
            if waiters.isEmpty {
                occupied = false
                return true
            }
            waiters.removeFirst().resume()
            return false
        }
    }

    // MARK: - Account Removal

    /// Removes an account and its associated Keychain credentials.
    ///
    /// SwiftData cascade rules will delete all associated task lists and tasks.
    /// - Parameter accountID: The ID of the account to remove.
    func removeAccount(accountID: String) async throws {
        try await withAccountOperation(accountID) { _ in
            // Removal also touches recovery lists and pending moves belonging to
            // other accounts. Always take the account slot before the store slot.
            let storeID = ObjectIdentifier(modelContext.container)
            let removal = Self.storeRemovals[storeID] ?? OperationSlot()
            Self.storeRemovals[storeID] = removal
            await removal.acquire()
            defer {
                if removal.release() { Self.storeRemovals.removeValue(forKey: storeID) }
            }
            try Task.checkCancellation()
            try await performRemoval(accountID: accountID)
        }
    }

    private func performRemoval(accountID: String) async throws {
        guard let account = try Self.account(accountID, in: modelContext) else { return }

        // Preserve never-synced (local-only) tasks before the cascade delete so
        // removing an account can't destroy work that exists nowhere else.
        try preserveUnsyncedTasks(of: account)

        // A task moved into one of these lists from another account still owes that
        // account a DELETE of its old copy. Rescued tasks above keep theirs; the rest
        // go with the cascade, so leave the DELETE behind as a tombstone.
        for list in account.taskLists {
            try TaskListHelpers.settlePendingMoves(beforeDeleting: list, in: modelContext)
        }

        // Remove Keychain entry (idempotent — safe for Vault accounts too)
        try await deleteCredentials(accountID)

        try NextcloudDiscoverySeed.remove(accountID: accountID, in: modelContext)
        try SyncImportCheckpoint.removeAccount(accountID, in: modelContext)
        try VTODOOpaqueState.remove(tasks: account.taskLists.flatMap(\.tasks), in: modelContext)
        try CalendarMirrorState.stagePurge(account.taskLists.flatMap(\.tasks), in: modelContext)
        modelContext.delete(account)
        try ReminderSchedulingJournal.saveTaskChanges(in: modelContext, needsRecovery: true)
        Self.uncertainCredentialIDs.remove(accountID)
        ReminderScheduler.requestReconcile(modelContext: modelContext)
    }

    /// Moves the account's never-synced tasks into a local Vault "Recovered Tasks"
    /// list so they survive removal. A task is considered never-synced when it has
    /// no `remoteHref` (never created on or pulled from the server). Synced tasks
    /// remain safe on the server and are removed with the account.
    private func preserveUnsyncedTasks(of account: ServerAccount) throws {
        let accID = account.id
        let listPredicate = #Predicate<TaskList> { $0.account?.id == accID }
        let lists = try preservationReads.lists(modelContext, FetchDescriptor<TaskList>(predicate: listPredicate))

        var unsynced: [TaskItem] = []
        for list in lists {
            let listID = list.id
            let taskPredicate = #Predicate<TaskItem> {
                $0.taskList?.id == listID && !$0.isDeletedLocally
            }
            let tasks = try preservationReads.tasks(modelContext, FetchDescriptor<TaskItem>(predicate: taskPredicate))
            unsynced.append(contentsOf: tasks.filter { ($0.remoteHref ?? "").isEmpty })
        }

        guard !unsynced.isEmpty else { return }

        let recoveryList = try findOrCreateRecoveryList(excludingAccountID: accID)
        let preservedIDs = Set(unsynced.map(\.id))
        for task in unsynced {
            // Detach from a parent that won't be preserved so the parentTask
            // cascade can't delete this task along with the removed account.
            if let parent = task.parentTask, !preservedIDs.contains(parent.id) {
                task.parentTask = nil
            }
            task.taskList = recoveryList
        }
        try modelContext.save()
    }

    /// Returns a Vault "Recovered Tasks" list to hold preserved tasks, creating
    /// the Vault account and/or the list if needed. Never reuses the account
    /// currently being removed.
    private func findOrCreateRecoveryList(excludingAccountID: String) throws -> TaskList {
        let allAccounts = try preservationReads.accounts(modelContext)
        let vault: ServerAccount
        if let existing = allAccounts.first(where: { $0.mode == .vault && $0.id != excludingAccountID }) {
            vault = existing
        } else {
            vault = ServerAccount(vaultDisplayName: String(localized: "Recovered"))
            modelContext.insert(vault)
        }

        // Identified by a stable sentinel, never by its (localized, user-renameable) name.
        if let existing = vault.taskLists.first(where: { $0.isRecoveryList }) {
            return existing
        }
        let recoveryName = String(
            localized: "recovery.list.name", defaultValue: "Recovered Tasks",
            comment: "Name of the local list holding tasks rescued from a removed account. Display only — the list is identified internally by a fixed marker.")
        let list = TaskList(serverURL: TaskList.recoveryListServerURL,
                            name: recoveryName, colorHex: "#007AFF")
        list.account = vault
        modelContext.insert(list)
        return list
    }

    // MARK: - Credential Access

    /// Read a committed account and its password under the same slot that
    /// protects replacement and recovery. The caller owns only values when it
    /// starts network work, so no transport request holds the slot.
    static func admitCredentials(
        accountID: String, expected: AccountCredentialScope? = nil,
        container: ModelContainer, keychainManager: KeychainManager = KeychainManager()
    ) async throws -> AccountCredentialAdmission {
        try Task.checkCancellation()
        try BackgroundRunBudget.current?.checkRemoteAdmission()
        let slot = accountOperations[accountID] ?? OperationSlot()
        guard slot.tryAcquire() else { return .deferred(.busy) }
        accountOperations[accountID] = slot
        defer {
            if slot.release() { accountOperations.removeValue(forKey: accountID) }
        }

        guard !uncertainCredentialIDs.contains(accountID) else { return .deferred(.uncertainCredential) }
        let scope = try BackgroundRunBudget.protectingCurrent {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return try account(accountID, in: context).map(AccountCredentialScope.init)
        }
        if let expected, scope != expected { return .deferred(.staleAccount) }
        guard let scope, scope.mode == .nextcloud else { return .missing }

        let password = try await keychainManager.retrieve(for: accountID)
        try Task.checkCancellation()
        try BackgroundRunBudget.current?.checkRemoteAdmission()
        guard let password else { return .missing }
        return .available(CommittedAccountCredentials(scope: scope, password: password))
    }

    /// Stored credential lookup for the explicit Test Connection action.
    func getCredentials(for accountID: String, expected: AccountCredentialScope? = nil)
        async throws -> (username: String, password: String)? {
        switch try await Self.admitCredentials(accountID: accountID, expected: expected,
                                               container: modelContext.container, keychainManager: keychainManager) {
        case .available(let credentials): return (credentials.scope.username, credentials.password)
        case .missing: return nil
        case .deferred(let reason): throw reason
        }
    }
}
