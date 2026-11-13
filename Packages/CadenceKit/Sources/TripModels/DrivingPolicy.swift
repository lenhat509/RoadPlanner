import Foundation

/// A wall-clock time of day (in the local time zone of wherever the car is).
public struct LocalTime: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int = 0) {
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
    }

    public var secondsFromMidnight: TimeInterval { TimeInterval(hour * 3_600 + minute * 60) }

    public var description: String { String(format: "%02d:%02d", hour, minute) }

    public static func < (lhs: LocalTime, rhs: LocalTime) -> Bool {
        lhs.secondsFromMidnight < rhs.secondsFromMidnight
    }
}

/// Safety and comfort rules the planner must respect.
///
/// `maxContinuousDriving` is a hard safety limit and is never relaxed. The other limits are
/// preferences that the feasibility ladder may loosen (and report) when a deadline or a
/// sparse road network would otherwise make the trip impossible.
public struct DrivingPolicy: Codable, Hashable, Sendable {
    /// Longest stretch of non-stop driving before a break. Defaults to 3 h, so the driver
    /// rests every 2–3 hours.
    public var maxContinuousDriving: TimeInterval
    /// Length of a rest break.
    public var restStopDuration: TimeInterval
    /// Length of a fuel stop (it also counts as a rest break).
    public var fuelStopDuration: TimeInterval
    /// Maximum driving time per day.
    public var maxDailyDriving: TimeInterval
    /// Earliest local time to leave an overnight stop.
    public var dayStart: LocalTime
    /// Latest local time to arrive at an overnight stop (or the destination).
    public var dayEnd: LocalTime
    /// Minimum time spent at an overnight stop.
    public var minimumOvernightRest: TimeInterval
    /// Minimum fuel level as a fraction of the tank. The planner makes sure the car always reaches
    /// the next gas station (and the destination) before dropping below it. Never relaxed.
    public var fuelReserveFraction: Double
    /// Dollar value of one hour, used to trade time against money for the balanced goal.
    public var valueOfTimePerHour: Double

    public init(
        maxContinuousDriving: TimeInterval = 3 * 3_600,
        restStopDuration: TimeInterval = 15 * 60,
        fuelStopDuration: TimeInterval = 15 * 60,
        maxDailyDriving: TimeInterval = 10 * 3_600,
        dayStart: LocalTime = LocalTime(hour: 8),
        dayEnd: LocalTime = LocalTime(hour: 21),
        minimumOvernightRest: TimeInterval = 9 * 3_600,
        fuelReserveFraction: Double = 0.15,
        valueOfTimePerHour: Double = 25
    ) {
        self.maxContinuousDriving = maxContinuousDriving
        self.restStopDuration = restStopDuration
        self.fuelStopDuration = fuelStopDuration
        self.maxDailyDriving = maxDailyDriving
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.minimumOvernightRest = minimumOvernightRest
        self.fuelReserveFraction = fuelReserveFraction
        self.valueOfTimePerHour = valueOfTimePerHour
    }

    /// The default policy: rest every 2–3 hours, at most 10 hours of driving per day.
    public static let standard = DrivingPolicy()

    /// Allowed range for the user's minimum fuel level.
    public static let allowedFuelReserve: ClosedRange<Double> = 0.05...0.5

    /// Allowed range for the user's "drive before resting" input.
    public static let allowedContinuousDriving: ClosedRange<TimeInterval> = (30 * 60)...(5 * 3_600)
}
