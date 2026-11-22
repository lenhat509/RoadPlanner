import XCTest

/// Captures the promo screenshots and a walkthrough with the real app and live Google data:
/// Denver → Salt Lake City → Las Vegas (a night, hotel nearby) → San Jose. Run by
/// `.github/workflows/promo.yml`, which records the simulator's screen meanwhile; the marks
/// (printed and attached) say when each step happened, for cutting the clip. Skipped elsewhere:
/// it needs a Google key and the network.
final class PromoCaptureTests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var marks: [[String: Any]] = []

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROMO_CAPTURE"] == "1", "run by the Promo workflow")
        // Keep going after a miss: one run should give as many screens as it can.
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = [LaunchArgument.simulateNavigation]
        app.launchEnvironment["TZ"] = "America/Denver"
    }

    // MARK: Helpers

    private func mark(_ name: String) {
        let time = Date().timeIntervalSince1970
        marks.append(["name": name, "time": time])
        print("PROMO-MARK \(name) \(String(format: "%.3f", time))")
    }

    private func attachMarks() {
        guard let data = try? JSONSerialization.data(withJSONObject: marks, options: [.prettyPrinted]) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "promo-marks"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        mark("shot-\(name)")
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Accepts first-run prompts (the terms, Google's navigation terms, the driving safety notice,
    /// the system's notification and location prompts) until one of `targets` shows.
    @discardableResult
    private func acceptPrompts(until targets: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let systemAnswers = ["Allow While Using App", "Allow"]
        let appAnswers = ["Got It", "GOT IT", "Got it", "I Agree", "I AGREE", "Agree", "Accept", "ACCEPT"]
        while Date() < deadline {
            if targets.contains(where: \.exists) { return true }
            for label in systemAnswers {
                let button = springboard.alerts.buttons[label].firstMatch
                if button.exists { button.tap(); break }
            }
            for identifier in [AccessibilityID.Terms.agree, AccessibilityID.Drive.safetyAccept] {
                let button = app.buttons[identifier].firstMatch
                if button.exists && button.isHittable { button.tap() }
            }
            for label in appAnswers {
                let button = app.buttons[label].firstMatch
                if button.exists && button.isHittable { button.tap(); break }
            }
            _ = targets.first?.waitForExistence(timeout: 1)
        }
        let found = targets.contains(where: \.exists)
        if !found { XCTFail("not shown; on screen: \(app.visibleIdentifiers())") }
        return found
    }

    /// Swipes the page up until `target` can be tapped.
    private func reveal(_ target: XCUIElement, attempts: Int = 8) {
        var swipes = 0
        while target.exists && !target.isHittable && swipes < attempts {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
    }

    /// Types into a place field and picks Google's suggestion named `pick`.
    private func choose(_ identifier: String, typing text: String, pick: String) {
        let field = app.textFields[identifier]
        guard field.waitForExistence(timeout: 10) else { return XCTFail("no field \(identifier)") }
        reveal(field)
        for _ in 0..<5 where !((field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false) {
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        }
        field.typeText(text)
        let exact = app.buttons[AccessibilityID.Plan.suggestion(pick)].firstMatch
        let similar = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.Plan.suggestion(pick))).firstMatch
        if exact.waitForExistence(timeout: 15) {
            pause(0.6)
            exact.tap()
        } else if similar.exists {
            similar.tap()
        } else {
            XCTFail("no suggestion \(pick); on screen: \(app.visibleIdentifiers())")
        }
        pause(1)
    }

    /// Taps a stay stepper's + (`label` is the stepper's accessibility label; `index` counts stops).
    private func increment(_ label: String, index: Int) {
        let stepper = app.steppers.matching(NSPredicate(format: "label == %@", label)).element(boundBy: index)
        guard stepper.waitForExistence(timeout: 5) else { return XCTFail("no stepper \(label) #\(index)") }
        reveal(stepper)
        stepper.buttons["Increment"].firstMatch.tap()
        pause(0.8)
    }

    /// Taps a plan button, at the end of its scrolling page.
    private func tapPlanButton(_ identifier: String) {
        let button = app.buttons[identifier].firstMatch
        guard button.waitForExistence(timeout: 10) else { return XCTFail("no \(identifier)") }
        var swipes = 0
        while !button.isHittable && swipes < 12 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        button.tap()
    }

    /// Adds a visit from Adjust visits' search.
    private func addVisit(typing text: String, pick: String) {
        let add = app.buttons[AccessibilityID.Visits.add].firstMatch
        guard add.waitForExistence(timeout: 10) else { return XCTFail("no Add a visit") }
        add.tap()
        choose(AccessibilityID.Results.addStopSearch, typing: text, pick: pick)
        let confirm = app.buttons[AccessibilityID.Results.addStopConfirm].firstMatch
        let deadline = Date().addingTimeInterval(15)
        while !(confirm.exists && confirm.isEnabled) && Date() < deadline { pause(0.5) }
        pause(1.2) // the stay, on screen for the clip
        confirm.tap()
        pause(1.5)
    }

    /// The reorder handles of Adjust visits' list, top to bottom.
    private var reorderHandles: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'reorder' AND identifier != %@", AccessibilityID.Visits.reorder))
    }

    // MARK: The walkthrough

    func testCapturePromo() {
        defer { attachMarks() }
        app.launch()
        mark("launch")
        let planTrip = app.buttons[AccessibilityID.Home.planTrip].firstMatch
        acceptPrompts(until: [planTrip], timeout: 90)
        pause(2)
        capture("00-home")

        // The new trip: Denver to San Jose by Salt Lake City (2 h) and Las Vegas (a night).
        mark("form")
        planTrip.tap()
        pause(1.5)
        choose(AccessibilityID.Plan.origin, typing: "Denver", pick: "Denver")
        choose(AccessibilityID.Plan.destination, typing: "San Jose", pick: "San Jose")
        mark("stops")
        let addStop = app.buttons[AccessibilityID.Plan.addStop].firstMatch
        reveal(addStop)
        addStop.tap()
        choose(AccessibilityID.Plan.stop(0), typing: "Salt Lake", pick: "Salt Lake City")
        reveal(addStop)
        addStop.tap()
        choose(AccessibilityID.Plan.stop(1), typing: "Las Vegas", pick: "Las Vegas")
        let order = app.segmentedControls[AccessibilityID.Plan.stopOrder].firstMatch
        if order.waitForExistence(timeout: 5) {
            reveal(order)
            order.buttons["As listed"].tap()
            pause(1)
        }
        mark("stays")
        increment("Hours there", index: 0)
        increment("Nights there", index: 1)
        pause(1.5)
        app.swipeDown(velocity: .slow)
        app.swipeDown(velocity: .slow)
        pause(1)
        capture("01-form-top")
        app.swipeUp(velocity: .slow)
        pause(1.5)
        capture("01-form-stops")
        app.swipeUp(velocity: .slow)
        pause(1.5)
        capture("01-form-bottom")

        mark("submit")
        let submit = app.buttons[AccessibilityID.Plan.submit].firstMatch
        reveal(submit)
        submit.tap()
        let fastest = app.buttons[AccessibilityID.Results.option("fastest")].firstMatch
        guard fastest.waitForExistence(timeout: 180) else {
            return XCTFail("no plan; on screen: \(app.visibleIdentifiers())")
        }
        mark("plan")
        pause(7) // map tiles
        capture("02-plan-top")
        app.swipeUp(velocity: .slow)
        pause(2)
        capture("02-plan-timeline")
        app.swipeUp(velocity: .slow)
        pause(2)
        capture("02-plan-timeline-2")

        // Adjust visits: add Rocky Mountain National Park and Aspen before the others, and take
        // Salt Lake City off; the page before Update plan.
        mark("visits")
        tapPlanButton(AccessibilityID.Results.adjustVisits)
        guard app.buttons[AccessibilityID.Visits.add].firstMatch.waitForExistence(timeout: 15) else {
            return XCTFail("no Adjust visits; on screen: \(app.visibleIdentifiers())")
        }
        pause(4)
        addVisit(typing: "Rocky Mountain Nat", pick: "Rocky Mountain National Park")
        addVisit(typing: "Aspen, CO", pick: "Aspen")
        mark("visits-order")
        let reorder = app.buttons[AccessibilityID.Visits.reorder].firstMatch
        if reorder.waitForExistence(timeout: 5) {
            reveal(reorder)
            reorder.tap()
            pause(1.5)
            // Salt Lake City, Las Vegas, Rocky Mountain, Aspen → Rocky Mountain, Aspen, Salt Lake City, Las Vegas.
            for (from, to) in [(2, 0), (3, 1)] where reorderHandles.count > from {
                reorderHandles.element(boundBy: from).press(forDuration: 0.8, thenDragTo: reorderHandles.element(boundBy: to))
                pause(1.2)
            }
            app.buttons[AccessibilityID.Visits.reorder].firstMatch.tap()
            pause(1.5)
        }
        mark("visits-remove")
        let saltLake = app.collectionViews.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Salt Lake City")).firstMatch
        if saltLake.waitForExistence(timeout: 5) {
            reveal(saltLake)
            saltLake.tap()
        } else {
            XCTFail("Salt Lake City not in the list; on screen: \(app.visibleIdentifiers())")
        }
        pause(1.5)
        app.swipeDown(velocity: .slow)
        pause(1.5)
        capture("05-visits-top")
        app.swipeUp(velocity: .slow)
        pause(1.5)
        capture("05-visits-list")
        mark("visits-done")
        app.navigationBars.buttons["Cancel"].firstMatch.tap()
        pause(2)

        // Start driving: the first drive's preview, then Google's turn-by-turn directions.
        mark("preview")
        tapPlanButton(AccessibilityID.Results.start)
        let preview = element(AccessibilityID.Drive.preview)
        acceptPrompts(until: [preview], timeout: 60)
        pause(6) // the zoom into the drive, and the map tiles
        capture("03-preview")
        mark("navigation")
        let start = app.buttons[AccessibilityID.Drive.startNavigation].firstMatch
        if start.waitForExistence(timeout: 10) { start.tap() }
        let driving = [AccessibilityID.Drive.exit, AccessibilityID.Drive.menu, AccessibilityID.Drive.banner].map(element)
        acceptPrompts(until: driving, timeout: 60)
        pause(14)
        capture("04-drive")
        pause(8)
        capture("04-drive-2")
        mark("end")
    }
}
