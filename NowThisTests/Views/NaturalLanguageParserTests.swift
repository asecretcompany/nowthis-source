import XCTest
@testable import NowThis

final class NaturalLanguageParserTests: XCTestCase {

    // MARK: - Priority Parsing

    func testParsePriorityHigh() {
        let result = NaturalLanguageParser.parse("Buy milk !high")
        XCTAssertEqual(result.priority, .high)
        XCTAssertEqual(result.cleanTitle, "Buy milk")
    }

    func testParsePriorityMedium() {
        let result = NaturalLanguageParser.parse("Fix bug !medium")
        XCTAssertEqual(result.priority, .medium)
        XCTAssertEqual(result.cleanTitle, "Fix bug")
    }

    func testParsePriorityMediumShorthand() {
        let result = NaturalLanguageParser.parse("Fix bug !med")
        XCTAssertEqual(result.priority, .medium)
        XCTAssertEqual(result.cleanTitle, "Fix bug")
    }

    func testParsePriorityLow() {
        let result = NaturalLanguageParser.parse("Water plants !low")
        XCTAssertEqual(result.priority, .low)
        XCTAssertEqual(result.cleanTitle, "Water plants")
    }

    func testParsePriorityCaseInsensitive() {
        let result = NaturalLanguageParser.parse("Task !HIGH")
        XCTAssertEqual(result.priority, .high)
        XCTAssertEqual(result.cleanTitle, "Task")
    }

    func testNoPriority() {
        let result = NaturalLanguageParser.parse("Just a normal task")
        XCTAssertNil(result.priority)
        XCTAssertEqual(result.cleanTitle, "Just a normal task")
    }

    // MARK: - List Parsing

    func testParseListName() {
        let result = NaturalLanguageParser.parse("Fix bug #Work")
        XCTAssertEqual(result.listName, "Work")
        XCTAssertEqual(result.cleanTitle, "Fix bug")
    }

    func testNoListName() {
        let result = NaturalLanguageParser.parse("Fix bug")
        XCTAssertNil(result.listName)
    }

    // MARK: - Tag Parsing

    func testParseSingleTag() {
        let result = NaturalLanguageParser.parse("Groceries @errands")
        XCTAssertEqual(result.tagNames, ["errands"])
        XCTAssertEqual(result.cleanTitle, "Groceries")
    }

    func testParseMultipleTags() {
        let result = NaturalLanguageParser.parse("Clean house @home @weekly")
        XCTAssertEqual(result.tagNames, ["home", "weekly"])
        XCTAssertEqual(result.cleanTitle, "Clean house")
    }

    func testNoTags() {
        let result = NaturalLanguageParser.parse("Normal task")
        XCTAssertTrue(result.tagNames.isEmpty)
    }

    // MARK: - Date Parsing

    func testParseTomorrow() {
        let result = NaturalLanguageParser.parse("Call dentist tomorrow")
        XCTAssertNotNil(result.dueDate)
        XCTAssertEqual(result.cleanTitle, "Call dentist")

        let expected = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        XCTAssertEqual(result.dueDate, DueDateHelper.dateOnlyValue(for: expected))
        XCTAssertFalse(result.dueHasTime)
    }

    func testParseToday() {
        let result = NaturalLanguageParser.parse("Submit report today")
        XCTAssertNotNil(result.dueDate)
        XCTAssertEqual(result.cleanTitle, "Submit report")

        XCTAssertEqual(result.dueDate, DueDateHelper.dateOnlyValue(for: Date()))
        XCTAssertFalse(result.dueHasTime)
    }

    func testParseInNDays() {
        let result = NaturalLanguageParser.parse("Review code in 3 days")
        XCTAssertNotNil(result.dueDate)
        XCTAssertEqual(result.cleanTitle, "Review code")

        let expected = Calendar.current.date(byAdding: .day, value: 3, to: Date())!
        XCTAssertEqual(result.dueDate, DueDateHelper.dateOnlyValue(for: expected))
        XCTAssertFalse(result.dueHasTime)
    }

    func testKeywordsAndClocksAroundDaylightSavingTransitions() throws {
        let schedules = [
            ("America/Los_Angeles", "03-07", "03-08", "03-10"),
            ("America/Los_Angeles", "10-31", "11-01", "11-03"),
            ("Europe/Berlin", "03-28", "03-29", "03-31"),
            ("Europe/Berlin", "10-24", "10-25", "10-27"),
            ("Australia/Sydney", "04-04", "04-05", "04-07"),
            ("Australia/Sydney", "10-03", "10-04", "10-06"),
            ("UTC", "03-07", "03-08", "03-10"),
        ]
        let iso = ISO8601DateFormatter()

        for (zone, saturday, sunday, tuesday) in schedules {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let saturdayNow = try XCTUnwrap(iso.date(from: "2026-\(saturday)T12:00:00Z"))
            let sundayNow = try XCTUnwrap(iso.date(from: "2026-\(sunday)T12:00:00Z"))
            let cases = [
                ("today", saturdayNow, saturday),
                ("tomorrow", saturdayNow, sunday),
                ("in 3 days", saturdayNow, tuesday),
                ("next sunday", saturdayNow, sunday),
                ("today", sundayNow, sunday),
                ("", sundayNow, sunday),
            ]
            for (keyword, now, target) in cases {
                let context = "\(zone), \(now), \(keyword)"
                let midnightUTC = try XCTUnwrap(iso.date(from: "2026-\(target)T00:00:00Z"))
                if !keyword.isEmpty {
                    let bare = NaturalLanguageParser.parse("Buy milk \(keyword)", now: now, calendar: local)
                    XCTAssertEqual(bare.cleanTitle, "Buy milk", context)
                    XCTAssertFalse(bare.dueHasTime, context)
                    XCTAssertEqual(bare.dueDate, midnightUTC, context)
                }

                let timed = NaturalLanguageParser.parse("Buy milk \(keyword) at 5:30pm", now: now, calendar: local)
                XCTAssertEqual(timed.cleanTitle, "Buy milk", context)
                XCTAssertTrue(timed.dueHasTime, context)
                let due = try XCTUnwrap(timed.dueDate, context)
                let monthDay = target.split(separator: "-")
                let expected = local.date(from: DateComponents(
                    year: 2026, month: Int(monthDay[0]), day: Int(monthDay[1]),
                    hour: 17, minute: 30, second: 0
                ))
                XCTAssertEqual(due, expected, context)
            }
        }
    }

    func testRegionCalendarKeepsGregorianDateOnlyStorage() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        let iso = ISO8601DateFormatter()
        let now = try XCTUnwrap(iso.date(from: "2026-10-03T12:00:00Z"))
        let expected = try XCTUnwrap(iso.date(from: "2026-10-04T00:00:00Z"))

        let result = NaturalLanguageParser.parse("Buy milk tomorrow", now: now, calendar: buddhist)

        XCTAssertFalse(result.dueHasTime)
        XCTAssertEqual(result.dueDate, expected)
    }

    func testDetectorFallbackForExplicitCalendarDate() throws {
        // A named month with a year goes through Foundation's date detector.
        // This expression doesn't require a relative clock or an injected calendar.
        let result = NaturalLanguageParser.parse("Buy milk March 8, 2026")
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T00:00:00Z"))

        XCTAssertEqual(result.cleanTitle, "Buy milk")
        XCTAssertFalse(result.dueHasTime)
        XCTAssertEqual(result.dueDate, expected)
    }

    func testDetectorFallbackCombinesExplicitClockOnDetectedDay() throws {
        let local = DueDateHelper.localCalendar()
        let expected = try XCTUnwrap(local.date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 17, minute: 30
        )))
        var injected = Calendar(identifier: .gregorian)
        injected.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))

        let result = NaturalLanguageParser.parse(
            "Buy milk March 8, 2026 at 5:30pm", now: .distantPast, calendar: injected
        )

        XCTAssertEqual(result.cleanTitle, "Buy milk")
        XCTAssertTrue(result.dueHasTime)
        XCTAssertEqual(result.dueDate, expected)
    }

    func testNoDate() {
        let result = NaturalLanguageParser.parse("Buy groceries")
        XCTAssertNil(result.dueDate)
    }

    // MARK: - Time-of-Day Parsing

    func testTomorrowAtTimeStripsTimeFromTitle() {
        // The whole "tomorrow at 5pm" phrase should be removed from the title.
        let result = NaturalLanguageParser.parse("Call dentist tomorrow at 5pm")
        XCTAssertEqual(result.cleanTitle, "Call dentist")
    }

    func testTomorrowAtTimeSetsClockTime() throws {
        let result = NaturalLanguageParser.parse("Call dentist tomorrow at 5pm")
        let due = try XCTUnwrap(result.dueDate)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: due)
        XCTAssertEqual(comps.hour, 17)
        XCTAssertEqual(comps.minute, 0)

        let tomorrow = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        )
        XCTAssertEqual(Calendar.current.startOfDay(for: due), tomorrow)
    }

    func testDueHasTimeTrueWhenTimeSpecified() {
        let result = NaturalLanguageParser.parse("Call dentist tomorrow at 5pm")
        XCTAssertTrue(result.dueHasTime)
    }

    func testDueHasTimeFalseForBareKeywordDate() {
        let result = NaturalLanguageParser.parse("Call dentist tomorrow")
        XCTAssertNotNil(result.dueDate)
        XCTAssertFalse(result.dueHasTime)
    }

    func testParseTimeWithColonAndMinutes() throws {
        let result = NaturalLanguageParser.parse("Meeting tomorrow at 5:30pm")
        let due = try XCTUnwrap(result.dueDate)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: due)
        XCTAssertEqual(comps.hour, 17)
        XCTAssertEqual(comps.minute, 30)
        XCTAssertEqual(result.cleanTitle, "Meeting")
        XCTAssertTrue(result.dueHasTime)
    }

    func testParseMorningTimeToday() throws {
        let result = NaturalLanguageParser.parse("Standup today at 9am")
        let due = try XCTUnwrap(result.dueDate)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: due)
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(result.cleanTitle, "Standup")
        XCTAssertTrue(result.dueHasTime)
    }

    func testParseNoon() throws {
        let result = NaturalLanguageParser.parse("Lunch tomorrow at noon")
        let due = try XCTUnwrap(result.dueDate)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: due)
        XCTAssertEqual(comps.hour, 12)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(result.cleanTitle, "Lunch")
        XCTAssertTrue(result.dueHasTime)
    }

    func testParse24HourTime() throws {
        let result = NaturalLanguageParser.parse("Deploy tomorrow at 17:00")
        let due = try XCTUnwrap(result.dueDate)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: due)
        XCTAssertEqual(comps.hour, 17)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertTrue(result.dueHasTime)
    }

    func testTimeOnlyDefaultsToToday() throws {
        let result = NaturalLanguageParser.parse("Standup at 9am")
        let due = try XCTUnwrap(result.dueDate)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: due)
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(Calendar.current.startOfDay(for: due),
                       Calendar.current.startOfDay(for: Date()))
        XCTAssertEqual(result.cleanTitle, "Standup")
        XCTAssertTrue(result.dueHasTime)
    }

    func testBareNumberNotParsedAsTime() {
        // "at 5" without am/pm or a colon is too ambiguous — leave it in the title.
        let result = NaturalLanguageParser.parse("Order 5 boxes")
        XCTAssertFalse(result.dueHasTime)
        XCTAssertNil(result.dueDate)
        XCTAssertEqual(result.cleanTitle, "Order 5 boxes")
    }

    // MARK: - Combined Parsing

    func testParseAllTokensCombined() {
        let result = NaturalLanguageParser.parse("Deploy app !high #Work @urgent tomorrow")
        XCTAssertEqual(result.priority, .high)
        XCTAssertEqual(result.listName, "Work")
        XCTAssertEqual(result.tagNames, ["urgent"])
        XCTAssertNotNil(result.dueDate)
        XCTAssertEqual(result.cleanTitle, "Deploy app")
    }

    // MARK: - Edge Cases

    func testEmptyString() {
        let result = NaturalLanguageParser.parse("")
        XCTAssertEqual(result.cleanTitle, "")
        XCTAssertNil(result.priority)
        XCTAssertNil(result.listName)
        XCTAssertTrue(result.tagNames.isEmpty)
        XCTAssertNil(result.dueDate)
    }

    func testOnlyTokens() {
        let result = NaturalLanguageParser.parse("!high #Work @urgent")
        XCTAssertEqual(result.priority, .high)
        XCTAssertEqual(result.listName, "Work")
        XCTAssertEqual(result.tagNames, ["urgent"])
        XCTAssertEqual(result.cleanTitle, "")
    }

    func testExclamationMidWord() {
        // Should NOT parse "exciting!" as a priority
        let result = NaturalLanguageParser.parse("This is exciting!")
        XCTAssertNil(result.priority)
        XCTAssertEqual(result.cleanTitle, "This is exciting!")
    }

    func testEmailAddressNotParsedAsTag() {
        // "@" mid-word in "user@email.com" is NOT matched because
        // the regex requires whitespace or start-of-string before @
        let result = NaturalLanguageParser.parse("Email user@email.com")
        XCTAssertTrue(result.tagNames.isEmpty)
        XCTAssertEqual(result.cleanTitle, "Email user@email.com")
    }
}
