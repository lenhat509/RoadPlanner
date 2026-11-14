import UIKit
import XCTest

/// End-to-end UI tests in the offline sandbox (`-UITestSandbox`): simulated Google services,
/// simulated GPS that drives the planned route, isolated storage.
final class WaystageUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Accept any system permission prompt (location, notifications) so it can't block a test.
        addUIInterruptionMonitor(withDescription: "System permission") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
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

    /// "Start driving" opens the first leg's preview, like resuming; Start begins guidance.
    private func startDrive() {
        openDrive()
        startFromPreview()
    }

    /// "Start driving", past the safety notice.
    private func openDrive() {
        app.buttons[AccessibilityID.Results.start].tap()
        let accept = app.buttons[AccessibilityID.Drive.safetyAccept]
        if accept.waitForExistence(timeout: 5) {
            accept.tap()
            XCTAssertTrue(accept.waitForNonExistence(timeout: 5), "safety notice stayed on screen")
        }
    }

    /// Drive mode is showing guidance (the maneuver banner), an arrival card, or — because the
    /// simulated car drives very fast — the trip-completed card.
    private func assertDriving(file: StaticString = #filePath, line: UInt = #line) {
        let states = [AccessibilityID.Drive.banner, AccessibilityID.Drive.arrivalCard, AccessibilityID.Drive.completedCard]
            .map(element)
        let deadline = Date().addingTimeInterval(15)
        var shown = false
        while !shown && Date() < deadline {
            shown = states.contains { $0.exists }
            if !shown { _ = states[0].waitForExistence(timeout: 1) }
        }
        XCTAssertTrue(shown, "drive mode not shown; on screen: \(app.visibleIdentifiers())", file: file, line: line)
    }

    /// After resuming: a trip paused at a stop shows its arrival card first; continuing from there
    /// opens the preview of the next leg.
    private func continueIfAtStop() {
        let preview = element(AccessibilityID.Drive.preview), arrival = element(AccessibilityID.Drive.arrivalCard)
        let deadline = Date().addingTimeInterval(15)
        while !preview.exists && !arrival.exists && Date() < deadline {
            _ = preview.waitForExistence(timeout: 1)
        }
        if !preview.exists && arrival.exists {
            app.buttons[AccessibilityID.Drive.continueToNext].firstMatch.tap()
        }
    }

    /// The route preview (start, resume, continue) is shown; tapping Start begins guidance.
    private func startFromPreview(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(AccessibilityID.Drive.preview).waitForExistence(timeout: 15),
                      "route preview not shown; on screen: \(app.visibleIdentifiers())", file: file, line: line)
        XCTAssertTrue(app.buttons[AccessibilityID.Drive.exit].exists, "the preview has an exit button", file: file, line: line)
        let start = app.buttons[AccessibilityID.Drive.startNavigation]
        XCTAssertTrue(start.exists, file: file, line: line)
        start.tap()
        assertDriving(file: file, line: line)
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
        XCTAssertTrue(app.textFields[AccessibilityID.Plan.tank].exists, "tank size is on the main form")
        XCTAssertTrue(element(AccessibilityID.Plan.minimumFuel).exists, "minimum fuel level is on the main form")
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
        XCTAssertTrue(element(AccessibilityID.Results.legend).exists, "the map legend is shown below the route preview")
        app.buttons[AccessibilityID.Results.option("cheapest")].tap()
        XCTAssertTrue(app.buttons[AccessibilityID.Results.option("cheapest")].isSelected)
        XCTAssertTrue(app.buttons[AccessibilityID.Results.start].isEnabled)
    }

    func testDriveArrivesAtAStopAndContinuesToTheNext() {
        launch()
        planLosAngelesToVegas()
        startDrive()
        // The simulated car drives the leg; the "next stop" option appears near/at the stop.
        let continueButton = app.buttons[AccessibilityID.Drive.continueToNext]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 90))
        continueButton.tap()
        startFromPreview()
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
        continueIfAtStop()
        startFromPreview()
    }

    func testExitLeavesDriveModeAndResumingShowsTheRoutePreview() {
        launch()
        planLosAngelesToVegas()
        startDrive()
        let exit = app.buttons[AccessibilityID.Drive.exit]
        XCTAssertTrue(exit.waitForExistence(timeout: 5), "drive mode has a dedicated exit button")
        exit.tap()
        let resume = app.buttons[AccessibilityID.Home.resume]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "exiting keeps the trip for later")
        resume.tap()
        continueIfAtStop()
        startFromPreview()
    }

    func testEndingATripReturnsHomeAndClearsProgress() {
        launch()
        planLosAngelesToVegas()
        startDrive()
        guard let endTrip = app.tripMenuItem("End trip") else {
            return XCTFail("trip menu did not open; on screen: \(app.visibleIdentifiers())")
        }
        endTrip.tap()
        let confirm = app.sheets.buttons["End trip"].firstMatch
        let confirmButton = confirm.waitForExistence(timeout: 3) ? confirm : app.buttons["End trip"].firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 3))
        confirmButton.tap()
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

    // MARK: Plan start vs. current location

    func testATripStartingFarAwayLeadsToItsStartFirst() {
        launch() // the simulated phone is in Los Angeles
        app.buttons[AccessibilityID.Home.planTrip].tap()
        choosePlace(field: AccessibilityID.Plan.origin, typing: "San", pick: "San Francisco")
        choosePlace(field: AccessibilityID.Plan.destination, typing: "Vegas", pick: "Las Vegas")
        app.buttons[AccessibilityID.Plan.submit].tap()
        XCTAssertTrue(app.buttons[AccessibilityID.Results.option("balanced")].waitForExistence(timeout: 30))
        let note = element(AccessibilityID.Results.startNote)
        XCTAssertTrue(note.exists, "the plan says it starts far from the user")
        XCTAssertTrue(note.label.hasPrefix("Starts in San Francisco"), note.label)

        app.buttons[AccessibilityID.Results.start].tap()
        let accept = app.buttons[AccessibilityID.Drive.safetyAccept]
        if accept.waitForExistence(timeout: 5) { accept.tap() }
        XCTAssertTrue(element(AccessibilityID.Drive.preview).waitForExistence(timeout: 15),
                      "drive mode previews the way to the start; on screen: \(app.visibleIdentifiers())")
        XCTAssertTrue(app.buttons["Directions to start"].exists)
        XCTAssertTrue(elementWithLabel(containing: "Trip start · San Francisco").exists, "the header names the trip's start")

        // Or start the trip from here: the preview switches to the first stop.
        guard let startHere = app.tripMenuItem("Start the trip from here") else {
            return XCTFail("trip menu did not open; on screen: \(app.visibleIdentifiers())")
        }
        startHere.tap()
        XCTAssertTrue(app.buttons[AccessibilityID.Drive.startNavigation].waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(10)
        while app.buttons["Directions to start"].exists && Date() < deadline { _ = app.buttons["Start"].waitForExistence(timeout: 1) }
        XCTAssertFalse(app.buttons["Directions to start"].exists)
        startFromPreview()
    }

    // MARK: Map

    /// Screenshots of the screen for `seconds`, as fast as they come (they don't wait for the app
    /// to settle).
    private func routeTraces(for seconds: TimeInterval) -> [RouteTrace?] {
        var traces: [RouteTrace?] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { traces.append(RouteTrace(XCUIScreen.main.screenshot().image)) }
        return traces
    }

    func testStartingADriveZoomsIntoTheLegThenToTheCarWithTheRouteAlwaysOnScreen() {
        // Screenshot pace: the simulated car waits for the camera before driving off.
        launch(extra: [LaunchArgument.screenshotPace])
        planLosAngelesToVegas()
        openDrive()
        XCTAssertTrue(element(AccessibilityID.Drive.preview).waitForExistence(timeout: 15), "Start driving previews the first leg")
        XCTAssertFalse(element(AccessibilityID.Drive.banner).exists, "no guidance before Start")
        // The whole trip, then the zoom into the leg: the leg stays in view.
        let opening = routeTraces(for: 3)
        XCTAssertFalse(opening.isEmpty)
        XCTAssertTrue(opening.allSatisfy { $0 != nil }, "the route left the screen while zooming into the leg: \(opening)")

        app.buttons[AccessibilityID.Drive.startNavigation].tap()
        // Down to the car: the car, where the route starts, stays in view.
        let flyIn = routeTraces(for: 2.5)
        XCTAssertTrue(flyIn.allSatisfy { $0 != nil }, "the route left the screen on the way to the car: \(flyIn)")
        assertDriving()
    }

    func testZoomButtonsZoomFromTheCurrentViewAndBack() throws {
        launch()
        planLosAngelesToVegas()
        let map = element(AccessibilityID.Results.map)
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2) // tiles and the first framing
        let before = try XCTUnwrap(RouteTrace(map.screenshot().image), "the route is visible on the map")

        app.buttons["Zoom in"].tap()
        Thread.sleep(forTimeInterval: 1.2)
        let zoomed = RouteTrace(map.screenshot().image)
        XCTAssertNotEqual(zoomed, before, "zooming in changes the view")

        app.buttons["Zoom out"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        let after = try XCTUnwrap(RouteTrace(map.screenshot().image))
        // Zooming happens around the view on screen: in and back out returns to the same view.
        XCTAssertLessThan(after.distance(to: before), 0.03, "the view drifted: \(before) → \(after)")
    }
}

/// Where the blue route line is in a map screenshot: the centroid of route-blue pixels, as
/// fractions of the image size, and how many there are.
struct RouteTrace: Equatable, CustomStringConvertible {
    let x: Double
    let y: Double
    let pixels: Int

    init?(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return nil }
        let width = 160, height = max(1, Int(Double(cgImage.height) / Double(cgImage.width) * 160))
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sumX = 0.0, sumY = 0.0, count = 0
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                let red = Int(data[offset]), green = Int(data[offset + 1]), blue = Int(data[offset + 2])
                // The route's blue (and its darker edge): strongly blue, little red.
                if blue > 150 && red < 80 && green > 60 && green < 160 && blue - green > 70 {
                    sumX += Double(column)
                    sumY += Double(row)
                    count += 1
                }
            }
        }
        guard count >= 20 else { return nil }
        x = sumX / Double(count) / Double(width)
        y = sumY / Double(count) / Double(height)
        pixels = count
    }

    func distance(to other: RouteTrace) -> Double {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }

    var description: String { String(format: "(%.3f, %.3f; %d px)", x, y, pixels) }
}
