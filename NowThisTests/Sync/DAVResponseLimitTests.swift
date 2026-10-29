import Foundation
import Testing
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
