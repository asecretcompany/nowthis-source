import XCTest

final class OnboardingCardJourneysTests: XCTestCase {
    @MainActor
    func testVaultOpensFromBlankPaintedCardInOuterLandscape() throws {
        // The host selects a dedicated Duo with an empty synthetic store and restores it afterward.
        guard let value = ProcessInfo.processInfo.environment["NOWTHIS_DUO_ONBOARDING_RUN_ID"],
              let runID = UUID(uuidString: value) else {
            throw XCTSkip("Run tools/verify_duo_onboarding.py on a dedicated Duo with an empty synthetic store.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
        defer { app.terminate() }

        let window = app.windows.firstMatch
        let welcome = app.buttons["Get Started"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), "The test requires an empty store.")
        XCTAssertEqual(window.frame.size, CGSize(width: 466, height: 678))
        welcome.tap()
        XCTAssertTrue(app.navigationBars["Choose Mode"].waitForExistence(timeout: 5))

        let markers = URL.documentsDirectory.appending(path: "DuoOnboarding-\(runID.uuidString)")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        try Data().write(to: markers.appending(path: "ready"), options: .atomic)
        let applied = markers.appending(path: "landscape")
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: applied.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: applied.path), "Host did not confirm outer landscape.")
        let landscapeSize = CGSize(width: 678, height: 466)
        let reflowDeadline = Date().addingTimeInterval(5)
        while window.frame.size != landscapeSize, Date() < reflowDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(window.frame.size, landscapeSize)

        let vault = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Vault Mode.")).firstMatch
        XCTAssertTrue(vault.waitForExistence(timeout: 5))
        let frame = vault.frame
        let blank = CGPoint(x: 403, y: 422)
        XCTAssertTrue(frame.contains(blank) && window.frame.contains(blank),
                      "Expected the blank tap to be within the visible Vault card. Vault frame is \(frame).")
        XCTAssertGreaterThan(frame.height, 220, "Expected the stacked accessibility-size Vault card.")
        XCTAssertLessThan(blank.y, frame.minY + 65, "Tap beside the lock, above the title.")

        print("Vault blank surface tap \(blank), card \(frame), window \(window.frame)")
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: blank.x, dy: blank.y)).tap()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5),
                      "A coordinate tap on the blank painted Vault surface should open Today.")
    }
}
