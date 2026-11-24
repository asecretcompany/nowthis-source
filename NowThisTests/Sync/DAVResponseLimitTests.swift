import Foundation
import Testing
import Synchronization
@testable import NowThis

@Suite("Bounded DAV response bodies", .serialized)
struct DAVResponseLimitTests {
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DAVResponseLimitURLProtocol.self]
        return configuration
    }

    private func request(_ path: String) -> URLRequest {
        URLRequest(url: URL(string: "https://dav-response-limit.invalid/\(path)")!)
    }

    @Test("DAV redirect hop budget rejects the sixth hop and resets after completion")
    func redirectHopLimit() {
        let budget = DAVRedirectBudget()
        for _ in 0..<5 { #expect(budget.allow(taskID: 1)) }
        #expect(!budget.allow(taskID: 1))
        #expect(budget.allow(taskID: 2))
        budget.complete(taskID: 1)
        #expect(budget.allow(taskID: 1))
    }

    @Test("Rejected streaming redirects drain and respect caller cancellation", arguments: [false, true])
    func redirectPolicyCannotBeBypassed(cancelled: Bool) async throws {
        let host = "redirect-" + UUID().uuidString.lowercased() + ".invalid"
        let gate = ScriptedDAVProtocol.Gate()
        defer { gate.release() }
        let config = ScriptedDAVProtocol.install(host: host, responses: [.init(status: 200, body: "ok", gate: gate), .init(status: 200, body: "next")])
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let original = URLRequest(url: URL(string: "https://" + host + "/tasks/")!)
        let limit = DAVResponseLimit(maxBytes: 8)
        let result = Task { try await limit.data(for: original, configuration: config, session: session) { _ in nil } }
        for _ in 0..<100 where ScriptedDAVProtocol.requests(host: host).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let active = try #require(await session.allTasks.first)
        let response = HTTPURLResponse(url: original.url!, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: [:])!
        let target = URLRequest(url: URL(string: "https://foreign.invalid/private")!)
        limit.urlSession(session, task: active, willPerformHTTPRedirection: response, newRequest: target) { rebuilt in
            #expect(rebuilt == nil)
            // Cancel while the redirect callback is still running, before the
            // delegate cancels/drains the rejected transport task.
            if cancelled { result.cancel() }
        }
        gate.release()
        do {
            _ = try await result.value
            Issue.record("Rejected redirect completed successfully")
        } catch is CancellationError { #expect(cancelled) }
        catch let error as DAVRedirectRejection {
            #expect(!cancelled)
            #expect(error.httpStatus == 307)
        }
        #expect(await session.allTasks.isEmpty)
        let next = try await DAVResponseLimit(maxBytes: 8).data(for: original, configuration: config, session: session) { $0 }
        #expect(next.0 == Data("next".utf8))
    }

    @Test("Caller cancellation drains a redirect whose validation is suspended")
    func cancellationDrainsPendingRedirectValidation() async throws {
        let host = "cancel-redirect-" + UUID().uuidString.lowercased() + ".invalid"
        let responseGate = ScriptedDAVProtocol.Gate()
        let validationEntered = ScriptedDAVProtocol.Gate()
        let validationGate = ScriptedDAVProtocol.Gate()
        let validatorWasCancelled = Mutex(false)
        defer { responseGate.release(); validationGate.release() }
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: 200, body: "ok", gate: responseGate)
        ])
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "https://" + host + "/tasks/original.ics"))
        let target = try #require(URL(string: "https://" + host + "/tasks/redirected.ics"))
        let limit = DAVResponseLimit()
        let result = Task {
            try await limit.data(for: URLRequest(url: url), configuration: config, session: session,
                validateRedirect: {
                    await withTaskCancellationHandler {
                        validationEntered.release()
                        await validationGate.wait()
                    } onCancel: {
                        validatorWasCancelled.withLock { $0 = true }
                        validationGate.release()
                    }
                }) { $0 }
        }
        for _ in 0..<100 where ScriptedDAVProtocol.requests(host: host).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let active = try #require(await session.allTasks.first)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: [:]))
        let decision = Task {
            await withCheckedContinuation { continuation in
                limit.urlSession(session, task: active, willPerformHTTPRedirection: response,
                    newRequest: URLRequest(url: target)) { request in
                    continuation.resume(returning: request)
                }
            }
        }
        await validationEntered.wait()
        result.cancel()
        #expect(await decision.value == nil)
        #expect(validatorWasCancelled.withLock { $0 })
        await #expect(throws: CancellationError.self) { try await result.value }
        #expect(await session.allTasks.isEmpty)
    }

    @Test("Bounded requests reuse the supplied session and leave it available after completion")
    func suppliedSessionRemainsReusable() async throws {
        let host = "pooled-" + UUID().uuidString.lowercased() + ".invalid"
        let gate = ScriptedDAVProtocol.Gate()
        defer { gate.release() }
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(body: "first", gate: gate), .init(body: "second")
        ])
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://" + host + "/tasks/")!)
        let first = Task {
            try await DAVResponseLimit(maxBytes: 8).data(for: request, configuration: config, session: session) { $0 }
        }
        for _ in 0..<100 where ScriptedDAVProtocol.requests(host: host).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
        let active = await session.allTasks
        #expect(active.count == 1, "The request must belong to the reusable client session")
        gate.release()
        #expect(String(decoding: try await first.value.0, as: UTF8.self) == "first")
        let next = try await DAVResponseLimit(maxBytes: 8).data(for: request, configuration: config, session: session) { $0 }
        #expect(String(decoding: next.0, as: UTF8.self) == "second")
        #expect(ScriptedDAVProtocol.requests(host: host).count == 2)
    }

    @Test("Absolute cutoff cancels and drains a pooled bounded response, leaving the session reusable")
    func deadlineDrainsBoundedResponse() async throws {
        let config = configuration()
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let slow = request("cancel")
        await #expect(throws: BackgroundBudgetExhausted.self) {
            try await DeadlineRequestExecutor.perform(deadline: ContinuousClock().now + .milliseconds(100)) {
                try await DAVResponseLimit(maxBytes: 8).data(for: slow, configuration: config, session: session) { $0 }
            }
        }
        #expect(await session.allTasks.isEmpty)
        let next = try await DAVResponseLimit(maxBytes: 8).data(for: request("small"), configuration: config, session: session) { $0 }
        #expect(next.0 == Data("ok".utf8))
    }

    @Test("Declared oversized response fails before its body is accepted")
    func rejectsDeclaredOversize() async throws {
        let limit = DAVResponseLimit(maxBytes: 8)
        do {
            _ = try await limit.data(for: request("known"), configuration: configuration()) { $0 }
            Issue.record("Expected a response limit error")
        } catch let error as DAVResponseLimitError {
            #expect(error.limit == 8)
            #expect(error.responseBytes == 16)
        }
    }

    @Test("Unknown-length response is capped as chunks arrive")
    func rejectsUnknownLengthOversize() async throws {
        let limit = DAVResponseLimit(maxBytes: 8)
        do {
            _ = try await limit.data(for: request("unknown"), configuration: configuration()) { $0 }
            Issue.record("Expected a response limit error")
        } catch let error as DAVResponseLimitError {
            #expect(error.limit == 8)
            #expect((error.responseBytes ?? 0) > 8)
        }
    }

    @Test("CalDAV REPORT surfaces the configured response limit")
    func reportUsesConfiguredLimit() async throws {
        let client = CalDAVClient(
            configuration: configuration(),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0),
            maxResponseBytes: 8
        )

        do {
            _ = try await client.fetchTaskBatch(
                baseURL: "https://dav-response-limit.invalid",
                calendarPath: "/known",
                hrefs: ["/known/item.ics"],
                credentials: .init(username: "user", password: "pass")
            )
            Issue.record("Expected a response limit error")
        } catch let error as DAVResponseLimitError {
            #expect(error.limit == 8)
        }
    }

    @Test("Every mutation rejects oversized success and error replies", arguments: ["PUT", "DELETE", "PROPPATCH", "MKCALENDAR", "PROPFIND"], [false, true])
    func allMethodsUseConfiguredLimit(method: String, declared: Bool) async throws {
        for status in [200, 500] {
            let host = "mutation-\(UUID().uuidString.lowercased()).invalid"
            let config = ScriptedDAVProtocol.install(host: host, responses: [
                .init(status: status, body: String(repeating: "x", count: 65),
                      headers: declared ? ["Content-Length": "65"] : [:])
            ])
            let client = CalDAVClient(configuration: config,
                retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0), maxResponseBytes: 64)
            let credentials = CalDAVClient.Credentials(username: "user", password: "pass")
            do {
                switch method {
                case "PUT":
                    _ = try await client.putTask(baseURL: "https://\(host)", taskPath: "/tasks/item.ics",
                        icsData: "BEGIN:VTODO\nUID:item\nEND:VTODO", etag: "original", credentials: credentials)
                case "DELETE":
                    try await client.deleteTask(baseURL: "https://\(host)", taskPath: "/tasks/item.ics",
                        etag: "original", credentials: credentials)
                case "PROPPATCH":
                    try await client.updateCalendarProperties(baseURL: "https://\(host)", calendarPath: "/tasks/",
                        name: "Tasks", colorHex: "#ffffff", credentials: credentials)
                case "MKCALENDAR":
                    _ = try await client.createCalendar(baseURL: "https://\(host)", calendarHomePath: "/", listID: "fixture",
                        name: "Tasks", color: nil, credentials: credentials)
                default:
                    _ = try await client.discoverPrincipal(baseURL: "https://\(host)", credentials: credentials)
                }
                Issue.record("Accepted oversized \(method) reply")
            } catch let error as DAVResponseLimitError {
                #expect(error.limit == 64)
                #expect(error.responseBytes == 65)
            } catch {
                Issue.record("Expected size rejection before status/parse handling: \(error)")
            }
            let requests = ScriptedDAVProtocol.requests(host: host)
            #expect(requests.count == 1, "Overflow must not replay an indeterminate mutation")
            if method == "PUT" || method == "DELETE" {
                #expect(requests.first?.ifMatch == "\"original\"")
            }
        }
    }

    @Test("Mutation replies reject chunked bodies with no declared length")
    func chunkedMutationCancelsEarly() async throws {
        let host = "chunked-mutation-\(UUID().uuidString.lowercased()).invalid"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkedMutationLimitProtocol.self]
        let client = CalDAVClient(configuration: config,
            retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0), maxResponseBytes: 8)
        do {
            _ = try await client.putTask(baseURL: "https://\(host)", taskPath: "/tasks/item.ics",
                icsData: "BEGIN:VTODO\nUID:item\nEND:VTODO", etag: "original",
                credentials: .init(username: "user", password: "pass"))
            Issue.record("Accepted chunked mutation overflow")
        } catch let error as DAVResponseLimitError {
            // URLProtocol delivery can be coalesced by URLSession; the collector's
            // per-chunk early cancellation is covered by the direct delegate test.
            #expect((error.responseBytes ?? 0) > 8)
        }
        // Cancellation callbacks run on the session delegate queue.
        for _ in 0..<100 where !ChunkedMutationLimitProtocol.metrics(host: host).stopped {
            try await Task.sleep(for: .milliseconds(10))
        }
        let metrics = ChunkedMutationLimitProtocol.metrics(host: host)
        #expect(metrics.stopped)
        #expect(metrics.chunks > 0 && metrics.chunks <= 32)
    }

    @Test("Conflict GET rejects an oversized body", arguments: [false, true])
    func getUsesConfiguredLimit(declaredLength: Bool) async throws {
        let host = "get-limit-\(declaredLength).invalid"
        let configuration = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: 200, body: String(repeating: "x", count: 65),
                  headers: declaredLength ? ["Content-Length": "65"] : [:])
        ])
        let client = CalDAVClient(
            configuration: configuration,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0),
            maxResponseBytes: 64
        )

        do {
            _ = try await client.fetchTask(
                baseURL: "https://\(host)", taskPath: "/tasks/conflict.ics",
                credentials: .init(username: "user", password: "pass")
            )
            Issue.record("Expected GET to reject a body above the response limit")
        } catch let error as DAVResponseLimitError {
            #expect(error.limit == 64)
            #expect(error.responseBytes == 65)
        }
    }

    @Test("Conflict GET applies the default 16 MiB cap")
    func getUsesDefaultLimit() async throws {
        let host = "get-default-limit.invalid"
        let byteCount = 16 * 1024 * 1024 + 1
        let configuration = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: 200, body: String(repeating: "x", count: byteCount))
        ])
        let client = CalDAVClient(
            configuration: configuration,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0)
        )

        do {
            _ = try await client.fetchTask(
                baseURL: "https://\(host)", taskPath: "/tasks/conflict.ics",
                credentials: .init(username: "user", password: "pass")
            )
            Issue.record("Expected GET to reject a body above 16 MiB")
        } catch let error as DAVResponseLimitError {
            #expect(error.limit == 16 * 1024 * 1024)
            #expect(error.responseBytes == byteCount)
        }
    }

    @Test("Conflict GET accepts a body exactly at the limit and preserves its ETag")
    func getAcceptsExactLimit() async throws {
        let host = "get-limit-exact.invalid"
        let body = "BEGIN:VTODO\nUID:task\nEND:VTODO"
        let configuration = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: 200, body: body, headers: ["ETag": "\"revision\""])
        ])
        let client = CalDAVClient(configuration: configuration, maxResponseBytes: body.utf8.count)

        let resource = try await client.fetchTask(
            baseURL: "https://\(host)", taskPath: "/tasks/conflict.ics",
            credentials: .init(username: "user", password: "pass")
        )

        #expect(resource.icsData == body)
        #expect(resource.etag == "revision")
        #expect(resource.href == "/tasks/conflict.ics")
    }

    @Test("A response below the limit succeeds")
    func acceptsSmallResponse() async throws {
        let (data, response) = try await DAVResponseLimit(maxBytes: 8).data(
            for: request("small"), configuration: configuration()
        ) { $0 }

        #expect(data == Data("ok".utf8))
        #expect((response as? HTTPURLResponse)?.statusCode == 207)
    }

    @Test("Cancellation propagates from the streaming response")
    func cancellationPropagates() async throws {
        let limit = DAVResponseLimit(maxBytes: 8)
        let request = request("cancel")
        let configuration = configuration()
        let operation = Task {
            try await limit.data(for: request, configuration: configuration) { $0 }
        }
        try await Task.sleep(for: .milliseconds(50))
        operation.cancel()

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
    }
}

private final class DAVResponseLimitURLProtocol: URLProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private var didStop = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch request.url?.lastPathComponent {
        case "known":
            send(Data(repeating: 0x61, count: 16), headers: ["Content-Length": "16"])
        case "unknown":
            sendInChunks(Data(repeating: 0x62, count: 16), chunkSize: 4, headers: [:])
        case "cancel":
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
                guard let self, !self.isStopped else { return }
                self.send(Data("ok".utf8), headers: ["Content-Length": "2"])
            }
        default:
            send(Data("ok".utf8), headers: ["Content-Length": "2"])
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return didStop
    }

    override func stopLoading() {
        stateLock.lock()
        didStop = true
        stateLock.unlock()
    }

    private func sendInChunks(_ body: Data, chunkSize: Int, headers: [String: String]) {
        guard let response = makeResponse(headers: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: body.count, by: chunkSize) {
            let end = min(offset + chunkSize, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func send(_ body: Data, headers: [String: String]) {
        guard let response = makeResponse(headers: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func makeResponse(headers: [String: String]) -> HTTPURLResponse? {
        guard let url = request.url else { return nil }
        return HTTPURLResponse(url: url, statusCode: 207, httpVersion: "HTTP/1.1", headerFields: headers)
    }
}

private final class ChunkedMutationLimitProtocol: URLProtocol, @unchecked Sendable {
    struct Metrics { var chunks = 0; var stopped = false }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [String: Metrics] = [:]
    private var operation: Task<Void, Never>?

    static func metrics(host: String) -> Metrics {
        lock.withLock { recorded[host] ?? Metrics() }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url!.host!
        Self.lock.withLock { Self.recorded[host] = Metrics() }
        operation = Task { @Sendable [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for _ in 0..<32 {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard !Task.isCancelled else { return }
                Self.lock.withLock { Self.recorded[host, default: Metrics()].chunks += 1 }
                client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: 4))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        Self.lock.withLock { Self.recorded[request.url!.host!, default: Metrics()].stopped = true }
        operation?.cancel()
    }
}
