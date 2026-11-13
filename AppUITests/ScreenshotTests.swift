import XCTest

/// Captures App Store screenshots as test attachments. Run with `fastlane screenshots`,
/// which exports the attachments from the .xcresult bundle.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [LaunchArgument.uiTestSandbox, LaunchArgument.resetState, LaunchArgument.skipSafetyNotice]
        app.launch()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCaptureAppStoreScreenshots() {
        XCTAssertTrue(app.buttons[AccessibilityID.Home.planTrip].waitForExistence(timeout: 5))
        app.buttons[AccessibilityID.Home.planTrip].tap()

        let origin = app.textFields[AccessibilityID.Plan.origin]
        XCTAssertTrue(origin.waitForExistence(timeout: 5))
        origin.tap()
        origin.typeText("San")
        app.buttons[AccessibilityID.Plan.suggestion("San Francisco")].tap()
        let destination = app.textFields[AccessibilityID.Plan.destination]
        destination.tap()
        destination.typeText("New")
        app.buttons[AccessibilityID.Plan.suggestion("New York")].tap()
        capture("01-Plan")

        app.buttons[AccessibilityID.Plan.submit].tap()
        XCTAssertTrue(app.buttons[AccessibilityID.Results.option("balanced")].waitForExistence(timeout: 60))
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
}
