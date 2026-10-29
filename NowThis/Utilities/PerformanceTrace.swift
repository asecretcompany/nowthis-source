import os

/// Intervals contain aggregate counts only; never task contents, hrefs or credentials.
enum PerformanceTrace {
    static let reminderPlanName: StaticString = "ReminderPlan"
    private static let signposter = OSSignposter(subsystem: "com.nowthis", category: "performance")

    static func begin(_ name: StaticString, count: Int = 0, bytes: Int = 0) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID(),
                                 "count=\(count) bytes=\(bytes)")
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
