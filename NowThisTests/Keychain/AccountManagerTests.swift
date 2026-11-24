import Testing
import Foundation
import Security
import SwiftData
import Synchronization

@testable import NowThis

// MARK: - AccountManager Tests

@Suite("AccountManager")
struct AccountManagerTests {
    private enum InjectedFailure: Error { case database }

    enum NewAccountKind: CaseIterable { case vault, manual, loginFlow, withoutPassword }
    enum FailedEdit: CaseIterable { case keychain, database, invalidURL }

    @Test("A failed account save cannot be committed by a later draft save", arguments: NewAccountKind.allCases)
    @MainActor
    func failedCreateLeavesNoAccountOrSeed(kind: NewAccountKind) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let keychain = TestAccountKeychain()
        let manager = AccountManager(modelContext: context, keychainManager: keychain.manager,
                                     saveAccount: { _ in throw InjectedFailure.database })

        await #expect(throws: InjectedFailure.database) {
            switch kind {
            case .vault:
                _ = try manager.createVaultAccount()
            case .manual, .withoutPassword:
                _ = try await manager.addNextcloudAccount(
                    displayName: "Cloud", serverURL: "https://example.invalid/remote.php/dav/",
                    username: "fixture", password: "fixture", storeInKeychain: kind == .manual)
            case .loginFlow:
                _ = try await manager.addNextcloudAccountViaLoginFlow(
                    serverURL: "https://example.invalid/remote.php/dav/",
                    loginName: "fixture", appPassword: "fixture")
            }
        }

        try saveUnrelatedDraft(in: context)
        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<ServerAccount>()) == 0)
        #expect(try fresh.fetchCount(FetchDescriptor<TaskList>()) == 0)
        #expect(try fresh.fetchCount(FetchDescriptor<SyncMetadata>()) == 0)
        #expect(keychain.itemCount == 0)
    }

    @Test("A failed Keychain add leaves no pending account or DAV seed")
    @MainActor
    func failedCredentialAddLeavesNoAccount() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let keychain = TestAccountKeychain()
        keychain.rejectWrites(of: "new")
        let manager = AccountManager(modelContext: context, keychainManager: keychain.manager)

        await #expect(throws: KeychainManager.KeychainError.self) {
            _ = try await manager.addNextcloudAccountViaLoginFlow(
                serverURL: "https://example.invalid/remote.php/dav/", loginName: "fixture", appPassword: "new")
        }

        try saveUnrelatedDraft(in: context)
        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<ServerAccount>()) == 0)
        #expect(try fresh.fetchCount(FetchDescriptor<SyncMetadata>()) == 0)
        #expect(keychain.itemCount == 0)
    }

    @Test("A failed account edit preserves persisted settings, seed and credential", arguments: FailedEdit.allCases)
    @MainActor
    func failedEditDoesNotLeakIntoDraftSave(failure: FailedEdit) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let keychain = TestAccountKeychain()
        let initial = AccountManager(modelContext: context, keychainManager: keychain.manager)
        let originalSeed = "https://original.invalid/remote.php/dav/calendars/alice/tasks/"
        let account = try await initial.addNextcloudAccount(
            displayName: "Original", serverURL: originalSeed, username: "alice", password: "valid")
        let id = account.id
        if failure == .keychain { keychain.rejectWrites(of: "replacement") }
        let manager = AccountManager(modelContext: context, keychainManager: keychain.manager,
                                     saveAccount: {
            if failure == .database { throw InjectedFailure.database }
            try $0.save()
        })

        await #expect(throws: (any Error).self) {
            try await manager.updateNextcloudAccount(
                accountID: id, displayName: "Changed",
                serverURL: failure == .invalidURL ? "http://bad.invalid" : "https://changed.invalid/remote.php/dav/",
                username: "bob", password: "replacement")
        }

        try saveUnrelatedDraft(in: context)
        let fresh = ModelContext(container)
        let stored = try #require(fresh.fetch(FetchDescriptor<ServerAccount>()).first)
        #expect(stored.displayName == "Original")
        #expect(stored.serverBaseURL == "https://original.invalid")
        #expect(stored.username == "alice")
        #expect(try NextcloudDiscoverySeed.address(accountID: id, serverURL: stored.serverBaseURL, in: fresh)
            .discoverySeed?.absoluteString == originalSeed)
        #expect(try await keychain.manager.retrieve(for: id) == "valid")
    }

    @Test("A failed Vault promotion preserves the Vault and its lists")
    @MainActor
    func failedPromotionRestoresCredentialAbsence() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let keychain = TestAccountKeychain()
        let vault = try AccountManager(modelContext: context).createVaultAccount(displayName: "Original Vault")
        let id = vault.id
        let manager = AccountManager(modelContext: context, keychainManager: keychain.manager,
                                     saveAccount: { _ in throw InjectedFailure.database })

        await #expect(throws: InjectedFailure.database) {
            try await manager.promoteToNextcloud(accountID: id, serverURL: "https://example.invalid/remote.php/dav/",
                                                 username: "bob", password: "replacement")
        }

        try saveUnrelatedDraft(in: context)
        let fresh = ModelContext(container)
        let stored = try #require(fresh.fetch(FetchDescriptor<ServerAccount>()).first)
        #expect(stored.mode == .vault)
        #expect(stored.displayName == "Original Vault")
        #expect(stored.username.isEmpty)
        #expect(stored.serverBaseURL.isEmpty)
        #expect(stored.taskLists.count == 1)
        #expect(try fresh.fetchCount(FetchDescriptor<SyncMetadata>()) == 0)
        #expect(try await keychain.manager.retrieve(for: id) == nil)
    }

    @Test("A successful staged account write remains visible without saving unrelated edits")
    @MainActor
    func committedAccountIsVisibleInCallerContext() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let draft = TaskItem(title: "Unrelated")
        context.insert(draft)
        try context.save()
        draft.notes = "Pending draft"
        let manager = AccountManager(modelContext: context)
        let account = try await manager.addNextcloudAccount(
            displayName: "Original", serverURL: "https://original.invalid",
            username: "alice", password: "unused", storeInKeychain: false)
        #expect(account.modelContext === context)
        #expect(try context.fetch(FetchDescriptor<ServerAccount>()).first === account)

        try await manager.updateNextcloudAccount(accountID: account.id, displayName: "Changed", username: "bob")

        #expect(account.displayName == "Changed")
        #expect(account.username == "bob")
        #expect(draft.notes == "Pending draft")
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.notes == "")
        #expect(context.hasChanges)
    }

    @Test("A superseded edit restores credentials before the next manager can commit", arguments: [false, true])
    @MainActor
    func overlappingEditsKeepNewestCommit(newerChangesCredential: Bool) async throws {
        let container = try makeContainer()
        let keychain = TestAccountKeychain()
        let first = AccountManager(modelContext: container.mainContext, keychainManager: keychain.manager,
                                   saveAccount: { _ in throw InjectedFailure.database })
        let second = AccountManager(modelContext: ModelContext(container), keychainManager: keychain.manager)
        let account = try await second.addNextcloudAccount(
            displayName: "Original", serverURL: "https://original.invalid", username: "alice", password: "valid")
        let id = account.id
        let firstWrite = AccountWriteGate()
        keychain.beforeWrite("superseded", action: firstWrite.pause)
        let older = Task {
            try await first.updateNextcloudAccount(accountID: id, displayName: "Older",
                                                   username: "old", password: "superseded")
        }
        await firstWrite.waitUntilPaused()
        let newer = await startAccountOperation {
            try await second.updateNextcloudAccount(accountID: id, displayName: "Newer",
                password: newerChangesCredential ? "current" : nil)
        }
        firstWrite.resume()
        await #expect(throws: CancellationError.self) { try await older.value }
        try await newer.value

        let fresh = ModelContext(container)
        let stored = try #require(fresh.fetch(FetchDescriptor<ServerAccount>()).first)
        #expect(stored.displayName == "Newer")
        #expect(stored.username == "alice")
        #expect(try await keychain.manager.retrieve(for: id) == (newerChangesCredential ? "current" : "valid"))
    }

    @Test("Removing an account supersedes an in-flight credential replacement")
    @MainActor
    func removalWaitsForCredentialReplacementRecovery() async throws {
        let container = try makeContainer()
        let keychain = TestAccountKeychain()
        let editor = AccountManager(modelContext: container.mainContext, keychainManager: keychain.manager)
        let remover = AccountManager(modelContext: ModelContext(container), keychainManager: keychain.manager)
        let account = try await editor.addNextcloudAccount(
            displayName: "Original", serverURL: "https://original.invalid", username: "alice", password: "valid")
        let id = account.id
        let firstWrite = AccountWriteGate()
        keychain.beforeWrite("superseded", action: firstWrite.pause)
        let edit = Task {
            try await editor.updateNextcloudAccount(accountID: id, username: "old", password: "superseded")
        }
        await firstWrite.waitUntilPaused()
        let removal = await startAccountOperation { try await remover.removeAccount(accountID: id) }
        firstWrite.resume()
        await #expect(throws: CancellationError.self) { try await edit.value }
        try await removal.value

        #expect(try ModelContext(container).fetchCount(FetchDescriptor<ServerAccount>()) == 0)
        #expect(try await keychain.manager.retrieve(for: id) == nil)
    }

    @Test("DAV never sends provisional credentials during or after failed recovery", arguments: [false, true])
    @MainActor
    func credentialAdmissionDuringRecovery(restoreFails: Bool) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let keychain = TestAccountKeychain()
        let oldHost = "previous-" + UUID().uuidString.lowercased() + ".invalid"
        let oldURL = "https://" + oldHost
        let newURL = "https://replacement-" + UUID().uuidString.lowercased() + ".invalid"
        let manager = AccountManager(modelContext: context, keychainManager: keychain.manager)
        let account = try await manager.addNextcloudAccount(
            displayName: "Cloud", serverURL: oldURL, username: "owner", password: "committed")
        let id = account.id
        let configuration = ScriptedDAVProtocol.install(host: oldHost, responses: [
            .init(status: 503, body: "fixture"), .init(status: 503, body: "fixture"),
            .init(status: 503, body: "fixture")
        ], authorizationLabels: [
            basicAuthorization(user: "owner", password: "committed"): "committed",
            basicAuthorization(user: "owner", password: "provisional"): "provisional",
            basicAuthorization(user: "owner", password: "repaired"): "repaired"
        ])
        let scheduler = scheduler(configuration: configuration, keychain: keychain.manager)
        let event = TaskItem(title: "Credential fixture event")
        event.dueDate = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(event)
        try context.save()
        let eventID = event.id
        let calendarRequests = AccountCalendarRecorder()
        let calendar = NextcloudCalendarSyncManager(transport: calendarRequests, keychainManager: keychain.manager)

        let recovery = AccountWriteGate()
        keychain.beforeWrite("committed", action: recovery.pause)
        if restoreFails { keychain.rejectWrites(of: "committed") }
        let failing = AccountManager(modelContext: context, keychainManager: keychain.manager,
                                     saveAccount: { _ in throw InjectedFailure.database })
        let edit = Task {
            try await failing.updateNextcloudAccount(accountID: id, serverURL: newURL,
                                                     username: "new-owner", password: "provisional")
        }
        await recovery.waitUntilPaused()
        await scheduler.syncNow(modelContext: context)
        #expect(ScriptedDAVProtocol.requests(host: oldHost).isEmpty)
        #expect(scheduler.lastSyncFailure == nil, "A deferred read must not report missing credentials")
        #expect(scheduler.lastSyncDate == nil)
        #expect(try await calendar.syncSingleTask(taskID: eventID, accountID: id, role: .managedMirror, container: container) == false)
        #expect(await calendarRequests.collectionURLs.isEmpty)
        await #expect(throws: AccountCredentialDeferral.busy) {
            _ = try await manager.getCredentials(for: id)
        }
        recovery.resume()
        await #expect(throws: (any Error).self) { try await edit.value }
        #expect(account.serverBaseURL == oldURL)
        #expect(account.username == "owner")

        await scheduler.syncNow(modelContext: context)
        if restoreFails {
            #expect(ScriptedDAVProtocol.requests(host: oldHost).isEmpty)
            try await manager.updateNextcloudAccount(accountID: id, displayName: "Renamed")
            await #expect(throws: InjectedFailure.database) {
                try await failing.updateNextcloudAccount(accountID: id, password: "unsaved repair")
            }
            await #expect(throws: AccountCredentialDeferral.uncertainCredential) {
                _ = try await manager.getCredentials(for: id)
            }
            await scheduler.syncNow(modelContext: context)
            #expect(ScriptedDAVProtocol.requests(host: oldHost).isEmpty)
            #expect(scheduler.lastSyncDate == nil)
            #expect(try await calendar.syncSingleTask(taskID: eventID, accountID: id, role: .managedMirror, container: container) == false)
            #expect(await calendarRequests.collectionURLs.isEmpty)
            try await manager.updateNextcloudAccount(accountID: id, password: "repaired")
            await scheduler.syncNow(modelContext: context)
            #expect(ScriptedDAVProtocol.requests(host: oldHost).map(\.authorizationLabel) == ["repaired"])
        } else {
            #expect(ScriptedDAVProtocol.requests(host: oldHost).map(\.authorizationLabel) == ["committed"])
        }
        #expect(try await calendar.syncSingleTask(taskID: eventID, accountID: id, role: .managedMirror, container: container))
        #expect(await calendarRequests.collectionURLs == [oldURL])
        #expect(await calendarRequests.collectionPasswords == [restoreFails ? "repaired" : "committed"])
    }

    @Test("Credential admission retains exact raw account scope", arguments: [false, true])
    @MainActor
    func credentialScopeUsesRawBytes(changeUsername: Bool) async throws {
        let container = try makeContainer()
        let keychain = TestAccountKeychain()
        let manager = AccountManager(modelContext: container.mainContext, keychainManager: keychain.manager)
        let account = try await manager.addNextcloudAccount(
            displayName: "Cloud", serverURL: "https://example.invalid", username: "Caf\u{00E9}", password: "fixture")
        let expected = AccountCredentialScope(id: account.id,
            serverBaseURL: changeUsername ? "https://example.invalid" : "https://example.invalid:443",
            username: changeUsername ? "Cafe\u{0301}" : "Caf\u{00E9}")
        let result = try await AccountManager.admitCredentials(accountID: account.id, expected: expected,
                                                               container: container, keychainManager: keychain.manager)
        if case .deferred(.staleAccount) = result { return }
        Issue.record("The different raw account scope should have been deferred")
    }

    @Test("A credential reader hands the slot to a waiting writer without admitting a second reader")
    @MainActor
    func readingHandsOffToWriter() async throws {
        let container = try makeContainer()
        let keychain = TestAccountKeychain()
        let manager = AccountManager(modelContext: container.mainContext, keychainManager: keychain.manager)
        let originalURL = "https://old.invalid"
        let newURL = "https://new.invalid"
        let account = try await manager.addNextcloudAccount(
            displayName: "Cloud", serverURL: originalURL, username: "old", password: "valid")
        let other = try await manager.addNextcloudAccount(
            displayName: "Other", serverURL: "https://other.invalid", username: "other", password: "other")
        let id = account.id
        let readGate = AccountWriteGate()
        keychain.beforeRead(id, action: readGate.pause)
        let read = Task {
            try await AccountManager.admitCredentials(accountID: id, container: container,
                                                       keychainManager: keychain.manager)
        }
        await readGate.waitUntilPaused()
        let writer = await startAccountOperation {
            try await manager.updateNextcloudAccount(accountID: id, serverURL: newURL,
                                                     username: "new", password: "replacement")
        }
        await #expect(throws: AccountCredentialDeferral.busy) {
            _ = try await manager.getCredentials(for: id)
        }
        #expect(try await manager.getCredentials(for: other.id)?.password == "other")
        readGate.resume()
        if case .available(let before) = try await read.value {
            #expect(before.scope.serverBaseURL == originalURL)
            #expect(before.scope.username == "old")
            #expect(before.password == "valid")
        } else {
            Issue.record("The admitted read should complete with the previous account and credential")
        }
        try await writer.value
        #expect(account.serverBaseURL == newURL)
        #expect(try await manager.getCredentials(for: id)?.password == "replacement")
    }

    @Test("A pre-commit DAV snapshot cannot use credentials for a newly committed server")
    @MainActor
    func staleDAVSnapshotDoesNotUseReplacement() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let keychain = TestAccountKeychain()
        let manager = AccountManager(modelContext: context, keychainManager: keychain.manager)
        let prefix = UUID().uuidString.lowercased()
        let gateHost = "gate-" + prefix + ".invalid"
        let oldHost = "before-" + prefix + ".invalid"
        let newHost = "after-" + prefix + ".invalid"
        let gateAccount = try await manager.addNextcloudAccount(
            displayName: "First", serverURL: "https://" + gateHost, username: "gate", password: "gate")
        let account = try await manager.addNextcloudAccount(
            displayName: "Second", serverURL: "https://" + oldHost, username: "old", password: "committed")
        #expect(try context.fetch(FetchDescriptor<ServerAccount>()).map(\.id) == [gateAccount.id, account.id])
        let gate = ScriptedDAVProtocol.Gate()
        let configuration = ScriptedDAVProtocol.install(host: gateHost, responses: [
            .init(status: 503, body: "fixture", gate: gate), .init(status: 503, body: "fixture")
        ])
        _ = ScriptedDAVProtocol.install(host: oldHost, responses: [.init(status: 503, body: "fixture")],
            authorizationLabels: [basicAuthorization(user: "old", password: "new-password"): "mismatched"])
        _ = ScriptedDAVProtocol.install(host: newHost, responses: [.init(status: 503, body: "fixture")],
            authorizationLabels: [basicAuthorization(user: "new", password: "new-password"): "replacement"])
        let scheduler = scheduler(configuration: configuration, keychain: keychain.manager)
        let run = Task { await scheduler.syncNow(modelContext: context) }
        defer { gate.release(); run.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while ScriptedDAVProtocol.requests(host: gateHost).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!ScriptedDAVProtocol.requests(host: gateHost).isEmpty)

        try await manager.updateNextcloudAccount(accountID: account.id, serverURL: "https://" + newHost,
                                                 username: "new", password: "new-password")
        gate.release()
        await run.value
        #expect(ScriptedDAVProtocol.requests(host: oldHost).isEmpty)
        #expect(ScriptedDAVProtocol.requests(host: newHost).isEmpty)

        await scheduler.syncNow(modelContext: context)
        #expect(ScriptedDAVProtocol.requests(host: oldHost).isEmpty)
        #expect(ScriptedDAVProtocol.requests(host: newHost).map(\.authorizationLabel) == ["replacement"])
    }

    @Test("An old Edit form cannot test its old server using another edit's replacement password")
    @MainActor
    func staleAccountFormDoesNotSendReplacementCredential() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let keychain = TestAccountKeychain()
        let manager = AccountManager(modelContext: context, keychainManager: keychain.manager)
        let suffix = UUID().uuidString.lowercased() + ".invalid"
        let oldHost = "previous-form-" + suffix
        let oldURL = "https://" + oldHost
        let account = try await manager.addNextcloudAccount(
            displayName: "Cloud", serverURL: oldURL, username: "old", password: "original")
        let form = AccountCredentialScope(account)
        let otherWindow = AccountManager(modelContext: ModelContext(container), keychainManager: keychain.manager)
        try await otherWindow.updateNextcloudAccount(accountID: account.id, serverURL: "https://new-form-" + suffix,
                                                      username: "new", password: "replacement")

        let discovery = DAVSyncScenario.discovery(paths: [])
        let configuration = ScriptedDAVProtocol.install(host: oldHost, responses: discovery + discovery,
            authorizationLabels: [
                basicAuthorization(user: "old", password: "replacement"): "mixed",
                basicAuthorization(user: "old", password: "typed"): "typed"
            ])
        let result = await AccountEditView.performConnectionTest(account: form,
            serverURL: oldURL, username: "old", password: "", in: context,
            keychainManager: keychain.manager, configuration: configuration)
        #expect(result == nil)
        #expect(ScriptedDAVProtocol.requests(host: oldHost).isEmpty)

        let explicit = await AccountEditView.performConnectionTest(account: form,
            serverURL: oldURL, username: "old", password: "typed", in: context,
            keychainManager: keychain.manager, configuration: configuration)
        if case .success? = explicit {} else { Issue.record("Explicit typed credentials should still test") }
        #expect(ScriptedDAVProtocol.requests(host: oldHost).map(\.authorizationLabel) == ["typed", "typed", "typed"])

        let current = try #require(ModelContext(container).fetch(FetchDescriptor<ServerAccount>()).first)
        let newHost = "new-form-" + suffix
        _ = ScriptedDAVProtocol.install(host: newHost, responses: discovery,
            authorizationLabels: [basicAuthorization(user: "new", password: "replacement"): "replacement"])
        let fresh = await AccountEditView.performConnectionTest(account: AccountCredentialScope(current),
            serverURL: current.serverBaseURL, username: current.username, password: "", in: context,
            keychainManager: keychain.manager, configuration: configuration)
        if case .success? = fresh {} else { Issue.record("Current stored credentials should test") }
        #expect(ScriptedDAVProtocol.requests(host: newHost).map(\.authorizationLabel)
            == ["replacement", "replacement", "replacement"])
    }

    @Test("An old reauthentication cannot replace the credential of a newly rebound account")
    @MainActor
    func staleReauthenticationCannotSaveAgainstNewBinding() async throws {
        let container = try makeContainer()
        let keychain = TestAccountKeychain()
        let editor = AccountManager(modelContext: container.mainContext, keychainManager: keychain.manager)
        let otherWindow = AccountManager(modelContext: ModelContext(container), keychainManager: keychain.manager)
        let account = try await editor.addNextcloudAccountViaLoginFlow(
            serverURL: "https://old-auth.invalid", loginName: "old", appPassword: "original")
        let startingScope = AccountCredentialScope(account)
        let id = account.id
        try await otherWindow.updateNextcloudAccount(accountID: id, serverURL: "https://new-auth.invalid",
                                                       username: "new", password: "replacement")
        var shownSuccess = false
        var failure: String?
        await AccountLoginSave.perform(save: {
            try await editor.reauthenticateNextcloudAccount(account: startingScope,
                returnedServer: "https://old-auth.invalid", loginName: "old-reauth", appPassword: "old-server")
        }, onSuccess: { shownSuccess = true }, onFailure: { failure = $0 })
        let fresh = try #require(ModelContext(container).fetch(FetchDescriptor<ServerAccount>()).first)
        #expect(!shownSuccess)
        #expect(failure == nil)
        #expect(fresh.serverBaseURL == "https://new-auth.invalid")
        #expect(fresh.username == "new")
        #expect(try await keychain.manager.retrieve(for: id) == "replacement")

        let currentScope = AccountCredentialScope(fresh)
        await #expect(throws: LoginFlowError.serverMismatch) {
            try await editor.reauthenticateNextcloudAccount(account: currentScope,
                returnedServer: "https://old-auth.invalid", loginName: "wrong", appPassword: "old-server")
        }
        let retryScope = AccountCredentialScope(try #require(ModelContext(container).fetch(FetchDescriptor<ServerAccount>()).first))
        await AccountLoginSave.perform(save: {
            try await editor.reauthenticateNextcloudAccount(account: retryScope,
                returnedServer: "https://new-auth.invalid", loginName: "new-reauth", appPassword: "current")
        }, onSuccess: { shownSuccess = true }, onFailure: { failure = $0 })
        #expect(shownSuccess)
        #expect(failure == nil)
        #expect(try await keychain.manager.retrieve(for: id) == "current")
    }

    @Test("A delayed reauthentication cannot supersede an account rebind already saving")
    @MainActor
    func staleReauthenticationDoesNotInterruptRebind() async throws {
        let container = try makeContainer()
        let keychain = TestAccountKeychain()
        let editor = AccountManager(modelContext: container.mainContext, keychainManager: keychain.manager)
        let otherWindow = AccountManager(modelContext: ModelContext(container), keychainManager: keychain.manager)
        let account = try await editor.addNextcloudAccountViaLoginFlow(
            serverURL: "https://old-auth.invalid", loginName: "old", appPassword: "original")
        let startingScope = AccountCredentialScope(account)
        let id = account.id
        let gate = AccountWriteGate()
        defer { gate.resume() }
        keychain.beforeWrite("replacement", action: gate.pause)
        let rebind = Task {
            try await otherWindow.updateNextcloudAccount(accountID: id, serverURL: "https://new-auth.invalid",
                                                           username: "new", password: "replacement")
        }
        await gate.waitUntilPaused()
        var shownSuccess = false
        var deferral: AccountCredentialDeferral?
        let lateLogin = await startAccountOperation {
            await AccountLoginSave.perform(save: {
                do {
                    try await editor.reauthenticateNextcloudAccount(account: startingScope,
                        returnedServer: "https://old-auth.invalid", loginName: "old-reauth", appPassword: "old-server")
                } catch let reason as AccountCredentialDeferral {
                    deferral = reason
                    throw reason
                }
            }, onSuccess: { shownSuccess = true }, onFailure: { _ in Issue.record("Deferral should not show an error") })
        }
        gate.resume()
        try await lateLogin.value
        #expect(deferral == .busy)
        #expect(!shownSuccess)
        if case .failure(let error) = await rebind.result {
            Issue.record("The in-progress rebind should commit, but returned \(type(of: error))")
        }
        let fresh = try #require(ModelContext(container).fetch(FetchDescriptor<ServerAccount>()).first)
        #expect(fresh.serverBaseURL == "https://new-auth.invalid")
        #expect(fresh.username == "new")
        #expect(try await keychain.manager.retrieve(for: id) == "replacement")
    }

    @MainActor
    private func scheduler(configuration: URLSessionConfiguration, keychain: KeychainManager) -> SyncScheduler {
        let client = CalDAVClient(configuration: configuration, retryPolicy: .init(maxAttempts: 1, baseDelay: 0))
        return SyncScheduler(syncEngine: SyncEngine(calDAVClient: client), keychainManager: keychain,
                             onWidgetReload: {}, onNotificationFlush: { _ in })
    }

    private func basicAuthorization(user: String, password: String) -> String {
        "Basic " + Data((user + ":" + password).utf8).base64EncodedString()
    }

    @MainActor
    private func saveUnrelatedDraft(in context: ModelContext) throws {
        let unrelated = TaskItem(title: "Unrelated save")
        context.insert(unrelated)
        try context.save()
        #expect(try ModelContext(context.container).fetchCount(FetchDescriptor<TaskItem>()) == 1)
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self,
            configurations: config
        )
    }

    @Test("Explicit DAV seed survives account updates and is removed with the account")
    @MainActor
    func explicitSeedLifecycle() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let manager = AccountManager(modelContext: context)
        let input = "https://example.com/cloud/remote.php/dav/calendars/alice/tasks/"
        let account = try await manager.addNextcloudAccount(displayName: "Cloud", serverURL: input, username: "alice", password: "pw", storeInKeychain: false)
        #expect(account.serverBaseURL == "https://example.com/cloud")
        let reopened = ModelContext(container)
        #expect(try NextcloudDiscoverySeed.address(accountID: account.id, serverURL: account.serverBaseURL, in: reopened).discoverySeed?.absoluteString == input)
        try await manager.updateNextcloudAccount(accountID: account.id, displayName: "Renamed", serverURL: account.serverBaseURL)
        #expect(try NextcloudDiscoverySeed.address(accountID: account.id, serverURL: account.serverBaseURL, in: ModelContext(container)).discoverySeed?.absoluteString == input)
        try await manager.updateNextcloudAccount(accountID: account.id, serverURL: "https://example.com/other")
        #expect(try NextcloudDiscoverySeed.address(accountID: account.id, serverURL: account.serverBaseURL, in: ModelContext(container)).discoverySeed == nil)
        try NextcloudDiscoverySeed.store(accountID: account.id, seed: URL(string: input), baseURL: URL(string: "https://example.com/cloud")!, in: context)
        try context.save()
        try await manager.removeAccount(accountID: account.id)
        #expect(try NextcloudDiscoverySeed.address(accountID: account.id, serverURL: "https://example.com/cloud", in: ModelContext(container)).discoverySeed == nil)
    }

    @Test("Login flow rejects a foreign seed before inserting an account")
    @MainActor
    func loginFlowRejectsForeignSeed() async throws {
        let context = ModelContext(try makeContainer())
        let manager = AccountManager(modelContext: context)
        do {
            _ = try await manager.addNextcloudAccountViaLoginFlow(
                serverURL: "https://example.com/cloud", loginName: "alice", appPassword: "pw",
                discoverySeed: URL(string: "https://example.com/other/remote.php/dav/")!
            )
            Issue.record("Expected the foreign installation seed to be rejected")
        } catch {
            #expect(try context.fetch(FetchDescriptor<ServerAccount>()).isEmpty)
            #expect(try context.fetch(FetchDescriptor<SyncMetadata>()).isEmpty)
        }
    }

    @Test("Foreign DAV seed is rejected")
    @MainActor
    func foreignSeedRejected() throws {
        let context = ModelContext(try makeContainer())
        #expect(throws: (any Error).self) {
            try NextcloudDiscoverySeed.store(accountID: "account", seed: URL(string: "https://evil.example/remote.php/dav/")!, baseURL: URL(string: "https://example.com")!, in: context)
        }
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
        task.remoteHref = "/cal/work/uid-moved.ics"; task.etag = "source-baseline"
        task.isLocalOnly = false
        task.taskList = work
        context.insert(task)
        try SyncResourceFixture.prove(task, in: context)
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

private actor AccountCalendarRecorder: NextcloudCalendarTransport {
    private(set) var collectionURLs: [String] = []
    private(set) var collectionPasswords: [String] = []

    func discover(address: NextcloudServerAddress, admitted: CommittedAccountCredentials,
                  validate: @escaping CalendarRequestValidation) async throws -> CalDAVDiscoveryResult {
        try await validate()
        collectionURLs.append(admitted.scope.serverBaseURL)
        collectionPasswords.append(admitted.password)
        let home = try #require(URL(string: address.baseURL.absoluteString + "/fixture-calendar/"))
        return .init(principalURL: nil, calendarHomeURL: home, calendars: .init(live: [], trashed: []), collectionAddresses: [])
    }

    func ensureCollection(target: URL, marker: String, create: Bool, admitted: CommittedAccountCredentials,
                          validate: @escaping CalendarRequestValidation) async throws -> URL {
        try await validate()
        return target
    }

    func read(target: CalendarEventTarget, admitted: CommittedAccountCredentials,
              validate: @escaping CalendarRequestValidation) async throws -> CalendarEventRead { .absent }

    func put(_ intent: CalendarEventIntent, admitted: CommittedAccountCredentials,
             validate: @escaping CalendarRequestValidation) async throws -> CalendarEventWrite {
        try await validate()
        return .acknowledged(intent.target.version(try #require(CalendarStrongETag("\"fixture\""))))
    }

    func remove(_ intent: CalendarEventIntent, admitted: CommittedAccountCredentials,
                validate: @escaping CalendarRequestValidation) async throws {}
}

@Suite("Keychain credential replacement")
struct KeychainCredentialReplacementTests {
    @Test("A failed replacement retains the existing password")
    func failedReplacementRetainsItem() async throws {
        let keychain = TestAccountKeychain()
        let manager = keychain.manager
        try await manager.save(password: "valid", for: "account")
        keychain.rejectWrites(of: "replacement")

        await #expect(throws: KeychainManager.KeychainError.self) {
            try await manager.save(password: "replacement", for: "account")
        }

        #expect(try await manager.retrieve(for: "account") == "valid")
    }

    @Test("Credentials stay scoped by service and account through insert, update and delete")
    func replacementUsesItemIdentity() async throws {
        let keychain = TestAccountKeychain()
        let manager = keychain.manager
        let other = KeychainManager(service: "other", operations: keychain.operations)
        try await manager.save(password: "initial", for: "account")
        try await other.save(password: "another service", for: "account")
        try await manager.save(password: "another account", for: "other")
        try await manager.save(password: "replacement", for: "account")

        #expect(try await manager.retrieve(for: "account") == "replacement")
        #expect(try await other.retrieve(for: "account") == "another service")
        #expect(try await manager.retrieve(for: "other") == "another account")
        try await manager.delete(for: "account")
        try await manager.delete(for: "account")
        #expect(try await manager.retrieve(for: "account") == nil)
    }
}

/// In-memory implementation of the Security boundary. SwiftData and both
/// production managers remain in the test path.
final class TestAccountKeychain: Sendable {
    private struct Item: Hashable {
        let service: String
        let account: String

        init(_ query: CFDictionary) {
            let attributes = query as NSDictionary
            service = attributes[kSecAttrService] as? String ?? ""
            account = attributes[kSecAttrAccount] as? String ?? ""
        }
    }

    private struct State {
        var items: [Item: Data] = [:]
        var rejected: Data?
        var gates: [Data: @Sendable () -> Void] = [:]
        var readGates: [String: @Sendable () -> Void] = [:]
    }

    private let state = Mutex(State())

    var manager: KeychainManager { KeychainManager(operations: operations) }
    var itemCount: Int { state.withLock { $0.items.count } }

    var operations: KeychainManager.Operations {
        .init(add: { query in self.write(query, attributes: query, adding: true) },
              update: { query, attributes in self.write(query, attributes: attributes, adding: false) },
              copyMatching: { query in
                  let item = Item(query)
                  self.state.withLock { $0.readGates.removeValue(forKey: item.account) }?()
                  return self.state.withLock {
                      guard let data = $0.items[item] else { return (errSecItemNotFound, nil) }
                      return (errSecSuccess, data as NSData)
                  }
              },
              delete: { query in
                  self.state.withLock {
                      $0.items.removeValue(forKey: Item(query)) == nil ? errSecItemNotFound : errSecSuccess
                  }
              })
    }

    func rejectWrites(of password: String) {
        state.withLock { $0.rejected = Data(password.utf8) }
    }

    func beforeWrite(_ password: String, action: @escaping @Sendable () -> Void) {
        state.withLock { $0.gates[Data(password.utf8)] = action }
    }

    func beforeRead(_ accountID: String, action: @escaping @Sendable () -> Void) {
        state.withLock { $0.readGates[accountID] = action }
    }

    private func write(_ query: CFDictionary, attributes: CFDictionary, adding: Bool) -> OSStatus {
        guard let data = (attributes as NSDictionary)[kSecValueData] as? Data else { return errSecParam }
        state.withLock { $0.gates.removeValue(forKey: data) }?()
        let item = Item(query)
        return state.withLock {
            let exists = $0.items[item] != nil
            if adding && exists { return errSecDuplicateItem }
            if !adding && !exists { return errSecItemNotFound }
            if $0.rejected == data { return errSecInteractionNotAllowed }
            $0.items[item] = data
            return errSecSuccess
        }
    }
}

final class AccountWriteGate: Sendable {
    private let started = AsyncStream<Void>.makeStream()
    private let release = DispatchSemaphore(value: 0)

    func pause() {
        started.continuation.yield()
        started.continuation.finish()
        if release.wait(timeout: .now() + 10) == .timedOut {
            Issue.record("The credential write was never released")
        }
    }

    func waitUntilPaused() async {
        for await _ in started.stream { return }
    }

    func resume() { release.signal() }
}

/// Returning to the main actor here means the new operation reached its first suspension.
@MainActor
func startAccountOperation(
    _ operation: @escaping @MainActor () async throws -> Void
) async -> Task<Void, any Error> {
    let started = AsyncStream<Void>.makeStream()
    let task = Task {
        started.continuation.yield()
        started.continuation.finish()
        try await operation()
    }
    for await _ in started.stream { break }
    return task
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
