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

    @Test("Today shows overdue timed tasks once and carries forward a task still visible on its original day",
          arguments: [false, true])
    func todaysRowsAreDisjoint(showCompleted: Bool) throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let now = instant("2024-03-10T20:00:00Z")
        let yesterday = instant("2024-03-09T19:00:00Z")
        let earlier = task("earlier", due: instant("2024-03-10T18:00:00Z"), in: context)
        let previous = task("previous", due: yesterday, in: context)
        let later = task("later", due: instant("2024-03-10T22:00:00Z"), in: context)
        try context.save()
        let projection = CalendarTaskProjection(rows: [earlier, previous, later].glanceRows(),
            calendar: losAngeles, now: now, showCompleted: showCompleted)

        let today = projection.sections(on: now)
        #expect(today.due.map(\.id) == ["later"])
        #expect(today.overdue.map(\.id) == ["earlier", "previous"])
        let visibleIDs = (today.due + today.overdue).map(\.id)
        #expect(Set(visibleIDs).count == visibleIDs.count)
        #expect(projection.bucket(on: now).rows.map(\.id) == ["earlier", "later"])
        #expect(projection.bucket(on: yesterday).rows.map(\.id) == ["previous"])
        #expect(projection.sections(on: yesterday).due.map(\.id) == ["previous"])
        #expect(projection.sections(on: yesterday).overdue.isEmpty)
        withExtendedLifetime(container) {}
    }

    @Test("Completed visibility controls dated markers and day sections while cancelled rows stay dated",
          arguments: [false, true])
    func completedVisibilityControlsDatedRows(showCompleted: Bool) throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let now = instant("2024-03-10T20:00:00Z")
        let upcoming = task("upcoming", due: instant("2024-03-10T22:00:00Z"), priority: .medium, in: context)
        let done = task("done", due: instant("2024-03-10T17:00:00Z"), status: .completed, priority: .high, in: context)
        let cancelled = task("cancelled", due: instant("2024-03-10T16:00:00Z"), status: .cancelled, priority: .low, in: context)
        try context.save()
        let projection = CalendarTaskProjection(rows: [upcoming, done, cancelled].glanceRows(),
            calendar: losAngeles, now: now, showCompleted: showCompleted)

        let expected = showCompleted ? ["upcoming", "done", "cancelled"] : ["upcoming", "cancelled"]
        let bucket = projection.bucket(on: now)
        #expect(bucket.rows.map(\.id) == expected)
        #expect(bucket.highestPriority == (showCompleted ? .high : .medium))
        #expect(projection.sections(on: now).due.map(\.id) == expected)
        #expect(projection.sections(on: now).overdue.isEmpty)
        withExtendedLifetime(container) {}
    }

    @Test("Repeated weekday labels retain distinct identities at fixed columns")
    func weekdayHeaderSlotIDs() {
        var calendar = losAngeles
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        let mondayFirst = CalendarMonthView.weekdayHeaderSlots(for: calendar)
        #expect(mondayFirst.map(\.value) == ["M", "T", "W", "T", "F", "S", "S"])
        #expect(Set(mondayFirst.map(\.id)).count == 7)

        calendar.firstWeekday = 1
        let sundayFirst = CalendarMonthView.weekdayHeaderSlots(for: calendar)
        #expect(sundayFirst.map(\.value) == ["S", "M", "T", "W", "T", "F", "S"])
        #expect(sundayFirst.map(\.id) == mondayFirst.map(\.id))
    }

    @Test("Padding and dates retain distinct identities at fixed month grid positions")
    func monthSlotIDs() throws {
        var calendar = losAngeles
        calendar.firstWeekday = 2
        let july = CalendarMonthView.monthSlots(for: instant("2026-07-15T20:00:00Z"), calendar: calendar)
        try #require(july.count == 33)
        #expect(july[0].value == nil)
        #expect(july[1].value == nil)
        #expect(july[2].value == instant("2026-07-01T07:00:00Z"))
        #expect(Set(july.map(\.id)).count == july.count)

        let august = CalendarMonthView.monthSlots(for: instant("2026-08-15T20:00:00Z"), calendar: calendar)
        #expect(august.prefix(july.count).map(\.id) == july.map(\.id))
    }
}
