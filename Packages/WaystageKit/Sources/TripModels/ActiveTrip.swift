import Foundation

/// Where the driver is within the itinerary. Persisted after every change so a trip can be
/// resumed after the app is closed or the phone restarts.
public struct TripProgress: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// Trip saved but not started.
        case notStarted
        /// Driving towards `targetStopIndex`.
        case enRoute
        /// Arrived and stopped at `targetStopIndex`.
        case atStop
        /// Arrived at the destination.
        case completed
    }

    public var phase: Phase
    /// Index (into `Itinerary.stops`) of the stop being driven to, or the current stop when `atStop`.
    public var targetStopIndex: Int
    /// Actual arrival times keyed by stop ID.
    public var actualArrivals: [String: Date]
    /// Actual departure times keyed by stop ID.
    public var actualDepartures: [String: Date]
    /// IDs of stops the driver chose to skip.
    public var skippedStopIDs: Set<String>
    public var lastKnownLocation: GeoCoordinate?
    public var updatedAt: Date

    public init(
        phase: Phase = .notStarted,
        targetStopIndex: Int = 1,
        actualArrivals: [String: Date] = [:],
        actualDepartures: [String: Date] = [:],
        skippedStopIDs: Set<String> = [],
        lastKnownLocation: GeoCoordinate? = nil,
        updatedAt: Date = Date()
    ) {
        self.phase = phase
        self.targetStopIndex = targetStopIndex
        self.actualArrivals = actualArrivals
        self.actualDepartures = actualDepartures
        self.skippedStopIDs = skippedStopIDs
        self.lastKnownLocation = lastKnownLocation
        self.updatedAt = updatedAt
    }
}

/// A trip the user has started (or is about to start), with its saved progress.
public struct ActiveTrip: Codable, Hashable, Sendable, Identifiable {
    public var itinerary: Itinerary
    public var progress: TripProgress
    /// Directions refreshed during the drive (e.g. after a reroute), keyed by the leg's start stop index.
    public var rerouteLegs: [Int: RouteLeg]

    public var id: UUID { itinerary.id }

    public init(itinerary: Itinerary, progress: TripProgress = TripProgress(), rerouteLegs: [Int: RouteLeg] = [:]) {
        self.itinerary = itinerary
        self.progress = progress
        self.rerouteLegs = rerouteLegs
    }

    /// The stop being driven to (or the current stop when `atStop`).
    public var targetStop: ItineraryStop? {
        itinerary.stops.indices.contains(progress.targetStopIndex) ? itinerary.stops[progress.targetStopIndex] : nil
    }

    /// The stop after the target, if any.
    public var stopAfterTarget: ItineraryStop? {
        let next = progress.targetStopIndex + 1
        return itinerary.stops.indices.contains(next) ? itinerary.stops[next] : nil
    }

    /// Directions into the target stop, preferring a refreshed leg.
    public var legToTarget: RouteLeg? {
        let fromIndex = progress.targetStopIndex - 1
        return rerouteLegs[fromIndex] ?? itinerary.leg(after: fromIndex)
    }

    /// Fraction of planned stops that have been reached or skipped, `0...1`.
    public var completionFraction: Double {
        let total = max(1, itinerary.stops.count - 1)
        switch progress.phase {
        case .notStarted: return 0
        case .completed: return 1
        case .atStop: return Double(progress.targetStopIndex) / Double(total)
        case .enRoute: return Double(progress.targetStopIndex - 1) / Double(total)
        }
    }
}
