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

    /// Starts the drive and waits for drive mode: guidance, or (the simulated car is fast, and a
    /// slow simulator may load directions late) already the arrival card at the first stop.
    private func startDriving(file: StaticString = #filePath, line: UInt = #line) {
        let start = app.buttons[AccessibilityID.Results.start]
        XCTAssertTrue(start.waitForExistence(timeout: 5), file: file, line: line)
        start.tap()
        let states = [AccessibilityID.Drive.banner, AccessibilityID.Drive.arrivalCard, AccessibilityID.Drive.completedCard]
            .map { app.descendants(matching: .any)[$0].firstMatch }
        let deadline = Date().addingTimeInterval(30)
        while !states.contains(where: \.exists) && Date() < deadline {
            _ = states[0].waitForExistence(timeout: 1)
        }
        let onScreen = app.descendants(matching: .any).allElementsBoundByIndex.prefix(200)
            .map(\.identifier).filter { !$0.isEmpty }.joined(separator: ", ")
        XCTAssertTrue(states.contains(where: \.exists), "drive mode not shown; on screen: \(onScreen)", file: file, line: line)
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
        settle()
        capture("02-Options")
        app.swipeUp()
        capture("03-Timeline")

        startDriving()
        settle(6) // the car parks a little way into the leg
        capture("04-Drive")

        // Arrival card: "I've arrived" from the trip menu.
        app.buttons[AccessibilityID.Drive.menu].firstMatch.tap()
        let byID = app.buttons[AccessibilityID.Drive.arrived].firstMatch
        let arrived = byID.waitForExistence(timeout: 3) ? byID : app.buttons["I've arrived"].firstMatch
        XCTAssertTrue(arrived.waitForExistence(timeout: 3))
        arrived.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.Drive.arrivalCard].firstMatch.waitForExistence(timeout: 10))
        settle(2)
        capture("05-Arrival")
    }

    func testCaptureDarkModeScreenshots() {
        launch(dark: true)
        XCTAssertTrue(app.buttons[AccessibilityID.Home.planTrip].waitForExistence(timeout: 5))
        capture("10-Home-Dark")
        planCrossCountry(captureForm: "11-Plan-Dark")
        settle()
        capture("12-Options-Dark")
        startDriving()
        settle(6)
        capture("13-Drive-Dark")
    }
}
