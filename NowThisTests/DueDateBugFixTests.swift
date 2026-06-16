import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Calendar Discovery Filter Tests

@Suite("Calendar Discovery Filter")
struct CalendarDiscoveryFilterTests {

    @Test("VTODO-only filter excludes VEVENT-only calendars")
    func filterExcludesVEVENTOnly() {
        // Simulate DAV resources from a Nextcloud server
        var vtodoCal = DAVXMLParser.DAVResource()
        vtodoCal.href = "/remote.php/dav/calendars/user/tasks/"
        vtodoCal.isVTODOSupported = true
        vtodoCal.isCalendar = true
        vtodoCal.displayName = "Tasks"

        var veventCal = DAVXMLParser.DAVResource()
        veventCal.href = "/remote.php/dav/calendars/user/personal/"
        veventCal.isVTODOSupported = false
        veventCal.isCalendar = true
        veventCal.displayName = "Personal Calendar"

        var mixedCal = DAVXMLParser.DAVResource()
        mixedCal.href = "/remote.php/dav/calendars/user/reminder/"
        mixedCal.isVTODOSupported = true
        mixedCal.isCalendar = true
        mixedCal.displayName = "Reminder"

        let resources = [vtodoCal, veventCal, mixedCal]

        // The correct filter: only calendars that support VTODO
        let filtered = resources.filter { $0.isVTODOSupported }

        #expect(filtered.count == 2, "Should include VTODO and mixed calendars, exclude VEVENT-only")
        let hrefs = Set(filtered.map(\.href))
        #expect(hrefs.contains("/remote.php/dav/calendars/user/tasks/"))
        #expect(hrefs.contains("/remote.php/dav/calendars/user/reminder/"))
        #expect(!hrefs.contains("/remote.php/dav/calendars/user/personal/"))
    }

    @Test("DAVXMLParser correctly distinguishes VTODO vs VEVENT calendars")
    func parserDistinguishesCalendarTypes() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:multistatus xmlns:d="DAV:"
                       xmlns:cs="http://calendarserver.org/ns/"
                       xmlns:c="urn:ietf:params:xml:ns:caldav"
                       xmlns:x="http://apple.com/ns/ical/">
          <d:response>
            <d:href>/calendars/user/tasks/</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>Tasks</d:displayname>
                <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
                <c:supported-calendar-component-set>
                  <c:comp name="VTODO"/>
                </c:supported-calendar-component-set>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/calendars/user/personal/</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>Personal</d:displayname>
                <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
                <c:supported-calendar-component-set>
                  <c:comp name="VEVENT"/>
                </c:supported-calendar-component-set>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

        let parser = DAVXMLParser()
        let resources = parser.parse(data: xml.data(using: .utf8)!)

        let tasksCalendar = resources.first(where: { $0.href.contains("tasks") })
        #expect(tasksCalendar?.isVTODOSupported == true)
        #expect(tasksCalendar?.isCalendar == true)

        let personalCalendar = resources.first(where: { $0.href.contains("personal") })
        #expect(personalCalendar?.isVTODOSupported == false)
        #expect(personalCalendar?.isCalendar == true)

        // Only VTODO calendars should be included in task sync
        let taskCalendars = resources.filter { $0.isVTODOSupported }
        #expect(taskCalendars.count == 1)
    }
}

// MARK: - UID Deduplication Tests

@Suite("UID Deduplication")
struct UIDDeduplicationTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self,
            configurations: config
        )
    }

    @Test("deduplicateByUID removes tasks with duplicate UIDs, keeping first")
    func removeDuplicateUIDs() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let task1 = TaskItem(id: "id-1", uid: "uid-A", title: "Pay the pet license")
        let task2 = TaskItem(id: "id-2", uid: "uid-A", title: "Pay the pet license") // duplicate UID
        let task3 = TaskItem(id: "id-3", uid: "uid-B", title: "Practice guitar")

        context.insert(task1)
        context.insert(task2)
        context.insert(task3)

        let result = TaskListHelpers.deduplicateByUID([task1, task2, task3])

        #expect(result.count == 2, "Should have 2 tasks after removing duplicate UID")
        #expect(result[0].id == "id-1", "Should keep the first occurrence")
        #expect(result[1].id == "id-3", "Second unique task preserved")
    }

    @Test("deduplicateByUID preserves order of unique tasks")
    func preservesOrder() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let task1 = TaskItem(id: "id-1", uid: "uid-A", title: "First")
        let task2 = TaskItem(id: "id-2", uid: "uid-B", title: "Second")
        let task3 = TaskItem(id: "id-3", uid: "uid-C", title: "Third")

        context.insert(task1)
        context.insert(task2)
        context.insert(task3)

        let result = TaskListHelpers.deduplicateByUID([task1, task2, task3])

        #expect(result.count == 3)
        #expect(result[0].title == "First")
        #expect(result[1].title == "Second")
        #expect(result[2].title == "Third")
    }

    @Test("deduplicateByUID handles empty input")
    func emptyInput() {
        let result = TaskListHelpers.deduplicateByUID([])
        #expect(result.isEmpty)
    }
}

// MARK: - Due Date Formatting Tests

@Suite("Due Date Formatting")
struct DueDateFormattingTests {

    @Test("Date-only due dates show no time component")
    func dateOnlyFormat() {
        // Local midnight = a date-only task (no specific time set)
        let localMidnight = Calendar.current.startOfDay(for: Date())

        let formatted = DueDateFormatter.format(localMidnight)

        // Should NOT contain a colon (time separator like "2:00")
        // Should just be like "May 28"
        #expect(!formatted.contains(":"), "Date-only should not show a time")
    }

    @Test("Due dates with a specific time show the time")
    func dateTimeFormat() {
        // 2:00 PM local time — has a meaningful time component
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 28
        components.hour = 14
        components.minute = 0
        let dateTime = Calendar.current.date(from: components)!

        let formatted = DueDateFormatter.format(dateTime)

        // Should contain time info — the formatted string should be longer
        // than just "May 28" and include a time component
        #expect(formatted.count > 6, "Date+time format should include time info")
        // A formatted time typically contains ":" (e.g., "2:00 PM")
        #expect(formatted.contains(":"), "Should show the time with a colon separator")
    }
}
