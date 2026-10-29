import Testing
import Foundation

@testable import NowThis

// MARK: - VALARM Parser Tests

@Suite("ICalendarParser VALARM")
struct ICalendarParserVALARMTests {

    @Test("Parse VTODO with VALARM trigger -PT15M")
    func parseVALARM15Min() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:alarm-test-1
        SUMMARY:Task with 15min reminder
        DUE:20240615T120000Z
        BEGIN:VALARM
        TRIGGER;VALUE=DURATION:-PT15M
        ACTION:DISPLAY
        DESCRIPTION:Reminder
        END:VALARM
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo?.alarmTriggerSeconds == 900)
    }

    @Test("Parse VTODO with VALARM trigger -PT1H")
    func parseVALARM1Hour() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:alarm-test-2
        SUMMARY:Task with 1hr reminder
        BEGIN:VALARM
        TRIGGER;VALUE=DURATION:-PT1H
        ACTION:DISPLAY
        DESCRIPTION:Reminder
        END:VALARM
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo?.alarmTriggerSeconds == 3600)
    }

    @Test("Parse VTODO with VALARM trigger -P1D")
    func parseVALARM1Day() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:alarm-test-3
        SUMMARY:Task with 1day reminder
        BEGIN:VALARM
        TRIGGER;VALUE=DURATION:-P1D
        ACTION:DISPLAY
        DESCRIPTION:Reminder
        END:VALARM
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo?.alarmTriggerSeconds == 86400)
    }

    @Test("Parse VTODO with VALARM trigger PT0S (at due time)")
    func parseVALARMAtDueTime() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:alarm-test-4
        SUMMARY:Reminder at due time
        BEGIN:VALARM
        TRIGGER;VALUE=DURATION:PT0S
        ACTION:DISPLAY
        DESCRIPTION:Reminder
        END:VALARM
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo?.alarmTriggerSeconds == 0)
    }

    @Test("Parse VTODO with compound VALARM trigger -PT1H30M")
    func parseVALARMCompound() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:alarm-test-5
        SUMMARY:Compound reminder
        BEGIN:VALARM
        TRIGGER;VALUE=DURATION:-PT1H30M
        ACTION:DISPLAY
        DESCRIPTION:Reminder
        END:VALARM
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo?.alarmTriggerSeconds == 5400)
    }

    @Test("Parse VTODO without VALARM has nil alarmTriggerSeconds")
    func parseNoVALARM() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:no-alarm-test
        SUMMARY:No reminder
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo?.alarmTriggerSeconds == nil)
    }

    @Test("VALARM DESCRIPTION does not overwrite VTODO DESCRIPTION")
    func valarmDescriptionIsolated() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:desc-test
        SUMMARY:Important task
        DESCRIPTION:This is the real task description
        BEGIN:VALARM
        TRIGGER;VALUE=DURATION:-PT5M
        ACTION:DISPLAY
        DESCRIPTION:Reminder
        END:VALARM
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo?.description == "This is the real task description")
        #expect(todo?.alarmTriggerSeconds == 300)
    }

    @Test("Only first VALARM is used when multiple exist")
    func multipleVALARMs() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:multi-alarm
        SUMMARY:Multi alarm task
        BEGIN:VALARM
        TRIGGER;VALUE=DURATION:-PT15M
        ACTION:DISPLAY
        DESCRIPTION:First
        END:VALARM
        BEGIN:VALARM
        TRIGGER;VALUE=DURATION:-PT1H
        ACTION:EMAIL
        DESCRIPTION:Second
        END:VALARM
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo?.alarmTriggerSeconds == 900)
    }

    @Test("An invalid first alarm does not hide a later valid reminder", arguments: [
        "P", "-PT", "-P1DT", "20261015T120000Z"
    ])
    func invalidAlarmDoesNotHideValidAlarm(trigger: String) throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:recover-alarm
        SUMMARY:Task with a usable reminder
        DUE:20501015T120000Z
        BEGIN:VALARM
        TRIGGER:\(trigger)
        ACTION:DISPLAY
        END:VALARM
        BEGIN:VALARM
        TRIGGER:-PT15M
        ACTION:DISPLAY
        END:VALARM
        END:VTODO
        END:VCALENDAR
        """

        let todo = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(todo?.alarmTriggerSeconds == 900)
    }
}

// MARK: - Duration Parsing Tests

@Suite("ICalendarParser Duration Parsing")
struct ICalendarParserDurationTests {

    @Test("An oversized server alarm does not crash duration parsing", arguments: [
        "-P106751991167301D", "-P15250284452472W", "-PT2562047788015216H",
        "-PT153722867280912931M", "-PT9223372036854775808S",
        "-P106751991167300DT15H30M8S"
    ])
    func rejectsOverflowingDuration(duration: String) {
        #expect(ICalendarParser.parseDurationToSeconds(duration) == nil)
    }

    @Test("The largest representable second offset remains valid")
    func acceptsMaximumSeconds() {
        #expect(ICalendarParser.parseDurationToSeconds("-PT9223372036854775807S") == Int.max)
    }

    @Test("Truncated and out-of-order durations are not converted to reminders", arguments: [
        "P", "PT", "P1", "P1DT", "PT1", "PT1H30", "PT1H1H", "PT1M1H",
        "P1W1D", "P1DT1DT1H", "PT1HT1M", "P1D2D", "PT1.5H", "PT１H"
    ])
    func rejectsMalformedDuration(duration: String) {
        #expect(ICalendarParser.parseDurationToSeconds(duration) == nil)
    }

    @Test("Valid zero, week and compound durations keep their offsets", arguments: [
        ("P0D", 0), ("-P2W", 1_209_600), ("-P1DT2H3M4S", 93_784),
        ("PT30S", 30), ("-PT1H0M20S", 3_620)
    ])
    func supportedDurationForms(duration: String, seconds: Int) {
        #expect(ICalendarParser.parseDurationToSeconds(duration) == seconds)
    }

    @Test("Parse -PT15M to 900 seconds")
    func parsePT15M() {
        let result = ICalendarParser.parseDurationToSeconds("-PT15M")
        #expect(result == 900)
    }

    @Test("Parse -PT1H to 3600 seconds")
    func parsePT1H() {
        let result = ICalendarParser.parseDurationToSeconds("-PT1H")
        #expect(result == 3600)
    }

    @Test("Parse -P1D to 86400 seconds")
    func parseP1D() {
        let result = ICalendarParser.parseDurationToSeconds("-P1D")
        #expect(result == 86400)
    }

    @Test("Parse -PT1H30M to 5400 seconds")
    func parsePT1H30M() {
        let result = ICalendarParser.parseDurationToSeconds("-PT1H30M")
        #expect(result == 5400)
    }

    @Test("Parse PT0S to 0 seconds")
    func parsePT0S() {
        let result = ICalendarParser.parseDurationToSeconds("PT0S")
        #expect(result == 0)
    }

    @Test("Parse -PT5M to 300 seconds")
    func parsePT5M() {
        let result = ICalendarParser.parseDurationToSeconds("-PT5M")
        #expect(result == 300)
    }

    @Test("Parse -PT30M to 1800 seconds")
    func parsePT30M() {
        let result = ICalendarParser.parseDurationToSeconds("-PT30M")
        #expect(result == 1800)
    }

    @Test("Invalid duration returns nil")
    func parseInvalid() {
        let result = ICalendarParser.parseDurationToSeconds("garbage")
        #expect(result == nil)
    }
}
