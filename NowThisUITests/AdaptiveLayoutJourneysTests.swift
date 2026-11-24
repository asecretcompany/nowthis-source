import XCTest

/// Exercises actual Duo chrome and hit regions, rather than approximating its safe area.
final class AdaptiveLayoutJourneysTests: XCTestCase {
    @MainActor
    func testFilterChipsStayClearOfVerticalNavigationControls() throws {
        try runFilterJourney(orientation: .portrait)
    }

    @MainActor
    func testFilterChipsInLandscapeLeft() throws {
        try runFilterJourney(orientation: .landscapeLeft)
    }

    @MainActor
    func testFilterChipsInLandscapeRight() throws {
        try runFilterJourney(orientation: .landscapeRight)
    }

    @MainActor
    func testFilterChipsWithRightToLeftLayout() throws {
        try runFilterJourney(orientation: .portrait, rightToLeft: true)
    }

    /// The host helper changes Simulator traits while this process and app remain alive.
    /// UIKit trait overrides cannot reproduce Duo's scene-owned vertical toolbar.
    @MainActor
    func testToolbarAddSurvivesLiveTextSizeAndRotation() throws {
        guard let runID = ProcessInfo.processInfo.environment["NOWTHIS_DUO_TRAIT_RUN_ID"] else {
            throw XCTSkip("Run through tools/verify_duo_toolbar.py to coordinate live Simulator traits")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-performance-task-count", "80", "-performance-list-count", "4",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-startupScreen", "smart:Today"
        ]
        app.launch()
        defer { app.terminate() }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let add = app.buttons["Add task"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "The cold large-text baseline must expose Add")
        XCTAssertTrue(app.buttons["BackButton"].exists, "The baseline must have a pushed list")
        let directory = URL.documentsDirectory.appending(path: "DuoToolbar-\(runID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("ready".utf8).write(to: directory.appending(path: "ready"), options: .atomic)
        let deadline = Date().addingTimeInterval(45)
        while !FileManager.default.fileExists(atPath: directory.appending(path: "continue").path) {
            guard Date() < deadline else { XCTFail("Host did not apply the live trait change"); return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let rotationDeadline = Date().addingTimeInterval(10)
        while app.windows.firstMatch.frame.width <= app.windows.firstMatch.frame.height, Date() < rotationDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height,
                             "This regression requires actual landscape reflow")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "toolbar-after-live-accessibility-size-and-rotation"
        attachment.lifetime = .keepAlways
        self.add(attachment)
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Live trait changes must retain the accessible Add action")
        XCTAssertTrue(add.isHittable)
        add.tap()
        XCTAssertTrue(app.textFields["Task title"].waitForExistence(timeout: 5), "Add must open Quick Add")
        XCTAssertTrue(app.staticTexts["New Task"].exists)
        let titleField = app.textFields["Task title"]
        let cancel = app.buttons["Cancel"]
        XCTAssertGreaterThanOrEqual(titleField.frame.minY, cancel.frame.maxY,
                                    "The task title must stay below the sheet toolbar at large text sizes")
        titleField.typeText("Duo toolbar draft")
        XCTAssertEqual(titleField.value as? String, "Duo toolbar draft")
        XCTAssertTrue(cancel.isHittable, "The keyboard must leave Cancel reachable")
        XCTAssertGreaterThanOrEqual(titleField.frame.minY, max(0, cancel.frame.maxY))
        let editorAttachment = XCTAttachment(screenshot: app.screenshot())
        editorAttachment.name = "quick-add-large-text-with-typed-draft"
        editorAttachment.lifetime = .keepAlways
        self.add(editorAttachment)
        try Data().write(to: directory.appending(path: "fold"))
        try waitForDuoHost("opened", in: directory)
        let openDeadline = Date().addingTimeInterval(10)
        while max(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height) < 800,
              Date() < openDeadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertGreaterThan(max(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height), 800)
        XCTAssertEqual(titleField.value as? String, "Duo toolbar draft")
        try Data().write(to: directory.appending(path: "close"))
        try waitForDuoHost("closed", in: directory)
        let closeDeadline = Date().addingTimeInterval(10)
        while max(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height) > 800,
              Date() < closeDeadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertLessThan(max(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height), 800)
        XCTAssertEqual(titleField.value as? String, "Duo toolbar draft")
        cancel.tap()
        try Data().write(to: directory.appending(path: "restore"))
        try waitForDuoHost("restored", in: directory)
        XCUIDevice.shared.orientation = .portrait
        let portraitDeadline = Date().addingTimeInterval(10)
        while app.windows.firstMatch.frame.width >= app.windows.firstMatch.frame.height,
              Date() < portraitDeadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertLessThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Add must survive the complete draft/fold/trait roundtrip")
        XCTAssertTrue(app.buttons["BackButton"].exists, "Back must survive the complete roundtrip")
    }

    @MainActor
    func testSidebarRemainsReachableAfterDuoColdInnerCollapse() throws {
        guard let runID = ProcessInfo.processInfo.environment["NOWTHIS_DUO_TRAIT_RUN_ID"] else {
            throw XCTSkip("Run tools/verify_duo_toolbar.py --journey navigation to coordinate the live Duo hinge")
        }
        continueAfterFailure = false
        let directory = URL.documentsDirectory.appending(path: "DuoToolbar-\(runID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = [
            "-performance-task-count", "80", "-performance-list-count", "4",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-startupScreen", "smart:Today"
        ]
        app.launch()
        defer { app.terminate() }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }

        func checkpoint(_ name: String, innerPanel: Bool, selection: String) throws {
            assertDuoPanel(in: app, innerPanel: innerPanel)
            XCTAssertTrue(app.navigationBars[selection].waitForExistence(timeout: 5),
                          "The \(selection) list should remain selected at \(name)")
            attach(app, name: name)
            try Data().write(to: directory.appending(path: name), options: .atomic)
            try waitForDuoHost("\(name)-recorded", in: directory)
        }

        let listName = "Fixture list 001"
        try checkpoint("cold-inner", innerPanel: true, selection: "Today")
        try waitForDuoHost("closed", in: directory)
        try checkpoint("cold-inner-then-closed", innerPanel: false, selection: "Today")
        selectFixtureList(listName, using: app.buttons["tasks.showSidebar"], in: app)
        attach(app, name: "fixture-list-after-cold-inner-collapse")
        app.terminate()

        app.launch()
        try checkpoint("cold-outer", innerPanel: false, selection: "Today")
        selectFixtureList(listName, using: app.buttons["BackButton"], in: app)
        try Data().write(to: directory.appending(path: "open"), options: .atomic)
        try waitForDuoHost("opened", in: directory)
        try checkpoint("cold-outer-then-open", innerPanel: true, selection: listName)
        try waitForDuoHost("reclosed", in: directory)
        try checkpoint("cold-outer-roundtrip", innerPanel: false, selection: listName)
        selectFixtureList("Fixture list 002", using: app.buttons["BackButton"], in: app)
        attach(app, name: "different-fixture-list-after-cold-outer-roundtrip")
    }

    @MainActor
    private func assertDuoPanel(in app: XCUIApplication, innerPanel: Bool) {
        let window = app.windows.firstMatch
        let deadline = Date().addingTimeInterval(10)
        let expectedSize = innerPanel ? CGSize(width: 951, height: 669) : CGSize(width: 466, height: 678)
        var frame = window.frame
        while frame.size != expectedSize, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            frame = window.frame
        }
        print("Duo \(innerPanel ? "inner" : "outer") panel: \(frame)")
        XCTAssertEqual(frame.size, expectedSize, "Expected the real Duo \(innerPanel ? "open" : "closed portrait") window")
    }

    @MainActor
    private func selectFixtureList(_ name: String, using control: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(control.waitForExistence(timeout: 5) && control.isHittable,
                      "The expected navigation control must be reachable to select \(name)")
        control.tap()
        let sidebar = app.collectionViews.firstMatch
        XCTAssertTrue(app.navigationBars["NowThis"].waitForExistence(timeout: 5),
                      "The navigation control should return to the Tasks sidebar")
        let row = sidebar.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(name), ")).firstMatch
        for _ in 0..<3 where !row.isHittable { sidebar.swipeUp() }
        XCTAssertTrue(row.isHittable, "Expected the accessible sidebar row for \(name)")
        row.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5), "Expected the selected fixture list")
    }

    @MainActor
    private func runFilterJourney(orientation: UIDeviceOrientation, rightToLeft: Bool = false) throws {
        let markers = try outerDisplayPoseMarkers(for: orientation)
        continueAfterFailure = false
        if markers == nil {
            XCUIDevice.shared.orientation = orientation
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-performance-task-count", "80", "-performance-list-count", "4",
            "-performance-fixture-reset", "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US", "-startupScreen", "smart:Today"
        ]
        if rightToLeft {
            app.launchArguments += ["-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"]
        }
        addTeardownBlock {
            defer { app.terminate() }
            if let markers, FileManager.default.fileExists(atPath: markers.appending(path: "ready").path) {
                try Data().write(to: markers.appending(path: "restore"), options: .atomic)
                try Self.waitForPoseMarker("restored", in: markers)
            } else {
                XCUIDevice.shared.orientation = .portrait
            }
        }
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let low = app.buttons["Low filter"]
        XCTAssertTrue(low.waitForExistence(timeout: 10))
        if let markers {
            try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
            try Data().write(to: markers.appending(path: "ready"), options: .atomic)
            try Self.waitForPoseMarker("applied", in: markers)
        }
        assertOuterDisplayGeometry(in: app, orientation: orientation)
        let back = app.buttons["BackButton"]
        let add = app.buttons.matching(identifier: "Add task").allElementsBoundByIndex
            .filter { $0.isEnabled && $0.isHittable }
        var chrome = add
        if back.exists { chrome.append(back) }
        XCTAssertFalse(chrome.isEmpty, "Probe requires actual navigation controls")
        if orientation == .portrait && !rightToLeft {
            XCTAssertTrue(back.exists, "The portrait regression must include the overlapping BackButton")
        }

        let chips = ["Completed filter", "High filter", "Medium filter", "Low filter"]
            .map { app.buttons[$0] }
        XCTAssertEqual(chips.filter(\.exists).count, 4)
        XCTAssertGreaterThanOrEqual(chips.filter(\.isHittable).count, orientation == .portrait ? 3 : 1)
        assertClear(chips: chips, chrome: chrome)
        attach(app, name: "Filters at rest")
        if let markers {
            try Data().write(to: markers.appending(path: "rest"), options: .atomic)
            try Self.waitForPoseMarker("rest-captured", in: markers)
        }

        let scroll = app.scrollViews.containing(.button, identifier: "Low filter").firstMatch
        XCTAssertTrue(scroll.exists, "The probe must locate the actual horizontal chip scroller")
        let completed = app.buttons["Completed filter"]
        if rightToLeft {
            XCTAssertGreaterThan(completed.frame.midX, low.frame.midX,
                                 "The RTL probe must actually reverse the chip order")
        }
        for _ in 0..<4 where !low.isHittable {
            let visible = ["Medium filter", "High filter", "Completed filter"]
                .map { app.buttons[$0] }.first { $0.isHittable }
            XCTAssertNotNil(visible, "A real visible chip must anchor the scroll gesture")
            guard let visible else { return }
            let start = visible.frame
            let delta: CGFloat = low.frame.midX < completed.frame.midX ? 160 : -160
            let bounds = app.windows.firstMatch.frame
            let endX = min(bounds.maxX - 1, max(bounds.minX + 1, start.midX + delta))
            visible.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo:
                    app.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: endX, dy: start.midY)))
        }
        XCTAssertTrue(low.isHittable, "The final chip must scroll fully into the content region: \(low.frame)")
        assertClear(chips: chips, chrome: chrome)
        low.tap()
        XCTAssertTrue(low.isSelected, "The last chip must remain actionable after scrolling")
        attach(app, name: "Final filter is reachable")
        if let markers {
            try Data().write(to: markers.appending(path: "selected"), options: .atomic)
        }
    }

    private func outerDisplayPoseMarkers(for orientation: UIDeviceOrientation) throws -> URL? {
        guard orientation.isLandscape else { return nil }
        let environment = ProcessInfo.processInfo.environment
        if let runID = environment["NOWTHIS_DUO_POSE_RUN_ID"], let id = UUID(uuidString: runID) {
            let pose = orientation == .landscapeLeft ? "landscape_left" : "landscape_right"
            return URL.documentsDirectory
                .appending(path: "DuoFilterPoses-\(id.uuidString)", directoryHint: .isDirectory)
                .appending(path: pose, directoryHint: .isDirectory)
        }
        #if targetEnvironment(simulator)
        let runtime = ProcessInfo.processInfo.operatingSystemVersionString
        let runtimeBuild = runtime.split { !$0.isLetter && !$0.isNumber }.last
        if environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4", runtimeBuild == "24B91016s" {
            throw XCTSkip("Run tools/verify_duo_chips.py --help to coordinate outer-display rotation on Duo simulator build 24B91016s")
        }
        #endif
        return nil
    }

    private func waitForDuoHost(_ marker: String, in directory: URL) throws {
        let deadline = Date().addingTimeInterval(45)
        while !FileManager.default.fileExists(atPath: directory.appending(path: marker).path) {
            guard Date() < deadline else {
                throw NSError(domain: "Duo host handshake", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Host did not confirm the '\(marker)' marker"
                ])
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func waitForPoseMarker(_ marker: String, in directory: URL) throws {
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: directory.appending(path: marker).path) {
            guard Date() < deadline else {
                throw NSError(domain: "Duo outer-display pose host", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Host did not confirm the '\(marker)' pose marker"
                ])
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    @MainActor
    private func assertOuterDisplayGeometry(in app: XCUIApplication, orientation: UIDeviceOrientation) {
        // A rotating window can briefly report the expected aspect before its chrome settles.
        let window = app.windows.firstMatch
        let deadline = Date().addingTimeInterval(5)
        var previousFrame = CGRect.null
        var stableSince = Date()
        var settledFrame: CGRect?
        while Date() < deadline {
            let frame = window.frame
            let now = Date()
            if frame != previousFrame {
                previousFrame = frame
                stableSince = now
            }
            let hasExpectedAspect = orientation.isLandscape ? frame.width > frame.height : frame.height > frame.width
            if hasExpectedAspect && now < deadline && now.timeIntervalSince(stableSince) >= 0.5 {
                settledFrame = frame
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let frame = settledFrame else {
            XCTFail("App window did not settle in the requested outer-display pose \(orientation.rawValue) within 5 seconds. Last frame was \(previousFrame)")
            return
        }
        print("Outer-display geometry for requested pose \(orientation.rawValue): \(frame.width) × \(frame.height) pt")
        switch orientation {
        case .landscapeLeft, .landscapeRight:
            XCTAssertGreaterThan(frame.width, frame.height, "Expected actual outer-display landscape reflow")
        case .portrait:
            XCTAssertGreaterThan(frame.height, frame.width, "Expected actual outer-display portrait reflow")
        default:
            XCTFail("Unsupported outer-display test pose")
        }
    }

    @MainActor
    private func assertClear(chips: [XCUIElement], chrome: [XCUIElement]) {
        for chip in chips where chip.exists && chip.isHittable {
            for control in chrome {
                XCTAssertFalse(chip.frame.intersects(control.frame),
                               "Visible \(chip.label) at \(chip.frame) overlaps navigation control \(control.frame)")
            }
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
