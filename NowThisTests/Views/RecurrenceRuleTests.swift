import XCTest
@testable import NowThis

final class RecurrenceRuleTests: XCTestCase {

    // MARK: - Parsing

    func testParseDaily() {
        let rule = RecurrenceRule.parse("FREQ=DAILY")
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.frequency, .daily)
        XCTAssertEqual(rule?.interval, 1)
        XCTAssertTrue(rule?.byDay.isEmpty ?? false)
    }

    func testParseWeeklyWithInterval() {
        let rule = RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2")
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.frequency, .weekly)
        XCTAssertEqual(rule?.interval, 2)
    }

    func testParseWeeklyWithByDay() {
        let rule = RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=MO,WE,FR")
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.frequency, .weekly)
        XCTAssertEqual(rule?.byDay, [.monday, .wednesday, .friday])
    }

    func testParseMonthly() {
        let rule = RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=3")
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.frequency, .monthly)
        XCTAssertEqual(rule?.interval, 3)
    }

    func testParseYearly() {
        let rule = RecurrenceRule.parse("FREQ=YEARLY")
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.frequency, .yearly)
    }

    func testParseWithCount() {
        let rule = RecurrenceRule.parse("FREQ=DAILY;COUNT=10")
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.count, 10)
    }

    func testParseInvalidReturnsNil() {
        let rule = RecurrenceRule.parse("INVALID=RULE")
        XCTAssertNil(rule)
    }

    func testParseEmptyReturnsNil() {
        let rule = RecurrenceRule.parse("")
        XCTAssertNil(rule)
    }

    // MARK: - Serialization

    func testSerializeDaily() {
        let rule = RecurrenceRule(frequency: .daily, interval: 1, byDay: [])
        XCTAssertEqual(rule.toRRULEString(), "FREQ=DAILY")
    }

    func testSerializeWeeklyWithInterval() {
        let rule = RecurrenceRule(frequency: .weekly, interval: 2, byDay: [])
        XCTAssertEqual(rule.toRRULEString(), "FREQ=WEEKLY;INTERVAL=2")
    }

    func testSerializeWeeklyWithByDay() {
        let rule = RecurrenceRule(frequency: .weekly, interval: 1, byDay: [.monday, .friday])
        XCTAssertEqual(rule.toRRULEString(), "FREQ=WEEKLY;BYDAY=MO,FR")
    }

    func testRoundTrip() {
        let original = "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR"
        let parsed = RecurrenceRule.parse(original)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.toRRULEString(), original)
    }

    // MARK: - Display Text

    func testDisplayDaily() {
        let rule = RecurrenceRule(frequency: .daily, interval: 1, byDay: [])
        XCTAssertEqual(rule.displayText, "Daily")
    }

    func testDisplayEvery3Days() {
        let rule = RecurrenceRule(frequency: .daily, interval: 3, byDay: [])
        XCTAssertEqual(rule.displayText, "Every 3 days")
    }

    func testDisplayWeeklyWithDays() {
        let rule = RecurrenceRule(frequency: .weekly, interval: 1, byDay: [.monday, .wednesday])
        XCTAssertEqual(rule.displayText, "Weekly on Mon, Wed")
    }

    // MARK: - Next Date

    func testNextDateDaily() {
        let now = Date()
        let rule = RecurrenceRule(frequency: .daily, interval: 1, byDay: [])
        let next = rule.nextDate(after: now)
        XCTAssertNotNil(next)

        let expectedDay = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        XCTAssertEqual(
            Calendar.current.startOfDay(for: next!),
            Calendar.current.startOfDay(for: expectedDay)
        )
    }

    func testNextDateWeeklyInterval2() {
        let now = Date()
        let rule = RecurrenceRule(frequency: .weekly, interval: 2, byDay: [])
        let next = rule.nextDate(after: now)
        XCTAssertNotNil(next)

        let expected = Calendar.current.date(byAdding: .weekOfYear, value: 2, to: now)!
        XCTAssertEqual(
            Calendar.current.startOfDay(for: next!),
            Calendar.current.startOfDay(for: expected)
        )
    }

    func testNextDateMonthly() {
        let now = Date()
        let rule = RecurrenceRule(frequency: .monthly, interval: 1, byDay: [])
        let next = rule.nextDate(after: now)
        XCTAssertNotNil(next)

        let expected = Calendar.current.date(byAdding: .month, value: 1, to: now)!
        XCTAssertEqual(
            Calendar.current.startOfDay(for: next!),
            Calendar.current.startOfDay(for: expected)
        )
    }

    func testNextDateYearly() {
        let now = Date()
        let rule = RecurrenceRule(frequency: .yearly, interval: 1, byDay: [])
        let next = rule.nextDate(after: now)
        XCTAssertNotNil(next)

        let expected = Calendar.current.date(byAdding: .year, value: 1, to: now)!
        XCTAssertEqual(
            Calendar.current.startOfDay(for: next!),
            Calendar.current.startOfDay(for: expected)
        )
    }

    func testNextDateCountExhausted() {
        let rule = RecurrenceRule(frequency: .daily, interval: 1, byDay: [], count: 5)
        let next = rule.nextDate(after: Date(), completionCount: 5)
        XCTAssertNil(next, "Should return nil when count is exhausted")
    }

    func testNextDateCountNotExhausted() {
        let rule = RecurrenceRule(frequency: .daily, interval: 1, byDay: [], count: 5)
        let next = rule.nextDate(after: Date(), completionCount: 3)
        XCTAssertNotNil(next, "Should return a date when count is not yet exhausted")
    }
}
