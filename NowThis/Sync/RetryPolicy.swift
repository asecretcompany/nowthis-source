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

    /// Total number of attempts, including the first. `3` == 1 initial try + 2 retries.
    let maxAttempts: Int

    /// Base delay (seconds) for exponential backoff between retries.
    let baseDelay: TimeInterval

    /// Default policy: 3 attempts with 0.5s → 1.0s backoff.
    static let `default` = RetryPolicy(maxAttempts: 3, baseDelay: 0.5)

    /// Returns whether `error` is transient and therefore worth retrying.
    func isRetryable(_ error: Error) -> Bool {
        // Never retry a cancelled task — cancellation is intentional.
        if error is CancellationError { return false }

        if let calDAVError = error as? CalDAVError {
            switch calDAVError {
            case .serverError(let statusCode):
                // 5xx (500/502/503/504 …) are transient server-side failures.
                return (500...599).contains(statusCode)
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

    /// Returns the delay for the given retry attempt, respecting `Retry-After` from 429s.
    func delay(forRetry retryIndex: Int, error: Error? = nil) -> TimeInterval {
        guard retryIndex > 0 else { return 0 }

        // Respect the server's Retry-After header for rate-limited responses
        if let calDAVError = error as? CalDAVError,
           case .rateLimited(let retryAfter) = calDAVError,
           let retryAfter {
            return retryAfter
        }

        return baseDelay * pow(2.0, Double(retryIndex - 1))
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
    sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
    operation: @Sendable () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await operation()
        } catch {
            let isLastAttempt = attempt >= policy.maxAttempts
            if isLastAttempt || !policy.isRetryable(error) {
                throw error
            }
            try await sleep(policy.delay(forRetry: attempt, error: error))
            attempt += 1
        }
    }
}
