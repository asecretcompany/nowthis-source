import XCTest

final class SavedFilterJourneysTests: XCTestCase {
    private let reset = "-performance-fixture-reset"

    @MainActor
    func testDamagedAndInvalidOrFiltersNeverDisplayUnfilteredTasksAndCanBeRepaired() {
        let app = launch()
        defer { app.terminate() }
        openFilter("Legacy invalid OR", in: app)
        XCTAssertFalse(task("Filter expected priority", in: app).waitForExistence(timeout: 2),
                       "A valid OR branch cannot display tasks from a filter with another invalid rule.")
        XCTAssertFalse(task("Filter unrelated undated", in: app).exists)
        openFilter("Legacy damaged filter", in: app)
        XCTAssertFalse(task("Filter unrelated past", in: app).waitForExistence(timeout: 2),
                       "Corrupt stored criteria must not display unfiltered tasks.")
        let edit = app.buttons["Edit Filter"].firstMatch
        let canEdit = edit.waitForExistence(timeout: 3)
        XCTAssertTrue(canEdit)
        guard canEdit else { return }
        attachScreenshot("Saved filter repair action", in: app)
        edit.tap()
        let sheet = app.navigationBars["Edit Filter"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.buttons["Cancel"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))

        app.terminate()
        app.launchArguments.removeAll { $0 == reset }
        app.launch()
        openFilter("Legacy damaged filter", in: app)
        XCTAssertFalse(task("Filter unrelated past", in: app).exists)
        XCTAssertTrue(edit.isHittable)
        edit.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        addRule("Priority", in: app)
        attachScreenshot("Saved filter Priority default", in: app)
        sheet.buttons["Save"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Legacy damaged filter"].exists)
        XCTAssertTrue(task("Filter expected priority", in: app).waitForExistence(timeout: 5),
                      "The selected filter refreshes after repair without leaving its screen.")
        XCTAssertFalse(task("Filter unrelated past", in: app).exists)

        openFilter("Existing editable filter", in: app)
        XCTAssertTrue(task("Filter unrelated past", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(task("Filter expected priority", in: app).exists)
        let menu = app.buttons["More"].firstMatch
        if !edit.isHittable, menu.exists { menu.tap() }
        XCTAssertTrue(edit.isHittable, app.debugDescription)
        edit.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let name = app.textFields["Filter name"]
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Existing editable filter".count))
        name.typeText("Renamed editable filter")
        let value = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Value, Low")).firstMatch
        for _ in 0..<4 where !value.isHittable { app.swipeUp() }
        XCTAssertTrue(value.isHittable, app.debugDescription)
        value.tap()
        app.buttons["High"].tap()
        sheet.buttons["Save"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Renamed editable filter"].waitForExistence(timeout: 5))
        XCTAssertTrue(task("Filter expected priority", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(task("Filter unrelated past", in: app).exists)
        returnToSidebar(in: app)
        XCTAssertTrue(app.buttons["Renamed editable filter, custom filter"].exists)
        XCTAssertFalse(app.buttons["Existing editable filter, custom filter"].exists)
    }

    @MainActor
    func testNewFilterSavesTheDefaultOfTheFieldSelected() {
        let app = launch()
        defer { app.terminate() }
        for (field, positive, negative) in [
            ("Priority", "Filter expected priority", "Filter unrelated past"),
            ("Has Due Date", "Filter expected priority", "Filter unrelated undated"),
            ("Due Before", "Filter unrelated past", "Filter expected priority"),
            ("Due After", "Filter expected priority", "Filter unrelated past"),
        ] {
            returnToSidebar(in: app)
            let new = app.buttons["New Filter"]
            for _ in 0..<3 where !new.isHittable { app.swipeUp() }
            XCTAssertTrue(new.isHittable)
            new.tap()
            let sheet = app.navigationBars["New Filter"]
            XCTAssertTrue(sheet.waitForExistence(timeout: 5))
            let name = app.textFields["Filter name"]
            name.tap()
            let filterName = "New \(field) test"
            name.typeText(filterName)
            addRule(field, in: app, changeOldComparison: true)
            sheet.buttons["Save"].tap()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
            openFilter(filterName, in: app)
            XCTAssertTrue(task(positive, in: app).waitForExistence(timeout: 3), "\(field) should keep its displayed default on save.")
            XCTAssertFalse(task(negative, in: app).exists)
        }
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-performance-task-count", "1", "-performance-list-count", "1",
            "-performance-filter-repair-fixture", reset,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-startupScreen", "smart:All Tasks",
            "-sidebarHiddenSections", "[]", "-showCompletedTasks", "NO"
        ]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        return app
    }

    @MainActor
    private func addRule(_ field: String, in app: XCUIApplication, changeOldComparison: Bool = false) {
        let add = app.buttons["Add Rule"]
        for _ in 0..<4 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.isHittable)
        add.tap()
        if changeOldComparison {
            let comparison = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Comparison")).firstMatch
            for _ in 0..<3 where !comparison.isHittable { app.swipeUp() }
            comparison.tap()
            app.buttons["is not"].tap()
        }
        let picker = app.buttons["Field"].firstMatch
        for _ in 0..<3 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.isHittable)
        picker.tap()
        app.buttons[field].tap()
    }

    @MainActor
    private func openFilter(_ name: String, in app: XCUIApplication) {
        if app.navigationBars[name].exists { return }
        returnToSidebar(in: app)
        let row = app.buttons["\(name), custom filter"]
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable, app.debugDescription)
        row.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))
    }

    @MainActor
    private func returnToSidebar(in app: XCUIApplication) {
        if app.navigationBars["NowThis"].exists { return }
        let back = app.buttons.matching(NSPredicate(format: "identifier == %@", "BackButton")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(app.navigationBars["NowThis"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func task(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    @MainActor
    private func attachScreenshot(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
