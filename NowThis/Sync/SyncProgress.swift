import Observation

struct SyncProgress: Sendable, Equatable {
    enum Stage: Sendable, Equatable {
        case discovering
        case inventory
        case downloading
        case applying
        case finishing
    }

    var accountID: String
    var listID: String?
    var stage: Stage
    var completed: Int
    var total: Int?
}

@MainActor
@Observable
final class SyncProgressState {
    var current: SyncProgress?

    @discardableResult
    func apply(_ progress: SyncProgress) -> Bool {
        var normalized = progress
        normalized.completed = max(0, normalized.completed)
        if let total = normalized.total {
            let clampedTotal = max(0, total)
            normalized.total = clampedTotal
            normalized.completed = min(normalized.completed, clampedTotal)
        }

        guard current != normalized else { return false }
        current = normalized
        return true
    }

    func clear() {
        current = nil
    }
}
