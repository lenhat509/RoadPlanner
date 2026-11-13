import XCTest

extension XCUIApplication {
    /// Opens drive mode's trip menu (the "…" button) and returns the item labelled `label` once
    /// it shows, or nil if it never does.
    ///
    /// SwiftUI menu items don't reliably expose identifiers, so items are found by their visible
    /// label. The menu sometimes misses a tap, and the simulated car is fast enough that the panel
    /// holding the menu can swap (driving → at a stop) while it is open, which closes it: so this
    /// opens it again, a few times, until the item shows.
    func tripMenuItem(_ label: String, attempts: Int = 3) -> XCUIElement? {
        let item = buttons[label].firstMatch
        for _ in 0..<attempts {
            let menu = buttons[AccessibilityID.Drive.menu].firstMatch
            guard menu.waitForExistence(timeout: 5) else { return nil }
            menu.tap()
            if item.waitForExistence(timeout: 3) { return item }
        }
        return nil
    }

    /// Everything on screen with an identifier, for failure messages.
    func visibleIdentifiers(limit: Int = 300) -> String {
        descendants(matching: .any).allElementsBoundByIndex.prefix(limit)
            .map(\.identifier).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
