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

    static func color(for kind: StopKind, isPullOff: Bool = false) -> Color {
        if isPullOff { return Color(uiColor: .systemGray) }
        switch kind {
        case .origin: return accent
        case .rest: return success
        case .fuel: return warning
        case .lodging: return Color(red: 0.36, green: 0.36, blue: 0.84)
        case .destination: return Color(red: 0.90, green: 0.28, blue: 0.30)
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
