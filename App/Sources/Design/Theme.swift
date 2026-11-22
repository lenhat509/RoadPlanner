import SwiftUI
import TripModels

/// Design tokens for Waystage's look: plain and practical, like a road atlas. Neutral grey
/// background, white boxes with thin borders (no shadows), small corner radii (boxes and buttons
/// are nearly rectangular), the system font, one solid highway-sign green for actions (no
/// gradients anywhere), and colour-blind-safe stop dots. Colour carries meaning (stop types, the
/// primary action), not decoration.
enum Theme {
    static let accent = Color.accentColor

    // MARK: Brand
    /// Primary actions and selected states: highway-sign green (white text on it in both looks).
    static let brand = Color(red: 0.0, green: 0.42, blue: 0.27)
    /// The drive-mode turn banner: dark slate, like a road sign's back.
    static let hero = Color(red: 0.12, green: 0.14, blue: 0.16)

    // MARK: Surfaces
    /// Neutral light grey, near-black in dark mode.
    static let canvas = dynamic(light: UIColor(white: 0.95, alpha: 1), dark: UIColor(white: 0.07, alpha: 1))
    static let card = dynamic(light: .white, dark: UIColor(white: 0.12, alpha: 1))
    /// The thin border around boxes, buttons and tiles (instead of shadows).
    static let cardStroke = dynamic(light: UIColor(white: 0, alpha: 0.13), dark: UIColor(white: 1, alpha: 0.15))
    /// Inputs, tiles and unselected chips inside cards.
    static let mutedFill = dynamic(light: UIColor(white: 0.93, alpha: 1), dark: UIColor(white: 0.17, alpha: 1))
    static let background = canvas
    static let surface = card
    static let elevated = mutedFill
    static let warning = Color(red: 0.89, green: 0.61, blue: 0.18)
    static let success = Color(red: 0.18, green: 0.62, blue: 0.42)
    static let routeLine = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.40, green: 0.65, blue: 1.00, alpha: 1)
            : UIColor(red: 0.10, green: 0.45, blue: 0.91, alpha: 1)
    })
    /// Darker edge around the route line, so it reads on any map background.
    static let routeCasing = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.10, green: 0.30, blue: 0.62, alpha: 1)
            : UIColor(red: 0.05, green: 0.28, blue: 0.62, alpha: 1)
    })
    /// The rest of the trip beyond the leg being driven.
    static let routeLineMuted = routeLine.opacity(0.38)
    /// Other routes found for a trip (plan results), grey like other map apps' alternatives.
    static let routeAlternative = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.64, green: 0.69, blue: 0.77, alpha: 1)
            : UIColor(red: 0.47, green: 0.53, blue: 0.62, alpha: 1)
    })
    /// Exit navigation.
    static let danger = Color(red: 0.86, green: 0.20, blue: 0.18)

    /// Stop colours from the Okabe–Ito palette, distinguishable with common colour-vision
    /// deficiencies. Stops are drawn as plain dots; the legend explains the colours.
    static func color(for kind: StopKind, isPullOff: Bool = false) -> Color {
        if isPullOff { return Color(uiColor: .systemGray) }
        switch kind {
        case .origin:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(white: 0.85, alpha: 1)
                    : UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1)
            })
        case .rest: return Color(red: 0.0, green: 0.62, blue: 0.45) // bluish green
        case .fuel: return Color(red: 0.90, green: 0.62, blue: 0.0) // orange
        case .lodging: return Color(red: 0.80, green: 0.47, blue: 0.65) // reddish purple
        case .visit: return Color(red: 0.0, green: 0.45, blue: 0.70) // blue
        case .destination: return Color(red: 0.84, green: 0.37, blue: 0.0) // vermillion
        }
    }

    /// Legend title for a stop type.
    static func legendTitle(for kind: StopKind, isPullOff: Bool = false) -> String {
        if isPullOff { return "Roadside break" }
        switch kind {
        case .origin: return "Start"
        case .rest: return "Rest stop"
        case .fuel: return "Fuel stop"
        case .lodging: return "Overnight stay"
        case .visit: return "Stop on the way"
        case .destination: return "Destination"
        }
    }

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    /// Two small radii, so boxes and controls read as rectangles with softened corners.
    enum Radius {
        /// Every box: cards, selectable choices, notes, panels over the map, maps.
        static let card: CGFloat = 8
        /// Every control: buttons, icon buttons, inputs and tiles you type into or choose from.
        static let control: CGFloat = 6
    }
}
