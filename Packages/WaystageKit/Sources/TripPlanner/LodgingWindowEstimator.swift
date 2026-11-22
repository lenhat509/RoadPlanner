import Foundation
import TripModels

/// A section of the route where an overnight stop is likely.
public struct LodgingWindow: Hashable, Sendable {
    public var dayIndex: Int
    /// Range of driving time along the route (seconds from the start).
    public var routeTimeRange: ClosedRange<TimeInterval>
    /// Approximate check-in time.
    public var checkIn: Date
}

/// Predicts where each driving day will end so lodging is only searched where it matters,
/// keeping Places/Expedia requests (and cost) low.
public struct LodgingWindowEstimator: Sendable {
    /// How far before the predicted end of day to search.
    public var lookBack: TimeInterval
    /// How far after the predicted end of day to search (covers relaxed, longer days).
    public var lookAhead: TimeInterval

    public init(lookBack: TimeInterval = 3 * 3_600, lookAhead: TimeInterval = 2 * 3_600) {
        self.lookBack = lookBack
        self.lookAhead = lookAhead
    }

    /// - Parameters:
    ///   - stays: visits on the way (time along the route, and how long), which push later days back.
    ///   - drivenToday: driving already done today (a trip planned again during a drive).
    public func windows(
        routeDuration: TimeInterval,
        departure: Date,
        utcOffset: Int,
        policy: DrivingPolicy,
        stays: [(at: TimeInterval, duration: TimeInterval)] = [],
        drivenToday initialDriving: TimeInterval = 0
    ) -> [LodgingWindow] {
        var windows: [LodgingWindow] = []
        var along: TimeInterval = 0
        var clock = departure.timeIntervalSince1970 + Double(utcOffset) // local seconds
        var drivenToday: TimeInterval = min(max(0, initialDriving), max(0, policy.maxDailyDriving - 3_600))
        var cutoff = dayCutoff(startingAt: clock, policy: policy)
        var day = 0
        var pendingStays = stays.sorted { $0.at < $1.at }

        while along < routeDuration && day < 60 {
            // Reached a visit: the clock moves on by its stay. A night or more there is that
            // night's rest: the next driving day starts after it.
            if let stay = pendingStays.first, stay.at - along <= 60 {
                let nights = Int(floor((clock + stay.duration) / Units.secondsPerDay) - floor(clock / Units.secondsPerDay))
                clock += stay.duration
                pendingStays.removeFirst()
                if nights > 0 && stay.duration >= policy.minimumOvernightRest {
                    drivenToday = 0
                    cutoff = dayCutoff(startingAt: clock, policy: policy)
                    day += nights
                }
                continue
            }
            let available = min(
                policy.maxContinuousDriving,
                routeDuration - along,
                policy.maxDailyDriving - drivenToday,
                cutoff - clock,
                pendingStays.first.map { $0.at - along } ?? .infinity
            )
            if available > 60 {
                along += available
                clock += available
                drivenToday += available
                if along < routeDuration { clock += policy.restStopDuration }
                continue
            }
            // Day over: the driver stops for the night around `along`.
            windows.append(LodgingWindow(
                dayIndex: day,
                routeTimeRange: max(0, along - lookBack)...min(routeDuration, along + lookAhead),
                checkIn: Date(timeIntervalSince1970: clock - Double(utcOffset))
            ))
            var nextStart = floor(clock / Units.secondsPerDay) * Units.secondsPerDay + policy.dayStart.secondsFromMidnight
            if nextStart <= clock { nextStart += Units.secondsPerDay }
            clock = max(clock + policy.minimumOvernightRest, nextStart)
            cutoff = dayCutoff(startingAt: clock, policy: policy)
            drivenToday = 0
            day += 1
        }
        return windows
    }

    private func dayCutoff(startingAt local: TimeInterval, policy: DrivingPolicy) -> TimeInterval {
        let midnight = floor(local / Units.secondsPerDay) * Units.secondsPerDay
        return max(midnight + policy.dayEnd.secondsFromMidnight, local + 2 * 3_600)
    }
}
