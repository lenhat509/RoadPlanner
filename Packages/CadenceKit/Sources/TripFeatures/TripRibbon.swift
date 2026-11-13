import Foundation
import TripModels

/// A stop placed along a trip ribbon (a one-line overview of the trip: start, breaks, fuel,
/// nights and destination as dots along a line).
public struct RibbonMark: Hashable, Sendable, Identifiable {
    public var id: String
    /// Position along the trip, `0...1` by distance.
    public var fraction: Double
    public var kind: StopKind
    public var isPullOff: Bool

    public init(id: String, fraction: Double, kind: StopKind, isPullOff: Bool) {
        self.id = id
        self.fraction = fraction
        self.kind = kind
        self.isPullOff = isPullOff
    }
}

public enum TripRibbon {
    /// Every stop of the itinerary positioned by distance from the start.
    public static func marks(for itinerary: Itinerary) -> [RibbonMark] {
        let total = max(1, itinerary.stops.last?.distanceFromStartMeters ?? 0)
        return itinerary.stops.map { stop in
            RibbonMark(
                id: stop.id,
                fraction: min(1, max(0, stop.distanceFromStartMeters / total)),
                kind: stop.kind,
                isPullOff: stop.isRoadsidePullOff
            )
        }
    }

    /// Fraction of the trip's distance already driven, `0...1`.
    ///
    /// - Parameter legProgress: progress along the current leg (from guidance), `0...1`.
    public static func progress(of trip: ActiveTrip, legProgress: Double?) -> Double {
        let stops = trip.itinerary.stops
        guard let total = stops.last?.distanceFromStartMeters, total > 0 else { return 0 }
        switch trip.progress.phase {
        case .notStarted: return 0
        case .completed: return 1
        case .atStop:
            return min(1, stops[min(trip.progress.targetStopIndex, stops.count - 1)].distanceFromStartMeters / total)
        case .enRoute:
            let target = min(trip.progress.targetStopIndex, stops.count - 1)
            let from = stops[max(0, target - 1)].distanceFromStartMeters
            let to = stops[target].distanceFromStartMeters
            let leg = min(1, max(0, legProgress ?? 0))
            return min(1, max(0, (from + (to - from) * leg) / total))
        }
    }
}
