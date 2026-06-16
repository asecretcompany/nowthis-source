import Testing
import Foundation

@testable import NowThis

// MARK: - ICalendarParser Tests

@Suite("ICalendarParser")
struct ICalendarParserTests {

    // MARK: - Basic Parsing

    @Test("Parse basic VTODO with all standard properties")
    func parseBasicVTODO() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Nextcloud//Tasks//EN
        BEGIN:VTODO
        UID:abc-123-def
        SUMMARY:Buy groceries
        DESCRIPTION:Milk\\, eggs\\, and bread
        STATUS:NEEDS-ACTION
        PRIORITY:1
        PERCENT-COMPLETE:25
        DUE:20240615T120000Z
        DTSTART:20240610T090000Z
        CREATED:20240601T080000Z
        LAST-MODIFIED:20240612T150000Z
        CATEGORIES:Shopping,Errands
        LOCATION:Whole Foods
        GEO:37.7749;-122.4194
        URL:https://example.com/list
        END:VTODO
        END:VCALENDAR
        """

        let todos = try ICalendarParser.parseVTODOs(from: ics)
        #expect(todos.count == 1)

        let todo = todos[0]
        #expect(todo.uid == "abc-123-def")
        #expect(todo.summary == "Buy groceries")
        #expect(todo.description == "Milk, eggs, and bread")
        #expect(todo.status == "NEEDS-ACTION")
        #expect(todo.priority == 1)
        #expect(todo.percentComplete == 25)
        #expect(todo.categories == ["Shopping", "Errands"])
        #expect(todo.location == "Whole Foods")
        #expect(todo.latitude == 37.7749)
        #expect(todo.longitude == -122.4194)
        #expect(todo.url == "https://example.com/list")
        #expect(todo.dueDate != nil)
        #expect(todo.startDate != nil)
        #expect(todo.createdDate != nil)
        #expect(todo.lastModifiedDate != nil)
    }

    @Test("Parse VTODO with RELATED-TO parent")
    func parseParentRelation() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:child-task-1
        SUMMARY:Subtask
        RELATED-TO;RELTYPE=PARENT:parent-task-1
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo?.parentUID == "parent-task-1")
    }

    @Test("Parse VTODO with RRULE")
    func parseRecurrence() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:recurring-1
        SUMMARY:Weekly standup
        RRULE:FREQ=WEEKLY;BYDAY=MO
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo?.recurrenceRule == "FREQ=WEEKLY;BYDAY=MO")
    }

    @Test("Parse multiple VTODOs from single file")
    func parseMultiple() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:task-1
        SUMMARY:First
        END:VTODO
        BEGIN:VTODO
        UID:task-2
        SUMMARY:Second
        END:VTODO
        BEGIN:VTODO
        UID:task-3
        SUMMARY:Third
        END:VTODO
        END:VCALENDAR
        """

        let todos = try ICalendarParser.parseVTODOs(from: ics)
        #expect(todos.count == 3)
        #expect(todos[0].summary == "First")
        #expect(todos[1].summary == "Second")
        #expect(todos[2].summary == "Third")
    }

    @Test("Skip VTODO without UID")
    func skipMissingUID() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        SUMMARY:No UID task
        END:VTODO
        END:VCALENDAR
        """

        let todos = try ICalendarParser.parseVTODOs(from: ics)
        #expect(todos.isEmpty)
    }

    // MARK: - Line Unfolding

    @Test("Unfold long lines per RFC-5545")
    func unfoldLines() {
        let folded = "DESCRIPTION:This is a very long line that has been\r\n folded across multiple\r\n lines in the file"
        let unfolded = ICalendarParser.unfoldLines(folded)
        #expect(unfolded == "DESCRIPTION:This is a very long line that has beenfolded across multiplelines in the file")
    }

    @Test("Unfold with tab continuation")
    func unfoldWithTab() {
        let folded = "SUMMARY:Hello\n\tWorld"
        let unfolded = ICalendarParser.unfoldLines(folded)
        #expect(unfolded == "SUMMARY:HelloWorld")
    }

    // MARK: - Date Parsing

    @Test("Parse UTC date-time (Z suffix)")
    func parseDateTimeUTC() {
        let date = ICalendarParser.parseDate("20240115T120000Z")
        #expect(date != nil)

        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: date!)
        #expect(components.year == 2024)
        #expect(components.month == 1)
        #expect(components.day == 15)
        #expect(components.hour == 12)
    }

    @Test("Parse local date-time (no Z)")
    func parseDateTimeLocal() {
        let date = ICalendarParser.parseDate("20240115T120000")
        #expect(date != nil)
    }

    @Test("Parse date-only")
    func parseDateOnly() {
        let date = ICalendarParser.parseDate("20240115")
        #expect(date != nil)
    }

    // MARK: - Text Unescaping

    @Test("Unescape newlines")
    func unescapeNewlines() {
        let result = ICalendarParser.unescapeText("Line 1\\nLine 2\\NLine 3")
        #expect(result == "Line 1\nLine 2\nLine 3")
    }

    @Test("Unescape commas and semicolons")
    func unescapeCommasSemicolons() {
        let result = ICalendarParser.unescapeText("Hello\\, World\\; Goodbye")
        #expect(result == "Hello, World; Goodbye")
    }

    @Test("Unescape backslashes")
    func unescapeBackslash() {
        let result = ICalendarParser.unescapeText("Path\\\\to\\\\file")
        #expect(result == "Path\\to\\file")
    }

    // MARK: - Property Splitting

    @Test("Split simple property")
    func splitSimple() {
        let (name, value) = ICalendarParser.splitProperty("SUMMARY:My Task")
        #expect(name == "SUMMARY")
        #expect(value == "My Task")
    }

    @Test("Split property with parameters")
    func splitWithParams() {
        let (name, value) = ICalendarParser.splitProperty("DTSTART;VALUE=DATE:20240115")
        #expect(name == "DTSTART")
        #expect(value == "20240115")
    }

    @Test("Split RELATED-TO with RELTYPE parameter")
    func splitRelatedTo() {
        let (name, value) = ICalendarParser.splitProperty("RELATED-TO;RELTYPE=PARENT:parent-uid-123")
        #expect(name == "RELATED-TO")
        #expect(value == "parent-uid-123")
    }

    // MARK: - Status Parsing

    @Test("Parse all RFC-5545 VTODO statuses")
    func parseAllStatuses() throws {
        let statuses = ["NEEDS-ACTION", "IN-PROCESS", "COMPLETED", "CANCELLED"]

        for status in statuses {
            let ics = """
            BEGIN:VCALENDAR
            BEGIN:VTODO
            UID:\(status)-test
            SUMMARY:\(status) task
            STATUS:\(status)
            END:VTODO
            END:VCALENDAR
            """

            let todo = try ICalendarParser.parseSingleVTODO(from: ics)
            #expect(todo?.status == status)
        }
    }
}
