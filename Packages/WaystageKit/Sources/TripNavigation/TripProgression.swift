import Foundation
import TripModels

/// Invalid trip state transitions.
public enum TripTransitionError: Error, Equatable, Sendable {
    case notStarted
    case alreadyStarted
    case notAtStop
    case tripCompleted
    case cannotSkipDestination
}

/// A stop's schedule adjusted for how the drive is actually going.
public struct ProjectedStop: Hashable, Sendable {
    public var stopID: String
    public var arrival: Date?
    public var departure: Date?
    /// Positive when running late versus the plan.
    public var delay: TimeInterval
}

/// The trip state machine. Every mutation updates `progress.updatedAt` so callers can persist.
extension ActiveTrip {
    public var isFinalTarget: Bool { progress.targetStopIndex >= itinerary.stops.count - 1 }

    /// Starts driving from the origin.
    public mutating func start(at date: Date) throws {
        guard progress.phase == .notStarted else { throw TripTransitionError.alreadyStarted }
        progress.phase = .enRoute
        progress.targetStopIndex = 1
        progress.actualDepartures[itinerary.stops[0].id] = date
        progress.updatedAt = date
    }

    /// Records arrival at the target stop (or completes the trip at the destination).
    public mutating func markArrived(at date: Date) throws {
        switch progress.phase {
        case .notStarted: throw TripTransitionError.notStarted
        case .completed: throw TripTransitionError.tripCompleted
        case .atStop: return
        case .enRoute: break
        }
        guard let target = targetStop else { throw TripTransitionError.tripCompleted }
        progress.actualArrivals[target.id] = date
        progress.phase = isFinalTarget ? .completed : .atStop
        progress.updatedAt = date
    }

    /// Leaves the current stop (or moves past the target if still en route) towards the next one.
    public mutating func continueToNextStop(at date: Date) throws {
        switch progress.phase {
        case .notStarted: throw TripTransitionError.notStarted
        case .completed: throw TripTransitionError.tripCompleted
        case .enRoute:
            if isFinalTarget {
                try markArrived(at: date)
                return
            }
            if let target = targetStop, progress.actualArrivals[target.id] == nil {
                progress.actualArrivals[target.id] = date
            }
        case .atStop:
            break
        }
        guard let target = targetStop else { throw TripTransitionError.tripCompleted }
        progress.actualDepartures[target.id] = date
        progress.targetStopIndex += 1
        progress.phase = .enRoute
        progress.updatedAt = date
    }

    /// Skips the stop being driven to.
    public mutating func skipTargetStop(at date: Date) throws {
        guard progress.phase == .enRoute else {
            throw progress.phase == .completed ? TripTransitionError.tripCompleted : TripTransitionError.notStarted
        }
        guard !isFinalTarget, let target = targetStop else { throw TripTransitionError.cannotSkipDestination }
        progress.skippedStopIDs.insert(target.id)
        progress.targetStopIndex += 1
        progress.updatedAt = date
    }

    public mutating func record(location: GeoCoordinate, at date: Date) {
        progress.lastKnownLocation = location
        progress.updatedAt = date
    }

    /// Planned times shifted by the current delay. Overnight departures stay at their planned
    /// morning time unless the driver arrives too late for the minimum rest.
    ///
    /// - Parameter remainingToTarget: live driving time to the target stop, from guidance.
    public func projectedSchedule(now: Date, remainingToTarget: TimeInterval?) -> [ProjectedStop] {
        let stops = itinerary.stops
        let policy = itinerary.appliedPolicy
        var result: [ProjectedStop] = []
        var shiftedDeparture: Date?

        for (index, stop) in stops.enumerated() {
            if index < progress.targetStopIndex || (index == progress.targetStopIndex && progress.phase == .atStop) {
                let arrival = progress.actualArrivals[stop.id] ?? stop.arrival
                let departure = progress.actualDepartures[stop.id] ?? stop.departure
                result.append(ProjectedStop(
                    stopID: stop.id, arrival: arrival, departure: departure,
                    delay: (arrival ?? now).timeIntervalSince(stop.arrival ?? arrival ?? now)
                ))
                if index == progress.targetStopIndex {
                    shiftedDeparture = max(now, stop.arrival.flatMap { arrivalPlanned in
                        stop.dwellDuration.map { (progress.actualArrivals[stop.id] ?? arrivalPlanned).addingTimeInterval($0) }
                    } ?? now)
                } else {
                    shiftedDeparture = departure
                }
                continue
            }
            let plannedDrive: TimeInterval = {
                guard index > 0, let previousDeparture = stops[index - 1].departure, let arrival = stop.arrival else { return 0 }
                return arrival.timeIntervalSince(previousDeparture)
            }()
            let arrival: Date
            if index == progress.targetStopIndex, progress.phase == .enRoute {
                arrival = now.addingTimeInterval(remainingToTarget ?? plannedDrive)
            } else {
                arrival = (shiftedDeparture ?? now).addingTimeInterval(plannedDrive)
            }
            var departure: Date?
            if stop.kind == .lodging, let planned = stop.departure {
                departure = max(planned, arrival.addingTimeInterval(policy.minimumOvernightRest))
            } else if let dwell = stop.dwellDuration {
                departure = arrival.addingTimeInterval(dwell)
            }
            result.append(ProjectedStop(
                stopID: stop.id, arrival: arrival, departure: departure,
                delay: arrival.timeIntervalSince(stop.arrival ?? arrival)
            ))
            shiftedDeparture = departure
        }
        return result
    }
}
