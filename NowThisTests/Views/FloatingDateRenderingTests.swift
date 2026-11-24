import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Floating due dates in task rows")
@MainActor
struct FloatingDateRenderingTests {
    @Test("Calendar day and overdue rows show the floating date without a clock", arguments: [-8, 10])
    func calendarRows(offset: Int) throws {
        let container = try DAVSyncScenario.container()
        let task = try allDayTask(in: container.mainContext)
        let calendar = try calendar(offset: offset)
        let now = try instant("2026-11-12T00:00:00Z")
        let rows = [task].glanceRows()
        let projection = CalendarTaskProjection(rows: rows, calendar: calendar, now: now)
        let selectedDay = try instant("2026-11-10T12:00:00Z")
        let due = try #require(projection.bucket(on: selectedDay).rows.first?.data)
        let overdue = try #require(projection.overdueRows.first?.data)

        #expect(DayTaskRow(data: due).dueDateLabel(timeZone: calendar.timeZone) == "Nov 10 · All day")
        #expect(OverdueTaskRow(data: overdue).dueDateLabel(timeZone: calendar.timeZone) == "Nov 10 · All day")
        #expect(due.spokenAllDayDueDate(timeZone: calendar.timeZone) == "Nov 10, All day")
        #expect(overdue.spokenAllDayDueDate(timeZone: calendar.timeZone) == "Nov 10, All day")
    }

    @Test("Board and Matrix project an all-day task into date-aware labels", arguments: [-8, 10])
    func boardAndMatrixRows(offset: Int) throws {
        let container = try DAVSyncScenario.container()
        let task = try allDayTask(in: container.mainContext)
        let calendar = try calendar(offset: offset)
        let now = try instant("2026-11-10T12:00:00Z")
        let board = try #require(KanbanCardData(task: task))
        let data = try #require(TaskGlanceData(task: task))
        let matrix = MatrixTaskRow(data: data, tintColor: .blue, onTap: {})

        #expect(board.dueDateLabel(timeZone: calendar.timeZone) == "Nov 10 · All day")
        #expect(board.spokenDueDate(now: now, timeZone: calendar.timeZone) == "Nov 10, All day")
        #expect(matrix.dueDateLabel(timeZone: calendar.timeZone) == "Nov 10 · All day")
        #expect(data.spokenAllDayDueDate(timeZone: calendar.timeZone) == "Nov 10, All day")
    }

    @Test("The Board marks an all-day task overdue at the start of the next local day", arguments: [-8, 10])
    func boardOverdueBoundary(offset: Int) throws {
        let container = try DAVSyncScenario.container()
        let task = try allDayTask(in: container.mainContext)
        let calendar = try calendar(offset: offset)
        let board = try #require(KanbanCardData(task: task))
        let deadlineUTC = offset < 0 ? "2026-11-11T08:00:00Z" : "2026-11-10T14:00:00Z"
        let deadline = try instant(deadlineUTC)

        #expect(!board.isOverdue(now: deadline.addingTimeInterval(-1), calendar: calendar))
        #expect(board.isOverdue(now: deadline, calendar: calendar))
        #expect(board.isOverdue(now: deadline.addingTimeInterval(1), calendar: calendar))
    }

    @Test("Upcoming occurrence rows show and speak the date carried by the occurrence", arguments: [-8, 10])
    func occurrenceRows(offset: Int) throws {
        let container = try DAVSyncScenario.container()
        let task = try allDayTask(in: container.mainContext)
        let calendar = try calendar(offset: offset)
        let now = try instant("2026-11-09T00:00:00Z")
        let occurrence = try #require(TaskListHelpers.occurrences(from: [task], smartList: .upcoming,
                                                                   now: now).first)
        let data = try #require(TaskRowData(task: occurrence.task))

        let due = try #require(data.dueDate)
        let badge = DueDateBadge(date: due, isDateOnly: data.isDueDateOnly, isOverdue: false)
        #expect(badge.label(timeZone: calendar.timeZone) == "Nov 10 · All day")
        #expect(occurrence.spokenDueDate(timeZone: calendar.timeZone) == "Nov 10, All day")
    }

    @Test("Weekly and monthly sections keep floating dates on the correct side of local boundaries",
          arguments: [-8, 10])
    func occurrenceGrouping(offset: Int) throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let calendar = try calendar(offset: offset)
        let now = try instant("2026-10-31T00:00:00Z")
        // November 1, 2026 was a Sunday. In UTC-8 a raw comparison groups its
        // midnight carrier under Saturday, October 31.
        let allDay = try allDayTask(due: "2026-11-01T00:00:00Z", in: context)
        let timed = TaskItem(title: "Local Sunday at noon")
        timed.dueDate = try instant("2026-11-01T12:00:00Z").addingTimeInterval(Double(-offset) * 3600)
        context.insert(timed)
        let occurrences = TaskListHelpers.occurrences(from: [allDay, timed], smartList: .upcoming, now: now)
        try #require(occurrences.count == 2)

        let week = TaskListView.groupOccurrences(occurrences, by: .weekOfYear, calendar: calendar)
        let month = TaskListView.groupOccurrences(occurrences, by: .month, calendar: calendar)
        #expect(week.count == 1)
        #expect(month.count == 1)
        #expect(month.first?.title == "November 2026")
    }

    @Test("The widget's compact and expanded date styles agree for all-day tasks", arguments: [-8, 10])
    func widgetDueDateStyles(offset: Int) throws {
        let zone = try calendar(offset: offset).timeZone
        let due = try instant("2026-11-10T00:00:00Z")
        let compact = Date.FormatStyle.dateTime.month(.abbreviated).day()
        #expect(DueDateFormatter.format(due, isDateOnly: true, timeZone: zone, timedStyle: compact)
                == "Nov 10 · All day")
        #expect(DueDateFormatter.format(due, isDateOnly: true, timeZone: zone) == "Nov 10 · All day")
        #expect(DueDateFormatter.accessibilityLabel(due, isDateOnly: true, timeZone: zone) == "Nov 10, All day")
        #expect(DueDateFormatter.format(due, isDateOnly: false, timeZone: zone, timedStyle: compact)
                == (offset < 0 ? "Nov 9" : "Nov 10"))
        var expanded = compact.hour().minute()
        expanded.timeZone = zone
        #expect(DueDateFormatter.format(due, isDateOnly: false, timeZone: zone) == due.formatted(expanded))
    }

    private func allDayTask(due: String = "2026-11-10T00:00:00Z", in context: ModelContext) throws -> TaskItem {
        let task = TaskItem(title: "All-day task")
        task.dueDate = try instant(due)
        task.isDueDateOnly = true
        context.insert(task)
        try context.save()
        return task
    }

    private func calendar(offset: Int) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: offset * 3600))
        calendar.firstWeekday = 1
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }

    private func instant(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }
}
