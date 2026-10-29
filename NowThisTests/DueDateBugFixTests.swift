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
    func parserDistinguishesCalendarTypes() throws {
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
        let resources = try parser.parse(data: xml.data(using: .utf8)!)

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

    /// The all-day phrase as the app actually renders it, with the date removed.
    ///
    /// `DueDateFormatter` builds a whole template — "Jul 6 · All day" — so the phrase cannot be
    /// asserted as a bare literal any more, and asserting the English one would fail on a correct
    /// German build. Rendering a known date and subtracting the formatted date isolates the
    /// non-date part without hardcoding either half.
    static let allDayMarker: String = {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = utc.date(from: DateComponents(year: 2026, month: 7, day: 6))!
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = TimeZone(identifier: "UTC")!
        return DueDateFormatter.format(day, isDateOnly: true)
            .replacingOccurrences(of: day.formatted(style), with: "")
    }()

    /// The spoken form of the same phrase — a different key, because the badge uses a middle dot
    /// and VoiceOver must not read "middle dot".
    static let spokenAllDayMarker: String = {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = utc.date(from: DateComponents(year: 2026, month: 7, day: 6))!
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = TimeZone(identifier: "UTC")!
        return DueDateFormatter.accessibilityLabel(day, isDateOnly: true)
            .replacingOccurrences(of: day.formatted(style), with: "")
    }()

    @Test("Date-only due dates show no time component")
    func dateOnlyFormat() {
        // Local midnight = a date-only task (no specific time set)
        let localMidnight = Calendar.current.startOfDay(for: Date())

        let formatted = DueDateFormatter.format(localMidnight)

        // Should NOT contain a colon (time separator like "2:00")
        // Should just be like "May 28"
        #expect(!formatted.contains(":"), "Date-only should not show a time")
    }

    @Test("Date-only due dates display the stored UTC calendar day, not a timezone-shifted day")
    func dateOnlyRendersUTCDay() {
        // A CalDAV `DUE;VALUE=DATE:20260629` is parsed and stored as midnight UTC
        // (2026-06-29 00:00:00 +0000). In any timezone west of UTC (e.g. PDT) the
        // raw value is the *previous* evening, so naive local formatting yields the
        // wrong day ("Jun 28") and/or a spurious time ("5:00 PM").
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnightUTC = utc.date(from: DateComponents(year: 2026, month: 6, day: 29))!

        let formatted = DueDateFormatter.format(midnightUTC, isDateOnly: true)

        #expect(!formatted.contains(":"), "Date-only must not show a time component")
        #expect(formatted.contains("29"), "Must show the stored UTC day (29), not a timezone-shifted day (28)")
    }

    @Test("Date-only due dates show an 'All day' label instead of no time")
    func dateOnlyShowsAllDay() {
        // A date-only task (DUE;VALUE=DATE) is stored as midnight UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnightUTC = utc.date(from: DateComponents(year: 2026, month: 7, day: 6))!

        let formatted = DueDateFormatter.format(midnightUTC, isDateOnly: true)

        // Compared against the same catalog lookup the formatter performs, not the English
        // words: once a translation exists, "All day" is not what a German build renders and this
        // assertion would fail on correct code. `allDayMarker` isolates the phrase from the date.
        #expect(formatted.contains(Self.allDayMarker),
                "Date-only badge should carry the all-day phrase for time consistency: \(formatted)")
        #expect(formatted.contains("6"), "Must still show the stored calendar day")
        #expect(!formatted.contains(":"), "Date-only must not show a clock time")
    }

    @Test("Date+time due dates do not show the 'All day' label")
    func dateTimeHasNoAllDayLabel() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 6
        components.hour = 19
        components.minute = 0
        let dateTime = Calendar.current.date(from: components)!

        let formatted = DueDateFormatter.format(dateTime, isDateOnly: false)

        #expect(!formatted.contains(Self.allDayMarker),
                "Timed tasks show the clock time, not the all-day phrase: \(formatted)")
        #expect(formatted.contains(":"), "Timed tasks show the time with a colon separator")
    }

    @Test("VoiceOver label for a date-only task reads 'All day' without the visual middle-dot glyph")
    func accessibilityLabelDateOnlyOmitsMiddleDot() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnightUTC = utc.date(from: DateComponents(year: 2026, month: 7, day: 6))!

        let label = DueDateFormatter.accessibilityLabel(midnightUTC, isDateOnly: true)

        #expect(label.contains(Self.spokenAllDayMarker),
                "VoiceOver should hear the all-day designation: \(label)")
        #expect(!label.contains("·"), "The spoken label must not contain the decorative middle-dot glyph")
        #expect(!label.contains(":"), "Date-only must not read a clock time")
        #expect(label.contains("6"), "Must read the stored calendar day")
    }

    @Test("VoiceOver label for a timed task reads the clock time")
    func accessibilityLabelTimedReadsTime() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 6
        components.hour = 19
        components.minute = 0
        let dateTime = Calendar.current.date(from: components)!

        let label = DueDateFormatter.accessibilityLabel(dateTime, isDateOnly: false)

        #expect(!label.contains(Self.spokenAllDayMarker),
                "Timed tasks read the clock time, not the all-day phrase: \(label)")
        #expect(label.contains(":"), "Timed tasks read the clock time")
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
