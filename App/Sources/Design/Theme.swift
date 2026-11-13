import SwiftUI
import TripModels

/// Design tokens for Cadence's look: warm "paper" background, soft white cards, one teal brand
/// gradient, rounded type, and colour-blind-safe stop dots. Calm by default; colour is used to
/// carry meaning (stop types, the primary action), not decoration.
enum Theme {
    static let accent = Color.accentColor

    // MARK: Brand
    static let brandDeep = Color(red: 0.04, green: 0.18, blue: 0.21)
    /// Primary actions and selected states.
    static let brandGradient = LinearGradient(
        colors: [Color(red: 0.09, green: 0.56, blue: 0.58), Color(red: 0.04, green: 0.32, blue: 0.41)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    /// Hero header and the drive-mode banner.
    static let heroGradient = LinearGradient(
        colors: [Color(red: 0.07, green: 0.47, blue: 0.50), Color(red: 0.04, green: 0.18, blue: 0.22)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // MARK: Surfaces
    /// Warm paper in light mode, deep ink in dark mode.
    static let canvas = dynamic(light: UIColor(red: 0.965, green: 0.957, blue: 0.937, alpha: 1),
                                dark: UIColor(red: 0.055, green: 0.075, blue: 0.082, alpha: 1))
    static let card = dynamic(light: .white, dark: UIColor(red: 0.10, green: 0.13, blue: 0.14, alpha: 1))
    static let cardStroke = dynamic(light: UIColor(white: 0, alpha: 0.05), dark: UIColor(white: 1, alpha: 0.08))
    /// Inputs, tiles and unselected chips inside cards.
    static let mutedFill = dynamic(light: UIColor(red: 0.94, green: 0.93, blue: 0.91, alpha: 1),
                                   dark: UIColor(red: 0.15, green: 0.18, blue: 0.19, alpha: 1))
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

    enum Radius {
        static let card: CGFloat = 22
        static let control: CGFloat = 16
        static let tile: CGFloat = 18
    }
}
