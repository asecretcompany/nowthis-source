import XCTest

final class TaskPermissionsJourneysTests: XCTestCase {
    @MainActor
    func testReadOnlyTaskDueDateDoesNotChangeOrPersist() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let reset = "-performance-fixture-reset"
        app.launchArguments = [
            "-performance-task-count", "1", "-performance-list-count", "1", reset,
            "-performance-read-only-task-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-startupScreen", "smart:All Tasks", "-defaultDueDateRule", "none", "-defaultReminderEnabled", "NO"
        ]
        app.launch()
        defer { app.terminate() }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }

        openReadOnlyTask(in: app)
        let due = app.switches["Due Date"]
        for _ in 0..<5 where !due.isHittable { app.swipeUp() }
        XCTAssertTrue(due.exists, app.debugDescription)
        XCTAssertEqual(due.value as? String, "0", "The saved task starts undated.")
        XCTAssertTrue(due.isEnabled && due.isHittable, "This control should explain a refused edit.")
        // The accessible element can include the label; tap the switch's trailing control.
        due.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: due.frame.width - min(24, due.frame.width / 2), dy: due.frame.height / 2)).tap()
        let refusal = app.alerts.staticTexts["This list is read-only. Ask the list owner for permission to edit it."]
        if refusal.waitForExistence(timeout: 3) { app.alerts.buttons["OK"].tap() }
        else { XCTFail("The read-only control did not explain the refusal.") }
        XCTAssertEqual(due.value as? String, "0", "The live editor must refuse a read-only date change.")

        app.terminate()
        app.launchArguments.removeAll { $0 == reset }
        app.launch()
        openReadOnlyTask(in: app)
        for _ in 0..<5 where !due.isHittable { app.swipeUp() }
        XCTAssertTrue(due.exists, app.debugDescription)
        XCTAssertEqual(due.value as? String, "0", "The attempted edit must not survive relaunch without Done.")

        let repeatRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Repeat")).firstMatch
        for _ in 0..<5 where !repeatRow.isHittable { app.swipeUp() }
        XCTAssertTrue(repeatRow.isHittable)
        repeatRow.tap()
        let picker = app.navigationBars["Repeat"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        app.buttons["Weekly"].tap()
        picker.buttons["Done"].tap()
        XCTAssertTrue(refusal.waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(picker.exists, "The refused Repeat draft should stay open.")
        picker.buttons["Cancel"].tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
        app.navigationBars["Task Details"].buttons["Done"].tap()
    }

    @MainActor
    private func openReadOnlyTask(in app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Read-only due-date target")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.navigationBars["Task Details"].waitForExistence(timeout: 5), app.debugDescription)
    }
}
