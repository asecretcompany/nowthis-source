import XCTest

final class RepeatDetailJourneysTests: XCTestCase {
    @MainActor
    func testRepeatCancelAndNeverLeaveUndatedTasksUndatedAfterRelaunch() {
        let app = XCUIApplication()
        let reset = "-performance-fixture-reset"
        app.launchArguments = [
            "-performance-task-count", "1", "-performance-list-count", "3", reset,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-startupScreen", "smart:All Tasks",
            "-defaultDueDateRule", "none", "-defaultReminderEnabled", "NO"
        ]
        app.launch()
        defer { app.terminate() }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }

        for (title, cancel) in [("Repeat cancel target", true), ("Repeat never target", false)] {
            let add = app.textFields["Quick add task"]
            XCTAssertTrue(add.waitForExistence(timeout: 10))
            add.tap()
            add.typeText(title)
            app.buttons["arrow.up.circle.fill"].tap()
            openTask(title, in: app)
            let due = app.switches["Due Date"]
            let repeatRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Repeat")).firstMatch
            for _ in 0..<5 where !repeatRow.isHittable { app.swipeUp() }
            XCTAssertEqual(due.value as? String, "0", "The fixture task starts undated.")
            XCTAssertTrue(repeatRow.isHittable)
            repeatRow.tap()
            let picker = app.navigationBars["Repeat"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            app.buttons["Weekly"].tap()
            if !cancel { app.buttons["Never"].tap() }
            picker.buttons[cancel ? "Cancel" : "Done"].tap()
            XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
            XCTAssertEqual(due.value as? String, "0", "\(title) must leave the task undated.")
            app.terminate()
            app.launchArguments.removeAll { $0 == reset }
            app.launch()
            openTask(title, in: app)
            for _ in 0..<5 where !due.isHittable { app.swipeUp() }
            XCTAssertEqual(due.value as? String, "0", "The unwanted date must not survive a relaunch.")
            app.navigationBars["Task Details"].buttons["Done"].tap()
        }
    }

    @MainActor
    func testWeeklyStillSetsARequiredDueDate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let reset = "-performance-fixture-reset"
        app.launchArguments = [
            "-performance-task-count", "1", "-performance-list-count", "5", reset,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-startupScreen", "smart:All Tasks",
            "-defaultDueDateRule", "none", "-defaultReminderEnabled", "NO"
        ]
        app.launch()
        defer { app.terminate() }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }

        let title = "Weekly save target"
        let add = app.textFields["Quick add task"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        add.typeText(title)
        app.buttons["arrow.up.circle.fill"].tap()
        openTask(title, in: app)
        let due = app.switches["Due Date"]
        let repeatRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Repeat")).firstMatch
        for _ in 0..<5 where !repeatRow.isHittable { app.swipeUp() }
        XCTAssertEqual(due.value as? String, "0")
        repeatRow.tap()
        let picker = app.navigationBars["Repeat"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        app.buttons["Weekly"].tap()
        picker.buttons["Done"].tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
        for _ in 0..<5 where !repeatRow.isHittable { app.swipeUp() }
        XCTAssertTrue(repeatRow.exists)
        XCTAssertTrue(repeatRow.label.contains("Weekly"))
        for _ in 0..<4 where !due.exists { app.swipeDown() }
        XCTAssertEqual(due.value as? String, "1")
        app.navigationBars["Task Details"].buttons["Done"].tap()

        app.terminate()
        app.launchArguments.removeAll { $0 == reset }
        app.launch()
        openTask(title, in: app)
        for _ in 0..<5 where !repeatRow.isHittable { app.swipeUp() }
        XCTAssertTrue(repeatRow.label.contains("Weekly"))
        for _ in 0..<4 where !due.exists { app.swipeDown() }
        XCTAssertEqual(due.value as? String, "1")
    }

    @MainActor
    private func openTask(_ title: String, in app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["Task Details"].waitForExistence(timeout: 5))
    }
}
