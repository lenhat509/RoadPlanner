import SwiftUI
import TripModels

/// Design tokens. Calm, high-contrast colours; one accent; stop colours that stay
/// distinguishable for common colour-vision deficiencies (also paired with distinct icons).
enum Theme {
    static let accent = Color.accentColor
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let elevated = Color(uiColor: .tertiarySystemGroupedBackground)
    static let warning = Color(red: 0.89, green: 0.61, blue: 0.18)
    static let success = Color(red: 0.18, green: 0.62, blue: 0.42)
    static let routeLine = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.40, green: 0.65, blue: 1.00, alpha: 1)
            : UIColor(red: 0.10, green: 0.45, blue: 0.91, alpha: 1)
    })
    /// Drive-mode banner background: deep, legible in sunlight and at night.
    static let bannerBackground = Color(red: 0.04, green: 0.25, blue: 0.29)

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

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 20
        static let control: CGFloat = 14
    }
}
