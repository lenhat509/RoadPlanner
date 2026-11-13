import Foundation

/// Unit conversion constants used across the planner.
public enum Units {
    /// Meters in one statute mile.
    public static let metersPerMile = 1_609.344
    /// Meters in one foot.
    public static let metersPerFoot = 0.3048
    /// Seconds in one hour.
    public static let secondsPerHour: TimeInterval = 3_600
    /// Seconds in one day.
    public static let secondsPerDay: TimeInterval = 86_400

    /// Converts meters to statute miles.
    public static func miles(fromMeters meters: Double) -> Double { meters / metersPerMile }

    /// Converts statute miles to meters.
    public static func meters(fromMiles miles: Double) -> Double { miles * metersPerMile }
}
