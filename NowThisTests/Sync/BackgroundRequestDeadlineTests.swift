import Foundation
import SwiftData
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
        let accountID = try DAVSyncScenario.account(in: container)
        let host = "next-run-" + UUID().uuidString.lowercased() + ".invalid"
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
        let accountID = try DAVSyncScenario.account(in: container)
        let host = "server-delay-" + UUID().uuidString.lowercased() + ".invalid"
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
