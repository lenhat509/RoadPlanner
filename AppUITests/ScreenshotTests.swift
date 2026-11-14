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
        app.launchArguments = [
            LaunchArgument.uiTestSandbox, LaunchArgument.resetState, LaunchArgument.skipSafetyNotice, LaunchArgument.screenshotPace,
        ] + (dark ? [LaunchArgument.darkMode] : [])
        app.launch()
    }

    /// Gives map tiles a moment to load before a capture.
    private func settle(_ seconds: TimeInterval = 4) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// "Start driving" (the first leg's preview), then Start, and waits for drive mode: guidance,
    /// or (the simulated car is fast, and a slow simulator may load directions late) already the
    /// arrival card at the first stop.
    private func startDriving(file: StaticString = #filePath, line: UInt = #line) {
        let start = app.buttons[AccessibilityID.Results.start]
        XCTAssertTrue(start.waitForExistence(timeout: 5), file: file, line: line)
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.Drive.preview].firstMatch.waitForExistence(timeout: 20),
                      "Start driving previews the first leg", file: file, line: line)
        settle(3) // the zoom from the whole trip into the leg
        app.buttons[AccessibilityID.Drive.startNavigation].tap()
        let states = [AccessibilityID.Drive.banner, AccessibilityID.Drive.arrivalCard, AccessibilityID.Drive.completedCard]
            .map { app.descendants(matching: .any)[$0].firstMatch }
        let deadline = Date().addingTimeInterval(30)
        while !states.contains(where: \.exists) && Date() < deadline {
            _ = states[0].waitForExistence(timeout: 1)
        }
        XCTAssertTrue(states.contains(where: \.exists), "drive mode not shown; on screen: \(app.visibleIdentifiers())",
                      file: file, line: line)
    }

    /// "I've arrived" from the trip menu, then waits for the arrival card.
    private func arriveViaMenu() {
        guard let arrived = app.tripMenuItem("I've arrived") else {
            return XCTFail("trip menu did not open; on screen: \(app.visibleIdentifiers())")
        }
        arrived.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.Drive.arrivalCard].firstMatch.waitForExistence(timeout: 10))
        settle(2)
    }

    /// "Continue to next stop" from the arrival card, then waits for the route preview.
    private func continueToPreview() {
        app.buttons[AccessibilityID.Drive.continueToNext].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.Drive.preview].firstMatch.waitForExistence(timeout: 15))
        settle(3)
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

    /// Home → plan form → plan a trip to New York → results, and returns when results show. The
    /// simulated phone is in Los Angeles.
    private func planCrossCountry(from origin: (typing: String, pick: String), captureForm: String?) {
        XCTAssertTrue(app.buttons[AccessibilityID.Home.planTrip].waitForExistence(timeout: 5))
        app.buttons[AccessibilityID.Home.planTrip].tap()
        choose(AccessibilityID.Plan.origin, typing: origin.typing, pick: origin.pick)
        choose(AccessibilityID.Plan.destination, typing: "New", pick: "New York")
        if let captureForm { capture(captureForm) }
        app.buttons[AccessibilityID.Plan.submit].tap()
        XCTAssertTrue(app.buttons[AccessibilityID.Results.option("balanced")].waitForExistence(timeout: 90))
    }

    func testCaptureAppStoreScreenshots() {
        launch(dark: false)
        XCTAssertTrue(app.buttons[AccessibilityID.Home.planTrip].waitForExistence(timeout: 5))
        capture("00-Home")
        planCrossCountry(from: ("Los", "Los Angeles"), captureForm: "01-Plan")
        settle()
        capture("02-Options")
        app.swipeUp()
        capture("03-Timeline")

        startDriving()
        settle(6) // the car parks a little way into the leg
        capture("04-Drive")

        arriveViaMenu()
        capture("05-Arrival")
        continueToPreview()
        capture("06-Preview")
    }

    func testCaptureDarkModeScreenshots() {
        launch(dark: true)
        XCTAssertTrue(app.buttons[AccessibilityID.Home.planTrip].waitForExistence(timeout: 5))
        capture("10-Home-Dark")
        // Starts in San Francisco, far from the phone: the plan says so, and drive mode leads
        // to the start first.
        planCrossCountry(from: ("San", "San Francisco"), captureForm: "11-Plan-Dark")
        settle()
        capture("12-Options-Dark")
        app.buttons[AccessibilityID.Results.start].tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.Drive.preview].firstMatch.waitForExistence(timeout: 20))
        settle(4) // the whole trip, then the zoom into the way to the start
        capture("13-ToStart-Dark")
        app.buttons[AccessibilityID.Drive.startNavigation].tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.Drive.banner].firstMatch.waitForExistence(timeout: 30))
        settle(10) // the car parks ~7.5 s after Start; then the map tiles load
        capture("14-Drive-Dark")
    }
}
