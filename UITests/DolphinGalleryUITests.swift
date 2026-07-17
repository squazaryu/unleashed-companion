import XCTest

final class DolphinGalleryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-onboardingDone", "YES"]
        app.launch()
    }

    func testDurationPersistsAndLongPressOpensAnimatedPreview() throws {
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        let gallery = app.buttons["Dolphin Gallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 5))
        gallery.tap()

        let timing = app.segmentedControls["dolphin-timing-picker"]
        XCTAssertTrue(timing.waitForExistence(timeout: 5))
        timing.buttons["Custom"].tap()

        let duration = app.buttons["dolphin-duration-link"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        duration.tap()

        let minuteWheel = app.pickerWheels.element(boundBy: 1)
        XCTAssertTrue(minuteWheel.waitForExistence(timeout: 5))
        minuteWheel.adjust(toPickerWheelValue: "02")
        app.buttons["dolphin-duration-save"].tap()
        XCTAssertEqual(duration.label, "Duration, 00:02:00")

        app.navigationBars["Dolphin Gallery"].buttons["Settings"].tap()
        app.buttons["Dolphin Gallery"].tap()
        let persistedDuration = app.buttons["dolphin-duration-link"]
        XCTAssertTrue(persistedDuration.waitForExistence(timeout: 5))
        XCTAssertEqual(persistedDuration.label, "Duration, 00:02:00")

        let legacy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Legacy'"))
            .firstMatch
        XCTAssertTrue(legacy.waitForExistence(timeout: 5))
        legacy.tap()

        let artwork = app.otherElements["dolphin-preview-L1_Tv_128x47"]
        for _ in 0..<4 where !artwork.isHittable { app.swipeUp() }
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        artwork.press(forDuration: 0.5)

        XCTAssertTrue(app.navigationBars["Animation preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].exists)

        let firstFrame = XCUIScreen.main.screenshot().pngRepresentation
        Thread.sleep(forTimeInterval: 0.65)
        let secondFrame = XCUIScreen.main.screenshot().pngRepresentation
        XCTAssertNotEqual(firstFrame, secondFrame, "The full-screen preview must advance frames")
    }
}
