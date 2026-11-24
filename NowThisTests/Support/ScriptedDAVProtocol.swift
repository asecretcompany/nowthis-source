import Foundation

/// HTTP boundary double: all matching requests stay inside the test process.
final class ScriptedDAVProtocol: URLProtocol, @unchecked Sendable {
    struct RecordedRequest: Sendable {
        let method: String
        let url: URL
        let path: String
        let body: Data
        let ifMatch: String?
        let ifNoneMatch: String?
        let depth: String?
        let basicAuthUsername: String?
        let authorizationLabel: String?
        var bodyBytes: Int { body.count }
    }
    struct Response: Sendable {
        var status = 207
        var body: String
        var headers: [String: String] = [:]
        var gate: Gate? = nil
        var responseURL: URL? = nil
        var errorCode: URLError.Code? = nil
        var redirectURL: URL? = nil
        var bodyGate: Gate? = nil
        var bodyForRequest: (@Sendable (RecordedRequest) -> String)? = nil
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
        var authorizationLabels: [String: [String: String]] = [:]
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()
    private var operation: Task<Void, Never>?

    static func install(
        host: String, responses: [Response], authorizationLabels: [String: String] = [:]
    ) -> URLSessionConfiguration {
        lock.lock()
        state.responses[host] = responses
        state.requests[host] = []
        state.authorizationLabels[host] = authorizationLabels
        lock.unlock()
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
        let authorizationLabel = request.value(forHTTPHeaderField: "Authorization").flatMap {
            Self.state.authorizationLabels[host]?[$0]
        }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "", url: request.url!, path: request.url!.path,
            body: body, ifMatch: request.value(forHTTPHeaderField: "If-Match"),
            ifNoneMatch: request.value(forHTTPHeaderField: "If-None-Match"),
            depth: request.value(forHTTPHeaderField: "Depth"),
            basicAuthUsername: Self.basicAuthUsername(request), authorizationLabel: authorizationLabel)
        Self.state.requests[host, default: []].append(recorded)
        let response = Self.state.responses[host]?.isEmpty == false
            ? Self.state.responses[host]!.removeFirst() : nil
        Self.lock.unlock()
        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        operation = Task { @Sendable [self] in
            if let gate = response.gate { await gate.wait() }
            guard !Task.isCancelled else { return }
            if let code = response.errorCode {
                client?.urlProtocol(self, didFailWithError: URLError(code)); return
            }
            let http = HTTPURLResponse(url: response.responseURL ?? request.url!, statusCode: response.status,
                                       httpVersion: "HTTP/1.1", headerFields: response.headers)!
            if let destination = response.redirectURL {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: http)
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            let body = Data((response.bodyForRequest?(recorded) ?? response.body).utf8)
            if let bodyGate = response.bodyGate {
                let split = body.count / 2
                client?.urlProtocol(self, didLoad: Data(body.prefix(split)))
                await bodyGate.wait()
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didLoad: Data(body.dropFirst(split)))
            } else {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private static func basicAuthUsername(_ request: URLRequest) -> String? {
        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Basic "),
              let encoded = Data(base64Encoded: String(header.dropFirst(6))),
              let credentials = String(data: encoded, encoding: .utf8),
              let separator = credentials.firstIndex(of: ":") else { return nil }
        return String(credentials[..<separator])
    }

    override func stopLoading() { operation?.cancel() }
}
