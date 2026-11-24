import XCTest

final class TaskNotesJourneysTests: XCTestCase {
    @MainActor
    func testNotesStartTallerAndCanExpandAndCollapseWithoutLosingDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-performance-task-count", "20", "-performance-list-count", "1",
            "-performance-fixture-reset", "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US", "-startupScreen", "smart:Today"
        ]
        app.launch()
        defer { app.terminate() }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }

        let task = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Fixture task 00000")).firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.tap()
        XCTAssertTrue(app.navigationBars["Task Details"].waitForExistence(timeout: 5))

        let notes = app.textViews.firstMatch
        for _ in 0..<6 where !notes.isHittable { app.swipeUp() }
        XCTAssertTrue(notes.isHittable)
        let compactHeight = notes.frame.height
        XCTAssertGreaterThanOrEqual(compactHeight, 160, "The default Notes editor should show several more lines.")

        let expand = app.buttons["Expand Notes"]
        XCTAssertTrue(expand.isHittable)
        expand.tap()

        let collapse = app.buttons["Collapse Notes"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(notes.frame.height, compactHeight + 80)
        let expandedScreenshot = XCTAttachment(screenshot: app.screenshot())
        expandedScreenshot.name = "Expanded task notes"
        expandedScreenshot.lifetime = .keepAlways
        add(expandedScreenshot)

        collapse.tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertEqual(notes.frame.height, compactHeight, accuracy: 1)

        // Check the draft with the keyboard up, when the editor's visible frame can be clipped.
        expand.tap()
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        notes.tap()
        notes.typeText("An unsaved note draft")
        XCTAssertTrue(collapse.isHittable)
        collapse.tap()

        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertEqual(notes.value as? String, "An unsaved note draft")
        let draftScreenshot = XCTAttachment(screenshot: app.screenshot())
        draftScreenshot.name = "Task note draft after collapsing"
        draftScreenshot.lifetime = .keepAlways
        add(draftScreenshot)
    }
}
