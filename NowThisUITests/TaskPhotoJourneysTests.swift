import XCTest

/// Functional task photo journeys using the existing performance launch fixture.
/// The parent test run seeds the simulator photo library with a genuine JPEG.
final class TaskPhotoJourneysTests: XCTestCase {
    @MainActor
    private static var resetProfiles = Set<String>()

    @MainActor
    func testLibraryPhotoCanBeAddedViewedAndRemovedAndSharingDefaultsOff() {
        let app = launchFixture()
        XCTAssertTrue(app.tabBars.buttons["Tasks"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let photoSettings = app.switches["taskPhotos.settings.shareFullResolution"]
        for _ in 0..<20 where !photoSettings.exists { app.swipeUp() }
        XCTAssertTrue(photoSettings.waitForExistence(timeout: 5))
        if !photoSettings.isHittable { app.swipeUp() }
        XCTAssertEqual(photoSettings.value as? String, "0", "Full-resolution photo sharing should default off.")
        attachScreenshot(of: app, named: "Task photo settings default off")

        app.tabBars.buttons["Tasks"].tap()
        let task = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Fixture task 00000")
        ).firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.tap()

        let picker = app.buttons["taskPhotos.picker"]
        for _ in 0..<8 where !picker.exists {
            app.swipeUp()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()

        let pickerCancel = app.buttons["Cancel"]
        XCTAssertTrue(pickerCancel.waitForExistence(timeout: 10), "The photo library should open before selecting a photo.")
        let photoLibrary = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow.photospicker")
        attachScreenshot(of: photoLibrary, named: "System photo picker")
        let libraryPhoto = photoLibrary.images.firstMatch
        XCTAssertTrue(libraryPhoto.waitForExistence(timeout: 10), "The simulator library should contain the JPEG seeded by the parent test run.")
        libraryPhoto.tap()
        let addButton = photoLibrary.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()
        XCTAssertTrue(pickerCancel.waitForNonExistence(timeout: 10))

        let thumbnail = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "taskPhotos.photo.")
        ).firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 15), "The selected library photo should appear in the task.")
        attachScreenshot(of: app, named: "Task photo added")

        // Reopen the same disk fixture to prove the preview and identity were saved.
        let persistedPhotoID = thumbnail.identifier
        app.terminate()
        app.launchArguments.removeAll { $0 == "-performance-fixture-reset" }
        app.launch()
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.tap()
        for _ in 0..<8 where !thumbnail.exists { app.swipeUp() }
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 10))
        XCTAssertEqual(thumbnail.identifier, persistedPhotoID)
        attachScreenshot(of: app, named: "Task photo survives reopening")

        thumbnail.tap()
        XCTAssertTrue(app.images["taskPhotos.viewer.image"].waitForExistence(timeout: 10))
        attachScreenshot(of: app, named: "Task photo viewer")

        app.buttons["taskPhotos.remove"].tap()
        let confirmRemove = app.sheets.buttons.matching(identifier: "taskPhotos.confirmRemove").firstMatch
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 5), "Removing a photo should ask for confirmation.")
        confirmRemove.tap()

        XCTAssertTrue(thumbnail.waitForNonExistence(timeout: 10), "The removed photo should disappear from the task.")
        attachScreenshot(of: app, named: "Task photo removed")
        app.terminate()
    }

    @MainActor
    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-performance-task-count", "20",
            "-performance-list-count", "1",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-startupScreen", "smart:Today"
        ]
        if Self.resetProfiles.insert("20-1").inserted {
            app.launchArguments.append("-performance-fixture-reset")
        }
        app.launch()
        let notificationPermission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if notificationPermission.waitForExistence(timeout: 2) { notificationPermission.tap() }
        return app
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
