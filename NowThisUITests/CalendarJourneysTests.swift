import XCTest

final class CalendarJourneysTests: XCTestCase {
    @MainActor
    func testCalendarAddCancelsCleanlyAndSavesInTheSelectedList() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // UserDefaults reads this as a property-list string containing JSON.
        let visibleTabs = #""[\"calendar\"]""#
        let reset = "-performance-fixture-reset"
        app.launchArguments = [
            "-performance-task-count", "1", "-performance-list-count", "2",
            "-performance-calendar-draft-fixture", reset,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-tabBarVisible", visibleTabs, "-startupScreen", "tab:calendar",
            "-defaultNewTaskListID", "performance-fixture-list-0", "-defaultDueDateRule", "none",
            "-defaultReminderEnabled", "NO", "-showCompletedTasks", "NO"
        ]
        app.launch()
        defer { app.terminate() }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }

        let calendar = Calendar.current
        let nextMonth = try XCTUnwrap(calendar.dateInterval(of: .month, for: Date())?.end)
        let selectedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: nextMonth))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        let dateLabel = formatter.string(from: selectedDay)
        let defaultList = "Fixture list 000"
        let scopedList = "Fixture list 001"
        let emptyDay = app.staticTexts["No tasks are due on this date."]
        let openDraft = app.buttons["Add task due on this date"]
        let cancel = app.buttons["Cancel"]
        let confirm = app.buttons["Add"]

        XCTAssertTrue(app.navigationBars["Calendar"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Calendar"].buttons["Done"].exists)
        openDay(in: app, list: scopedList, dateLabel: dateLabel)
        XCTAssertTrue(emptyDay.waitForExistence(timeout: 5))
        XCTAssertTrue(openDraft.isHittable)
        openDraft.tap()
        let openedDraft = cancel.waitForExistence(timeout: 3)
        let blankDraftCanSave = confirm.exists && confirm.isEnabled
        if openedDraft { cancel.tap() }

        // Reopen the same dedicated fixture without reseeding. A blank row inserted by the
        // old Add action is durable in the default list, even though it was tapped in B.
        app.terminate()
        app.launchArguments.removeAll { $0 == reset }
        app.launch()
        openDay(in: app, list: defaultList, dateLabel: dateLabel)
        XCTAssertTrue(emptyDay.waitForExistence(timeout: 5), "Opening Add must leave the default list's selected day empty after relaunch.")
        selectList(scopedList, in: app)
        XCTAssertTrue(emptyDay.waitForExistence(timeout: 5), "Cancel must leave the scoped list's selected day empty after relaunch.")
        XCTAssertTrue(openedDraft, "Calendar Add must open the cancellable editor.")
        XCTAssertFalse(blankDraftCanSave)
        guard openedDraft else { return }

        let week = app.segmentedControls["Calendar view mode"].buttons["Week"]
        XCTAssertTrue(week.isHittable)
        week.tap()
        openDraft.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[scopedList].exists)
        let dueDate = app.buttons["Due date"]
        XCTAssertEqual(dueDate.value as? String, "Set")
        let draftScreenshot = XCTAttachment(screenshot: app.screenshot())
        draftScreenshot.name = "Calendar draft showing its list and due date"
        draftScreenshot.lifetime = .keepAlways
        add(draftScreenshot)
        let taskTitle = "Calendar draft verification"
        let title = app.descendants(matching: .any).matching(identifier: "Task title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(taskTitle)
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(taskRow(in: app, title: taskTitle).waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        openDay(in: app, list: scopedList, dateLabel: dateLabel)
        let created = taskRow(in: app, title: taskTitle)
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", taskTitle)).count, 1)
        selectList(defaultList, in: app)
        XCTAssertTrue(emptyDay.waitForExistence(timeout: 5))
    }

    @MainActor
    func testHiddenCalendarKeepsItsOwnAddAndDismissControls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-performance-task-count", "1", "-performance-list-count", "2",
            "-performance-calendar-draft-fixture", "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US", "-startupScreen", "smart:Today"
        ]
        app.launch()
        defer { app.terminate() }
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        app.buttons["Appearance & Layout"].tap()
        let hide = app.buttons["Hide Calendar"]
        if hide.exists { hide.tap() }
        let show = app.buttons["Show Calendar"]
        XCTAssertTrue(show.exists)

        app.buttons["Tasks"].tap()
        let titleMenu = app.navigationBars["Today"].descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Today")).firstMatch
        XCTAssertTrue(titleMenu.waitForExistence(timeout: 5))
        titleMenu.tap()
        let calendar = app.buttons["Calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        calendar.tap()
        let calendarMode = app.segmentedControls["Calendar view mode"]
        XCTAssertTrue(calendarMode.waitForExistence(timeout: 5))
        let done = app.buttons["Done"]
        let openDraft = app.buttons["Add task due on this date"]
        XCTAssertTrue(done.isHittable)
        selectList("Fixture list 001", in: app)
        let today = app.buttons["Go to today"]
        XCTAssertTrue(today.isHittable)
        app.buttons["Next month"].tap()
        today.tap()
        let todayCell = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", ", today")).firstMatch
        XCTAssertTrue(todayCell.waitForExistence(timeout: 5))
        XCTAssertTrue(todayCell.isSelected)
        XCTAssertTrue(openDraft.isHittable)
        openDraft.tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(calendarMode.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(titleMenu.waitForExistence(timeout: 5))

        settings.tap()
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        show.tap()
    }

    @MainActor
    func testTodayRevealsItsSelectedDayInLandscapeMonth() throws {
        continueAfterFailure = false
        let rightToLeft = ProcessInfo.processInfo.environment["NOWTHIS_CALENDAR_RTL"] == "1"
        let app = XCUIApplication()
        app.launchArguments = [
            "-performance-task-count", "1", "-performance-list-count", "2",
            "-performance-calendar-draft-fixture", "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US", "-tabBarVisible", #""[\"calendar\"]""#,
            "-startupScreen", "tab:calendar", "-showCompletedTasks", "NO"
        ]
        if rightToLeft {
            app.launchArguments += ["-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"]
        }
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }

        let toolbar = app.navigationBars["Calendar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        waitForCalendarLayout {
            window.frame.width > window.frame.height && window.frame.height > 0
        }
        XCTAssertGreaterThan(window.frame.width, window.frame.height, "The journey requires real landscape geometry.")

        let scope = app.buttons["Select list"]
        let today = app.buttons["Go to today"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        XCTAssertTrue(scope.isHittable)
        XCTAssertTrue(today.isHittable)
        XCTAssertGreaterThanOrEqual(scope.frame.minY, toolbar.frame.maxY - 1)
        XCTAssertGreaterThanOrEqual(today.frame.minY, toolbar.frame.maxY - 1)
        if rightToLeft {
            XCTAssertGreaterThan(scope.frame.midX, today.frame.midX, "The scope row must actually mirror in RTL.")
        } else {
            XCTAssertLessThan(scope.frame.midX, today.frame.midX)
        }

        let nextMonth = app.buttons["Next month"]
        let month = app.scrollViews.containing(.button, identifier: "Next month").firstMatch
        XCTAssertTrue(month.waitForExistence(timeout: 5), "The journey requires the constrained month scroller.")
        let todayCell = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", ", today")).firstMatch
        print("Calendar landscape window=\(window.frame) toolbar=\(toolbar.frame) scope=\(scope.frame) direction=\(rightToLeft ? "RTL" : "LTR")")
        XCTAssertTrue(nextMonth.isHittable)
        nextMonth.tap()
        XCTAssertTrue(todayCell.waitForNonExistence(timeout: 5))
        today.tap()
        assertSelectedDayIsVisible(todayCell, within: month, checkpoint: "Today from next month")

        // Hide today's row while keeping the selection. Try the opposite edge if today is already near the top.
        for _ in 0..<5 where dayIsVisible(todayCell, within: month) { month.swipeDown() }
        for _ in 0..<5 where dayIsVisible(todayCell, within: month) { month.swipeUp() }
        XCTAssertFalse(dayIsVisible(todayCell, within: month), "Manual scrolling must hide the already-selected day.")
        today.tap()
        assertSelectedDayIsVisible(todayCell, within: month, checkpoint: "Today after scrolling away")

        let calendar = Calendar.current
        let end = try XCTUnwrap(calendar.dateInterval(of: .month, for: Date())?.end)
        let lastDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: end))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        let lastCell = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", formatter.string(from: lastDay)
        )).firstMatch
        for _ in 0..<6 where !dayIsVisible(lastCell, within: month) { month.swipeUp() }
        XCTAssertTrue(dayIsVisible(lastCell, within: month), "Manual scrolling must reach the last day.")
        lastCell.tap()
        assertSelectedDayIsVisible(lastCell, within: month, checkpoint: "Manually selected last day")
    }

    @MainActor
    private func assertSelectedDayIsVisible(_ day: XCUIElement, within viewport: XCUIElement, checkpoint: String) {
        waitForCalendarLayout { dayIsVisible(day, within: viewport) && day.isSelected }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = checkpoint
        attachment.lifetime = .keepAlways
        add(attachment)
        print("\(checkpoint): day=\(day.frame) viewport=\(viewport.frame) hit=\(day.isHittable) selected=\(day.isSelected)")
        XCTAssertTrue(dayIsVisible(day, within: viewport), "\(checkpoint): the day must be hittable inside the month viewport.")
        XCTAssertTrue(day.isSelected, "\(checkpoint): the visible day must be selected.")
    }

    @MainActor
    private func dayIsVisible(_ day: XCUIElement, within viewport: XCUIElement) -> Bool {
        guard day.exists, day.isHittable else { return false }
        let frame = day.frame
        // AX5's text frame can extend beyond its 40-point cell; the actual day center must be visible.
        return viewport.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    @MainActor
    private func waitForCalendarLayout(_ ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !ready(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    @MainActor
    private func openDay(in app: XCUIApplication, list: String, dateLabel: String) {
        XCTAssertTrue(app.segmentedControls["Calendar view mode"].waitForExistence(timeout: 10))
        selectList(list, in: app)
        let next = app.buttons["Next month"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        let cell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", dateLabel)).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "The selected future date must be reachable in Month.")
        cell.tap()
    }

    @MainActor
    private func selectList(_ name: String, in app: XCUIApplication) {
        let picker = app.buttons["Select list"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.isHittable)
        picker.tap()
        let option = app.buttons[name]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        XCTAssertEqual(picker.value as? String, name)
    }

    @MainActor
    private func taskRow(in app: XCUIApplication, title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }
}
