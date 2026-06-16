import Testing
import Foundation

@testable import NowThis

// MARK: - VALARM Serializer Tests

@Suite("ICalendarSerializer VALARM")
struct ICalendarSerializerVALARMTests {

    @Test("Serialize with 15-minute alarm emits VALARM block")
    func serializeVALARM15Min() {
        let ics = ICalendarSerializer.serialize(
            uid: "alarm-ser-1",
            summary: "Task with alarm",
            alarmTriggerSeconds: 900
        )

        #expect(ics.contains("BEGIN:VALARM"))
        #expect(ics.contains("END:VALARM"))
        #expect(ics.contains("TRIGGER;VALUE=DURATION:-PT15M"))
        #expect(ics.contains("ACTION:DISPLAY"))
    }

    @Test("Serialize with 1-hour alarm")
    func serializeVALARM1Hour() {
        let ics = ICalendarSerializer.serialize(
            uid: "alarm-ser-2",
            summary: "1hr alarm",
            alarmTriggerSeconds: 3600
        )

        #expect(ics.contains("TRIGGER;VALUE=DURATION:-PT1H"))
    }

    @Test("Serialize with 1-day alarm")
    func serializeVALARM1Day() {
        let ics = ICalendarSerializer.serialize(
            uid: "alarm-ser-3",
            summary: "1day alarm",
            alarmTriggerSeconds: 86400
        )

        #expect(ics.contains("TRIGGER;VALUE=DURATION:-P1D"))
    }

    @Test("Serialize with 0-second alarm (at due time)")
    func serializeVALARMAtDue() {
        let ics = ICalendarSerializer.serialize(
            uid: "alarm-ser-4",
            summary: "At due time",
            alarmTriggerSeconds: 0
        )

        #expect(ics.contains("BEGIN:VALARM"))
        #expect(ics.contains("TRIGGER;VALUE=DURATION:PT0S"))
    }

    @Test("Serialize without alarm omits VALARM block")
    func serializeNoVALARM() {
        let ics = ICalendarSerializer.serialize(
            uid: "no-alarm-ser",
            summary: "No alarm"
        )

        #expect(!ics.contains("BEGIN:VALARM"))
        #expect(!ics.contains("END:VALARM"))
        #expect(!ics.contains("TRIGGER"))
    }

    @Test("VALARM block appears before END:VTODO")
    func valarmBeforeEndVTODO() {
        let ics = ICalendarSerializer.serialize(
            uid: "order-test",
            summary: "Order test",
            alarmTriggerSeconds: 900
        )

        guard let endAlarmIdx = ics.range(of: "END:VALARM")?.lowerBound,
              let endTodoIdx = ics.range(of: "END:VTODO")?.lowerBound else {
            Issue.record("VALARM or VTODO end marker not found")
            return
        }
        #expect(endAlarmIdx < endTodoIdx)
    }

    @Test("Roundtrip: serialize then parse VALARM preserves offset")
    func valarmRoundtrip() throws {
        let ics = ICalendarSerializer.serialize(
            uid: "roundtrip-alarm",
            summary: "Roundtrip alarm test",
            alarmTriggerSeconds: 1800
        )

        let parsed = try ICalendarParser.parseSingleVTODO(from: ics)
        #expect(parsed?.alarmTriggerSeconds == 1800)
    }
}

// MARK: - Duration Formatting Tests

@Suite("ICalendarSerializer Duration Formatting")
struct ICalendarSerializerDurationTests {

    @Test("Format 900 seconds as -PT15M")
    func format15Min() {
        let result = ICalendarSerializer.formatDuration(seconds: 900)
        #expect(result == "-PT15M")
    }

    @Test("Format 3600 seconds as -PT1H")
    func format1Hour() {
        let result = ICalendarSerializer.formatDuration(seconds: 3600)
        #expect(result == "-PT1H")
    }

    @Test("Format 86400 seconds as -P1D")
    func format1Day() {
        let result = ICalendarSerializer.formatDuration(seconds: 86400)
        #expect(result == "-P1D")
    }

    @Test("Format 0 seconds as PT0S")
    func formatZero() {
        let result = ICalendarSerializer.formatDuration(seconds: 0)
        #expect(result == "PT0S")
    }

    @Test("Format 5400 seconds as -PT1H30M")
    func formatCompound() {
        let result = ICalendarSerializer.formatDuration(seconds: 5400)
        #expect(result == "-PT1H30M")
    }

    @Test("Format 300 seconds as -PT5M")
    func format5Min() {
        let result = ICalendarSerializer.formatDuration(seconds: 300)
        #expect(result == "-PT5M")
    }
}
