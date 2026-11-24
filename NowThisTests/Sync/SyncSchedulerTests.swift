import Testing
import Foundation
import SwiftData

@testable import NowThis

@Suite("SyncScheduler Widget Coherency")
struct SyncSchedulerWidgetReloadTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    @Test("One notification flush is awaited before a sync run completes")
    @MainActor
    func runAwaitsExactlyOneNotificationFlush() async throws {
        let container = try makeContainer()
        var flushCount = 0
        var syncingDuringFlush = false
        weak var observedScheduler: SyncScheduler?
        let scheduler = SyncScheduler(onWidgetReload: {}, onNotificationFlush: { context in
            #expect(context === container.mainContext)
            flushCount += 1
            syncingDuringFlush = observedScheduler?.isSyncing == true
            await Task.yield()
        })
        observedScheduler = scheduler
        await scheduler.syncNow(modelContext: container.mainContext)
        #expect(flushCount == 1)
        #expect(syncingDuringFlush)
        #expect(!scheduler.isSyncing)
    }

    @Test("Cancellation retains saved recovery work without starting a fresh notification flush")
    @MainActor
    func cancelledRunRetainsRecoveryWithoutFreshFlush() async throws {
        let container = try makeContainer()
        container.mainContext.insert(ServerAccount(displayName: "Cancelled run",
            serverBaseURL: "https://example.com", username: "unused"))
        try container.mainContext.save()
        let ticket = ReminderSchedulingJournal.enqueue(in: container.mainContext)
        try container.mainContext.save()
        var flushCount = 0
        let scheduler = SyncScheduler(onWidgetReload: {}, onNotificationFlush: { _ in
            flushCount += 1
            await Task.yield()
        })
        let run = Task { await scheduler.syncNow(modelContext: container.mainContext) }
        run.cancel()
        await run.value
        #expect(flushCount == 0)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)) == [ticket])
        #expect(!scheduler.isSyncing)
        #expect(scheduler.lastSyncFailure == nil)
    }

    @Test("A successful sync reloads widget timelines")
    @MainActor
    func successfulSyncReloadsWidget() async throws {
        let container = try makeContainer()

        var reloaded = false
        let scheduler = SyncScheduler(onWidgetReload: { reloaded = true })

        // No accounts configured → sync completes successfully with nothing to do.
        await scheduler.syncNow(modelContext: container.mainContext)

        #expect(reloaded, "Widget timelines should be reloaded after a successful sync")
        #expect(scheduler.lastError == nil)
    }
}

@Suite("Foreground Startup Ordering")
struct ForegroundStartupOrderingTests {
    @Test("Foreground request starts while notification recovery is paused and recovery survives sync failure")
    @MainActor
    func networkStartsBeforePausedRecoveryAndRecoverySurvivesFailure() async throws {
        let container = try DAVSyncScenario.container()
        let host = "foreground-recovery-order-" + UUID().uuidString.lowercased() + ".invalid"
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: [
                .init(status: 500, body: "temporary server failure")
            ]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let keychain = KeychainManager(service: "nowthis.foreground-order." + UUID().uuidString)
        let manager = AccountManager(modelContext: container.mainContext, keychainManager: keychain)
        let account = try await manager.addNextcloudAccount(displayName: "Fixture",
            serverURL: "https://" + host, username: "fixture", password: "fixture")
        let accountID = account.id
        let releaseRecovery = ScriptedDAVProtocol.Gate()
        var recoveryIsPaused = false
        var recoveryFinished = false
        let scheduler = SyncScheduler(syncEngine: engine, keychainManager: keychain,
            onWidgetReload: {}, onNotificationFlush: { _ in })
        defer {
            releaseRecovery.release()
            scheduler.cancelInflightSync()
        }

        let foregroundRun = Task {
            await scheduler.startForegroundWork(modelContext: container.mainContext) {
                recoveryIsPaused = true
                await releaseRecovery.wait()
                recoveryFinished = true
            }
        }
        defer { foregroundRun.cancel() }

        let recoveryDeadline = ContinuousClock.now + .seconds(3)
        while !recoveryIsPaused && ContinuousClock.now < recoveryDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recoveryIsPaused, "Notification recovery should enter its paused operation")

        let requestDeadline = ContinuousClock.now + .seconds(3)
        while ScriptedDAVProtocol.requests(host: host).isEmpty && ContinuousClock.now < requestDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let requestsWhileRecoveryPaused = ScriptedDAVProtocol.requests(host: host)
        #expect(requestsWhileRecoveryPaused.first?.method == "PROPFIND")
        #expect(requestsWhileRecoveryPaused.first?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "remote.php/dav",
            "Foreground discovery should reach the server before notification recovery is released")

        let failureDeadline = ContinuousClock.now + .seconds(3)
        while scheduler.lastSyncFailure == nil && ContinuousClock.now < failureDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!scheduler.isSyncing)
        #expect(scheduler.lastSyncFailure != nil,
            "The fixture server failure should be reported by the real sync runner")

        releaseRecovery.release()
        await foregroundRun.value
        #expect(recoveryFinished, "Notification recovery should finish after a network failure")
        try await keychain.delete(for: accountID)
    }
}

@Suite("SyncScheduler Cancellation")
struct SyncSchedulerCancellationTests {

    @Test("cancelInflightSync cancels a running foreground sync task")
    func cancelInflightSyncCancelsForegroundTask() async throws {
        let tracker = CancellationTracker()

        await MainActor.run {
            let scheduler = SyncScheduler()

            scheduler.startTrackedTask {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch is CancellationError {
                    await tracker.markCancelled()
                } catch {}
            }

            // Cancel immediately
            scheduler.cancelInflightSync()
        }

        // Give cancellation time to propagate
        try await Task.sleep(for: .milliseconds(300))

        let wasCancelled = await tracker.isCancelled
        #expect(wasCancelled, "Expected the foreground sync task to be cancelled")
    }

    @Test("cancelInflightSync is safe to call with no inflight work")
    func cancelInflightSyncNoOp() async {
        await MainActor.run {
            let scheduler = SyncScheduler()
            // Should not crash or have side effects
            scheduler.cancelInflightSync()
            #expect(!scheduler.isSyncing)
        }
    }
}

// MARK: - Test Helpers

/// Thread-safe tracker for cancellation state in tests.
private actor CancellationTracker {
    var isCancelled = false

    func markCancelled() {
        isCancelled = true
    }
}

@Suite("SyncScheduler HTTP diagnostics")
@MainActor
struct SyncSchedulerHTTPDiagnosticsTests {
    @Test("Foreground and background share the latest rejected password for one login")
    func backgroundRejectionReplacesForegroundFingerprint() async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let host = "replaced-password-" + UUID().uuidString.lowercased() + ".invalid"
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let keychain = KeychainManager(service: "nowthis.replaced-password-tests." + UUID().uuidString)
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host,
            responses: [.init(status: 401, body: ""), .init(status: 401, body: "")] + DAVSyncScenario.discovery(paths: []))))
        let scheduler = SyncScheduler(syncEngine: engine, keychainManager: keychain,
            onWidgetReload: {}, onNotificationFlush: { _ in })

        try await keychain.save(password: "first", for: accountID)
        await scheduler.syncNow(modelContext: context)
        #expect(scheduler.lastSyncFailure?.httpStatusCode == 401)
        #expect(scheduler.lastError?.contains("Fixture") == true)
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)

        try await keychain.save(password: "second", for: accountID)
        let second = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: .init(username: "fixture", password: "second"), modelContainer: container,
            reconcileNotifications: false)
        #expect(second.failures.first?.httpStatusCode == 401)
        #expect(ScriptedDAVProtocol.requests(host: host).count == 2)

        try await keychain.save(password: "first", for: accountID)
        await scheduler.syncNow(modelContext: context)
        #expect(scheduler.lastSyncFailure == nil)
        #expect(ScriptedDAVProtocol.requests(host: host).count == 5)

        try await keychain.save(password: "second", for: accountID)
        await scheduler.syncNow(modelContext: context)
        #expect(scheduler.lastSyncFailure?.category == .authentication)
        #expect(scheduler.lastError?.contains("Fixture") == true)
        #expect(ScriptedDAVProtocol.requests(host: host).count == 5)
        try await keychain.delete(for: accountID)
    }

    @Test("Correcting account login settings retries with the same password", arguments: [false, true])
    func correctedLoginRetriesWithSamePassword(changeServer: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let host = "changed-login-" + UUID().uuidString.lowercased() + ".invalid"
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let context = container.mainContext
        let account = try #require(try context.fetch(FetchDescriptor<ServerAccount>()).first)
        let baseURL = "https://" + host
        if !changeServer { account.username = "wrong-user" }
        try context.save()

        let keychain = KeychainManager(service: "nowthis.changed-login-tests." + UUID().uuidString)
        try await keychain.save(password: "fixture", for: accountID)
        var discovery = DAVSyncScenario.discovery(paths: [])
        if changeServer {
            discovery[0].body = discovery[0].body.replacingOccurrences(of: "/remote.php/dav/", with: "/installation/remote.php/dav/")
        }
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: [.init(status: 401, body: "")] + discovery)))
        let scheduler = SyncScheduler(syncEngine: engine, keychainManager: keychain,
            onWidgetReload: {}, onNotificationFlush: { _ in })

        await scheduler.syncNow(modelContext: context)
        #expect(scheduler.lastSyncFailure?.category == .authentication)
        await scheduler.syncNow(modelContext: context)
        let rejected = ScriptedDAVProtocol.requests(host: host)
        #expect(rejected.count == 1)
        #expect(rejected.first?.basicAuthUsername == (changeServer ? "fixture" : "wrong-user"))

        if changeServer { account.serverBaseURL = baseURL + "/installation" }
        else { account.username = "fixture" }
        try context.save()
        await scheduler.syncNow(modelContext: context)
        let corrected = ScriptedDAVProtocol.requests(host: host).dropFirst()
        #expect(corrected.count == 3)
        #expect(corrected.first?.path == (changeServer ? "/installation/remote.php/dav" : "/remote.php/dav"))
        #expect(corrected.first?.basicAuthUsername == "fixture")
        #expect(scheduler.lastSyncFailure == nil)

        if changeServer { account.serverBaseURL = baseURL }
        else { account.username = "wrong-user" }
        try context.save()
        await scheduler.syncNow(modelContext: context)
        #expect(scheduler.lastSyncFailure?.category == .authentication)
        #expect(ScriptedDAVProtocol.requests(host: host).count == 4)
        try await keychain.delete(for: accountID)
    }

    @Test("Equivalent base URL spellings retain background authentication suppression")
    func equivalentBaseURLRetainsAuthSuppression() async throws {
        let host = "equivalent-login-" + UUID().uuidString.lowercased() + ".invalid"
        let baseURL = "https://" + host
        let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: [.init(status: 401, body: "")])))
        let first = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
        #expect(first.failures.first?.httpStatusCode == 401)

        let context = container.mainContext
        let account = try #require(try context.fetch(FetchDescriptor<ServerAccount>()).first)
        account.serverBaseURL = baseURL + ":443/"
        try context.save()
        let next = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: account.serverBaseURL,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
        #expect(next.failures.first?.httpStatusCode == 401)
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
    }

    @Test("A legacy source 401 suppresses only the account that sent the source request")
    func legacySourceRejectionBelongsToSourceAccount() async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let host = "source-login-" + UUID().uuidString.lowercased() + ".invalid"
        let baseURL = "https://" + host
        let source = ServerAccount(displayName: "Source", serverBaseURL: baseURL, username: "fixture")
        let destination = ServerAccount(displayName: "Destination", serverBaseURL: baseURL, username: "fixture")
        let sourceList = TaskList(serverURL: "/source/", name: "Source", colorHex: "#007AFF")
        let destinationList = TaskList(serverURL: "/destination/", name: "Destination", colorHex: "#007AFF")
        context.insert(source)
        context.insert(destination)
        context.insert(sourceList)
        context.insert(destinationList)
        sourceList.account = source
        destinationList.account = destination
        let moved = TaskItem(uid: "legacy", title: "Legacy move")
        context.insert(moved)
        moved.taskList = destinationList
        moved.pendingMoveFromHref = "/source/legacy.ics"
        moved.pendingMoveFromListID = sourceList.id
        moved.attachmentStateKnown = nil
        moved.isDirty = true
        try context.save()

        let discovery = DAVSyncScenario.discovery(paths: ["/destination/"])
        let manifest = ScriptedDAVProtocol.Response(body: DAVSyncScenario.manifest(count: 0, path: "/destination/"))
        let sourceCredentials = CalDAVClient.Credentials(username: "fixture", password: "source-fixture")
        let keychain = DAVSyncScenario.keychain(accountID: source.id, password: sourceCredentials.password)
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host,
            responses: discovery + [manifest, .init(status: 401, body: "")] + discovery,
            authorizationLabels: [sourceCredentials.basicAuthHeader: "source"])),
            taskPhotoSync: TaskPhotoSync(keychainManager: keychain))
        let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
        let first = await engine.performFullSyncOutcome(accountID: destination.id, serverBaseURL: baseURL,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
        #expect(first.failures.first?.httpStatusCode == 401)
        let next = await engine.performFullSyncOutcome(accountID: destination.id, serverBaseURL: baseURL,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
        #expect(next.failures.first?.httpStatusCode == 401)
        #expect(next.pendingOutboundCount == 1)
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.filter { $0.method == "PROPFIND" }.count == 6)
        #expect(requests.filter { $0.method == "GET" }.map(\.path) == ["/source/legacy.ics"])
        #expect(requests.filter { $0.method == "GET" }.map(\.authorizationLabel) == ["source"])
        #expect(!requests.contains { $0.method == "PUT" || $0.method == "DELETE" })

        let direct = await engine.performBackgroundSyncOutcome(accountID: source.id, serverBaseURL: baseURL,
            credentials: sourceCredentials, modelContainer: container, reconcileNotifications: false)
        #expect(direct.failures.first?.httpStatusCode == 401)
        #expect(ScriptedDAVProtocol.requests(host: host).count == requests.count)
    }

    @Test("An actual 401 keeps its HTTP status through the account-specific authentication message")
    func rejectedCredentialsRetainHTTPStatus() async throws {
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container)
        let account = try #require(try container.mainContext.fetch(FetchDescriptor<ServerAccount>()).first)
        let host = "http-diagnostics-" + UUID().uuidString.lowercased() + ".invalid"
        account.serverBaseURL = "https://" + host
        try container.mainContext.save()
        let keychain = KeychainManager(service: "nowthis.http-diagnostics-tests." + UUID().uuidString)
        try await keychain.save(password: "fixture", for: accountID)
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: [.init(status: 401, body: "private response content")]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let scheduler = SyncScheduler(syncEngine: engine, keychainManager: keychain,
            onWidgetReload: {}, onNotificationFlush: { _ in })
        await scheduler.syncNow(modelContext: container.mainContext)
        try await keychain.delete(for: accountID)
        #expect(scheduler.lastSyncFailure?.category == .authentication)
        #expect(scheduler.lastSyncFailure?.httpStatusCode == 401)
        #expect(scheduler.lastError?.contains("private response content") == false)
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
    }
}

@Suite("SyncScheduler account changes", .serialized)
@MainActor
struct SyncSchedulerAccountChangeTests {
    @Test("First login starts sync despite a recent empty launch run and respects history preferences",
          arguments: [nil, 0] as [Int?])
    func firstLoginImportsWithoutRelaunch(historyMonths: Int?) async throws {
        let defaults = UserDefaults.standard
        let previousWindow = defaults.object(forKey: SyncPreferences.windowMonthsKey)
        if let historyMonths { defaults.set(historyMonths, forKey: SyncPreferences.windowMonthsKey) }
        else { defaults.removeObject(forKey: SyncPreferences.windowMonthsKey) }
        defer {
            if let previousWindow { defaults.set(previousWindow, forKey: SyncPreferences.windowMonthsKey) }
            else { defaults.removeObject(forKey: SyncPreferences.windowMonthsKey) }
        }

        let container = try DAVSyncScenario.container()
        let host = "first-login-" + UUID().uuidString.lowercased() + ".invalid"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let recent = formatter.string(from: Date().addingTimeInterval(-86_400))
        let bodies = DAVSyncScenario.tasks(count: 3)
            .replacingOccurrences(of: "UID:fixture-0\n", with: "UID:fixture-0\nCREATED:19990101T120000Z\n")
            .replacingOccurrences(of: "UID:fixture-1\n", with: "UID:fixture-1\nSTATUS:COMPLETED\nCOMPLETED:\(recent)\n")
            .replacingOccurrences(of: "UID:fixture-2\n", with: "UID:fixture-2\nSTATUS:COMPLETED\nCOMPLETED:19990101T120000Z\n")
        let responses = DAVSyncScenario.discovery(paths: ["/one/"])
            + [.init(body: DAVSyncScenario.manifest(count: 3)), .init(body: bodies)]
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let keychain = KeychainManager(service: "nowthis.first-login-tests." + UUID().uuidString)
        var flushCount = 0
        let scheduler = SyncScheduler(syncEngine: engine, keychainManager: keychain,
            onWidgetReload: {}, onNotificationFlush: { _ in flushCount += 1 })
        defer { scheduler.cancelInflightSync() }

        // Launch occurs before browser login has returned any account.
        await scheduler.syncNow(modelContext: container.mainContext)
        #expect(flushCount == 1)
        #expect(scheduler.lastSyncDate != nil)
        #expect(ScriptedDAVProtocol.requests(host: host).isEmpty)

        let manager = AccountManager(modelContext: container.mainContext, keychainManager: keychain)
        let account = try await manager.addNextcloudAccountViaLoginFlow(serverURL: "https://" + host,
            loginName: "fixture", appPassword: "fixture")
        let accountID = account.id
        scheduler.commands.syncAfterAccountAdded(container.mainContext)
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline && (flushCount < 2 || scheduler.isSyncing) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await keychain.delete(for: accountID)
        #expect(flushCount == 2, "The saved account must start a sync without relaunch or foreground throttle")
        #expect(!scheduler.isSyncing)
        #expect(scheduler.lastSyncFailure == nil)
        let read = ModelContext(container)
        let tasks = try read.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.map(\.uid).sorted() == (historyMonths == 0
            ? ["fixture-0", "fixture-1", "fixture-2"] : ["fixture-0", "fixture-1"]))
        #expect(tasks.allSatisfy { $0.taskList?.account?.id == accountID })
        #expect(ScriptedDAVProtocol.requests(host: host).count == 5)
    }

    @Test("An account added during a sync gets a follow-up pass")
    func accountAddedDuringRunIsNotDropped() async throws {
        let container = try DAVSyncScenario.container()
        let host = "login-during-sync-" + UUID().uuidString.lowercased() + ".invalid"
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"])
                + [.init(body: DAVSyncScenario.manifest(count: 1)), .init(body: DAVSyncScenario.tasks(count: 1))]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let keychain = KeychainManager(service: "nowthis.first-login-tests." + UUID().uuidString)
        let entered = ScriptedDAVProtocol.Gate()
        let resume = ScriptedDAVProtocol.Gate()
        var flushCount = 0
        let scheduler = SyncScheduler(syncEngine: engine, keychainManager: keychain,
            onWidgetReload: {}, onNotificationFlush: { _ in
                flushCount += 1
                if flushCount == 1 { entered.release(); await resume.wait() }
            })
        let initialRun = Task { await scheduler.syncNow(modelContext: container.mainContext) }
        defer { initialRun.cancel(); resume.release(); scheduler.cancelInflightSync() }
        await entered.wait()
        #expect(scheduler.isSyncing)
        let manager = AccountManager(modelContext: container.mainContext, keychainManager: keychain)
        let account = try await manager.addNextcloudAccount(displayName: "Fixture", serverURL: "https://" + host,
            username: "fixture", password: "fixture")
        let accountID = account.id
        scheduler.commands.syncAfterAccountAdded(container.mainContext)
        resume.release()
        await initialRun.value
        try await keychain.delete(for: accountID)
        #expect(flushCount == 2)
        #expect(!scheduler.isSyncing)
        #expect(scheduler.lastSyncFailure == nil)
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<TaskItem>()).map(\.uid) == ["fixture-0"])
        #expect(ScriptedDAVProtocol.requests(host: host).count == 5)
    }

    @Test("An already-started first import resumes after background cancellation")
    func interruptedFirstImportRemainsPending() async throws {
        let container = try DAVSyncScenario.container()
        let host = "interrupted-first-import-" + UUID().uuidString.lowercased() + ".invalid"
        let gate = ScriptedDAVProtocol.Gate()
        var discovery = DAVSyncScenario.discovery(paths: ["/one/"])
        discovery[0].gate = gate
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: discovery),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let keychain = KeychainManager(service: "nowthis.first-login-tests." + UUID().uuidString)
        var flushCount = 0
        let scheduler = SyncScheduler(syncEngine: engine, keychainManager: keychain,
            onWidgetReload: {}, onNotificationFlush: { _ in flushCount += 1 })
        await scheduler.syncNow(modelContext: container.mainContext)
        let manager = AccountManager(modelContext: container.mainContext, keychainManager: keychain)
        let account = try await manager.addNextcloudAccountViaLoginFlow(serverURL: "https://" + host,
            loginName: "fixture", appPassword: "fixture")
        let accountID = account.id
        defer { gate.release(); scheduler.cancelInflightSync() }
        scheduler.commands.syncAfterAccountAdded(container.mainContext)
        let run = Task { await scheduler.syncNow(modelContext: container.mainContext) }
        defer { run.cancel() }
        let discoveryDeadline = ContinuousClock.now + .seconds(3)
        while ScriptedDAVProtocol.requests(host: host).isEmpty && ContinuousClock.now < discoveryDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ScriptedDAVProtocol.requests(host: host).count == 1)
        scheduler.cancelInflightSync()
        gate.release()
        await run.value
        #expect(flushCount == 1, "Cancellation must not begin fresh unprotected notification work")
        _ = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"])
            + [.init(body: DAVSyncScenario.manifest(count: 1)), .init(body: DAVSyncScenario.tasks(count: 1))])
        scheduler.syncOnForeground(modelContext: container.mainContext)
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline && (flushCount < 2 || scheduler.isSyncing) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await keychain.delete(for: accountID)
        #expect(flushCount == 2, "Canceled import must retain recovery work rather than start an unprotected notification flush")
        #expect(!scheduler.isSyncing)
        #expect(scheduler.lastSyncFailure == nil)
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<TaskItem>()).map(\.uid) == ["fixture-0"])
        #expect(ScriptedDAVProtocol.requests(host: host).count == 5)
    }

    @Test("Backgrounding during login preserves the first sync for foreground return",
          arguments: [false, true])
    func pendingLoginSyncSurvivesCancellation(returnsBeforeCleanup: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let host = "resume-first-login-" + UUID().uuidString.lowercased() + ".invalid"
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"])
                + [.init(body: DAVSyncScenario.manifest(count: 1)), .init(body: DAVSyncScenario.tasks(count: 1))]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        let keychain = KeychainManager(service: "nowthis.first-login-tests." + UUID().uuidString)
        let entered = ScriptedDAVProtocol.Gate()
        let resume = ScriptedDAVProtocol.Gate()
        var flushCount = 0
        let scheduler = SyncScheduler(syncEngine: engine, keychainManager: keychain,
            onWidgetReload: {}, onNotificationFlush: { _ in
                flushCount += 1
                if flushCount == 2 { entered.release(); await resume.wait() }
            })
        await scheduler.syncNow(modelContext: container.mainContext)
        let run = Task { await scheduler.syncNow(modelContext: container.mainContext) }
        defer { run.cancel(); resume.release(); scheduler.cancelInflightSync() }
        await entered.wait()
        let manager = AccountManager(modelContext: container.mainContext, keychainManager: keychain)
        let account = try await manager.addNextcloudAccountViaLoginFlow(serverURL: "https://" + host,
            loginName: "fixture", appPassword: "fixture")
        let accountID = account.id
        scheduler.commands.syncAfterAccountAdded(container.mainContext)
        scheduler.cancelInflightSync()
        if returnsBeforeCleanup { scheduler.syncOnForeground(modelContext: container.mainContext) }
        resume.release()
        await run.value
        if !returnsBeforeCleanup { scheduler.syncOnForeground(modelContext: container.mainContext) }
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline && (flushCount < 3 || scheduler.isSyncing) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await keychain.delete(for: accountID)
        #expect(flushCount == 3, "Returning to the app must resume the pending login sync, even within 30 seconds")
        #expect(!scheduler.isSyncing)
        #expect(scheduler.lastSyncFailure == nil)
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<TaskItem>()).map(\.uid) == ["fixture-0"])
        #expect(ScriptedDAVProtocol.requests(host: host).count == 5)
    }
}

/// Advances only the scheduler's debounce. Sync passes still execute the shipping runner,
/// and notification-flush barriers keep each pass suspended at a known point.
@MainActor
final class SchedulerDebounceClock {
    private struct Sleep {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }
    private var now: Duration = .zero
    private var sleeps: [UUID: Sleep] = [:]
    private var registrations: [Int: ScriptedDAVProtocol.Gate] = [:]
    private(set) var requestedDelays: [TimeInterval] = []
    let cancelled = ScriptedDAVProtocol.Gate()

    func sleep(for interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                sleeps[id] = Sleep(deadline: now + .seconds(interval), continuation: continuation)
                requestedDelays.append(interval)
                registration(requestedDelays.count).release()
            }
        } onCancel: {
            Task { @MainActor in
                self.sleeps.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
                self.cancelled.release()
            }
        }
    }

    func waitForSleeps(_ count: Int) async {
        await registration(count).wait()
    }

    private func registration(_ count: Int) -> ScriptedDAVProtocol.Gate {
        if let gate = registrations[count] { return gate }
        let gate = ScriptedDAVProtocol.Gate()
        registrations[count] = gate
        return gate
    }

    func advance(by duration: Duration) {
        now += duration
        let ready = sleeps.filter { $0.value.deadline <= now }.map(\.key)
        for id in ready { sleeps.removeValue(forKey: id)?.continuation.resume() }
    }
}

@Suite("SyncScheduler edit follow-up debounce", .serialized)
@MainActor
struct SyncSchedulerEditDebounceTests {
    @Test("Edits during a run coalesce and wait two seconds after ownership is released")
    func inFlightEditsDebounceAfterRun() async throws {
        let container = try DAVSyncScenario.container()
        let clock = SchedulerDebounceClock()
        let entered = ScriptedDAVProtocol.Gate()
        let resume = ScriptedDAVProtocol.Gate()
        let followupEntered = ScriptedDAVProtocol.Gate()
        let followupResume = ScriptedDAVProtocol.Gate()
        var passes = 0
        let scheduler = SyncScheduler(onWidgetReload: {}, onNotificationFlush: { _ in
            passes += 1
            if passes == 1 { entered.release(); await resume.wait() }
            if passes == 2 {
                followupEntered.release()
                // A buggy immediate follow-up must finish so the RED assertion can
                // observe it; a clock-triggered pass stays suspended until joined.
                if !clock.requestedDelays.isEmpty { await followupResume.wait() }
            }
        }, changeDebounceSleep: { try await clock.sleep(for: $0) })
        let run = Task { await scheduler.syncNow(modelContext: container.mainContext) }
        defer { run.cancel(); resume.release(); followupResume.release(); scheduler.cancelInflightSync() }
        await entered.wait()
        scheduler.syncAfterChange(modelContext: container.mainContext)
        scheduler.syncAfterChange(modelContext: container.mainContext)
        resume.release()
        await run.value
        try #require(passes == 1, "Edits must not immediately repeat the owned sync run")
        #expect(!scheduler.isSyncing, "The runner must release ownership before scheduling debounce")
        await clock.waitForSleeps(1)
        #expect(clock.requestedDelays == [2], "Shipping debounce remains two seconds")
        clock.advance(by: .milliseconds(1_999))
        #expect(passes == 1)
        #expect(!scheduler.isSyncing)
        clock.advance(by: .milliseconds(1))
        await followupEntered.wait()
        let release = Task { followupResume.release() }
        await scheduler.syncNow(modelContext: container.mainContext)
        await release.value
        #expect(passes == 2)
        #expect(!scheduler.isSyncing)
        #expect(clock.requestedDelays == [2], "Multiple in-flight edits queue just one follow-up")
    }

    @Test("A new edit after ownership release resets the pending follow-up debounce")
    func postRunEditCoalescesWithFollowup() async throws {
        let container = try DAVSyncScenario.container()
        let clock = SchedulerDebounceClock()
        let entered = ScriptedDAVProtocol.Gate()
        let resume = ScriptedDAVProtocol.Gate()
        let followupEntered = ScriptedDAVProtocol.Gate()
        let followupResume = ScriptedDAVProtocol.Gate()
        var passes = 0
        let scheduler = SyncScheduler(onWidgetReload: {}, onNotificationFlush: { _ in
            passes += 1
            if passes == 1 { entered.release(); await resume.wait() }
            if passes == 2 { followupEntered.release(); await followupResume.wait() }
        }, changeDebounceSleep: { try await clock.sleep(for: $0) })
        let run = Task { await scheduler.syncNow(modelContext: container.mainContext) }
        defer { run.cancel(); resume.release(); followupResume.release(); scheduler.cancelInflightSync() }
        await entered.wait()
        scheduler.syncAfterChange(modelContext: container.mainContext)
        resume.release()
        await run.value
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(1))
        scheduler.syncAfterChange(modelContext: container.mainContext)
        await clock.waitForSleeps(2)
        await clock.cancelled.wait()
        clock.advance(by: .seconds(1))
        #expect(passes == 1, "The superseded deadline must not start another run")
        #expect(!scheduler.isSyncing)
        clock.advance(by: .seconds(1))
        await followupEntered.wait()
        let release = Task { followupResume.release() }
        await scheduler.syncNow(modelContext: container.mainContext)
        await release.value
        #expect(passes == 2)
        #expect(!scheduler.isSyncing)
        #expect(clock.requestedDelays == [2, 2])
    }

    @Test("Login retains immediate priority while edits wait for a separate debounce")
    func accountAddedWinsOverPendingEdits() async throws {
        let container = try DAVSyncScenario.container()
        let clock = SchedulerDebounceClock()
        let entered = ScriptedDAVProtocol.Gate()
        let resume = ScriptedDAVProtocol.Gate()
        let accountPassEntered = ScriptedDAVProtocol.Gate()
        let accountPassResume = ScriptedDAVProtocol.Gate()
        var passes = 0
        let scheduler = SyncScheduler(onWidgetReload: {}, onNotificationFlush: { _ in
            passes += 1
            if passes == 1 { entered.release(); await resume.wait() }
            if passes == 2 { accountPassEntered.release(); await accountPassResume.wait() }
        }, changeDebounceSleep: { try await clock.sleep(for: $0) })
        let run = Task { await scheduler.syncNow(modelContext: container.mainContext) }
        defer { run.cancel(); resume.release(); accountPassResume.release(); scheduler.cancelInflightSync() }
        await entered.wait()
        scheduler.syncAfterChange(modelContext: container.mainContext)
        scheduler.syncAfterAccountAdded(modelContext: container.mainContext)
        resume.release()
        await accountPassEntered.wait()
        #expect(scheduler.isSyncing)
        #expect(clock.requestedDelays.isEmpty, "Account work starts before any edit delay")
        scheduler.syncAfterChange(modelContext: container.mainContext)
        scheduler.syncAfterChange(modelContext: container.mainContext)
        accountPassResume.release()
        await run.value
        #expect(passes == 2, "Awaited syncNow includes the immediate login pass")
        #expect(!scheduler.isSyncing)
        await clock.waitForSleeps(1)
        #expect(clock.requestedDelays == [2], "The pending edit still gets its debounced pass")
    }

    @Test("Background cancellation drops pending edit debounce but preserves login on return",
          arguments: [false, true])
    func cancelledEditsPreserveLogin(returnsBeforeCleanup: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let clock = SchedulerDebounceClock()
        let entered = ScriptedDAVProtocol.Gate()
        let resume = ScriptedDAVProtocol.Gate()
        let resumed = ScriptedDAVProtocol.Gate()
        let resumeFollowup = ScriptedDAVProtocol.Gate()
        var passes = 0
        let scheduler = SyncScheduler(onWidgetReload: {}, onNotificationFlush: { _ in
            passes += 1
            if passes == 1 { entered.release(); await resume.wait() }
            if passes == 2 { resumed.release(); await resumeFollowup.wait() }
        }, changeDebounceSleep: { try await clock.sleep(for: $0) })
        let run = Task { await scheduler.syncNow(modelContext: container.mainContext) }
        defer { run.cancel(); resume.release(); resumeFollowup.release(); scheduler.cancelInflightSync() }
        await entered.wait()
        scheduler.syncAfterChange(modelContext: container.mainContext)
        scheduler.syncAfterAccountAdded(modelContext: container.mainContext)
        scheduler.cancelInflightSync()
        if returnsBeforeCleanup { scheduler.syncOnForeground(modelContext: container.mainContext) }
        resume.release()
        await run.value
        if !returnsBeforeCleanup { scheduler.syncOnForeground(modelContext: container.mainContext) }
        await resumed.wait()
        #expect(clock.requestedDelays.isEmpty)
        let release = Task { resumeFollowup.release() }
        await scheduler.syncNow(modelContext: container.mainContext)
        await release.value
        #expect(passes == 2)
        #expect(!scheduler.isSyncing)
        #expect(clock.requestedDelays.isEmpty)
    }

    @Test("Backgrounding cancels a scheduled edit follow-up without restarting it")
    func backgroundCancelsScheduledDebounce() async throws {
        let container = try DAVSyncScenario.container()
        let clock = SchedulerDebounceClock()
        var passes = 0
        let scheduler = SyncScheduler(onWidgetReload: {}, onNotificationFlush: { _ in passes += 1 },
            changeDebounceSleep: { try await clock.sleep(for: $0) })
        defer { scheduler.cancelInflightSync() }
        scheduler.syncAfterChange(modelContext: container.mainContext)
        await clock.waitForSleeps(1)
        scheduler.cancelInflightSync()
        await clock.cancelled.wait()
        clock.advance(by: .seconds(2))
        #expect(passes == 0)
        #expect(!scheduler.isSyncing)
        // A later explicit sync can acquire ownership normally.
        await scheduler.syncNow(modelContext: container.mainContext)
        #expect(passes == 1)
        #expect(!scheduler.isSyncing)
    }
}
