import XCTest

/// Release-only UI journeys backed by `PerformanceLaunchFixture` in the app target.
final class PerformanceJourneysTests: XCTestCase {
    @MainActor
    private static var resetProfiles = Set<String>()

    @MainActor
    func testColdLaunchMetric() {
        let seedLaunch = launchFixture(taskCount: 10_000, listCount: 100)
        XCTAssertTrue(seedLaunch.tabBars.buttons["Tasks"].waitForExistence(timeout: 10))
        let seededTask = seedLaunch.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Fixture task 00000")
        ).firstMatch
        XCTAssertTrue(seededTask.waitForExistence(timeout: 10))
        seedLaunch.terminate()

        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = launchFixture(taskCount: 10_000, listCount: 100)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            XCTAssertTrue(app.tabBars.buttons["Tasks"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.tabBars.buttons["Board"].exists)
            XCTAssertFalse(app.buttons["Get Started"].exists)
            let seededTask = app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", "Fixture task 00000")
            ).firstMatch
            XCTAssertTrue(seededTask.waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    @MainActor
    func testWarmTabSearchAndScrollJourney() {
        let app = launchFixture(taskCount: 10_000, listCount: 100)
        XCTAssertTrue(app.tabBars.buttons["Tasks"].waitForExistence(timeout: 10))

        // Functional journey only. Device traces measure warm tab/scroll budgets;
        // XCTest's clock measurement also runs a warm-up and retains search state.
        app.tabBars.buttons["Board"].tap()
        XCTAssertTrue(app.navigationBars["Board"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Calendar"].tap()
        XCTAssertTrue(app.segmentedControls["Calendar view mode"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Matrix"].tap()
        XCTAssertTrue(app.navigationBars["Matrix"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Tasks"].tap()
        let sidebarBackButton = app.navigationBars.buttons["NowThis"]
        if sidebarBackButton.exists {
            sidebarBackButton.tap()
        }
        let journalsRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Journals")
        ).firstMatch
        XCTAssertTrue(journalsRow.waitForExistence(timeout: 5))
        journalsRow.tap()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 5))
        let seededJournal = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Fixture journal 00000")
        ).firstMatch
        XCTAssertTrue(seededJournal.exists)

        app.tabBars.buttons["Tasks"].tap()
        let journalsBack = app.navigationBars.buttons["NowThis"]
        if journalsBack.exists { journalsBack.tap() }
        let todayRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Today")).firstMatch
        XCTAssertTrue(todayRow.waitForExistence(timeout: 5))
        todayRow.tap()
        let searchField = app.searchFields["Search tasks…"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("Fixture task 00000")
        let matchingTask = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Fixture task 00000")
        ).firstMatch
        XCTAssertTrue(matchingTask.waitForExistence(timeout: 5))

        searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 18))
        let clearedValue = searchField.value as? String
        XCTAssertTrue(clearedValue == "" || clearedValue == "Search tasks…")
        // The default due-date sort has thousands of ties. Clearing search
        // restores that list; the matched task need not stay in its viewport.
        let restoredRows = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Fixture task ")
        )
        XCTAssertTrue(restoredRows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(restoredRows.count, 1)
        // Clearing the query disables the keyboard's Search key. Cancel
        // ends search focus so the following gestures reach the task list.
        if app.buttons["Cancel"].isHittable {
            app.buttons["Cancel"].tap()
        }

        let taskList = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        if taskList.exists {
            for _ in 0..<10 { taskList.swipeUp() }
        } else {
            XCTFail("The Tasks screen did not expose its scrollable list")
        }
        XCTAssertTrue(app.tabBars.buttons["Tasks"].exists)
        app.terminate()
    }

    @MainActor
    func testSingleListWarmTabJourney() {
        let app = launchFixture(taskCount: 10_000, listCount: 1)
        XCTAssertTrue(app.tabBars.buttons["Tasks"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Calendar"].tap()
        XCTAssertTrue(app.segmentedControls["Calendar view mode"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Board"].tap()
        XCTAssertTrue(app.navigationBars["Board"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Matrix"].tap()
        XCTAssertTrue(app.navigationBars["Matrix"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testStress50KWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["PERFORMANCE_RUN_STRESS_50K"] == "1" else {
            throw XCTSkip("Set PERFORMANCE_RUN_STRESS_50K=1 to run the 50k UI launch benchmark.")
        }
        let seedLaunch = launchFixture(taskCount: 50_000, listCount: 100)
        XCTAssertTrue(seedLaunch.tabBars.buttons["Tasks"].waitForExistence(timeout: 10))
        seedLaunch.terminate()

        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = launchFixture(taskCount: 50_000, listCount: 100)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            XCTAssertTrue(app.tabBars.buttons["Tasks"].waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    @MainActor
    func testRecoveryOffersAccessibleRetryWithoutOpeningTheApp() {
        let app = XCUIApplication()
        app.launchArguments = ["-performance-task-count", "50001", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your task data couldn't be opened"].waitForExistence(timeout: 10))
        let retry = app.buttons["Retry opening your saved task data"]
        XCTAssertTrue(retry.exists)
        XCTAssertFalse(app.tabBars.buttons["Tasks"].exists)
        retry.tap()
        XCTAssertTrue(app.staticTexts["Your task data couldn't be opened"].exists)
        XCTAssertTrue(retry.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Store recovery accessibility"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    @MainActor
    private func launchFixture(taskCount: Int, listCount: Int) -> XCUIApplication {
        let app = XCUIApplication()
        let profile = "\(taskCount)-\(listCount)"
        app.launchArguments = [
            "-performance-task-count", String(taskCount),
            "-performance-list-count", String(listCount),
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-startupScreen", "smart:Today"
        ]
        if Self.resetProfiles.insert(profile).inserted {
            app.launchArguments.append("-performance-fixture-reset")
        }
        app.launch()
        return app
    }
}
