import Foundation
import Testing

@testable import NowThis

@Suite("Concrete reminder request budget")
struct ReminderRequestPlanTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(_ id: String, seconds: Double = 3_600,
                       reminder: Bool = true, nag: Bool = false,
                       active: Bool = true) -> ReminderTaskInput {
        .init(id: id, title: id, hasActiveStatus: active,
              dueDate: now.addingTimeInterval(seconds), isDueDateOnly: false,
              reminderOffset: reminder ? 0 : nil, isNaggingReminder: nag,
              isDeletedLocally: false)
    }

    private func plan(_ tasks: [ReminderTaskInput], max: Int = 60,
                      foreign: Int = 0) -> ReminderRequestPlan {
        ReminderNotificationPlanner.planRequests(
            tasks: tasks, now: now, maxRequests: max,
            foreignPendingCount: foreign, badgesEnabled: true)
    }

    @Test("Sixty nagging tasks admit sixty primary requests, not 120 requests")
    func sixtyNaggingTasksNeverAdmit120Requests() {
        let result = plan((0..<60).map { input("task-\($0)", seconds: Double($0 + 1) * 3_600, nag: true) })
        #expect(result.requests.count == 60)
        #expect(result.requests.allSatisfy { $0.kind == .reminder })
        #expect(result.deferredTaskIDs.count == 60)
    }

    @Test("Actual foreign pending requests reduce admission slots")
    func foreignRequestsReduceAvailableSlots() {
        let tasks = (0..<6).map { input("task-\($0)") }
        let result = plan(tasks, max: 6, foreign: 2)
        #expect(result.requests.count == 4)
        #expect(result.requests.count + 2 == 6)
        #expect(plan(tasks, max: 6, foreign: 100).requests.isEmpty)
    }

    @Test("Explicit primaries are admitted before nags and overdue alerts")
    func primaryRemindersWinBeforeNagsAndOverdue() {
        let result = plan([
            input("overdue", seconds: 60, reminder: false),
            input("nagging", seconds: 120, nag: true),
            input("primary", seconds: 3_600)
        ], max: 3)
        #expect(result.requests.map(\.identifier) == [
            "reminder-nagging", "reminder-primary", "nag-nagging"
        ])
        #expect(result.deferredTaskIDs == ["overdue"])
    }

    @Test("An active nag survives its primary fire date, but completed nags disappear")
    func nagSurvivesPrimaryFireDate() {
        let result = plan([input("active", seconds: -60, nag: true),
                           input("completed", seconds: -60, nag: true, active: false)])
        #expect(result.requests.map(\.identifier) == ["nag-active"])
        #expect(result.requests.first?.trigger == .hourly)
    }

    @Test("Equal fire dates use task ID ties rather than input order")
    func equalDatesUseTaskIDTieBreak() {
        let result = plan([input("b"), input("a")], max: 1)
        #expect(result.requests.map(\.identifier) == ["reminder-a"])
        #expect(result.deferredTaskIDs == ["b"])
    }
}
