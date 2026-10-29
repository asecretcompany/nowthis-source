import Foundation
import Testing
@testable import NowThis

@Suite("Sync resource body validation")
struct SyncBodyValidationTests {
    private func resource(_ body: String) -> CalDAVClient.RemoteTask {
        .init(href: "/tasks/resource.ics", etag: "revision", icsData: body)
    }

    @Test("Malformed task bodies fail instead of being accounted as non-tasks", arguments: [
        "BEGIN:VTODO\nSUMMARY:Missing UID\nEND:VTODO",
        "BEGIN:VTODO\nUID:\nEND:VTODO",
        "BEGIN:VTODO\nUID:task",
        "BEGIN:VCALENDAR\nBEGIN:VTODO\nUID:task\nEND:VCALENDAR",
        "BEGIN:VCALENDAR\nBEGIN:VTODO\nSUMMARY:Missing UID\nEND:VTODO\nEND:VCALENDAR",
        "BEGIN:VTODO\nUID:task\nBEGIN:VALARM\nTRIGGER:-PT5M\nEND:VTODO",
        "BEGIN:VTODO\nUID:task\nEND:VEVENT",
        "END:VTODO\nBEGIN:VTODO\nUID:task\nEND:VTODO",
        "BEGIN:VCALENDAR\nBEGIN:VEVENT\nBEGIN:VTODO\nUID:task\nEND:VTODO\nEND:VEVENT\nEND:VCALENDAR"
    ])
    func rejectsMalformedTask(body: String) {
        do {
            _ = try SyncBodyValidation.parse(resource(body), using: ICalendarParser.FormatterCache())
            Issue.record("Expected invalidResponse for malformed resource")
        } catch CalDAVError.invalidResponse {
            // This resource must not reach import accounting.
        } catch {
            Issue.record("Expected invalidResponse, got \(error)")
        }
    }

    @Test("Incomplete and garbage calendar bodies fail", arguments: [
        "", "not an iCalendar resource", "UID:task",
        "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:event\nEND:VEVENT",
        "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:event\nEND:VTODO\nEND:VCALENDAR",
        "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:event\nEND:VEVENT\nEND:VCALENDAR\ngarbage",
        "BEGIN:VCALENDAR\nBEGIN:VEVENT\ngarbage\nEND:VEVENT\nEND:VCALENDAR",
        "BEGIN:VCALENDAR\nEND:VCALENDAR",
        "BEGIN:WHATEVER\nUID:unknown\nEND:WHATEVER",
        "BEGIN:VCALENDAR\nBEGIN:VCALENDAR\nEND:VCALENDAR\nEND:VCALENDAR"
    ])
    func rejectsInvalidCalendar(body: String) {
        do {
            _ = try SyncBodyValidation.parse(resource(body), using: ICalendarParser.FormatterCache())
            Issue.record("Expected invalidResponse for malformed resource")
        } catch CalDAVError.invalidResponse {
            // This resource must not reach import accounting.
        } catch {
            Issue.record("Expected invalidResponse, got \(error)")
        }
    }

    @Test("Balanced bare VTODO fixtures and complete calendars remain valid", arguments: [
        "BEGIN:VTODO\nUID:task\nSUMMARY:Task\nEND:VTODO",
        "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//NowThis//EN\nBEGIN:VTODO\nUID:task\nSUMMARY:Task\nEND:VTODO\nEND:VCALENDAR"
    ])
    func acceptsTask(body: String) throws {
        let parsed = try SyncBodyValidation.parse(resource(body), using: ICalendarParser.FormatterCache())
        #expect(parsed.todo?.uid == "task")
        #expect(parsed.todo?.summary == "Task")
        #expect(parsed.href == "/tasks/resource.ics")
        #expect(parsed.etag == "revision")
    }

    @Test("Well-formed non-task components keep resource accounting", arguments: ["VEVENT", "VJOURNAL", "VFREEBUSY"])
    func acceptsNonTask(component: String) throws {
        let body = "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//NowThis//EN\nBEGIN:\(component)\nUID:event\nDESCRIPTION:BEGIN:VTODO is just text\nEND:\(component)\nEND:VCALENDAR"
        let parsed = try SyncBodyValidation.parse(resource(body), using: ICalendarParser.FormatterCache())
        #expect(parsed.todo == nil)
        #expect(parsed.href == "/tasks/resource.ics")
        #expect(parsed.etag == "revision")
    }

    @Test("Folded lines, nested alarms and timezones reuse the caller's formatter cache")
    func acceptsFoldedTaskWithAlarm() throws {
        let cache = ICalendarParser.FormatterCache()
        let body = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTIMEZONE\r\nTZID:America/New_York\r\nBEGIN:STANDARD\r\nDTSTART:19701101T020000\r\nTZOFFSETFROM:-0400\r\nTZOFFSETTO:-0500\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\nBEGIN:VTO\r\n DO\r\nUID:folded-\r\n\tuid\r\nSUMMARY;LANGUAGE=en:Folded \r\n title\r\nDUE;TZID=America/New_York:20261008T120000\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT5M\r\nDESCRIPTION:Reminder\r\nEND:VALARM\r\nEND:VTODO\r\nEND:VCALENDAR"
        for _ in 0..<2 {
            let parsed = try SyncBodyValidation.parse(resource(body), using: cache)
            #expect(parsed.todo?.uid == "folded-uid")
            #expect(parsed.todo?.summary == "Folded title")
            #expect(parsed.todo?.alarmTriggerSeconds == 300)
            #expect(parsed.todo?.dueDate != nil)
        }
        #expect(cache.namedTimeZoneFormatterCreationCount == 1)
    }
}
