import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite(.serialized)
@MainActor
struct VTODOOpaquePropertyRoundTripTests {
    @Test("Long parameters do not charge owned text against the opaque budget")
    func longOwnedParametersRemainKnown() throws {
        var limits = ICalendarParser.WorkLimits.default
        limits.maxOpaqueBytes = 8
        let text = "BEGIN:VTODO\nUID:long-parameter\nDESCRIPTION;X-PARAM=\"" + String(repeating: "a", count: 100)
            + "\":accepted\nEND:VTODO"
        let todo = try #require(try ICalendarParser.parseSingleVTODO(from: text, limits: limits))
        #expect(todo.description == "accepted")
        #expect(todo.opaqueProperties.isEmpty)
    }
    @Test func importedUnknownPropertiesAndCompleteAlarmSurviveTitleEdit() throws {
        let container = try ModelContainer(for: Schema(SchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let task = TaskItem(uid: "opaque", title: "Old")
        context.insert(task)
        let data = try #require(try ICalendarParser.parseSingleVTODO(from: """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:opaque
        SUMMARY:Old
        CLASS:PRIVATE
        COMMENT:x
        X-FOO;BAR=1:baz
        SEQUENCE:7
        RELATED-TO;RELTYPE=SIBLING:u2
        BEGIN:VALARM
        ACTION:DISPLAY
        DESCRIPTION:Ping
        TRIGGER:-PT15M
        END:VALARM
        END:VTODO
        END:VCALENDAR
        """))
        try SyncImportStore(context: context).applyFields(data, to: task)
        task.title = "Edited"
        try context.save()
        let output = try SyncPushSnapshot.serialize(task, stamp: Date())
        for line in ["CLASS:PRIVATE", "COMMENT:x", "X-FOO;BAR=1:baz", "SEQUENCE:7", "RELATED-TO;RELTYPE=SIBLING:u2", "DESCRIPTION:Ping"] {
            #expect(ICalendarParser.unfoldLines(output).components(separatedBy: "\n").filter { $0 == line }.count == 1)
        }
    }
    private func parsed(_ content: String) throws -> ICalendarParser.VTODOData {
        try #require(try ICalendarParser.parseSingleVTODO(from: "BEGIN:VTODO\nUID:opaque\nSUMMARY:Original\n" + content + "\nEND:VTODO"))
    }

    @Test func foldedUnicodeAndMultipleAlarmsRemainIdempotent() throws {
        let comment = "COMMENT:" + String(repeating: "雪é", count: 60) + "  "
        let content = "CLASS:PRIVATE\nSEQUENCE:9\nRELATED-TO;reltype=sibling:u2\nRELATED-TO;RELTYPE=PARENT:p\n" + ICalendarSerializer.foldLine(comment) + "\nBEGIN:VALARM\nTRIGGER;VALUE=DATE-TIME:20261023T120000Z\nACTION:EMAIL\nATTENDEE:mailto:a@example.com\nEND:VALARM\nBEGIN:VALARM\nTRIGGER:-PT15M\nACTION:DISPLAY\nDESCRIPTION:Ping\nREPEAT:3\nDURATION:PT1M\nEND:VALARM"
        var data = try parsed(content)
        let original = try VTODOOpaqueState(data)
        #expect(data.parentUID == "p")
        #expect(data.alarmTriggerSeconds == 900)
        #expect(data.alarmBlocks.count == 2)
        #expect(data.opaqueProperties.contains(comment))
        let date = Date(timeIntervalSince1970: 0)
        var previous: String?
        for _ in 0..<3 {
            let output = ICalendarSerializer.serialize(uid: data.uid, summary: "Edited", createdDate: date,
                lastModifiedDate: date, parentUID: data.parentUID, alarmTriggerSeconds: data.alarmTriggerSeconds,
                dtStamp: date, opaqueState: try VTODOOpaqueState(data))
            if let previous { #expect(output == previous) }
            previous = output
            data = try #require(try ICalendarParser.parseSingleVTODO(from: output))
            #expect(try VTODOOpaqueState(data) == original)
            #expect(ICalendarParser.unfoldLines(output).components(separatedBy: "\n").filter { $0 == "RELATED-TO;RELTYPE=PARENT:p" }.count == 1)
        }
    }

    @Test func alarmBaselineControlsReplayReplacementAndClear() throws {
        let data = try parsed("BEGIN:VALARM\nACTION:EMAIL\nTRIGGER:-PT15M\nDESCRIPTION:Custom\nEND:VALARM")
        let state = try VTODOOpaqueState(data)
        let unchanged = ICalendarSerializer.serialize(uid: "opaque", summary: "Edit", alarmTriggerSeconds: 900, opaqueState: state)
        #expect(unchanged.contains("ACTION:EMAIL"))
        let changed = ICalendarSerializer.serialize(uid: "opaque", summary: "Edit", alarmTriggerSeconds: 60, opaqueState: state)
        #expect(!changed.contains("ACTION:EMAIL"))
        #expect(changed.contains("TRIGGER;VALUE=DURATION:-PT1M"))
        let cleared = ICalendarSerializer.serialize(uid: "opaque", summary: "Edit", opaqueState: state)
        #expect(!cleared.contains("BEGIN:VALARM"))
        let unsupported = try parsed("BEGIN:VALARM\nTRIGGER;VALUE=DATE-TIME:20261022T120000Z\nACTION:DISPLAY\nEND:VALARM")
        #expect(unsupported.alarmTriggerSeconds == nil)
        let replayed = ICalendarSerializer.serialize(uid: "opaque", summary: "Edit", opaqueState: try VTODOOpaqueState(unsupported))
        #expect(replayed.contains("TRIGGER;VALUE=DATE-TIME:20261022T120000Z"))
    }

    @Test(arguments: ["SUMMARY:Duplicate", "ATTACH:https://example.com/file", "BEGIN:VTODO", "X-EVIL:a\r\nEND:VTODO", "X-EVIL:a\u{2028}END:VTODO", "RELATED-TO;RELTYPE=PARENT:p"])
    func unsafeOrOwnedSidecarLinesCannotBeReplayed(line: String) throws {
        var state = VTODOOpaqueState.empty; state.opaqueProperties = [line]
        #expect(throws: VTODOOpaqueState.StateError.self) { try state.validate() }
        let output = ICalendarSerializer.serialize(uid: "opaque", summary: "Title", opaqueState: state)
        #expect(ICalendarParser.unfoldLines(output).components(separatedBy: "\n").filter { $0 == "BEGIN:VTODO" }.count == 1)
        if line != "BEGIN:VTODO" { #expect(!output.contains(line)) }
    }

    @Test(arguments: ["BEGIN:VALARM\nBEGIN:VALARM\nEND:VALARM\nEND:VALARM", "BEGIN:VALARM\nTRIGGER:-PT1M", "END:VALARM", "BEGIN:VEVENT\nEND:VEVENT"])
    func malformedNestedComponentsFailClosed(content: String) {
        #expect(throws: (any Error).self) { _ = try parsed(content) }
    }

    @Test func quotedParameterSeparatorsDoNotTurnSiblingIntoParent() throws {
        let line = #"RELATED-TO;X-INFO="urn:a;RELTYPE=PARENT";RELTYPE=SIBLING:other"#
        let data = try parsed(line)
        #expect(data.parentUID == nil)
        #expect(data.opaqueProperties == [line])
    }

    @Test(arguments: ["lines", "opaque", "categoryCount", "categoryName", "categoryBytes", "alarm"])
    func excessiveParserWorkIsRejected(kind: String) {
        let content: String
        switch kind {
        case "lines": content = Array(repeating: "SUMMARY:Repeated", count: 4097).joined(separator: "\n")
        case "opaque": content = "X-OPAQUE:" + String(repeating: "x", count: 1_048_576)
        case "categoryCount": content = Array(repeating: "CATEGORIES:repeat", count: 257).joined(separator: "\n")
        case "categoryName": content = "CATEGORIES:" + String(repeating: "é", count: 513)
        case "categoryBytes": content = Array(repeating: "CATEGORIES:" + String(repeating: "x", count: 1024), count: 65).joined(separator: "\n")
        default: content = "BEGIN:VALARM\nDESCRIPTION:" + String(repeating: "x", count: 1_048_576) + "\nEND:VALARM"
        }
        let expected: ICalendarParser.WorkLimitExceeded.Kind
        switch kind {
        case "lines": expected = .contentLines
        case "categoryCount": expected = .categoryValues
        case "categoryName": expected = .categoryNameBytes
        case "categoryBytes": expected = .categoryBytes
        default: expected = .opaqueBytes
        }
        #expect(throws: ICalendarParser.WorkLimitExceeded(kind: expected)) { _ = try parsed(content) }
    }

    @Test func admittedBoundaryCategoriesPreserveDuplicatesEscapesAndEmptyPresence() throws {
        let names = Array(repeating: String(repeating: "é", count: 128), count: 256)
        let data = try parsed(names.map { "CATEGORIES:" + $0 }.joined(separator: "\n"))
        #expect(data.categories == names)
        let escaped = try parsed("CATEGORIES:\nCATEGORIES:one\\,two,same,same\nCATEGORIES: ")
        #expect(escaped.categories == ["one,two", "same", "same"])
        #expect(try parsed("CATEGORIES:").categories == [])
        #expect(try parsed("COMMENT:absent").categories == nil)
    }

    @Test func admittedLineAndOpaqueBoundariesPreserveOrderAndFolding() throws {
        let lines = (0..<4094).map { "X-ORDER:\($0)" }
        #expect(try parsed(lines.joined(separator: "\n")).opaqueProperties == lines)
        let opaque = "COMMENT:" + String(repeating: "x", count: 1_048_576 - 8)
        #expect(try parsed(opaque).opaqueProperties == [opaque])
        let folded = "COMMENT:first\r\n second\r\n\tthird"
        #expect(try parsed(folded).opaqueProperties == ["COMMENT:firstsecondthird"])
        let name = String(repeating: "é", count: 512)
        #expect(try parsed("CATEGORIES:" + name).categories == [name])
    }

    @Test func limitsResetPerVTODOAndAlarmBudgetIncludesEveryLine() throws {
        let alarm = ["BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT1M", "END:VALARM"]
        let limits = ICalendarParser.WorkLimits(maxContentLines: 5, maxOpaqueBytes: alarm.reduce(0) { $0 + $1.utf8.count })
        let body = "BEGIN:VTODO\nUID:one\n" + alarm.joined(separator: "\n") + "\nEND:VTODO"
        let result = try ICalendarParser.parseVTODOs(from: body + "\n" + body, limits: limits)
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.alarmBlocks == [alarm] })
        var smaller = limits
        smaller.maxOpaqueBytes -= 1
        #expect(throws: ICalendarParser.WorkLimitExceeded(kind: .opaqueBytes)) {
            _ = try ICalendarParser.parseVTODOs(from: body, limits: smaller)
        }
    }

    @Test func cancelledParserWorkerDoesNotReturnPartialInput() async throws {
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ICalendarParser.parseSingleVTODO(from: "BEGIN:VTODO\nUID:cancelled\nEND:VTODO")
        }
        do {
            _ = try await worker.value
            Issue.record("Cancelled parser worker returned parsed input")
        } catch is CancellationError {
            // Cancellation remains distinct from invalid remote content.
        }
    }

}
