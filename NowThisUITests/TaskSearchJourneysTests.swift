import XCTest

final class TaskSearchJourneysTests: XCTestCase {
    @MainActor
    func testLocationAndTagSearchRespectAllUpcomingAndOverdueMembership() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-performance-task-count", "1", "-performance-list-count", "1",
            "-performance-sectioned-search-fixture", "-performance-fixture-reset",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-startupScreen", "smart:All Tasks",
            "-showCompletedTasks", "NO"
        ]
        app.launch()
        defer { app.terminate() }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }

        for list in ["All Tasks", "Upcoming", "Overdue"] {
            open(list, in: app)
            for (query, kind) in [("cafe annex", "location"), ("quasar", "tag")] {
                let search = app.searchFields["Search tasks…"]
                XCTAssertTrue(search.waitForExistence(timeout: 5))
                search.tap()
                search.typeText(query)
                let future = task("Search \(kind) future", in: app)
                let past = task("Search \(kind) past", in: app)
                if list != "Overdue" {
                    XCTAssertTrue(future.waitForExistence(timeout: 3), "\(list) must search task \(kind) metadata.")
                } else {
                    XCTAssertFalse(future.exists)
                }
                if list != "Upcoming" {
                    XCTAssertTrue(past.waitForExistence(timeout: 3), "\(list) must search task \(kind) metadata.")
                } else {
                    XCTAssertFalse(past.exists)
                    XCTAssertFalse(task("Search distant control", in: app).exists)
                }
                XCTAssertFalse(task("Search completed control", in: app).exists)
                let close = app.buttons["Close"]
                if close.exists { close.tap() } else { app.buttons["Cancel"].tap() }
            }
        }
    }

    @MainActor
    private func open(_ list: String, in app: XCUIApplication) {
        if app.navigationBars[list].exists { return }
        let back = app.buttons.matching(NSPredicate(format: "identifier == %@", "BackButton")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.navigationBars["NowThis"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", list)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars[list].waitForExistence(timeout: 5))
    }

    @MainActor
    private func task(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }
}
