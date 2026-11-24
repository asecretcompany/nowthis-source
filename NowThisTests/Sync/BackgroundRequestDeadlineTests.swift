import Foundation
import SwiftData
import Synchronization
import Testing
@testable import NowThis

@Suite("Shared background request deadlines", .serialized)
struct BackgroundRequestDeadlineTests {
    private let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")

    @Test("A later account receives the remaining allowance, then admission closes")
    func secondAccountGetsOnlyRemainingBudget() async throws {
        let clock = RequestBudgetClock()
        let budget = BackgroundRunBudget(startedAt: clock.now, now: { clock.now })
        let host = "remaining-" + UUID().uuidString.lowercased() + ".invalid"
        let client = CalDAVClient(configuration: DeadlineDAVProtocol.install(host: host, trickle: false))
        await client.setRunBudget(budget)
        try await client.deleteTask(baseURL: "https://" + host, taskPath: "/account-one.ics", etag: "one", credentials: credentials)
        clock.advance(.seconds(12))
        #expect(budget.remainingRemoteTime == .seconds(3))
        try await client.deleteTask(baseURL: "https://" + host, taskPath: "/account-two.ics", etag: "two", credentials: credentials)
        let requests = DeadlineDAVProtocol.snapshot(host).requests
        #expect(requests.count == 2)
        #expect((requests.last?.timeoutInterval ?? 99) <= 3)
        clock.advance(.seconds(4))
        await #expect(throws: BackgroundBudgetExhausted.self) {
            try await client.deleteTask(baseURL: "https://" + host, taskPath: "/account-three.ics", etag: nil, credentials: credentials)
        }
        #expect(DeadlineDAVProtocol.snapshot(host).requests.count == 2)
    }

    @Test("A trickling response stops at the absolute cutoff")
    func tricklingResponseStopsAtAbsoluteCutoff() async throws {
        let host = "trickle-" + UUID().uuidString.lowercased() + ".invalid"
        let client = CalDAVClient(configuration: DeadlineDAVProtocol.install(host: host))
        await client.setRunBudget(shortBudget())
        await #expect(throws: BackgroundBudgetExhausted.self) {
            _ = try await client.fetchTask(baseURL: "https://" + host, taskPath: "/slow.ics", credentials: credentials)
        }
        #expect(await DeadlineDAVProtocol.waitForCancellationDrain(host, path: "/slow.ics"))
        let observed = DeadlineDAVProtocol.snapshot(host)
        #expect(observed.chunks > 1, "Traffic continued during the request; an idle timeout is insufficient")
        #expect(observed.cancelledPaths == ["/slow.ics"])
        #expect(observed.requests.count == 1)
    }

    @Test("The deadline cancels bounded REPORT and ordinary PUT/DELETE/PROPFIND", arguments: ["REPORT", "PUT", "DELETE", "PROPFIND"])
    func deadlineCancelsBoundedREPORTAndOrdinaryRequest(method: String) async throws {
        let host = "method-" + UUID().uuidString.lowercased() + ".invalid"
        let client = CalDAVClient(configuration: DeadlineDAVProtocol.install(host: host))
        await client.setRunBudget(shortBudget())
        await #expect(throws: BackgroundBudgetExhausted.self) {
            switch method {
            case "REPORT":
                _ = try await client.fetchTaskBatch(baseURL: "https://" + host, calendarPath: "/tasks/", hrefs: ["/tasks/one.ics"], credentials: credentials)
            case "PUT":
                _ = try await client.putTask(baseURL: "https://" + host, taskPath: "/slow.ics", icsData: "BEGIN:VTODO\nUID:one\nEND:VTODO", etag: "one", credentials: credentials)
            case "DELETE":
                try await client.deleteTask(baseURL: "https://" + host, taskPath: "/slow.ics", etag: "one", credentials: credentials)
            default:
                _ = try await client.discoverPrincipal(baseURL: "https://" + host, credentials: credentials)
            }
        }
        let path = DeadlineDAVProtocol.snapshot(host).requests.last?.url?.path ?? "/missing"
        #expect(await DeadlineDAVProtocol.waitForCancellationDrain(host, path: path))
        let observed = DeadlineDAVProtocol.snapshot(host)
        #expect(observed.requests.map(\.httpMethod) == [method])
        #expect(observed.cancelledPaths.count == 1)
        #expect((observed.requests.first?.timeoutInterval ?? 99) <= 0.35)
        if method == "PUT" || method == "DELETE" {
            #expect(observed.requests.first?.value(forHTTPHeaderField: "If-Match") == "\"one\"")
        }
    }

    @Test("Redirected PROPFIND keeps its allowance and is cancelled while active")
    func redirectedPROPFINDKeepsAbsoluteCutoff() async throws {
        let host = "redirect-" + UUID().uuidString.lowercased() + ".invalid"
        let client = CalDAVClient(configuration: DeadlineDAVProtocol.install(host: host, redirect: true))
        await client.setRunBudget(shortBudget())
        await #expect(throws: BackgroundBudgetExhausted.self) {
            _ = try await client.discoverPrincipal(baseURL: "https://" + host, credentials: credentials)
        }
        #expect(await DeadlineDAVProtocol.waitForCancellationDrain(host, path: "/redirected"))
        let observed = DeadlineDAVProtocol.snapshot(host)
        #expect(observed.requests.count == 2)
        #expect(observed.requests.last?.url?.path == "/redirected")
        #expect(observed.requests.last?.httpMethod == "PROPFIND")
        #expect((observed.requests.last?.timeoutInterval ?? 99) <= 0.35)
        #expect(observed.requests.last?.value(forHTTPHeaderField: "Authorization") == credentials.basicAuthHeader)
        #expect(observed.cancelledPaths.contains("/redirected"))
    }

    @Test("Late cleanup cannot clear a newer run's exhausted budget")
    func lateCleanupCannotClearNewRunBudget() async throws {
        let host = "owner-" + UUID().uuidString.lowercased() + ".invalid"
        let client = CalDAVClient(configuration: DeadlineDAVProtocol.install(host: host, trickle: false))
        let old = BackgroundRunBudget()
        let newer = BackgroundRunBudget(startedAt: ContinuousClock().now - .seconds(16))
        await client.setRunBudget(old)
        await client.setRunBudget(newer)
        await client.clearRunBudget(runID: old.runID)
        await #expect(throws: BackgroundBudgetExhausted.self) {
            try await client.deleteTask(baseURL: "https://" + host, taskPath: "/must-not-start.ics", etag: nil, credentials: credentials)
        }
        #expect(DeadlineDAVProtocol.snapshot(host).requests.isEmpty)
        await client.clearRunBudget(runID: newer.runID)
        try await client.deleteTask(baseURL: "https://" + host, taskPath: "/foreground.ics", etag: nil, credentials: credentials)
        #expect(DeadlineDAVProtocol.snapshot(host).requests.count == 1)
    }

    @Test("An active request retains its captured deadline when a newer run is installed")
    func activeRequestRetainsCapturedBudget() async throws {
        let host = "capture-" + UUID().uuidString.lowercased() + ".invalid"
        let client = CalDAVClient(configuration: DeadlineDAVProtocol.install(host: host))
        let old = shortBudget()
        await client.setRunBudget(old)
        let operation = Task {
            try await client.deleteTask(baseURL: "https://" + host, taskPath: "/slow.ics", etag: nil, credentials: credentials)
        }
        for _ in 0..<100 where DeadlineDAVProtocol.snapshot(host).requests.isEmpty {
            try await Task.sleep(for: .milliseconds(2))
        }
        await client.setRunBudget(BackgroundRunBudget())
        await client.clearRunBudget(runID: old.runID)
        await #expect(throws: BackgroundBudgetExhausted.self) { try await operation.value }
        #expect(await DeadlineDAVProtocol.waitForCancellationDrain(host, path: "/slow.ics"))
        #expect(DeadlineDAVProtocol.snapshot(host).cancelledPaths == ["/slow.ics"])
    }

    @Test("A removed account stops without transport or an authentication failure")
    @MainActor
    func removedAccountStopsSafely() async throws {
        let container = try DAVSyncScenario.container()
        let host = "removed-" + UUID().uuidString.lowercased() + ".invalid"
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: DeadlineDAVProtocol.install(host: host)))
        let outcome = await engine.performBackgroundSyncOutcome(accountID: "removed-account", serverBaseURL: "https://" + host,
            credentials: credentials, modelContainer: container, reconcileNotifications: false, runBudget: BackgroundRunBudget())
        #expect(outcome.status == .cancelled)
        #expect(outcome.failures.isEmpty)
        #expect(DeadlineDAVProtocol.snapshot(host).requests.isEmpty)
    }

    @Test("Budget exhaustion leaves no credential or backoff pollution in the next run")
    @MainActor
    func budgetExhaustionDoesNotPolluteNextRun() async throws {
        let container = try DAVSyncScenario.container()
        let host = "next-run-" + UUID().uuidString.lowercased() + ".invalid"
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let config = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: []))
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config))
        let expired = BackgroundRunBudget(startedAt: ContinuousClock().now - .seconds(16))
        let first = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: credentials, modelContainer: container, reconcileNotifications: false, runBudget: expired)
        #expect(first.status != .completed)
        #expect(first.failures.isEmpty)
        #expect(ScriptedDAVProtocol.requests(host: host).isEmpty)
        let second = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: credentials, modelContainer: container, reconcileNotifications: false, runBudget: BackgroundRunBudget())
        #expect(second.status == .completed)
        #expect(second.failures.isEmpty)
        #expect(ScriptedDAVProtocol.requests(host: host).count == 3)
    }

    @Test("The next delivery respects a real server delay that exceeded the app allowance", arguments: [429, 503])
    @MainActor
    func nextDeliveryRespectsServerDeferral(status: Int) async throws {
        let container = try DAVSyncScenario.container()
        let host = "server-delay-" + UUID().uuidString.lowercased() + ".invalid"
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: status, body: "", headers: ["Retry-After": "60"])
        ] + DAVSyncScenario.discovery(paths: []))
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: config))
        let short = BackgroundRunBudget(startedAt: ContinuousClock().now - .seconds(14))
        let first = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: credentials, modelContainer: container, reconcileNotifications: false, runBudget: short)
        #expect(first.status == .partial)
        #expect(first.failures.map(\.category) == [.busy])
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
        let second = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: credentials, modelContainer: container, reconcileNotifications: false, runBudget: BackgroundRunBudget())
        #expect(second.status == .partial)
        #expect(second.failures.map(\.category) == [.busy])
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1, "The next delivery must not bypass the server's requested wait")
    }

    @Test("Deferred PUT stops later requests and the next run for that account")
    @MainActor
    func deferredPutStopsLaterAccountRequests() async throws {
        let host = "deferred-put-" + UUID().uuidString.lowercased() + ".invalid"
        let baseURL = "https://" + host
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let context = container.mainContext
        let account = try #require(try context.fetch(FetchDescriptor<ServerAccount>()).first)
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        list.account = account
        context.insert(list)
        for index in 0..<2 {
            let task = TaskItem(uid: "pending-\(index)", title: "Pending \(index)")
            task.taskList = list
            task.isDirty = true
            context.insert(task)
        }
        try context.save()

        let clock = RequestWallClock()
        let wall = clock.now
        let responses = DAVSyncScenario.discovery(paths: ["/one/"])
            + [.init(body: DAVSyncScenario.manifest(count: 0)),
               .init(status: 429, body: "", headers: ["Retry-After": "1800"]),
               .init(status: 201, body: "", headers: ["ETag": "after"])]
        let client = CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host, responses: responses),
            now: { clock.now }, sleep: { _ in Issue.record("A 30-minute wait must be deferred beyond the 15-minute run") })
        let engine = SyncEngine(calDAVClient: client, now: { clock.now })

        let first = await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
        let methods = ["PROPFIND", "PROPFIND", "PROPFIND", "REPORT", "PUT"]
        #expect(first.status == .partial)
        #expect(first.pendingOutboundCount == 2)
        #expect(first.failures.map(\.category) == [.busy])
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.method) == methods)

        clock.advance(1799)
        do {
            _ = try await engine.performFullSync(accountID: accountID, serverBaseURL: baseURL,
                credentials: .init(username: "fixture", password: "updated"),
                modelContainer: container, reconcileNotifications: false)
            Issue.record("Expected the retained server deadline on a new run")
        } catch let error as RetryDeferredError {
            #expect(error.deadline == wall.addingTimeInterval(1800))
        } catch {
            Issue.record("Expected the retained server deadline, received \(type(of: error))")
        }
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.method) == methods)

        clock.advance(1)
        _ = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: []))
        let resumed = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
        #expect(resumed.status == .completed)
        #expect(ScriptedDAVProtocol.requests(host: host).map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND"])
    }

    @Test("Cancelling a retry sleep preserves the received server deadline")
    @MainActor
    func cancellationDuringServerWaitDoesNotClearDeadline() async throws {
        let host = "cancelled-wait-" + UUID().uuidString.lowercased() + ".invalid"
        let baseURL = "https://" + host
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let wall = Date()
        let waiting = ScriptedDAVProtocol.Gate()
        let client = CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host, responses:
            [.init(status: 429, body: "", headers: ["Retry-After": "30"])] + DAVSyncScenario.discovery(paths: [])),
            now: { wall }, sleep: { _ in
                waiting.release()
                try await Task.sleep(for: .seconds(10))
            })
        let engine = SyncEngine(calDAVClient: client)
        let run = Task {
            await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
                credentials: credentials, modelContainer: container, reconcileNotifications: false)
        }
        await waiting.wait()
        run.cancel()
        let cancelled = await run.value
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.failures.isEmpty)

        do {
            try await engine.performBackgroundSync(accountID: accountID, serverBaseURL: baseURL,
                credentials: credentials, modelContainer: container, reconcileNotifications: false)
            Issue.record("Expected the received server deadline after cancellation")
        } catch let error as RetryDeferredError {
            #expect(error.deadline == wall.addingTimeInterval(30))
        } catch {
            Issue.record("Expected the received server deadline, received \(type(of: error))")
        }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
    }

    @Test("Retry-After survives a response body rejected by the size limit", arguments: [429, 503], [false, true])
    @MainActor
    func serverHeadersSurviveBodySizeRejection(status: Int, declaredLength: Bool) async throws {
        let host = "oversized-wait-" + UUID().uuidString.lowercased() + ".invalid"
        let baseURL = "https://" + host
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let clock = RequestWallClock()
        let wall = clock.now
        var headers = ["Retry-After": "1800"]
        if declaredLength { headers["Content-Length"] = "2048" }
        let responses = [.init(status: status, body: String(repeating: "x", count: 2048), headers: headers)]
            + DAVSyncScenario.discovery(paths: [])
        let client = CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host, responses: responses),
            maxResponseBytes: 1024, now: { clock.now })
        let engine = SyncEngine(calDAVClient: client, now: { clock.now })

        do {
            try await engine.performBackgroundSync(accountID: accountID, serverBaseURL: baseURL,
                credentials: credentials, modelContainer: container, reconcileNotifications: false)
            Issue.record("Expected the oversized body to be rejected")
        } catch let error as DAVResponseLimitError {
            #expect(error.limit == 1024)
            #expect(error.responseBytes == 2048)
        } catch {
            Issue.record("Expected response size rejection, received \(type(of: error))")
        }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)

        clock.advance(1799)
        do {
            _ = try await engine.performFullSync(accountID: accountID, serverBaseURL: baseURL,
                credentials: credentials, modelContainer: container, reconcileNotifications: false)
            Issue.record("Expected the server deadline retained from the rejected body's headers")
        } catch let error as RetryDeferredError {
            #expect(error.deadline == wall.addingTimeInterval(1800))
            #expect(error.httpStatusCode == status)
        } catch {
            Issue.record("Expected the retained server deadline, received \(type(of: error))")
        }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)

        clock.advance(1)
        let resumed = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
        #expect(resumed.status == .completed)
        #expect(ScriptedDAVProtocol.requests(host: host).count == 4)
    }

    @Test("Retry-After survives a stalled body interrupted by cutoff or cancellation", arguments: [false, true])
    @MainActor
    func serverHeadersSurviveInterruptedBody(cancelled: Bool) async throws {
        let host = "stalled-wait-" + UUID().uuidString.lowercased() + ".invalid"
        let baseURL = "https://" + host
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let body = ScriptedDAVProtocol.Gate()
        defer { body.release() }
        let wall = Date()
        let receivedHeaders = ScriptedDAVProtocol.Gate()
        let observedHeaders = Mutex(false)
        let responses = [.init(status: 503, body: String(repeating: "x", count: 2048),
                               headers: ["Retry-After": "120", "Content-Length": "2048", "Content-Type": "text/plain"], bodyGate: body)]
            + DAVSyncScenario.discovery(paths: [])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses), now: {
                // Clock reads before transport admission see no request. The
                // body stays gated, so a read during transport is header handling.
                if !ScriptedDAVProtocol.requests(host: host).isEmpty {
                    observedHeaders.withLock { $0 = true }
                    receivedHeaders.release()
                }
                return wall
            }), now: { wall })

        let budget = cancelled ? BackgroundRunBudget() :
            BackgroundRunBudget(startedAt: ContinuousClock.now - .seconds(14))
        let run = Task {
            await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
                credentials: credentials, modelContainer: container, reconcileNotifications: false,
                runBudget: budget)
        }
        if cancelled {
            let watchdog = Task {
                try await Task.sleep(for: .seconds(2))
                receivedHeaders.release()
            }
            await receivedHeaders.wait()
            watchdog.cancel()
            #expect(observedHeaders.withLock { $0 }, "Cancel after the response headers have reached CalDAV")
            run.cancel()
        }
        let first = await run.value
        #expect(observedHeaders.withLock { $0 })
        body.release()
        #expect(first.status == (cancelled ? .cancelled : .partial))
        #expect(first.failures.isEmpty)
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)

        do {
            try await engine.performBackgroundSync(accountID: accountID, serverBaseURL: baseURL,
                credentials: credentials, modelContainer: container, reconcileNotifications: false)
            Issue.record("Expected the deadline received before the body stalled")
        } catch let error as RetryDeferredError {
            #expect(error.deadline == wall.addingTimeInterval(120))
        } catch {
            Issue.record("Expected the retained server deadline, received \(type(of: error))")
        }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
    }

    @Test("Retry-After from an untrusted response cannot defer an account")
    @MainActor
    func untrustedResponseCannotSetServerWait() async throws {
        let host = "foreign-wait-" + UUID().uuidString.lowercased() + ".invalid"
        let baseURL = "https://" + host
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let foreignURL = try #require(URL(string: "https://foreign.invalid/remote.php/dav/"))
        let responses = [.init(status: 503, body: "", headers: ["Retry-After": "1800"], responseURL: foreignURL)]
            + DAVSyncScenario.discovery(paths: [])
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses)))

        let first = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
        #expect(first.status == .partial)
        #expect(first.failures.first?.discoveryStage == .principal)
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)

        let next = await engine.performBackgroundSyncOutcome(accountID: accountID, serverBaseURL: baseURL,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
        #expect(next.status == .completed)
        #expect(ScriptedDAVProtocol.requests(host: host).count == 4)
    }

    @Test("A slow body does not restart the server wait after its headers")
    func retryAfterStartsAtResponseHeaders() async throws {
        let host = "timed-wait-" + UUID().uuidString.lowercased() + ".invalid"
        let body = ScriptedDAVProtocol.Gate()
        let readingClock = ScriptedDAVProtocol.Gate()
        let clock = RequestWallClock()
        let receiptTime = clock.now
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: 503, body: String(repeating: "x", count: 2048),
                  headers: ["Retry-After": "120", "Content-Length": "2048", "Content-Type": "text/plain"], bodyGate: body)
        ])
        let client = CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0),
            now: {
                let value = clock.now
                readingClock.release()
                return value
            })
        let watchdog = Task {
            try await Task.sleep(for: .seconds(2))
            readingClock.release()
        }
        let operation = Task {
            try await client.putTask(baseURL: "https://" + host, taskPath: "/task.ics",
                icsData: "BEGIN:VCALENDAR", etag: nil, credentials: credentials)
        }
        await readingClock.wait()
        clock.advance(15)
        body.release()
        watchdog.cancel()

        do {
            _ = try await operation.value
            Issue.record("Expected the final response's server deadline")
        } catch let error as RetryDeferredError {
            #expect(error.deadline == receiptTime.addingTimeInterval(120))
        } catch {
            Issue.record("Expected the server deadline, received \(type(of: error))")
        }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
    }

    @Test("Legacy source deferral holds source requests and permits unrelated destination work")
    @MainActor
    func legacySourceDeferralBelongsToSourceAccount() async throws {
        let host = "source-deferral-" + UUID().uuidString.lowercased() + ".invalid"
        let baseURL = "https://" + host
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let source = ServerAccount(displayName: "Source", serverBaseURL: baseURL, username: "fixture")
        let destination = ServerAccount(displayName: "Destination", serverBaseURL: baseURL, username: "fixture")
        context.insert(source)
        context.insert(destination)
        let sourceList = TaskList(serverURL: "/source/", name: "Source", colorHex: "#007AFF")
        sourceList.account = source
        context.insert(sourceList)
        for index in 1...2 {
            let list = TaskList(serverURL: "/destination-\(index)/", name: "Destination \(index)", colorHex: "#007AFF")
            list.account = destination
            context.insert(list)
            let moved = TaskItem(uid: "legacy-\(index)", title: "Legacy move \(index)")
            moved.taskList = list
            moved.pendingMoveFromHref = "/source/legacy-\(index).ics"
            moved.pendingMoveFromListID = sourceList.id
            moved.attachmentStateKnown = nil
            moved.isDirty = true
            context.insert(moved)
            if index == 2 {
                let ordinary = TaskItem(uid: "ordinary", title: "Unrelated local task")
                ordinary.taskList = list
                ordinary.isDirty = true
                context.insert(ordinary)
            }
        }
        try context.save()

        let wall = Date()
        let responses = DAVSyncScenario.discovery(paths: ["/destination-1/", "/destination-2/"])
            + [.init(body: DAVSyncScenario.manifest(count: 0)),
               .init(status: 429, body: "", headers: ["Retry-After": "1800"]),
               .init(body: DAVSyncScenario.manifest(count: 0, path: "/destination-2/")),
               .init(status: 201, body: "", headers: ["ETag": "after"])]
        let sourceKeychain = DAVSyncScenario.keychain(accountID: source.id, password: credentials.password)
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration:
            ScriptedDAVProtocol.install(host: host, responses: responses), now: { wall }),
            taskPhotoSync: TaskPhotoSync(keychainManager: sourceKeychain))

        let first = await engine.performFullSyncOutcome(accountID: destination.id, serverBaseURL: baseURL,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
        #expect(first.status == .partial)
        #expect(first.failures.first?.category == .busy)
        #expect(first.pendingOutboundCount == 2)
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.filter { $0.method == "GET" }.map(\.path) == ["/source/legacy-1.ics"])
        #expect(requests.filter { $0.method == "PUT" }.map(\.path) == ["/destination-2/ordinary.ics"])
        #expect(!requests.contains { $0.method == "DELETE" })

        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        let held = saved.filter { $0.uid.hasPrefix("legacy-") }
        #expect(held.count == 2)
        #expect(held.allSatisfy { $0.isDirty && $0.pendingMoveFromHref != nil && $0.attachmentStateKnown != true })
        #expect(saved.first { $0.uid == "ordinary" }?.etag == "after")

        do {
            try await engine.performBackgroundSync(accountID: source.id, serverBaseURL: baseURL,
                credentials: credentials, modelContainer: container, reconcileNotifications: false)
            Issue.record("Expected the source's retained deadline")
        } catch let error as RetryDeferredError {
            #expect(error.deadline == wall.addingTimeInterval(1800))
        } catch {
            Issue.record("Expected the source's retained deadline, received \(type(of: error))")
        }
        #expect(ScriptedDAVProtocol.requests(host: host).count == requests.count)
    }

    @Test("Discovery preserves server delay beyond its own allowance", arguments: [429, 503], [false, true])
    func discoveryDefersBeyondItsOwnAllowance(status: Int, background: Bool) async throws {
        let host = "discovery-delay-" + UUID().uuidString.lowercased() + ".invalid"
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: status, body: "", headers: ["Retry-After": "120"])
        ])
        let wall = Date()
        let client = CalDAVClient(configuration: config, now: { wall })
        let url = URL(string: "https://" + host + "/remote.php/dav/")!
        do {
            _ = try await BackgroundRunBudget.$current.withValue(background ? BackgroundRunBudget() : nil) {
                try await DAVDiscoveryContext.$deadline.withValue(ContinuousClock.now + .milliseconds(100)) {
                    try await client.discoveryProperties(at: url, properties: ["<d:current-user-principal/>"],
                        depth: "0", allowedOrigin: url, credentials: credentials)
                }
            }
            Issue.record("Expected durable server deferral")
        } catch let error as RetryDeferredError {
            #expect(error.deadline == wall.addingTimeInterval(120))
        } catch {
            Issue.record("Server deferral lost: \(type(of: error))")
        }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
    }

    private func shortBudget() -> BackgroundRunBudget {
        BackgroundRunBudget(startedAt: ContinuousClock().now - .seconds(14) - .milliseconds(700))
    }
}

private final class RequestBudgetClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ContinuousClock().now
    var now: ContinuousClock.Instant { lock.withLock { value } }
    func advance(_ duration: Duration) { lock.withLock { value += duration } }
}

private final class RequestWallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

/// Finite trickling HTTP fixture: missing deadline code fails quickly instead of hanging.
private final class DeadlineDAVProtocol: URLProtocol, @unchecked Sendable {
    struct Snapshot {
        var requests: [URLRequest] = []
        var cancelledPaths: [String] = []
        var chunks = 0
        var trickle = true
        var redirect = false
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: Snapshot] = [:]
    nonisolated(unsafe) private static var drains: [String: [String: DrainSignal]] = [:]
    private let operationLock = NSLock()
    private var operation: Task<Void, Never>?
    private var didStop = false
    static func install(host: String, trickle: Bool = true, redirect: Bool = false) -> URLSessionConfiguration {
        lock.withLock {
            states[host] = Snapshot(trickle: trickle, redirect: redirect)
            drains[host] = [:]
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Self.self]
        return config
    }
    static func snapshot(_ host: String) -> Snapshot { lock.withLock { states[host] ?? Snapshot() } }
    private static func drainSignal(_ host: String, path: String) -> DrainSignal {
        lock.withLock {
            if let signal = drains[host]?[path] { return signal }
            let signal = DrainSignal()
            drains[host, default: [:]][path] = signal
            return signal
        }
    }
    /// URLSession's task callback and URLProtocol.stopLoading can be delivered on
    /// separate queues. Observe the stop callback AND fixture worker drain explicitly.
    static func waitForCancellationDrain(_ host: String, path: String) async -> Bool {
        let signal = drainSignal(host, path: path)
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            signal.resolve(false)
        }
        let drained = await signal.value()
        watchdog.cancel()
        return drained
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url!.host!
        let state = Self.lock.withLock {
            Self.states[host, default: Snapshot()].requests.append(request)
            return Self.states[host]!
        }
        if state.redirect && request.url?.path != "/redirected" {
            let destination = URL(string: "https://" + host + "/redirected/")!
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
            var proposed = URLRequest(url: destination)
            proposed.httpMethod = "GET"
            proposed.timeoutInterval = 60
            client?.urlProtocol(self, wasRedirectedTo: proposed, redirectResponse: response)
            return
        }
        let status = request.httpMethod == "DELETE" ? 204 : request.httpMethod == "PUT" ? 201 : 207
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["ETag": "\"one\""])!
        operationLock.withLock {
            guard !didStop else { return }
            operation = Task { @Sendable [self, host, response, trickle = state.trickle] in
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if trickle {
                    // Plenty of finite response margin keeps a delayed timer from
                    // racing fixture completion during a busy simulator test run.
                    for _ in 0..<80 {
                        do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
                        guard !Task.isCancelled else { return }
                        Self.lock.withLock { Self.states[host]?.chunks += 1 }
                        client?.urlProtocol(self, didLoad: Data("x".utf8))
                    }
                }
                guard !Task.isCancelled else { return }
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() {
        let task = operationLock.withLock {
            didStop = true
            return operation
        }
        let host = request.url!.host!
        let path = request.url!.path
        Self.lock.withLock { Self.states[host]?.cancelledPaths.append(path) }
        task?.cancel()
        let signal = Self.drainSignal(host, path: path)
        Task {
            if let task { await task.value }
            signal.resolve(true)
        }
    }

    private final class DrainSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Bool?
        private var waiters: [CheckedContinuation<Bool, Never>] = []
        func value() async -> Bool {
            await withCheckedContinuation { continuation in
                let ready: Bool? = lock.withLock {
                    if let result { return result }
                    waiters.append(continuation)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
        func resolve(_ value: Bool) {
            let pending: [CheckedContinuation<Bool, Never>] = lock.withLock {
                guard result == nil else { return [] }
                result = value
                let pending = waiters
                waiters.removeAll()
                return pending
            }
            pending.forEach { $0.resume(returning: value) }
        }
    }
}
