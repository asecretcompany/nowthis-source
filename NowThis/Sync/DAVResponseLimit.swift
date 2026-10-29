import Foundation

/// Identifies a DAV response that exceeded the configured body limit.
struct DAVResponseLimitError: Error, Equatable, Sendable {
    let limit: Int?
    let responseBytes: Int?

    init(limit: Int? = nil, responseBytes: Int? = nil) {
        self.limit = limit
        self.responseBytes = responseBytes
    }
}

/// Streams one response into bounded memory and follows redirects with the caller's
/// DAV-specific request rebuilding logic.
final class DAVResponseLimit: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let defaultMaxBytes = 16 * 1024 * 1024

    private let maxBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var response: URLResponse?
    private var data = Data()
    private var session: URLSession?
    private var ownsSession = false
    private var task: URLSessionDataTask?
    private var isCancelled = false
    private var redirectRequestBuilder: (@Sendable (URLRequest) -> URLRequest?)?

    init(maxBytes: Int = DAVResponseLimit.defaultMaxBytes) {
        precondition(maxBytes > 0, "DAV response limit must be positive")
        self.maxBytes = maxBytes
    }

    func data(
        for request: URLRequest,
        configuration: URLSessionConfiguration,
        session: URLSession? = nil,
        redirectRequestBuilder: @escaping @Sendable (URLRequest) -> URLRequest?
    ) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(
                    request: request,
                    session: session ?? URLSession(configuration: configuration),
                    ownsSession: session == nil,
                    redirectRequestBuilder: redirectRequestBuilder,
                    continuation: continuation
                )
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func start(
        request: URLRequest,
        session: URLSession,
        ownsSession: Bool,
        redirectRequestBuilder: @escaping @Sendable (URLRequest) -> URLRequest?,
        continuation: CheckedContinuation<(Data, URLResponse), Error>
    ) {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            if ownsSession { session.invalidateAndCancel() }
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        self.redirectRequestBuilder = redirectRequestBuilder
        self.session = session
        self.ownsSession = ownsSession
        let task = session.dataTask(with: request)
        // iOS 15+: task-specific data callbacks keep bounded response ownership,
        // while the client session retains its connection pool across batches.
        task.delegate = self
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        lock.unlock()
        // An installed transport resumes only from didCompleteWithError, so the
        // executor drains the active pooled task before returning its cutoff.
        if let task { task.cancel() }
        else { finish(throwing: CancellationError()) }
    }

    private func finish(throwing error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = ownsSession ? self.session : nil
        self.session = nil
        self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(throwing: error)
    }

    private func finishSuccessfully() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let response = self.response
        let data = self.data
        let session = ownsSession ? self.session : nil
        self.session = nil
        self.task = nil
        lock.unlock()

        guard let continuation else {
            session?.invalidateAndCancel()
            return
        }
        guard let response else {
            session?.invalidateAndCancel()
            continuation.resume(throwing: URLError(.badServerResponse))
            return
        }
        session?.finishTasksAndInvalidate()
        continuation.resume(returning: (data, response))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let expectedLength = response.expectedContentLength
        guard expectedLength < 0 || expectedLength <= Int64(maxBytes) else {
            completionHandler(.cancel)
            finish(throwing: DAVResponseLimitError(
                limit: maxBytes,
                responseBytes: expectedLength > Int64(Int.max) ? Int.max : Int(expectedLength)
            ))
            return
        }

        lock.lock()
        self.response = response
        if expectedLength > 0 {
            data.reserveCapacity(min(maxBytes, Int(expectedLength)))
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        let exceedsLimit = chunk.count > maxBytes - data.count
        if !exceedsLimit {
            data.append(chunk)
        }
        let observedBytes = exceedsLimit ? data.count + chunk.count : 0
        lock.unlock()

        guard exceedsLimit else { return }
        dataTask.cancel()
        finish(throwing: DAVResponseLimitError(limit: maxBytes, responseBytes: observedBytes))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if lock.withLock({ isCancelled }) {
            finish(throwing: CancellationError())
        } else if let error {
            finish(throwing: error)
        } else {
            finishSuccessfully()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let builder = redirectRequestBuilder
        lock.unlock()
        completionHandler(builder?(request) ?? request)
    }
}
