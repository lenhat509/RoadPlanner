import Foundation
import TripModels

/// Imperial distance phrasing for banners and voice prompts.
public enum DistanceText {
    /// Short form for banners: "2.4 mi", "0.3 mi", "450 ft".
    public static func short(_ meters: Double) -> String {
        let miles = Units.miles(fromMeters: max(0, meters))
        if miles >= 10 { return "\(Int(miles.rounded())) mi" }
        if miles >= 0.1 { return String(format: "%.1f mi", miles) }
        let feet = Int((max(0, meters) / Units.metersPerFoot / 50).rounded()) * 50
        return "\(max(50, feet)) ft"
    }

    /// Spoken form: "2 miles", "half a mile", "500 feet".
    public static func spoken(_ meters: Double) -> String {
        let miles = Units.miles(fromMeters: max(0, meters))
        if miles >= 0.95 {
            let rounded = Int(miles.rounded())
            return rounded == 1 ? "1 mile" : "\(rounded) miles"
        }
        if miles >= 0.4 { return "half a mile" }
        if miles >= 0.2 { return "a quarter mile" }
        let feet = Int((max(0, meters) / Units.metersPerFoot / 100).rounded()) * 100
        return "\(max(100, feet)) feet"
    }
}
