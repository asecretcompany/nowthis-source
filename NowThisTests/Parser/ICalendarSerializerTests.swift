import Testing
import Foundation

@testable import NowThis

// MARK: - ICalendarSerializer Tests

@Suite("ICalendarSerializer")
struct ICalendarSerializerTests {

    @Test("Serialize basic VTODO")
    func serializeBasic() {
        let ics = ICalendarSerializer.serialize(
            uid: "test-uid-123",
            summary: "Buy milk"
        )

        #expect(ics.contains("BEGIN:VCALENDAR"))
        #expect(ics.contains("END:VCALENDAR"))
        #expect(ics.contains("BEGIN:VTODO"))
        #expect(ics.contains("END:VTODO"))
        #expect(ics.contains("UID:test-uid-123"))
        #expect(ics.contains("SUMMARY:Buy milk"))
        #expect(ics.contains("VERSION:2.0"))
        #expect(ics.contains("PRODID:-//NowThis//NowThis iOS//EN"))
    }

    @Test("Serialize with description")
    func serializeDescription() {
        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Task",
            description: "This is a detailed description"
        )

        #expect(ics.contains("DESCRIPTION:This is a detailed description"))
    }

    @Test("Serialize with priority")
    func serializePriority() {
        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Urgent",
            priority: 1
        )

        #expect(ics.contains("PRIORITY:1"))
    }

    @Test("Zero priority is omitted")
    func zeroPriorityOmitted() {
        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Normal",
            priority: 0
        )

        #expect(!ics.contains("PRIORITY:"))
    }

    @Test("Serialize with categories")
    func serializeCategories() {
        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Tagged task",
            categories: ["Work", "Important"]
        )

        #expect(ics.contains("CATEGORIES:Work,Important"))
    }

    @Test("Serialize with GEO coordinates")
    func serializeGeo() {
        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Geo task",
            latitude: 37.7749,
            longitude: -122.4194
        )

        #expect(ics.contains("GEO:37.7749;-122.4194"))
    }

    @Test("Serialize with parent UID")
    func serializeParentUID() {
        let ics = ICalendarSerializer.serialize(
            uid: "child-uid",
            summary: "Child task",
            parentUID: "parent-uid"
        )

        #expect(ics.contains("RELATED-TO;RELTYPE=PARENT:parent-uid"))
    }

    @Test("Serialize with RRULE")
    func serializeRRule() {
        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Recurring",
            recurrenceRule: "FREQ=DAILY;COUNT=5"
        )

        #expect(ics.contains("RRULE:FREQ=DAILY;COUNT=5"))
    }

    @Test("Empty description is not serialized")
    func emptyDescriptionOmitted() {
        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "No desc",
            description: ""
        )

        #expect(!ics.contains("DESCRIPTION:"))
    }

    @Test("CRLF line endings in output")
    func crlfLineEndings() {
        let ics = ICalendarSerializer.serialize(
            uid: "test-uid",
            summary: "Line test"
        )

        #expect(ics.contains("\r\n"))
    }

    // MARK: - Text Escaping

    @Test("Escape commas in summary")
    func escapeCommas() {
        let escaped = ICalendarSerializer.escapeText("Hello, World")
        #expect(escaped == "Hello\\, World")
    }

    @Test("Escape semicolons")
    func escapeSemicolons() {
        let escaped = ICalendarSerializer.escapeText("A; B; C")
        #expect(escaped == "A\\; B\\; C")
    }

    @Test("Escape newlines")
    func escapeNewlines() {
        let escaped = ICalendarSerializer.escapeText("Line 1\nLine 2")
        #expect(escaped == "Line 1\\nLine 2")
    }

    @Test("Escape backslashes")
    func escapeBackslash() {
        let escaped = ICalendarSerializer.escapeText("path\\to\\file")
        #expect(escaped == "path\\\\to\\\\file")
    }

    // MARK: - Date Formatting

    @Test("Format date to UTC with Z suffix")
    func formatDateUTC() {
        let components = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "UTC"),
            year: 2024, month: 6, day: 15,
            hour: 12, minute: 30, second: 45
        )
        let date = components.date!
        let formatted = ICalendarSerializer.formatDate(date)
        #expect(formatted == "20240615T123045Z")
    }

    // MARK: - Line Folding

    @Test("Short line is not folded")
    func shortLineNotFolded() {
        let result = ICalendarSerializer.foldLine("SUMMARY:Short")
        #expect(result == "SUMMARY:Short")
    }

    @Test("Long line is folded at 75 octets")
    func longLineFolded() {
        let longValue = String(repeating: "A", count: 100)
        let line = "SUMMARY:\(longValue)"
        let folded = ICalendarSerializer.foldLine(line)

        #expect(folded.contains("\r\n "))
        // First line should be <= 75 bytes
        let firstLine = folded.components(separatedBy: "\r\n").first ?? ""
        #expect(firstLine.utf8.count <= 75)
    }

    // MARK: - Roundtrip

    @Test("Parse-then-serialize roundtrip preserves UID and summary")
    func roundtrip() throws {
        let original = ICalendarSerializer.serialize(
            uid: "roundtrip-uid",
            summary: "Roundtrip task",
            description: "Testing roundtrip",
            status: "IN-PROCESS",
            priority: 3,
            percentComplete: 50,
            categories: ["Test"],
            location: "Office"
        )

        let parsed = try ICalendarParser.parseSingleVTODO(from: original)
        #expect(parsed?.uid == "roundtrip-uid")
        #expect(parsed?.summary == "Roundtrip task")
        #expect(parsed?.description == "Testing roundtrip")
        #expect(parsed?.status == "IN-PROCESS")
        #expect(parsed?.priority == 3)
        #expect(parsed?.percentComplete == 50)
        #expect(parsed?.categories == ["Test"])
        #expect(parsed?.location == "Office")
    }
}
