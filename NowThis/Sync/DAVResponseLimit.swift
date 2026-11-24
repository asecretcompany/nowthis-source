import Foundation

/// Identifies a DAV response that exceeded the configured body limit.
struct DAVResponseLimitError: LocalizedError, Equatable, Sendable {
    var errorDescription: String? {
        String(localized: "The server response is too large to process safely. Please try again or contact your server administrator.",
               comment: "A server reply exceeded the safe processing limit; a write may already have committed remotely.")
    }

    let limit: Int?
    let responseBytes: Int?

    init(limit: Int? = nil, responseBytes: Int? = nil) {
        self.limit = limit
        self.responseBytes = responseBytes
    }
}

/// A rejected redirect retains no destination URL or credential-bearing data.
struct DAVRedirectRejection: LocalizedError, Sendable {
    let httpStatus: Int
    var errorDescription: String? { SyncFailure.discoveryMessage(.untrustedAddress) }
}

/// Streams one response into bounded memory and follows redirects with the caller's
/// DAV-specific request rebuilding logic.
final class DAVResponseLimit: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let defaultMaxBytes = 16 * 1024 * 1024

    private let redirectBudget = DAVRedirectBudget()
    private let maxBytes: Int
    private let didReceiveHeaders: (@Sendable (URLResponse) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var response: URLResponse?
    private var data = Data()
    private var session: URLSession?
    private var ownsSession = false
    private var task: URLSessionDataTask?
    private var isCancelled = false
    private var redirectError: Error?
    private var redirectRequestBuilder: (@Sendable (URLRequest) -> URLRequest?)?
    private var redirectValidator: (@Sendable () async throws -> Void)?
    private var pendingRedirect: (complete: @Sendable (URLRequest?) -> Void, validation: Task<Void, Never>)?

    init(maxBytes: Int = DAVResponseLimit.defaultMaxBytes,
         didReceiveHeaders: (@Sendable (URLResponse) -> Void)? = nil) {
        precondition(maxBytes > 0, "DAV response limit must be positive")
        self.maxBytes = maxBytes
        self.didReceiveHeaders = didReceiveHeaders
    }

    func data(
        for request: URLRequest,
        configuration: URLSessionConfiguration,
        session: URLSession? = nil,
        validateRedirect: (@Sendable () async throws -> Void)? = nil,
        redirectRequestBuilder: @escaping @Sendable (URLRequest) -> URLRequest?
    ) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(
                    request: request,
                    session: session ?? URLSession(configuration: configuration),
                    ownsSession: session == nil,
                    validateRedirect: validateRedirect,
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
        validateRedirect: (@Sendable () async throws -> Void)?,
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
        redirectValidator = validateRedirect
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
        let redirect = pendingRedirect
        pendingRedirect = nil
        lock.unlock()
        redirect?.validation.cancel()
        redirect?.complete(nil)
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
        let redirect = pendingRedirect
        pendingRedirect = nil
        lock.unlock()
        redirect?.validation.cancel()
        redirect?.complete(nil)
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
        let redirect = pendingRedirect
        pendingRedirect = nil
        lock.unlock()
        redirect?.validation.cancel()
        redirect?.complete(nil)

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
        guard lock.withLock({ redirectError == nil }) else {
            completionHandler(.cancel)
            return
        }
        // A received header can outlive cancellation or rejection of its body.
        didReceiveHeaders?(response)
        guard !lock.withLock({ isCancelled }) else {
            completionHandler(.cancel)
            return
        }
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
        let failure: Error? = lock.withLock {
            if isCancelled { return CancellationError() }
            return redirectError ?? error
        }
        if let failure {
            finish(throwing: failure)
        } else {
            finishSuccessfully()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let (builder, validator) = lock.withLock { (redirectRequestBuilder, redirectValidator) }
        let rejection: Error
        if !redirectBudget.allow(taskID: task.taskIdentifier) {
            rejection = URLError(.httpTooManyRedirects)
        } else if let approved = builder?(request) {
            if let validator {
                validate(approved, for: task, validator: validator, completionHandler: completionHandler)
            } else {
                completionHandler(approved)
            }
            return
        } else {
            rejection = DAVRedirectRejection(httpStatus: response.statusCode)
        }
        // Preserve the reason before cancellation. Drain this task through
        // didCompleteWithError, where caller cancellation takes precedence.
        lock.withLock { redirectError = rejection }
        completionHandler(nil)
        task.cancel()
    }

    private func validate(
        _ request: URLRequest,
        for task: URLSessionTask,
        validator: @escaping @Sendable () async throws -> Void,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        lock.lock()
        guard !isCancelled, continuation != nil, pendingRedirect == nil else {
            lock.unlock()
            completionHandler(nil)
            return
        }
        pendingRedirect = (completionHandler, Task {
            await validateRedirect(request, for: task, using: validator)
        })
        lock.unlock()
    }

    private func validateRedirect(
        _ request: URLRequest,
        for task: URLSessionTask,
        using validator: @Sendable () async throws -> Void
    ) async {
        let rejection: Error?
        do {
            try Task.checkCancellation()
            try await validator()
            rejection = nil
        } catch {
            rejection = error
        }
        let completion = lock.withLock {
            let completion = pendingRedirect?.complete
            pendingRedirect = nil
            if completion != nil { redirectError = rejection }
            return completion
        }
        // Cancellation or completion may already have drained the redirect callback.
        guard let completion else { return }
        completion(rejection == nil ? request : nil)
        if rejection != nil {
            task.cancel()
        }
    }

}

final class DAVRedirectBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int: Int] = [:]
    func allow(taskID: Int) -> Bool {
        lock.withLock {
            let next = (counts[taskID] ?? 0) + 1
            counts[taskID] = next
            return next <= 5
        }
    }
    func complete(taskID: Int) { _ = lock.withLock { counts.removeValue(forKey: taskID) } }
}
