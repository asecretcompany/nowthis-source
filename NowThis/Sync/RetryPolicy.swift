import Foundation

/// Policy describing whether a failed CalDAV request should be retried.
///
/// Transient failures are common on the **first** request after the app returns
/// from the background: the server (or its reverse proxy / pooled database
/// connection) drops idle keep-alive connections, so the first attempt fails
/// with a 5xx response or a dropped-connection `URLError` while an immediate
/// retry over a fresh connection succeeds. This is the root cause of the
/// spurious "Sync failed: Server error (500)" alert users saw when
/// foregrounding the app.
struct RetryPolicy: Sendable {

    /// Accepts delta-seconds or an HTTP-date. Server delays are never capped.
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
           let seconds = TimeInterval(text), seconds.isFinite {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }

    /// Total number of attempts, including the first. `3` == 1 initial try + 2 retries.
    let maxAttempts: Int

    /// Base delay (seconds) for exponential backoff between retries.
    let baseDelay: TimeInterval

    /// Setup is read-only, but only connection failures should repeat. In
    /// particular a TLS handshake failure must not be treated as VPN startup.
    var connectionFailuresOnly = false

    static let connectionSetup = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, connectionFailuresOnly: true)

    /// Default policy: 3 attempts with 0.5s → 1.0s backoff.
    static let `default` = RetryPolicy(maxAttempts: 3, baseDelay: 0.5)

    /// Returns whether `error` is transient and therefore worth retrying.
    func isRetryable(_ error: Error) -> Bool {
        // Never retry a cancelled task — cancellation is intentional.
        if error is CancellationError || error is BackgroundBudgetExhausted { return false }

        if connectionFailuresOnly {
            let underlying: Error
            if let dav = error as? CalDAVError, case .networkError(let wrapped) = dav {
                underlying = wrapped
            } else { underlying = error }
            guard let urlError = underlying as? URLError else { return false }
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
                 .networkConnectionLost, .notConnectedToInternet, .timedOut:
                return true
            default: return false
            }
        }

        if let responseError = error as? HTTPRetryError {
            return responseError.statusCode == 429 || ((500...599).contains(responseError.statusCode) && responseError.statusCode != 507)
        }
        if let calDAVError = error as? CalDAVError {
            switch calDAVError {
            case .serverError(let statusCode):
                // 5xx (500/502/503/504 …) are transient server-side failures.
                return (500...599).contains(statusCode) && statusCode != 507
            case .rateLimited:
                return true
            case .networkError(let underlying):
                return Self.isTransientURLError(underlying)
            default:
                // unauthorized, forbidden, notFound, conflict, invalidURL,
                // invalidResponse, noCalendarHomeSet, noUserPrincipal are permanent.
                return false
            }
        }

        return Self.isTransientURLError(error)
    }

    /// Returns the delay for the given retry attempt, respecting `Retry-After`.
    func delay(forRetry retryIndex: Int, error: Error? = nil) -> TimeInterval {
        guard retryIndex > 0 else { return 0 }
        return Self.serverWait(for: error)?.interval ?? baseDelay * pow(2.0, Double(retryIndex - 1))
    }

    fileprivate static func serverWait(for error: Error?) -> (interval: TimeInterval, statusCode: Int, deadline: Date?)? {
        if let response = error as? HTTPRetryError, let delay = response.retryAfter {
            return (delay, response.statusCode, response.retryDeadline)
        }
        if let calDAVError = error as? CalDAVError,
           case .rateLimited(let retryAfter) = calDAVError,
           let retryAfter {
            return (retryAfter, 429, nil)
        }
        return nil
    }

    /// Connection-level `URLError`s that typically resolve on an immediate retry.
    private static func isTransientURLError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost,   // stale keep-alive socket reused after resume
             .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .secureConnectionFailed:
            return true
        default:
            // .cancelled, .notConnectedToInternet, .userAuthenticationRequired,
            // .badURL, etc. are not worth an immediate retry.
            return false
        }
    }
}

/// Runs `operation`, retrying transient failures according to `policy`.
///
/// `sleep` is injectable so tests can run without real delays. Cancellation is
/// never retried — a `CancellationError` (or a cancellation that surfaces during
/// backoff) propagates immediately.
func withRetry<T>(
    policy: RetryPolicy = .default,
    deadline: Date? = nil,
    runBudget: BackgroundRunBudget? = nil,
    now: @Sendable () -> Date = { Date() },
    jitter: @Sendable (TimeInterval) -> TimeInterval = { $0 },
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
    operation: @Sendable () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        try await ServerRetryAdmission.current?.check()
        try BackgroundBudgetExhausted.checkAdmission(runBudget)
        if let deadline, now() >= deadline { throw RetryDeferredError(deadline: now()) }
        do {
            return try await operation()
        } catch {
            let serverWait = RetryPolicy.serverWait(for: error)
            let serverDeferral: RetryDeferredError?
            if let serverWait, serverWait.interval > 0, !policy.connectionFailuresOnly {
                let deferral = RetryDeferredError(deadline: serverWait.deadline ?? now().addingTimeInterval(serverWait.interval),
                    httpStatusCode: serverWait.statusCode)
                // The transport already recorded waits it received in HTTP headers.
                if serverWait.deadline == nil { ServerRetryAdmission.current?.retain(deferral) }
                serverDeferral = deferral
            } else {
                serverDeferral = nil
            }

            do {
                try BackgroundBudgetExhausted.checkAdmission(runBudget)
            } catch let budgetError as BackgroundBudgetExhausted {
                if let serverDeferral { throw serverDeferral }
                throw budgetError
            }
            let isLastAttempt = attempt >= policy.maxAttempts
            if isLastAttempt || !policy.isRetryable(error) {
                if let serverDeferral { throw serverDeferral }
                if let response = error as? HTTPRetryError, response.statusCode == 429 {
                    throw CalDAVError.rateLimited(retryAfter: response.retryAfter)
                }
                throw error
            }
            let remainingServerWait = serverWait?.deadline.map { max(0, $0.timeIntervalSince(now())) }
            let wait = remainingServerWait ?? serverWait?.interval ?? max(0, jitter(policy.delay(forRetry: attempt)))
            let retryDeadline = serverDeferral?.deadline ?? now().addingTimeInterval(wait)
            if let runBudget, wait >= BackgroundBudgetExhausted.remainingSeconds(runBudget) {
                // An explicit server delay remains authoritative across deliveries;
                // only our own policy backoff is app-budget exhaustion.
                if let serverDeferral { throw serverDeferral }
                throw BackgroundBudgetExhausted()
            }
            if let deadline, retryDeadline >= deadline {
                throw serverDeferral ?? RetryDeferredError(deadline: retryDeadline)
            }
            try await DeadlineRequestExecutor.perform(deadline: runBudget?.remoteCutoff) {
                try await sleep(wait)
            }
            attempt += 1
        }
    }
}

/// The coordinator can schedule a later run without violating Retry-After.
struct RetryDeferredError: Error, Sendable {
    let deadline: Date
    let httpStatusCode: Int?

    init(deadline: Date, httpStatusCode: Int? = nil) {
        self.deadline = deadline
        self.httpStatusCode = httpStatusCode
    }
}

/// Binds HTTP work to the account whose credentials it sends, including requests
/// made by a destination sync to recover a source account's task or original.
struct ServerRetryAdmission: Sendable {
    @TaskLocal static var current: Self?

    let accountID: String
    let checkDeadline: @Sendable (String) async throws -> Void
    let recordDeadline: @Sendable (String, RetryDeferredError) -> Void

    func check() async throws { try await checkDeadline(accountID) }
    func retain(_ deferral: RetryDeferredError) { recordDeadline(accountID, deferral) }

    func forAccount(_ accountID: String) -> Self {
        Self(accountID: accountID, checkDeadline: checkDeadline, recordDeadline: recordDeadline)
    }
}

/// Retains Retry-After on transient HTTP failures such as a 503. Without a
/// header, existing callers continue to receive CalDAVError.serverError.
struct HTTPRetryError: Error, Sendable {
    let statusCode: Int
    let retryAfter: TimeInterval?
    let retryDeadline: Date?

    init(statusCode: Int, retryAfter: TimeInterval?, retryDeadline: Date? = nil) {
        self.statusCode = statusCode
        self.retryAfter = retryAfter
        self.retryDeadline = retryDeadline
    }
}
