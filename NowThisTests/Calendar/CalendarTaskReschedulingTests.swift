import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Calendar drag rescheduling")
@MainActor
struct CalendarTaskReschedulingTests {
    struct DateOnlyDrop: Sendable {
        let zone: String
        let original: String
        let selectedDay: String
        let canonical: String
        let wireDate: String
    }

    @Test("The selected civil day survives the save, VTODO serialization and parse", arguments: [
        DateOnlyDrop(zone: "Australia/Sydney", original: "2026-07-15T00:00:00Z",
                     selectedDay: "2027-01-15T01:00:00Z", canonical: "2027-01-15T00:00:00Z",
                     wireDate: "20270115"),
        DateOnlyDrop(zone: "America/Los_Angeles", original: "2026-07-15T00:00:00Z",
                     selectedDay: "2026-11-01T20:00:00Z", canonical: "2026-11-01T00:00:00Z",
                     wireDate: "20261101"),
        DateOnlyDrop(zone: "America/Los_Angeles", original: "2026-11-10T00:00:00Z",
                     selectedDay: "2027-03-14T19:00:00Z", canonical: "2027-03-14T00:00:00Z",
                     wireDate: "20270314")
    ])
    func allDayRoundTrips(drop: DateOnlyDrop) throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let task = TaskItem(title: "All-day drag")
        task.dueDate = try instant(drop.original)
        task.isDueDateOnly = true
        task.isDirty = false
        context.insert(task)
        try context.save()
        let id = task.id

        let selectedDay = try instant(drop.selectedDay)
        let expected = try instant(drop.canonical)
        let calendar = try calendar(in: drop.zone)
        #expect(CalendarTaskRescheduling.reschedule(taskIDs: [id], to: selectedDay, among: [task],
                                                    in: context, calendar: calendar))

        let reader = ModelContext(container)
        let reloaded = try #require(reader.fetch(
            FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
        #expect(reloaded.dueDate == expected)
        #expect(reloaded.isDueDateOnly)
        #expect(reloaded.isDirty)
        let ics = ICalendarSerializer.serialize(uid: reloaded.uid, summary: reloaded.title,
                                                dueDate: reloaded.dueDate, isDueDateOnly: reloaded.isDueDateOnly)
        #expect(ics.contains("DUE;VALUE=DATE:\(drop.wireDate)\r\n"))
        let parsed = try #require(try ICalendarParser.parseSingleVTODO(from: ics))
        #expect(parsed.dueDate == expected)
        #expect(parsed.isDueDateOnly)
    }

    @Test("A timed drop retains the original wall clock across a DST change")
    func timedDropKeepsLocalClock() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let task = TaskItem(title: "Timed drag")
        // 18:45:23 PDT on July 15 and 18:45:23 PST on the selected November day.
        task.dueDate = try instant("2026-07-16T01:45:23Z")
        context.insert(task)
        try context.save()

        let selectedDay = try instant("2026-11-01T20:00:00Z")
        let expected = try instant("2026-11-02T02:45:23Z")
        let calendar = try calendar(in: "America/Los_Angeles")
        #expect(CalendarTaskRescheduling.reschedule(taskIDs: [task.id], to: selectedDay,
                                                    among: [task], in: context, calendar: calendar))
        let reader = ModelContext(container)
        let reloaded = try #require(reader.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(reloaded.dueDate == expected)
        #expect(!reloaded.isDueDateOnly)
        let ics = ICalendarSerializer.serialize(uid: reloaded.uid, summary: reloaded.title,
                                                dueDate: reloaded.dueDate, isDueDateOnly: reloaded.isDueDateOnly)
        #expect(ics.contains("DUE:20261102T024523Z\r\n"))
        let parsed = try #require(try ICalendarParser.parseSingleVTODO(from: ics))
        #expect(parsed.dueDate == expected)
        #expect(!parsed.isDueDateOnly)
    }

    @Test("A task deleted while its drag is in flight is ignored")
    func deletionDuringDragDoesNotReschedule() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let task = TaskItem(title: "Removed during drag")
        let original = try instant("2026-07-15T00:00:00Z")
        task.dueDate = original
        task.isDueDateOnly = true
        context.insert(task)
        try context.save()
        let dragID = task.id
        let staleScope = [task]

        // A CalDAV task remains in the store as a pending remote deletion.
        task.isDeletedLocally = true
        try context.save()

        let destination = try instant("2026-11-01T20:00:00Z")
        #expect(!CalendarTaskRescheduling.reschedule(taskIDs: [dragID], to: destination,
                                                     among: staleScope, in: context))
        #expect(task.dueDate == original)
    }

    @Test("A hard-deleted drag cannot touch its retained row or a task outside the calendar scope")
    func hardDeletionAndScope() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let original = try instant("2026-07-15T00:00:00Z")
        let destination = try instant("2026-11-02T00:00:00Z")
        let detached = TaskItem(title: "Deleted in this context")
        let stale = TaskItem(title: "Deleted in another context")
        let retained = TaskItem(title: "Still in this calendar")
        let outside = TaskItem(title: "Outside this calendar")
        for task in [detached, stale, retained, outside] {
            task.dueDate = original
            task.isDueDateOnly = true
            context.insert(task)
        }
        try context.save()
        let dragIDs = [detached.id, stale.id, retained.id, outside.id]
        let scope = [detached, stale, retained]

        let otherContext = ModelContext(container)
        let otherRow = try #require(otherContext.model(for: stale.persistentModelID) as? TaskItem)
        otherContext.delete(otherRow)
        try otherContext.save()
        #expect(stale.modelContext === context, "the second context's deletion leaves an attached stale row")
        context.delete(detached)
        try context.save()
        #expect(detached.modelContext == nil)

        let utc = try calendar(in: "UTC")
        #expect(CalendarTaskRescheduling.reschedule(taskIDs: dragIDs, to: destination, among: scope,
                                                    in: context, calendar: utc))
        let reader = ModelContext(container)
        let saved = try reader.fetch(FetchDescriptor<TaskItem>())
        #expect(saved.count == 2)
        #expect(saved.first { $0.title == "Still in this calendar" }?.dueDate == destination)
        #expect(saved.first { $0.title == "Outside this calendar" }?.dueDate == original)
    }

    @Test("A Calendar drop refuses before either date changes when a participant is read-only")
    func readOnlyDragRefusesWholeWriteSet() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let writableList = TaskList(serverURL: "", name: "Writable", colorHex: "#FF0000")
        let readOnlyList = TaskList(serverURL: "", name: "Shared", colorHex: "#FF0000")
        let writable = TaskItem(title: "Writable")
        let readOnly = TaskItem(title: "Read-only")
        let unrelated = TaskItem(title: "Peer")
        let original = try instant("2026-07-15T00:00:00Z")
        let destination = try instant("2026-11-02T00:00:00Z")
        readOnlyList.isReadOnly = true
        context.insert(writableList)
        context.insert(readOnlyList)
        for task in [writable, readOnly, unrelated] {
            task.dueDate = original
            task.isDueDateOnly = true
            task.isDirty = false
            context.insert(task)
        }
        writable.taskList = writableList
        readOnly.taskList = readOnlyList
        let writableID = writable.id
        let readOnlyID = readOnly.id
        try context.save()
        let error = ErrorState()
        #expect(!CalendarTaskRescheduling.reschedule(taskIDs: [writableID, readOnlyID], to: destination,
            among: [writable, readOnly], in: context, errorState: error, calendar: try calendar(in: "UTC")))
        #expect(error.currentError != nil)
        #expect(writable.dueDate == original && readOnly.dueDate == original)
        #expect(!writable.isDirty && !readOnly.isDirty)
        unrelated.title = "Unrelated edit"
        try context.save()
        let reader = ModelContext(container)
        let rows = try reader.fetch(FetchDescriptor<TaskItem>())
        #expect(rows.filter { $0.id == writableID || $0.id == readOnlyID }.count == 2)
        #expect(rows.allSatisfy { $0.dueDate == original && !$0.isDirty })
        #expect(try ReminderSchedulingJournal.capture(in: reader).isEmpty)
        withExtendedLifetime(container) {}
    }

    private func instant(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    private func calendar(in zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }
}
