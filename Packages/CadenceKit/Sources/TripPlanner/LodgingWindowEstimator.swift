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

    public func windows(
        routeDuration: TimeInterval,
        departure: Date,
        utcOffset: Int,
        policy: DrivingPolicy
    ) -> [LodgingWindow] {
        var windows: [LodgingWindow] = []
        var along: TimeInterval = 0
        var clock = departure.timeIntervalSince1970 + Double(utcOffset) // local seconds
        var drivenToday: TimeInterval = 0
        var cutoff = dayCutoff(startingAt: clock, policy: policy)
        var day = 0

        while along < routeDuration && day < 60 {
            let available = min(
                policy.maxContinuousDriving,
                routeDuration - along,
                policy.maxDailyDriving - drivenToday,
                cutoff - clock
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
