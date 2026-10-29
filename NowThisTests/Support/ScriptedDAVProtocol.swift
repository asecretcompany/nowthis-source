import Foundation

/// HTTP boundary double: all matching requests stay inside the test process.
final class ScriptedDAVProtocol: URLProtocol, @unchecked Sendable {
    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let body: Data
        let ifMatch: String?
        var bodyBytes: Int { body.count }
    }
    struct Response: Sendable {
        var status = 207
        var body: String
        var headers: [String: String] = [:]
        var gate: Gate? = nil
    }
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released { lock.unlock(); continuation.resume() }
                else { waiters.append(continuation); lock.unlock() }
            }
        }
        func release() {
            lock.lock(); released = true
            let pending = waiters; waiters.removeAll(); lock.unlock()
            for continuation in pending { continuation.resume() }
        }
    }
    private struct State {
        var responses: [String: [Response]] = [:]
        var requests: [String: [RecordedRequest]] = [:]
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()
    private var operation: Task<Void, Never>?

    static func install(host: String, responses: [Response]) -> URLSessionConfiguration {
        lock.lock(); state.responses[host] = responses; state.requests[host] = []; lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        configuration.httpAdditionalHeaders = ["X-Fixture-Host": host]
        return configuration
    }
    static func requests(host: String) -> [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return state.requests[host] ?? []
    }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url!.host!
        let body: Data
        if let bytes = request.httpBody { body = bytes }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var bytes = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(read))
            }
            body = bytes
        } else { body = Data() }
        Self.lock.lock()
        Self.state.requests[host, default: []].append(.init(
            method: request.httpMethod ?? "", path: request.url!.path,
            body: body, ifMatch: request.value(forHTTPHeaderField: "If-Match")))
        let response = Self.state.responses[host]?.isEmpty == false
            ? Self.state.responses[host]!.removeFirst() : nil
        Self.lock.unlock()
        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        operation = Task {
            if let gate = response.gate { await gate.wait() }
            guard !Task.isCancelled else { return }
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status,
                                       httpVersion: "HTTP/1.1", headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { operation?.cancel() }
}
