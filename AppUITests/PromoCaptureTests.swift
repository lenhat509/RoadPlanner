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
        addUIInterruptionMonitor(withDescription: "System prompts") { alert in
            for label in ["Allow While Using App", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
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

    /// Records a miss with a screenshot of what was on screen (the run keeps going).
    private func miss(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        misses += 1
        capture("miss-\(misses)")
        XCTFail("\(message); on screen: \(app.visibleIdentifiers())", file: file, line: line)
    }

    private var misses = 0

    /// Whether a button's label accepts a prompt (Google's navigation terms, a system prompt).
    private static func accepting(_ label: String) -> Bool {
        ["got it", "i agree", "agree", "accept", "i accept", "continue", "ok", "allow", "allow while using app"]
            .contains(label.lowercased())
    }

    /// Taps one prompt's accepting button, if a prompt shows: the system's notification and
    /// location prompts, an alert, Google's navigation terms, the driving safety notice.
    private func answerPrompt() -> Bool {
        for label in ["Allow While Using App", "Allow"] {
            let button = springboard.alerts.buttons[label].firstMatch
            if button.exists {
                button.tap()
                return true
            }
        }
        if app.alerts.count > 0 {
            let buttons = app.alerts.firstMatch.buttons.allElementsBoundByIndex
            if let accept = buttons.first(where: { Self.accepting($0.label) }) ?? buttons.last {
                print("PROMO-PROMPT alert: \(buttons.map(\.label))")
                accept.tap()
                return true
            }
        }
        let safety = app.buttons[AccessibilityID.Drive.safetyAccept].firstMatch
        if safety.exists && safety.isHittable {
            safety.tap()
            return true
        }
        let accepting = app.buttons.matching(NSPredicate(
            format: "label MATCHES[c] %@", "(got it|i agree|agree|accept|i accept|ok)"
        )).allElementsBoundByIndex.first { $0.isHittable }
        if let accepting {
            print("PROMO-PROMPT button: \(accepting.label)")
            accepting.tap()
            return true
        }
        return false
    }

    /// Answers prompts for `seconds`, logging the buttons on screen when they change.
    private func clearPrompts(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        var shown = ""
        while Date() < deadline {
            if answerPrompt() {
                pause(1)
                continue
            }
            let labels = app.buttons.allElementsBoundByIndex.prefix(30).map(\.label).joined(separator: " | ")
            if labels != shown {
                print("PROMO-BUTTONS \(labels)")
                shown = labels
            }
            pause(1)
        }
    }

    /// Answers prompts until one of `targets` shows with no prompt for 3 s.
    @discardableResult
    private func acceptPrompts(until targets: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var quiet = 0
        while Date() < deadline {
            if answerPrompt() {
                quiet = 0
                pause(1)
                continue
            }
            if targets.contains(where: \.exists) {
                quiet += 1
                if quiet >= 3 { return true }
            }
            pause(1)
        }
        miss("not shown")
        return false
    }

    /// First launch: "Before you start", then Google's navigation terms and the notification prompt.
    private func getPastFirstLaunch() {
        let agree = app.buttons[AccessibilityID.Terms.agree].firstMatch
        if agree.waitForExistence(timeout: 60) {
            pause(1)
            reveal(agree)
            agree.tap()
        } else {
            miss("no Before you start")
        }
        clearPrompts(for: 15)
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
        guard field.waitForExistence(timeout: 10) else { return miss("no field \(identifier)") }
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
            miss("no suggestion \(pick)")
        }
        pause(1)
    }

    /// Taps + on a stop's stay: `stepper` 0 is its nights, 1 its hours.
    private func increment(stop index: Int, stepper: Int) {
        let stay = element(AccessibilityID.Plan.stopStay(index))
        guard stay.waitForExistence(timeout: 5) else { return miss("no stay for stop \(index)") }
        let plus = stay.buttons.matching(identifier: "Increment").element(boundBy: stepper)
        guard plus.exists else { return miss("no + \(stepper) for stop \(index)") }
        reveal(plus)
        plus.tap()
        pause(0.8)
    }

    /// Taps a plan button, at the end of its scrolling page.
    private func tapPlanButton(_ identifier: String) {
        let button = app.buttons[identifier].firstMatch
        guard button.waitForExistence(timeout: 10) else { return miss("no \(identifier)") }
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
        guard add.waitForExistence(timeout: 10) else { return miss("no Add a visit") }
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
        getPastFirstLaunch()
        acceptPrompts(until: [planTrip], timeout: 30)
        pause(1)
        capture("00-home")

        // The new trip: Denver to San Jose by Salt Lake City (2 h) and Las Vegas (a night).
        mark("form")
        planTrip.tap()
        if !app.textFields[AccessibilityID.Plan.origin].waitForExistence(timeout: 10) {
            clearPrompts(for: 5)
            planTrip.tap()
        }
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
        increment(stop: 0, stepper: 1) // Salt Lake City: 2 hours
        increment(stop: 1, stepper: 0) // Las Vegas: a night
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
            return miss("no plan")
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
            return miss("no Adjust visits")
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
            miss("Salt Lake City not in the list")
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
