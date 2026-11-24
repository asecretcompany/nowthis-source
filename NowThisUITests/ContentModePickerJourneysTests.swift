import XCTest

final class ContentModePickerJourneysTests: XCTestCase {
#if compiler(>=6.4)
    @MainActor
    func testCalendarModesAnnounceTabsAndSwitchSelection() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Requires the iOS 27 VoiceOver testing service.") }
        let voiceOver = XCUIDevice.shared.voiceOverService
        let wasEnabled = voiceOver.isEnabled
        defer { restoreVoiceOver(wasEnabled) }
        if wasEnabled { try voiceOver.disable() }

        let app = launchFixture(tab: "calendar")
        defer { app.terminate() }
        let nextMonth = app.buttons["Next month"]
        let nextWeek = app.buttons["Next week"]
        XCTAssertTrue(nextMonth.waitForExistence(timeout: 5))

        let week = try mode("Week", in: app)
        week.tap()
        XCTAssertTrue(nextWeek.waitForExistence(timeout: 5))
        XCTAssertTrue(nextMonth.waitForNonExistence(timeout: 5))
        XCTAssertTrue(week.isSelected)
        attachScreenshot(of: app, named: "Calendar in Week mode")
        try assertSelectedTabSpeech(for: "Week")

        let month = try mode("Month", in: app)
        month.tap()
        XCTAssertTrue(nextMonth.waitForExistence(timeout: 5))
        XCTAssertTrue(nextWeek.waitForNonExistence(timeout: 5))
        XCTAssertTrue(month.isSelected)
        attachScreenshot(of: app, named: "Calendar in Month mode")
        try assertSelectedTabSpeech(for: "Month")
    }

    @MainActor
    func testBoardModesAnnounceTabsAndPreserveListSelection() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Requires the iOS 27 VoiceOver testing service.") }
        let voiceOver = XCUIDevice.shared.voiceOverService
        let wasEnabled = voiceOver.isEnabled
        defer { restoreVoiceOver(wasEnabled) }
        if wasEnabled { try voiceOver.disable() }

        let app = launchFixture(tab: "board")
        defer { app.terminate() }
        let status = try mode("Status", in: app)
        if !status.isSelected { status.tap() }
        let listName = "Fixture list 001"
        let listMenu = app.buttons["Select list"]
        XCTAssertTrue(listMenu.waitForExistence(timeout: 5))
        listMenu.tap()
        let option = app.buttons[listName]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()

        let lists = try mode("Lists", in: app)
        lists.tap()
        let listHeader = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(listName), ")).firstMatch
        XCTAssertTrue(listHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(listHeader.isHittable, "Lists should open on the selected list.")
        XCTAssertTrue(lists.isSelected)
        attachScreenshot(of: app, named: "Board in Lists mode on \(listName)")
        try assertSelectedTabSpeech(for: "Lists")

        status.tap()
        XCTAssertTrue(listMenu.waitForExistence(timeout: 5))
        XCTAssertTrue(status.isSelected)
        // The fixture assigns these To Do cards to list 001. Any one on
        // screen confirms the Status columns are scoped to the same list.
        let statusCard = app.buttons.matching(NSPredicate(format: "label MATCHES %@",
            "^Fixture task (00009|00021|00033|00045|00057|00069).*")).firstMatch
        XCTAssertTrue(statusCard.waitForExistence(timeout: 5))
        XCTAssertTrue(statusCard.isHittable, "Status should keep the selected list.")
        attachScreenshot(of: app, named: "Board in Status mode on \(listName)")
        try assertSelectedTabSpeech(for: "Status")

        lists.tap()
        XCTAssertTrue(listHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(listHeader.isHittable)
        app.terminate()
        app.launchArguments = fixtureArguments
        app.launch()
        let board = app.tabBars.buttons["Board"]
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        if !board.isSelected { board.tap() }
        XCTAssertTrue(lists.waitForExistence(timeout: 5))
        XCTAssertTrue(lists.isSelected, "Board should reopen in the last selected mode.")
        XCTAssertTrue(listHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(listHeader.isHittable, "Board should reopen on the last selected list.")
        attachScreenshot(of: app, named: "Board after relaunch on \(listName)")
    }

    func testModeSpeechMatchesRecordedPickerAndTabViewAnnouncements() {
        let picker = modeSpeech("selected NowThis Status Button 1 of 2", for: "Status")
        XCTAssertEqual(picker?.role, .button)
        XCTAssertEqual(picker?.isSelected, true)

        let native = modeSpeech("Tab Bar selected Home anchor Tab 1 of 2", for: "Home anchor")
        XCTAssertEqual(native?.role, .tab)
        XCTAssertEqual(native?.isSelected, true)

        let unselected = modeSpeech("Other anchor Tab 2 of 2", for: "Other anchor")
        XCTAssertEqual(unselected?.role, .tab)
        XCTAssertEqual(unselected?.isSelected, false)
        XCTAssertNil(modeSpeech("selected Week Button 2 of 2", for: "Month"))
    }

    func testModeSpeechKeepsTheContainerSeparateFromTheItemRole() {
        let button = modeSpeech("Tab Bar selected Month Button 1 of 2", for: "Month")
        XCTAssertEqual(button?.role, .button)
        XCTAssertEqual(button?.isSelected, true)

        let noRole = modeSpeech("Tab Bar selected Month 1 of 2", for: "Month")
        XCTAssertNotNil(noRole)
        XCTAssertNil(noRole?.role)

        let hint = modeSpeech("selected Month Button Double tap to activate tab", for: "Month")
        XCTAssertEqual(hint?.role, .button)
    }

    private enum SpokenRole: String {
        case button
        case tab
    }

    private func modeSpeech(_ utterance: String, for label: String) -> (isSelected: Bool, role: SpokenRole?)? {
        var item = utterance.lowercased().split { !$0.isLetter }[...]
        if item.starts(with: ["tab", "bar"]) {
            item = item.dropFirst(2)
        }
        // The app name and selected-state prefix can precede the item label.
        let namedItem = item.drop(while: { $0 == "selected" || $0 == "nowthis" })
        let expectedLabel = label.lowercased().split { !$0.isLetter }
        guard namedItem.starts(with: expectedLabel) else { return nil }

        // The role directly follows the item label and is independent of container speech.
        let suffix = namedItem.dropFirst(expectedLabel.count)
        let role = suffix.first.flatMap { SpokenRole(rawValue: String($0)) }
        let selected = item.prefix(upTo: namedItem.startIndex).contains("selected")
            || suffix.dropFirst().first == "selected"
        return (selected, role)
    }

    private let fixtureArguments = ["-performance-task-count", "80", "-performance-list-count", "4"]

    @MainActor
    private func launchFixture(tab: String) -> XCUIApplication {
        let app = XCUIApplication()
        // UserDefaults reads this argument as a quoted property-list string containing JSON.
        let visibleTabs = #""[\"calendar\",\"board\"]""#
        app.launchArguments = fixtureArguments + [
            "-performance-fixture-reset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-tabBarVisible", visibleTabs, "-startupScreen", "tab:\(tab)"
        ]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        XCTAssertFalse(app.tabBars.buttons["Matrix"].exists, "Only Calendar and Board should be configured.")
        return app
    }

    @MainActor
    private func mode(_ label: String, in app: XCUIApplication) throws -> XCUIElement {
        let option = app.navigationBars.buttons[label]
        return try XCTUnwrap(option.waitForExistence(timeout: 5) ? option : nil,
                             "Expected a \(label) mode option in the toolbar. \(app.navigationBars.debugDescription)")
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @available(iOS 27.0, *)
    @MainActor
    private func assertSelectedTabSpeech(for label: String) throws {
        let voiceOver = XCUIDevice.shared.voiceOverService
        try voiceOver.enable()
        defer { XCTAssertNoThrow(try voiceOver.disable()) }

        var announcements: [String] = []
        defer {
            let speech = XCTAttachment(string: announcements.joined(separator: "\n"))
            speech.name = "VoiceOver traversal to \(label)"
            speech.lifetime = .keepAlways
            add(speech)
        }

        // Enabling VoiceOver can already land on the first mode.
        var currentSpeech = try? voiceOver.currentSpeech().utterance
        for _ in 0..<24 {
            let utterance = try currentSpeech ?? voiceOver.moveForward().utterance
            currentSpeech = nil
            announcements.append(utterance)
            guard let speech = modeSpeech(utterance, for: label) else { continue }

            print("VoiceOver \(label) mode: \(utterance)")
            XCTAssertTrue(speech.isSelected, "Expected the selected state. Heard: \(utterance)")

            // Apple's standalone TabsPickerStyle sample also speaks Button on this simulator build.
            // A real TabView speaks Tab in the same VoiceOver session.
            let options = XCTExpectedFailure.Options()
#if targetEnvironment(simulator)
            let runtime = ProcessInfo.processInfo.operatingSystemVersionString
            let runtimeBuild = runtime.split { !$0.isLetter && !$0.isNumber }.last
            options.isEnabled = runtimeBuild == "24B8117"
#else
            options.isEnabled = false
#endif
            options.isStrict = true
            options.issueMatcher = { _ in speech.role == .button }
            XCTExpectFailure("TabsPickerStyle speaks Button on iOS simulator build 24B8117.", options: options) {
                XCTAssertTrue(speech.role == .tab, "Expected the native tab role. Heard: \(utterance)")
            }
            return
        }

        XCTFail("VoiceOver did not reach the \(label) mode. Heard: \(announcements)")
    }

    @available(iOS 27.0, *)
    @MainActor
    private func restoreVoiceOver(_ wasEnabled: Bool) {
        let voiceOver = XCUIDevice.shared.voiceOverService
        guard voiceOver.isEnabled != wasEnabled else { return }
        if wasEnabled {
            XCTAssertNoThrow(try voiceOver.enable())
        } else {
            XCTAssertNoThrow(try voiceOver.disable())
        }
    }
#endif
}
