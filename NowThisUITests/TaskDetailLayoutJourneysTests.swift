import XCTest

final class TaskDetailLayoutJourneysTests: XCTestCase {
#if compiler(>=6.4)
    @MainActor
    func testMoveMenuHasSpokenLabelAndMovesSectionWithoutDragging() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Requires the iOS 27 VoiceOver testing service.") }
        continueAfterFailure = false
        let app = launchFixture()
        defer { app.terminate() }
        openLayout(in: app)
        let reset = app.buttons["Reset to Default"]
        if reset.isEnabled { reset.tap() }
        let notes = app.staticTexts["Notes"]
        let tags = app.staticTexts["Tags"]
        XCTAssertLessThan(tags.frame.minY, notes.frame.minY)
        let navigation = app.navigationBars["Task Detail Layout"]
        navigation.buttons["Edit"].tap()
        let move = app.buttons["Move Notes"]
        XCTAssertTrue(move.exists)
        let voiceOver = XCUIDevice.shared.voiceOverService
        try voiceOver.enable()
        defer { if voiceOver.isEnabled { try? voiceOver.disable() } }

        var announcements: [String] = []
        for _ in 0..<24 {
            let announcement = try voiceOver.moveForward().utterance
            announcements.append(announcement)
            if announcement.localizedCaseInsensitiveContains("Move Notes") { break }
        }
        XCTAssertTrue(announcements.last?.localizedCaseInsensitiveContains("Move Notes") == true,
                      "VoiceOver should announce the Notes move menu. Heard: \(announcements)")
        let speech = XCTAttachment(string: announcements.joined(separator: "\n"))
        speech.name = "VoiceOver reading order"
        speech.lifetime = .keepAlways
        add(speech)

        try voiceOver.disable()
        move.tap()
        app.buttons["Move Up"].tap()
        XCTAssertLessThan(notes.frame.minY, tags.frame.minY)
        move.tap()
        app.buttons["Move Down"].tap()
        XCTAssertLessThan(tags.frame.minY, notes.frame.minY)
        navigation.buttons["Done"].tap()
    }
#endif

    @MainActor
    func testReorderedSectionsSurviveRelaunchAndApplyToTaskDetails() {
        continueAfterFailure = false
        let app = launchFixture()
        defer { app.terminate() }

        openLayout(in: app)
        let reset = app.buttons["Reset to Default"]
        if reset.isEnabled { reset.tap() }
        let title = app.staticTexts["Title"]
        let notes = app.staticTexts["Notes"]
        XCTAssertLessThan(title.frame.minY, notes.frame.minY)

        let navigation = app.navigationBars["Task Detail Layout"]
        navigation.buttons["Edit"].tap()
        let handle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder Notes")).firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)))
        navigation.buttons["Done"].tap()
        XCTAssertLessThan(notes.frame.minY, title.frame.minY)

        app.terminate()
        app.launchArguments.removeAll { $0 == "-performance-fixture-reset" }
        app.launch()
        let task = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Fixture task 00000")).firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.tap()
        XCTAssertTrue(app.navigationBars["Task Details"].waitForExistence(timeout: 5))
        let expand = app.buttons["Expand Notes"]
        XCTAssertTrue(expand.isHittable, "The reordered Notes section should be visible without scrolling.")
        let taskTitle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", "Fixture task 00000")).firstMatch
        XCTAssertTrue(taskTitle.exists)
        XCTAssertLessThan(expand.frame.minY, taskTitle.frame.minY)

        app.navigationBars["Task Details"].buttons["Done"].tap()
        openLayout(in: app)
        reset.tap()
        XCTAssertLessThan(title.frame.minY, notes.frame.minY)
    }

    @MainActor
    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-performance-task-count", "20", "-performance-list-count", "1",
            "-performance-fixture-reset", "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US", "-startupScreen", "smart:Today"
        ]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        return app
    }

    @MainActor
    private func openLayout(in app: XCUIApplication) {
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let tasks = app.buttons["settings.tasks"]
        if tasks.exists { tasks.tap() }
        let link = app.buttons["Task Detail Layout"]
        for _ in 0..<8 where !link.exists || !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.isHittable, "Settings should provide an entry point for task detail layout.")
        link.tap()
        XCTAssertTrue(app.navigationBars["Task Detail Layout"].waitForExistence(timeout: 5))
    }
}
