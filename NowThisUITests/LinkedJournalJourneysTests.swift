import XCTest

final class LinkedJournalJourneysTests: XCTestCase {
    @MainActor
    func testDeletedLinkedJournalStaysHiddenAfterRelaunch() {
        let app = XCUIApplication()
        let reset = "-performance-fixture-reset"
        app.launchArguments = [
            "-performance-task-count", "1", "-performance-list-count", "4", reset,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-startupScreen", "smart:All Tasks", "-sidebarHiddenSections", "[]", "-tabBarVisible", "[]"
        ]
        app.launch()
        defer { app.terminate() }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }

        let task = "Fixture task 00000"
        let removed = "Journal to remove"
        let retained = "Journal to keep"
        openJournals(in: app)
        for title in [removed, retained] {
            app.buttons["New journal entry"].tap()
            let new = app.navigationBars["New Entry"]
            XCTAssertTrue(new.waitForExistence(timeout: 5))
            let name = app.textFields["Title"]
            name.tap()
            name.typeText(title)
            new.buttons["Save"].tap()
            XCTAssertTrue(new.waitForNonExistence(timeout: 5))
            let row = journalRow(title, in: app)
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            let editor = app.navigationBars["Edit Entry"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            let link = app.buttons["Link Task"]
            for _ in 0..<5 where !link.isHittable { app.swipeUp() }
            XCTAssertTrue(link.isHittable)
            link.tap()
            let picker = app.navigationBars["Link Tasks"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            app.buttons[task].tap()
            picker.buttons["Done"].tap()
            editor.buttons["Cancel"].tap()
        }

        openLinkedJournals(task, retained: retained, in: app)
        let removedLink = app.buttons["\(removed), journal entry"]
        XCTAssertTrue(removedLink.exists, "The task originally links to both journals.")
        app.terminate()
        app.launchArguments.removeAll { $0 == reset }
        app.launch()
        openJournals(in: app)
        let row = journalRow(removed, in: app)
        row.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))

        openLinkedJournals(task, retained: retained, in: app)
        XCTAssertFalse(removedLink.exists, "The deleted association must be hidden immediately.")
        app.terminate()
        app.launch()
        openLinkedJournals(task, retained: retained, in: app)
        XCTAssertFalse(removedLink.exists, "The deleted association must stay hidden after relaunch.")
        app.buttons["\(retained), journal entry"].tap()
        XCTAssertTrue(app.navigationBars["Edit Entry"].waitForExistence(timeout: 5))
        let title = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", retained)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
    }

    @MainActor
    private func openJournals(in app: XCUIApplication) {
        if app.navigationBars["Journals"].exists { return }
        returnToSidebar(in: app)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Journals,")).firstMatch
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable, app.debugDescription)
        row.tap()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openLinkedJournals(_ task: String, retained: String, in app: XCUIApplication) {
        if !app.navigationBars["All Tasks"].exists { returnToSidebar(in: app) }
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "All Tasks")).firstMatch
        for _ in 0..<5 where !all.isHittable && !app.navigationBars["All Tasks"].exists { app.swipeDown() }
        if !app.navigationBars["All Tasks"].exists { all.tap() }
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", task)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Task Details"].waitForExistence(timeout: 5))
        let link = app.buttons["\(retained), journal entry"]
        for _ in 0..<8 where !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.isHittable, "The undeleted journal is still available.")
    }

    @MainActor
    private func returnToSidebar(in app: XCUIApplication) {
        if app.navigationBars["NowThis"].exists { return }
        let back = app.buttons.matching(NSPredicate(format: "identifier == %@", "BackButton")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(app.navigationBars["NowThis"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func journalRow(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }
}
