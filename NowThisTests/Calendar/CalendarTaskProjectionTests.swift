import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Calendar day projections")
@MainActor
struct CalendarTaskProjectionTests {
    private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var losAngeles: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }
    private func task(_ id: String, due: Date?, status: TaskStatus = .needsAction,
                      priority: TaskPriority = .none, allDay: Bool = false, in context: ModelContext) -> TaskItem {
        let task = TaskItem(id: id, title: id)
        task.dueDate = due; task.status = status; task.priority = priority; task.isDueDateOnly = allDay
        context.insert(task)
        return task
    }

    @Test("Date-only, timed and dated-subtask rows share the correct local DST day")
    func dateOnlyAndTimedRowsShareLocalDay() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let parent = task("parent", due: nil, in: context)
        let allDay = task("allDay", due: instant("2024-03-10T00:00:00Z"), priority: .high, allDay: true, in: context)
        let late = task("late", due: instant("2024-03-11T06:00:00Z"), priority: .low, in: context)
        let child = task("child", due: instant("2024-03-10T09:00:00Z"), priority: .medium, in: context)
        child.parentTask = parent
        let previous = task("previous", due: instant("2024-03-10T07:30:00Z"), in: context)
        try context.save()
        let projection = CalendarTaskProjection(rows: [parent, allDay, late, child, previous].glanceRows(),
            calendar: losAngeles, now: instant("2024-03-10T20:00:00Z"))
        let bucket = projection.bucket(on: instant("2024-03-10T20:00:00Z"))
        #expect(bucket.rows.map(\.id) == ["allDay", "late", "child"])
        #expect(bucket.highestPriority == .high)
        #expect(projection.bucket(on: instant("2024-03-09T20:00:00Z")).rows.map(\.id) == ["previous"])
        withExtendedLifetime(container) {}
    }

    @Test("Counts include completed and cancelled rows while carry-forward excludes them")
    func statusRulesPreserveMonthAndOverdueSemantics() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let due = instant("2024-03-10T00:00:00Z")
        let active = task("active", due: due, allDay: true, in: context)
        let completed = task("done", due: due, status: .completed, priority: .medium, allDay: true, in: context)
        let cancelled = task("cancelled", due: due, status: .cancelled, priority: .high, allDay: true, in: context)
        try context.save()
        let projection = CalendarTaskProjection(rows: [active, completed, cancelled].glanceRows(),
            calendar: losAngeles, now: instant("2024-03-11T07:00:00Z"))
        let bucket = projection.bucket(on: instant("2024-03-10T20:00:00Z"))
        #expect(bucket.rows.count == 3)
        #expect(bucket.highestPriority == .high)
        #expect(projection.overdueRows.map(\.id) == ["active"])
        #expect(projection.isToday(instant("2024-03-11T20:00:00Z")))
        withExtendedLifetime(container) {}
    }

    @Test("Rebuilding with a different time zone changes timed buckets without shifting all-day dates")
    func timeZoneChangesRebuildBuckets() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let timed = task("timed", due: instant("2024-10-08T00:30:00Z"), in: context)
        let allDay = task("allDay", due: instant("2024-10-08T00:00:00Z"), allDay: true, in: context)
        try context.save()
        let rows = [timed, allDay].glanceRows()
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let local = CalendarTaskProjection(rows: rows, calendar: losAngeles)
        let universal = CalendarTaskProjection(rows: rows, calendar: utc)
        let selected = instant("2024-10-08T20:00:00Z")
        #expect(local.bucket(on: selected).rows.map(\.id) == ["allDay"])
        #expect(universal.bucket(on: selected).rows.map(\.id) == ["timed", "allDay"])
        withExtendedLifetime(container) {}
    }
}
