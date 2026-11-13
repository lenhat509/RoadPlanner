import Foundation
import TripModels

/// A rule broken by an itinerary.
public enum ScheduleViolation: Hashable, Sendable {
    case timeGoesBackwards(stopIndex: Int)
    case continuousDrivingTooLong(legIndex: Int, duration: TimeInterval)
    case fuelBelowReserve(stopIndex: Int, gallons: Double)
    case dailyDrivingTooLong(dayIndex: Int, duration: TimeInterval)
    case deadlineMissed(arrival: Date)
}

/// Independently checks an itinerary against the safety rules. Used after directions are
/// finalized and as an oracle in tests: every plan the app produces must pass it.
public struct ScheduleValidator: Sendable {
    /// Allowed slack for rounding and minor estimate differences.
    public var timeTolerance: TimeInterval
    public var fuelTolerance: Double

    public init(timeTolerance: TimeInterval = 120, fuelTolerance: Double = 0.1) {
        self.timeTolerance = timeTolerance
        self.fuelTolerance = fuelTolerance
    }

    public func violations(in itinerary: Itinerary) -> [ScheduleViolation] {
        let policy = itinerary.appliedPolicy
        let vehicle = itinerary.request.vehicle
        let stops = itinerary.stops
        var violations: [ScheduleViolation] = []
        guard stops.count >= 2 else { return violations }

        let reserve = vehicle.tankCapacityGallons * policy.fuelReserveFraction
        let initialFuel = vehicle.tankCapacityGallons * vehicle.initialFuelFraction
        let firstLegReserve = min(reserve, initialFuel * 0.25)
        let fuelGapAccepted = itinerary.warnings.contains { $0.code == .fuelGap }
        var dailyDriving: [Int: TimeInterval] = [:]

        for index in stops.indices {
            let stop = stops[index]
            if let arrival = stop.arrival, let departure = stop.departure, departure < arrival - 1 {
                violations.append(.timeGoesBackwards(stopIndex: index))
            }
            if index > 0, let fuel = stop.fuelOnArrivalGallons, !fuelGapAccepted {
                let required = index == 1 ? firstLegReserve : reserve
                if fuel < required - fuelTolerance {
                    violations.append(.fuelBelowReserve(stopIndex: index, gallons: fuel))
                }
            }
            guard index > 0, let previousDeparture = stops[index - 1].departure, let arrival = stop.arrival else { continue }
            let drive = arrival.timeIntervalSince(previousDeparture)
            if drive < -1 {
                violations.append(.timeGoesBackwards(stopIndex: index))
            } else if drive > policy.maxContinuousDriving + timeTolerance {
                violations.append(.continuousDrivingTooLong(legIndex: index - 1, duration: drive))
            }
            dailyDriving[stops[index - 1].kind == .lodging ? stops[index - 1].dayIndex + 1 : stops[index - 1].dayIndex, default: 0] += max(0, drive)
        }
        for (day, duration) in dailyDriving.sorted(by: { $0.key < $1.key })
        where duration > policy.maxDailyDriving + timeTolerance {
            violations.append(.dailyDrivingTooLong(dayIndex: day, duration: duration))
        }
        if let deadline = itinerary.request.arriveBy, let arrival = itinerary.arrival,
           arrival > deadline + timeTolerance,
           !itinerary.warnings.contains(where: { $0.code == .deadlineMissed }) {
            violations.append(.deadlineMissed(arrival: arrival))
        }
        return violations
    }
}
