import XCTest

/// Captures screenshots as test attachments, for the App Store (`fastlane screenshots`) and for
/// design review (`.github/workflows/screenshots.yml`). Runs in the offline UI-test sandbox.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(dark: Bool) {
        app.launchArguments = [LaunchArgument.uiTestSandbox, LaunchArgument.resetState, LaunchArgument.skipSafetyNotice]
            + (dark ? [LaunchArgument.darkMode] : [])
        app.launch()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func choose(_ identifier: String, typing text: String, pick suggestion: String) {
        let field = app.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
        let row = app.buttons[AccessibilityID.Plan.suggestion(suggestion)]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
    }

    /// Home → plan form → plan San Francisco → New York → results, and returns when results show.
    private func planCrossCountry(captureForm: String?) {
        XCTAssertTrue(app.buttons[AccessibilityID.Home.planTrip].waitForExistence(timeout: 5))
        app.buttons[AccessibilityID.Home.planTrip].tap()
        choose(AccessibilityID.Plan.origin, typing: "San", pick: "San Francisco")
        choose(AccessibilityID.Plan.destination, typing: "New", pick: "New York")
        if let captureForm { capture(captureForm) }
        app.buttons[AccessibilityID.Plan.submit].tap()
        XCTAssertTrue(app.buttons[AccessibilityID.Results.option("balanced")].waitForExistence(timeout: 90))
    }

    func testCaptureAppStoreScreenshots() {
        launch(dark: false)
        XCTAssertTrue(app.buttons[AccessibilityID.Home.planTrip].waitForExistence(timeout: 5))
        capture("00-Home")
        planCrossCountry(captureForm: "01-Plan")
        capture("02-Options")
        app.swipeUp()
        capture("03-Timeline")

        app.buttons[AccessibilityID.Results.start].tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.Drive.banner].firstMatch.waitForExistence(timeout: 15))
        capture("04-Drive")
        if app.buttons[AccessibilityID.Drive.continueToNext].waitForExistence(timeout: 90) {
            capture("05-Arrival")
        }
    }

    func testCaptureDarkModeScreenshots() {
        launch(dark: true)
        XCTAssertTrue(app.buttons[AccessibilityID.Home.planTrip].waitForExistence(timeout: 5))
        capture("10-Home-Dark")
        planCrossCountry(captureForm: "11-Plan-Dark")
        capture("12-Options-Dark")
        app.buttons[AccessibilityID.Results.start].tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.Drive.banner].firstMatch.waitForExistence(timeout: 15))
        capture("13-Drive-Dark")
    }
}
