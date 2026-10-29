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
