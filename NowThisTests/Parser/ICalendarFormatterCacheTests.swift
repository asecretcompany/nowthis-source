import Foundation
import Testing
@testable import NowThis

@Suite("ICalendarParser formatter cache")
struct ICalendarFormatterCacheTests {
    @Test("reuses a named-timezone formatter across VTODO components")
    func reusesNamedTimezoneFormatter() throws {
        let cache = ICalendarParser.FormatterCache()
        let first = try ICalendarParser.parseSingleVTODO(from: Self.todo("TZID=Europe/Berlin", "20240115T140000"), using: cache)
        let second = try ICalendarParser.parseSingleVTODO(from: Self.todo("TZID=Europe/Berlin", "20240115T140000"), using: cache)

        #expect(first?.dueDate == Date(timeIntervalSince1970: 1_705_323_600))
        #expect(second?.dueDate == Date(timeIntervalSince1970: 1_705_323_600))
        #expect(cache.namedTimeZoneFormatterCreationCount == 1)
    }

    @Test("keeps no more than 32 named-timezone formatters and evicts the least recently used")
    func evictsLeastRecentlyUsedFormatterAtCapacity() throws {
        let zones = [
            "America/Los_Angeles", "America/New_York", "America/Chicago", "America/Denver",
            "America/Phoenix", "America/Anchorage", "America/Detroit", "America/Toronto",
            "America/Vancouver", "America/Mexico_City", "America/Sao_Paulo", "America/Argentina/Buenos_Aires",
            "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Rome", "Europe/Moscow",
            "Africa/Cairo", "Africa/Johannesburg", "Asia/Dubai", "Asia/Kolkata", "Asia/Dhaka",
            "Asia/Bangkok", "Asia/Singapore", "Asia/Hong_Kong", "Asia/Shanghai", "Asia/Tokyo",
            "Asia/Seoul", "Australia/Sydney", "Australia/Brisbane", "Pacific/Auckland", "Pacific/Fiji",
            "Pacific/Honolulu"
        ]
        let cache = ICalendarParser.FormatterCache()

        for zone in zones {
            _ = try ICalendarParser.parseSingleVTODO(from: Self.todo("TZID=\(zone)", "20240115T120000"), using: cache)
        }
        #expect(cache.cachedNamedTimeZoneFormatterCount == 32)
        #expect(cache.namedTimeZoneFormatterCreationCount == 33)

        _ = try ICalendarParser.parseSingleVTODO(from: Self.todo("TZID=Pacific/Honolulu", "20240115T120000"), using: cache)
        #expect(cache.namedTimeZoneFormatterCreationCount == 33)
        _ = try ICalendarParser.parseSingleVTODO(from: Self.todo("TZID=America/Los_Angeles", "20240115T120000"), using: cache)
        #expect(cache.cachedNamedTimeZoneFormatterCount == 32)
        #expect(cache.namedTimeZoneFormatterCreationCount == 34)
    }

    @Test("quoted TZID dates retain their instants across the spring DST transition")
    func quotedTimezonePreservesDSTBoundaryInstants() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:dst-boundary
        DTSTART;TZID="America/Los_Angeles":20240310T013000
        DUE;TZID="America/Los_Angeles":20240310T033000
        END:VTODO
        END:VCALENDAR
        """
        let todo = try #require(try ICalendarParser.parseSingleVTODO(from: ics, using: ICalendarParser.FormatterCache()))

        #expect(todo.startDate == Date(timeIntervalSince1970: 1_710_063_000))
        #expect(todo.dueDate == Date(timeIntervalSince1970: 1_710_066_600))
    }

    @Test("floating date-times and DATE values keep their existing timezone semantics")
    func preservesFloatingAndDateOnlySemantics() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:floating-and-date-only
        DTSTART:20240615T120000
        DUE;VALUE=DATE:20240615
        END:VTODO
        END:VCALENDAR
        """
        let parsed = try #require(try ICalendarParser.parseSingleVTODO(from: ics, using: ICalendarParser.FormatterCache()))
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = .current
        let expectedFloating = try #require(localCalendar.date(from: DateComponents(year: 2024, month: 6, day: 15, hour: 12)))

        #expect(parsed.startDate == expectedFloating)
        #expect(parsed.dueDate == Date(timeIntervalSince1970: 1_718_409_600))
        #expect(parsed.isDueDateOnly)
        #expect(!parsed.isStartDateOnly)
    }

    @Test("static parser calls do not share mutable named-timezone formatters across threads")
    func concurrentStaticCallsUseIndependentNamedTimezoneFormatters() {
        let cases: [(String, TimeInterval)] = [
            ("America/Los_Angeles", 1_705_348_800),
            ("America/New_York", 1_705_338_000),
            ("Europe/Berlin", 1_705_316_400),
            ("Asia/Tokyo", 1_705_287_600),
            ("Australia/Sydney", 1_705_280_400),
            ("Asia/Kolkata", 1_705_300_200)
        ]
        let failures = ConcurrentFailures()

        DispatchQueue.concurrentPerform(iterations: 600) { iteration in
            let (zone, expectedSeconds) = cases[iteration % cases.count]
            do {
                let parsed = try ICalendarParser.parseSingleVTODO(from: Self.todo("TZID=\(zone)", "20240115T120000"))
                if parsed?.dueDate != Date(timeIntervalSince1970: expectedSeconds) {
                    failures.record()
                }
            } catch {
                failures.record()
            }
        }

        #expect(failures.count == 0)
    }

    private static func todo(_ parameter: String, _ dateValue: String) -> String {
        """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:formatter-cache-test
        DUE;\(parameter):\(dateValue)
        END:VTODO
        END:VCALENDAR
        """
    }

    private final class ConcurrentFailures: @unchecked Sendable {
        private let lock = NSLock()
        private var storedCount = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedCount
        }

        func record() {
            lock.lock()
            storedCount += 1
            lock.unlock()
        }
    }
}
