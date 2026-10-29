import Foundation

struct PlannedReminderRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case reminder, overdue, nag }
    enum Trigger: Equatable, Sendable { case calendar(Date), hourly }

    let identifier: String
    let taskID: String
    let kind: Kind
    let trigger: Trigger
    let title: String
    let body: String
    let badge: Int?
}

struct ReminderRequestPlan: Sendable {
    let requests: [PlannedReminderRequest]
    let deferredTaskIDs: Set<String>
    let expiredTaskIDs: Set<String>
    var deferredRequests: [PlannedReminderRequest] = []

    var primaryEntries: [ReminderScheduler.PlannedNotification] {
        let nagIDs = Set(requests.filter { $0.kind == .nag }.map(\.taskID))
        return requests.compactMap { request in
            guard case .calendar(let date) = request.trigger else { return nil }
            return .init(taskID: request.taskID, fireDate: date, badge: request.badge,
                         kind: request.kind == .reminder ? .reminder : .overdue,
                         isNagging: nagIDs.contains(request.taskID), title: request.title)
        }
    }
}

extension ReminderNotificationPlanner {
    static func planRequests(
        tasks: [ReminderTaskInput], now: Date, maxRequests: Int,
        foreignPendingCount: Int, badgesEnabled: Bool,
        allDayReminderMinutes: Int = TaskDefaultsPreferences.allDayReminderMinutes,
        calendar: Calendar = .current
    ) -> ReminderRequestPlan {
        let active = tasks.filter { $0.hasActiveStatus && !$0.isDeletedLocally }
        let timeline = badgesEnabled
            ? BadgeTimeline(inputs: active, allDayReminderMinutes: allDayReminderMinutes, calendar: calendar)
            : nil
        typealias Candidate = (date: Date, request: PlannedReminderRequest)
        var primaries: [Candidate] = []
        var nags: [Candidate] = []
        var overdue: [Candidate] = []
        var expired: Set<String> = []
        for task in active {
            guard let due = task.dueDate else { continue }
            if let offset = task.reminderOffset {
                let fire = ReminderScheduler.computeFireDate(
                    dueDate: due, isDueDateOnly: task.isDueDateOnly, reminderOffset: offset,
                    allDayReminderMinutes: allDayReminderMinutes, calendar: calendar)
                if fire > now {
                    primaries.append((fire, PlannedReminderRequest(
                        identifier: NotificationIdentifiers.reminderPrefix + task.id,
                        taskID: task.id, kind: .reminder, trigger: .calendar(fire),
                        title: task.title, body: ReminderScheduler.bodyText(for: offset),
                        badge: timeline?.count(asOf: fire))))
                } else { expired.insert(task.id) }
                if task.isNaggingReminder {
                    nags.append((fire, PlannedReminderRequest(
                        identifier: NotificationIdentifiers.nagPrefix + task.id,
                        taskID: task.id, kind: .nag, trigger: .hourly, title: task.title,
                        body: String(localized: "notification.nag.body",
                            defaultValue: "Hourly reminder — still pending",
                            comment: "Body of the repeating hourly reminder. The notification's title is the task's own name."),
                        // Fixed badges on repeats become stale; dated requests own badge changes.
                        badge: nil)))
                }
            } else if badgesEnabled {
                let fire = DueDateHelper.effectiveDeadline(
                    for: due, isDateOnly: task.isDueDateOnly, regionCalendar: calendar)
                guard fire > now else { continue }
                overdue.append((fire, PlannedReminderRequest(
                    identifier: NotificationIdentifiers.overduePrefix + task.id,
                    taskID: task.id, kind: .overdue, trigger: .calendar(fire), title: task.title,
                    body: String(localized: "notification.overdue.body", defaultValue: "Now overdue",
                        comment: "Body of the notification sent the moment a task passes its due date. The title is the task's own name."),
                    badge: timeline?.count(asOf: fire))))
            }
        }
        let earlier: (Candidate, Candidate) -> Bool = {
            $0.date == $1.date ? $0.request.taskID < $1.request.taskID : $0.date < $1.date
        }
        let candidates = primaries.sorted(by: earlier) + nags.sorted(by: earlier) + overdue.sorted(by: earlier)
        let slots = max(0, max(0, maxRequests) - max(0, foreignPendingCount))
        return ReminderRequestPlan(requests: candidates.prefix(slots).map(\.request),
            deferredTaskIDs: Set(candidates.dropFirst(slots).map { $0.request.taskID }),
            expiredTaskIDs: expired, deferredRequests: candidates.dropFirst(slots).map(\.request))
    }
}
