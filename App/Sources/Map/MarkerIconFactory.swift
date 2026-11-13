import TripFeatures
import TripModels
import UIKit

/// Renders map marker images (white ring, coloured disc, SF Symbol), cached per style.
@MainActor
enum MarkerIconFactory {
    private static var cache: [String: UIImage] = [:]

    /// A plain coloured dot with a white ring (no symbol); colours are explained by the legend.
    static func icon(for kind: StopKind, isPullOff: Bool, isActive: Bool) -> UIImage {
        let diameter: CGFloat = isActive ? 26 : 20
        let key = "dot-\(kind.rawValue)-\(isPullOff)-\(diameter)"
        if let cached = cache[key] { return cached }
        let image = renderDot(color: UIColor(Theme.color(for: kind, isPullOff: isPullOff)), diameter: diameter)
        cache[key] = image
        return image
    }

    static func renderDot(color: UIColor, diameter: CGFloat) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: rect).fill()
            color.setFill()
            UIBezierPath(ovalIn: rect.insetBy(dx: max(2.5, diameter * 0.14), dy: max(2.5, diameter * 0.14))).fill()
        }
    }

    /// Heading arrow for the car's position in drive mode.
    static func vehicleIcon() -> UIImage {
        if let cached = cache["vehicle"] { return cached }
        let image = render(symbolName: "location.north.fill", color: UIColor(Theme.accent), diameter: 36)
        cache["vehicle"] = image
        return image
    }

    static func render(symbolName: String, color: UIColor, diameter: CGFloat) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: rect).fill()
            color.setFill()
            UIBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
            let configuration = UIImage.SymbolConfiguration(pointSize: diameter * 0.4, weight: .semibold)
            if let symbol = UIImage(systemName: symbolName, withConfiguration: configuration)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let origin = CGPoint(x: (diameter - symbol.size.width) / 2, y: (diameter - symbol.size.height) / 2)
                symbol.draw(in: CGRect(origin: origin, size: symbol.size))
            }
        }
    }
}
