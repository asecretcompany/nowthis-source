import XCTest

final class SettingsJourneysTests: XCTestCase {
    @MainActor
    func testSyncFailureOpensAccountsAndSyncFromAnotherSettingsPage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-performance-task-count", "20", "-performance-list-count", "1",
            "-performance-missing-credentials", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        defer { app.terminate() }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }

        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        app.buttons["settings.tasks"].tap()
        app.buttons["Task Detail Layout"].tap()
        XCTAssertTrue(app.navigationBars["Task Detail Layout"].waitForExistence(timeout: 5))

        let failure = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Can't sign in to Fixture Nextcloud")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        failure.tap()
        XCTAssertTrue(app.navigationBars["Accounts & Sync"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add Account"].exists)
        XCTAssertTrue(app.staticTexts["Fixture Nextcloud"].exists)
    }

    @MainActor
    func testSettingsGroupsRelatedControlsAndKeepsTheIconPreviewCompact() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-performance-task-count", "20", "-performance-list-count", "1",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        defer { app.terminate() }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }

        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "Settings topics")

        let tasks = app.buttons["settings.tasks"]
        XCTAssertTrue(tasks.waitForExistence(timeout: 5), "Settings should have a dedicated Tasks page.")
        tasks.tap()
        XCTAssertTrue(app.buttons["Task Detail Layout"].exists)
        XCTAssertTrue(app.staticTexts["New Task Defaults"].exists)
        app.navigationBars["Tasks"].buttons.firstMatch.tap()

        app.buttons["Appearance & Layout"].tap()
        XCTAssertTrue(app.buttons["App Icon"].exists)
        XCTAssertTrue(app.staticTexts["Tab Bar"].exists)
        app.buttons["App Icon"].tap()
        XCTAssertTrue(app.buttons["app-icon-default"].exists)
        app.navigationBars["App Icon"].buttons.firstMatch.tap()
        app.navigationBars["Appearance & Layout"].buttons.firstMatch.tap()

        app.buttons["Accounts & Sync"].tap()
        XCTAssertTrue(app.buttons["Add Account"].exists)
        XCTAssertTrue(app.staticTexts["Sync History"].exists)
        app.navigationBars["Accounts & Sync"].buttons.firstMatch.tap()

        app.buttons["Notifications"].tap()
        XCTAssertTrue(app.switches["Banners"].exists)
        app.navigationBars["Notifications"].buttons.firstMatch.tap()

        app.buttons["Integrations"].tap()
        XCTAssertTrue(app.switches["Sync to Apple Calendar"].exists)
        app.navigationBars["Integrations"].buttons.firstMatch.tap()

        app.buttons["Support Development"].tap()
        let more = app.buttons["More Icons"]
        for _ in 0..<4 where !more.exists || !more.isHittable { app.swipeUp() }
        XCTAssertTrue(more.isHittable)
        XCTAssertTrue(app.staticTexts["Supporter 2026"].exists)
        XCTAssertTrue(app.staticTexts["Midnight"].exists)
        let thirdPreview = app.staticTexts["Confetti"]
        XCTAssertFalse(thirdPreview.exists, "Only two artwork previews should be rendered initially.")
        attachScreenshot(of: app, named: "Two-icon Supporter preview")
        more.tap()
        XCTAssertTrue(thirdPreview.waitForExistence(timeout: 5))
        app.buttons["Fewer Icons"].tap()
        XCTAssertTrue(thirdPreview.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
