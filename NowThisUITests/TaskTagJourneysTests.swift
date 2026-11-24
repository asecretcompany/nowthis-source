import XCTest

final class TaskTagJourneysTests: XCTestCase {
    @MainActor
    func testSelectingAndClearingExistingTagKeepsTaskEditorOpen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let reset = "-performance-fixture-reset"
        app.launchArguments = [
            "-performance-task-count", "1", "-performance-list-count", "1",
            "-performance-sectioned-search-fixture", reset,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-startupScreen", "smart:All Tasks",
            "-taskDetailSectionOrder", "[]"
        ]
        app.launch()
        defer { app.terminate() }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }

        let task = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture task 00000")).firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.tap()

        let editor = app.navigationBars["Task Details"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let title = app.textFields.matching(NSPredicate(format: "value == %@", "Fixture task 00000")).firstMatch
        XCTAssertTrue(title.exists)
        title.tap()
        title.typeText("edited")
        let editedTitle = app.textFields.matching(NSPredicate(format: "value CONTAINS %@", "edited")).firstMatch
        let draftTitle = try XCTUnwrap(editedTitle.value as? String)

        let addTag = app.buttons["Add Tag"]
        for _ in 0..<8 where !addTag.isHittable { app.swipeUp() }
        XCTAssertTrue(addTag.isHittable)
        addTag.tap()

        let picker = app.navigationBars["Tags"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Add Tag should open the picker while a title edit is pending.")
        let tag = app.buttons["Quasar"]
        XCTAssertTrue(tag.isHittable)
        tag.tap()
        XCTAssertTrue(picker.buttons["Done"].isHittable, "Adding the first tag should keep the picker open.")
        XCTAssertTrue(tag.isSelected, "The selected tag should expose its selection to accessibility.")
        tag.tap()
        XCTAssertTrue(picker.buttons["Done"].isHittable, "Removing the last tag should keep the picker open.")
        XCTAssertFalse(tag.isSelected)
        tag.tap()
        picker.buttons["Done"].tap()

        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
        XCTAssertTrue(editor.buttons["Done"].waitForExistence(timeout: 5), "Closing Tags should return to Task Details.")
        let removeTag = app.buttons["Remove tag Quasar"]
        for _ in 0..<4 where !removeTag.isHittable { app.swipeDown() }
        XCTAssertTrue(removeTag.isHittable)
        editor.buttons["Done"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))

        app.terminate()
        app.launchArguments.removeAll { $0 == reset }
        app.launch()

        let savedTask = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", draftTitle)).firstMatch
        XCTAssertTrue(savedTask.waitForExistence(timeout: 5), "Saving the task should retain the draft title.")
        XCTAssertTrue(savedTask.staticTexts["Quasar"].exists, "The saved task should show its tag after relaunch.")
        savedTask.staticTexts[draftTitle].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        for _ in 0..<8 where !removeTag.isHittable { app.swipeUp() }
        XCTAssertTrue(removeTag.isHittable, "The selected tag should survive relaunching and reopening the task.")
    }
}
