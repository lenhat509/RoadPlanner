import Foundation
import TripModels

/// A GPS fix, decoupled from CoreLocation so navigation logic is testable anywhere.
public struct LocationSample: Hashable, Sendable {
    public var coordinate: GeoCoordinate
    /// Horizontal accuracy in meters (negative = invalid).
    public var horizontalAccuracy: Double
    /// Speed in m/s (negative = unknown).
    public var speed: Double
    /// Course in degrees from north (negative = unknown).
    public var course: Double
    public var timestamp: Date

    public init(coordinate: GeoCoordinate, horizontalAccuracy: Double = 5, speed: Double = -1, course: Double = -1, timestamp: Date) {
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.course = course
        self.timestamp = timestamp
    }
}
