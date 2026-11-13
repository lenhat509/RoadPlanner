import XCTest

/// End-to-end UI tests in the offline sandbox (`-UITestSandbox`): simulated Google services,
/// simulated GPS that drives the planned route, isolated storage.
final class CadenceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: Helpers

    private func launch(reset: Bool = true, extra: [String] = []) {
        app.launchArguments = [LaunchArgument.uiTestSandbox] + (reset ? [LaunchArgument.resetState] : []) + extra
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func choosePlace(field identifier: String, typing text: String, pick suggestion: String) {
        let field = app.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "missing field \(identifier)")
        field.tap()
        field.typeText(text)
        let row = app.buttons[AccessibilityID.Plan.suggestion(suggestion)]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "missing suggestion \(suggestion)")
        row.tap()
    }

    /// Plans Los Angeles → Las Vegas and waits for the results screen.
    private func planLosAngelesToVegas() {
        app.buttons[AccessibilityID.Home.planTrip].tap()
        choosePlace(field: AccessibilityID.Plan.origin, typing: "Los", pick: "Los Angeles")
        choosePlace(field: AccessibilityID.Plan.destination, typing: "Vegas", pick: "Las Vegas")
        let submit = app.buttons[AccessibilityID.Plan.submit]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(app.buttons[AccessibilityID.Results.option("balanced")].waitForExistence(timeout: 30))
    }

    private func startDrive() {
        app.buttons[AccessibilityID.Results.start].tap()
        let accept = app.buttons[AccessibilityID.Drive.safetyAccept]
        if accept.waitForExistence(timeout: 5) { accept.tap() }
        XCTAssertTrue(element(AccessibilityID.Drive.nextStop).waitForExistence(timeout: 10))
    }

    // MARK: Tests

    func testHomeOffersToPlanATrip() {
        launch()
        XCTAssertTrue(app.buttons[AccessibilityID.Home.planTrip].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[AccessibilityID.Home.resume].exists)
    }

    func testPlanButtonIsDisabledUntilPlacesAreChosen() {
        launch()
        app.buttons[AccessibilityID.Home.planTrip].tap()
        let submit = app.buttons[AccessibilityID.Plan.submit]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled)
        choosePlace(field: AccessibilityID.Plan.origin, typing: "Los", pick: "Los Angeles")
        XCTAssertFalse(submit.isEnabled)
        choosePlace(field: AccessibilityID.Plan.destination, typing: "Den", pick: "Denver")
        XCTAssertTrue(submit.isEnabled)
    }

    func testPlanningShowsThreeOptionsAndADailyTimeline() {
        launch()
        planLosAngelesToVegas()
        for goal in ["fastest", "cheapest", "balanced"] {
            XCTAssertTrue(app.buttons[AccessibilityID.Results.option(goal)].exists, "missing \(goal) option")
        }
        XCTAssertTrue(element(AccessibilityID.Results.day(0)).exists)
        app.buttons[AccessibilityID.Results.option("cheapest")].tap()
        XCTAssertTrue(app.buttons[AccessibilityID.Results.option("cheapest")].isSelected)
        XCTAssertTrue(app.buttons[AccessibilityID.Results.start].isEnabled)
    }

    func testDriveArrivesAtAStopAndContinuesToTheNext() {
        launch()
        planLosAngelesToVegas()
        startDrive()
        XCTAssertTrue(element(AccessibilityID.Drive.banner).waitForExistence(timeout: 10))
        // The simulated car drives the leg; the "next stop" option appears near/at the stop.
        let continueButton = app.buttons[AccessibilityID.Drive.continueToNext]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 90))
        continueButton.tap()
        XCTAssertTrue(element(AccessibilityID.Drive.nextStop).waitForExistence(timeout: 10))
    }

    func testTripProgressIsRestoredAfterRelaunch() {
        launch()
        planLosAngelesToVegas()
        startDrive()
        app.terminate()

        launch(reset: false)
        let resume = app.buttons[AccessibilityID.Home.resume]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "an active trip should be offered for resuming")
        resume.tap()
        XCTAssertTrue(element(AccessibilityID.Drive.nextStop).waitForExistence(timeout: 10))
    }

    func testEndingATripReturnsHomeAndClearsProgress() {
        launch()
        planLosAngelesToVegas()
        startDrive()
        app.buttons[AccessibilityID.Drive.menu].tap()
        app.buttons[AccessibilityID.Drive.endTrip].tap()
        app.buttons["End trip"].firstMatch.tap()
        XCTAssertTrue(app.buttons[AccessibilityID.Home.planTrip].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[AccessibilityID.Home.resume].exists)
    }

    func testSettingsArePersisted() {
        launch()
        app.buttons[AccessibilityID.Home.settings].tap()
        let stepper = app.steppers[AccessibilityID.Settings.restInterval]
        XCTAssertTrue(stepper.waitForExistence(timeout: 5))
        let decrement = stepper.buttons["Decrement"].exists ? stepper.buttons["Decrement"] : stepper.buttons.element(boundBy: 0)
        decrement.tap() // 3 h → 2 h 45 min
        XCTAssertTrue(elementWithLabel(containing: "2 h 45 min").waitForExistence(timeout: 2))
        app.terminate()

        launch(reset: false)
        app.buttons[AccessibilityID.Home.settings].tap()
        XCTAssertTrue(elementWithLabel(containing: "2 h 45 min").waitForExistence(timeout: 5))
    }

    /// Matches static texts or controls whose accessibility label contains `text`.
    private func elementWithLabel(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
}
