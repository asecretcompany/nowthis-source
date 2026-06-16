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
        let expectedDay = Calendar.current.startOfDay(for: expected)
        let resultDay = Calendar.current.startOfDay(for: result.dueDate!)
        XCTAssertEqual(resultDay, expectedDay)
    }

    func testParseToday() {
        let result = NaturalLanguageParser.parse("Submit report today")
        XCTAssertNotNil(result.dueDate)
        XCTAssertEqual(result.cleanTitle, "Submit report")

        let expectedDay = Calendar.current.startOfDay(for: Date())
        let resultDay = Calendar.current.startOfDay(for: result.dueDate!)
        XCTAssertEqual(resultDay, expectedDay)
    }

    func testParseInNDays() {
        let result = NaturalLanguageParser.parse("Review code in 3 days")
        XCTAssertNotNil(result.dueDate)
        XCTAssertEqual(result.cleanTitle, "Review code")

        let expected = Calendar.current.date(byAdding: .day, value: 3, to: Date())!
        let expectedDay = Calendar.current.startOfDay(for: expected)
        let resultDay = Calendar.current.startOfDay(for: result.dueDate!)
        XCTAssertEqual(resultDay, expectedDay)
    }

    func testNoDate() {
        let result = NaturalLanguageParser.parse("Buy groceries")
        XCTAssertNil(result.dueDate)
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
