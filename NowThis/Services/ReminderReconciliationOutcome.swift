import Foundation

struct ReminderReconciliationOutcome: Sendable, Equatable {
    enum Status: Sendable {
        case confirmed, capacityLimited, permissionDenied, superseded, cancelled, failed
    }

    var status: Status
    var requestedCount = 0
    var confirmedCount = 0
    var deferredTaskIDs: Set<String> = []
    var expiredTaskIDs: Set<String> = []
}

struct ReminderReconcilePolicy: Sendable {
    var allowsPermissionPrompt: Bool
    var deadline: ContinuousClock.Instant?

    static let foreground = Self(allowsPermissionPrompt: true)
    static let background = Self(allowsPermissionPrompt: false)

    var shouldStop: Bool {
        Task.isCancelled || deadline.map { ContinuousClock().now >= $0 } == true
            || BackgroundRunBudget.current.map { (try? $0.checkFinalAdmission()) == nil } == true
    }
}
