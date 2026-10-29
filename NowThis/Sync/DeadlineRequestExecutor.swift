import Foundation

/// App-owned allowance exhaustion is neither a server Retry-After nor an auth failure.
struct BackgroundBudgetExhausted: Error, Sendable {
    static func checkAdmission(_ budget: BackgroundRunBudget?) throws {
        try Task.checkCancellation()
        guard let budget else { return }
        do { try budget.checkRemoteAdmission() }
        catch {
            try Task.checkCancellation()
            throw BackgroundBudgetExhausted()
        }
    }

    static func remainingSeconds(_ budget: BackgroundRunBudget) -> TimeInterval {
        let remaining = budget.remainingRemoteTime.components
        return Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
    }
}

/// Only cancellation-cooperative asynchronous transport belongs here. The group
/// cancels and drains its operation before returning; it cannot preempt SQL work.
enum DeadlineRequestExecutor {
    static func perform<Value: Sendable>(
        deadline: ContinuousClock.Instant?,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard let deadline else { return try await operation() }
        guard ContinuousClock().now < deadline else { throw BackgroundBudgetExhausted() }
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                try Task.checkCancellation()
                throw BackgroundBudgetExhausted()
            }
            defer { group.cancelAll() }
            let value = try await group.next()!
            try Task.checkCancellation()
            guard ContinuousClock().now < deadline else { throw BackgroundBudgetExhausted() }
            return value
        }
    }
}
