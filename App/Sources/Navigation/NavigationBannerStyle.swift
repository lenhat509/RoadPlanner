import GoogleMaps
import GoogleNavigation
import SwiftUI
import UIKit

/// The colors of Google's turn-by-turn banner (the Navigation SDK's header), set to match
/// Waystage's cards and the map under it: white with dark text when the phone is in light mode,
/// the dark card style in dark mode. Left alone, the SDK picks its own colors, which can be dark
/// over a daytime map. Header colors are a customization Google supports (GMSUISettings).
enum NavigationBannerStyle {
    static func apply(_ scheme: ColorScheme, to settings: GMSUISettings) {
        let dark = scheme == .dark
        let background = dark ? UIColor(red: 0.10, green: 0.13, blue: 0.14, alpha: 1) : .white
        // The row under the main instruction: "Then" and lane guidance.
        let secondary = dark
            ? UIColor(red: 0.15, green: 0.18, blue: 0.19, alpha: 1)
            : UIColor(red: 0.94, green: 0.93, blue: 0.91, alpha: 1)
        let text = dark ? UIColor.white : UIColor(red: 0.07, green: 0.09, blue: 0.10, alpha: 1)
        let secondaryText = dark ? UIColor(white: 0.78, alpha: 1) : UIColor(white: 0.32, alpha: 1)
        // The app's teal, dark enough to read on white, light enough on the dark card.
        let accent = dark
            ? UIColor(red: 0.36, green: 0.78, blue: 0.80, alpha: 1)
            : UIColor(red: 0.04, green: 0.40, blue: 0.43, alpha: 1)

        settings.navigationHeaderPrimaryBackgroundColor = background
        settings.navigationHeaderSecondaryBackgroundColor = secondary
        settings.navigationHeaderPrimaryBackgroundColorNightMode = background
        settings.navigationHeaderSecondaryBackgroundColorNightMode = secondary
        settings.navigationHeaderInstructionsTextColor = text
        settings.navigationHeaderDistanceValueTextColor = text
        settings.navigationHeaderDistanceUnitsTextColor = secondaryText
        settings.navigationHeaderNextStepTextColor = secondaryText
        settings.navigationHeaderLargeManeuverIconColor = accent
        settings.navigationHeaderSmallManeuverIconColor = accent
        settings.navigationHeaderGuidanceRecommendedLaneColor = accent
    }
}
