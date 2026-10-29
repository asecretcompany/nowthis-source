import Testing
import Foundation

@testable import NowThis

@Suite("Retry Policy")
struct RetryPolicyTests {

    // MARK: - isRetryable

    @Test("5xx server errors are retryable")
    func serverErrorsAreRetryable() {
        let policy = RetryPolicy.default
        for code in [500, 502, 503, 504] {
            #expect(policy.isRetryable(CalDAVError.serverError(statusCode: code)),
                    "HTTP \(code) should be retried (transient server failure)")
        }
    }

    @Test("4xx and protocol errors are not retryable")
    func clientErrorsAreNotRetryable() {
        let policy = RetryPolicy.default
        #expect(!policy.isRetryable(CalDAVError.serverError(statusCode: 400)))
        #expect(!policy.isRetryable(CalDAVError.serverError(statusCode: 404)))
        #expect(!policy.isRetryable(CalDAVError.unauthorized))
        #expect(!policy.isRetryable(CalDAVError.forbidden))
        #expect(!policy.isRetryable(CalDAVError.notFound))
        #expect(!policy.isRetryable(CalDAVError.conflict(etag: nil)))
        #expect(!policy.isRetryable(CalDAVError.invalidResponse))
        #expect(!policy.isRetryable(CalDAVError.invalidURL))
    }

    @Test("Dropped-connection URL errors are retryable")
    func connectionErrorsAreRetryable() {
        let policy = RetryPolicy.default
        #expect(policy.isRetryable(URLError(.networkConnectionLost)),
                "A stale keep-alive socket reused after resume should be retried")
        #expect(policy.isRetryable(URLError(.timedOut)))
        #expect(policy.isRetryable(URLError(.cannotConnectToHost)))
        // Same when wrapped in CalDAVError.networkError
        #expect(policy.isRetryable(
            CalDAVError.networkError(underlying: URLError(.networkConnectionLost))))
    }

    @Test("Cancellation is never retryable")
    func cancellationIsNotRetryable() {
        let policy = RetryPolicy.default
        #expect(!policy.isRetryable(CancellationError()))
        #expect(!policy.isRetryable(URLError(.cancelled)))
    }

    @Test("No-connectivity fails fast (not retried)")
    func noConnectivityIsNotRetried() {
        let policy = RetryPolicy.default
        #expect(!policy.isRetryable(URLError(.notConnectedToInternet)))
    }

    @Test("An exhausted app budget is never retried")
    func cancelledDeadlineNeverRetries() async {
        let recorder = CallRecorder()
        await #expect(throws: BackgroundBudgetExhausted.self) {
            try await withRetry(policy: .init(maxAttempts: 3, baseDelay: 0), sleep: { await recorder.recordSleep($0) }) { () -> String in
                _ = await recorder.nextAttempt()
                throw BackgroundBudgetExhausted()
            }
        }
        #expect(await recorder.attempts == 1)
        #expect(await recorder.sleeps.isEmpty)
    }

    @Test("Backoff that consumes the remaining app allowance stops without server deferral")
    func budgetBoundsBackoff() async {
        let recorder = CallRecorder()
        let budget = BackgroundRunBudget(startedAt: ContinuousClock().now - .seconds(14))
        await #expect(throws: BackgroundBudgetExhausted.self) {
            try await withRetry(policy: .init(maxAttempts: 3, baseDelay: 2), runBudget: budget,
                sleep: { await recorder.recordSleep($0) }) { () -> String in
                _ = await recorder.nextAttempt()
                throw CalDAVError.serverError(statusCode: 503)
            }
        }
        #expect(await recorder.attempts == 1)
        #expect(await recorder.sleeps.isEmpty)
    }

    @Test("A server Retry-After survives an app allowance too short to wait", arguments: [429, 503])
    func serverDeferralSurvivesSharedBudget(status: Int) async {
        let recorder = CallRecorder()
        let budget = BackgroundRunBudget(startedAt: ContinuousClock().now - .seconds(14))
        let instant = Date(timeIntervalSince1970: 2_000_000_000)
        do {
            _ = try await withRetry(policy: .init(maxAttempts: 3, baseDelay: 0), runBudget: budget,
                now: { instant }, sleep: { await recorder.recordSleep($0) }) { () -> String in
                _ = await recorder.nextAttempt()
                if status == 429 { throw CalDAVError.rateLimited(retryAfter: 60) }
                throw HTTPRetryError(statusCode: 503, retryAfter: 60)
            }
            Issue.record("Expected the server's requested retry deadline")
        } catch let error as RetryDeferredError {
            #expect(error.deadline == Date(timeIntervalSince1970: 2_000_000_060))
        } catch {
            Issue.record("Expected RetryDeferredError for an actual server delay, received \(error)")
        }
        #expect(await recorder.attempts == 1)
        #expect(await recorder.sleeps.isEmpty)
    }

    // MARK: - Backoff

    @Test("Backoff grows exponentially from the base delay")
    func backoffIsExponential() {
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 0.5)
        #expect(policy.delay(forRetry: 1) == 0.5)
        #expect(policy.delay(forRetry: 2) == 1.0)
        #expect(policy.delay(forRetry: 3) == 2.0)
    }

    // MARK: - withRetry loop

    @Test("Retries a transient failure, then succeeds")
    func retriesTransientThenSucceeds() async throws {
        let recorder = CallRecorder()
        let result = try await withRetry(
            policy: RetryPolicy(maxAttempts: 3, baseDelay: 0.5),
            sleep: { await recorder.recordSleep($0) }
        ) { () -> String in
            let attempt = await recorder.nextAttempt()
            if attempt < 3 { throw CalDAVError.serverError(statusCode: 500) }
            return "ok"
        }
        #expect(result == "ok")
        #expect(await recorder.attempts == 3)
        #expect(await recorder.sleeps == [0.5, 1.0])
    }

    @Test("Rethrows after exhausting all attempts")
    func exhaustsAttemptsThenThrows() async {
        let recorder = CallRecorder()
        await #expect(throws: CalDAVError.self) {
            try await withRetry(
                policy: RetryPolicy(maxAttempts: 3, baseDelay: 0),
                sleep: { _ in }
            ) { () -> String in
                _ = await recorder.nextAttempt()
                throw CalDAVError.serverError(statusCode: 503)
            }
        }
        #expect(await recorder.attempts == 3)
    }

    @Test("Does not retry a non-transient failure")
    func doesNotRetryNonTransient() async {
        let recorder = CallRecorder()
        await #expect(throws: CalDAVError.self) {
            try await withRetry(
                policy: RetryPolicy(maxAttempts: 3, baseDelay: 0),
                sleep: { _ in }
            ) { () -> String in
                _ = await recorder.nextAttempt()
                throw CalDAVError.unauthorized
            }
        }
        #expect(await recorder.attempts == 1)
    }

    @Test("Does not retry a cancelled operation")
    func doesNotRetryCancellation() async {
        let recorder = CallRecorder()
        await #expect(throws: CancellationError.self) {
            try await withRetry(
                policy: RetryPolicy(maxAttempts: 3, baseDelay: 0),
                sleep: { _ in }
            ) { () -> String in
                _ = await recorder.nextAttempt()
                throw CancellationError()
            }
        }
        #expect(await recorder.attempts == 1)
    }
}

/// Thread-safe recorder for `withRetry` attempt counts and backoff delays.
private actor CallRecorder {
    private(set) var attempts = 0
    private(set) var sleeps: [TimeInterval] = []

    func nextAttempt() -> Int {
        attempts += 1
        return attempts
    }

    func recordSleep(_ delay: TimeInterval) {
        sleeps.append(delay)
    }
}
