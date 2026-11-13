import Foundation
import TripModels

/// Re-times an itinerary using the durations and distances of its final driving directions,
/// keeping the planned breaks and overnight rules. Fuel levels and purchases are recomputed.
public struct ScheduleRetimer: Sendable {
    public init() {}

    public func retime(_ itinerary: Itinerary, legs: [RouteLeg]) -> Itinerary {
        guard legs.count == itinerary.stops.count - 1 else { return itinerary }
        let policy = itinerary.appliedPolicy
        let vehicle = itinerary.request.vehicle
        var stops = itinerary.stops
        var clock = stops[0].departure ?? itinerary.request.departure
        var fuel = vehicle.tankCapacityGallons * vehicle.initialFuelFraction
        var fuelCost = 0.0, lodgingCost = 0.0, drivingDuration = 0.0, distance = 0.0
        var cumulativeDistance = 0.0

        for index in 1..<stops.count {
            let leg = legs[index - 1]
            let arrival = clock.addingTimeInterval(leg.duration)
            drivingDuration += leg.duration
            distance += leg.distanceMeters
            cumulativeDistance += leg.distanceMeters
            fuel -= vehicle.gallons(forMeters: leg.distanceMeters)

            var stop = stops[index]
            let plannedDwell = stop.dwellDuration ?? 0
            stop.arrival = arrival
            stop.fuelOnArrivalGallons = fuel
            stop.distanceFromStartMeters = cumulativeDistance

            switch stop.kind {
            case .fuel:
                if var purchase = stop.fuelPurchase {
                    let plannedLevel = (stops[index].fuelOnArrivalGallons ?? fuel) + purchase.gallons
                    purchase.gallons = max(0, min(vehicle.tankCapacityGallons, plannedLevel) - fuel)
                    fuel += purchase.gallons
                    fuelCost += purchase.cost
                    stop.fuelPurchase = purchase
                }
                stop.departure = arrival.addingTimeInterval(plannedDwell)
            case .lodging:
                let offset = TimeInterval(stop.place.utcOffsetSeconds)
                stop.departure = Self.nextMorningDeparture(after: arrival, utcOffset: offset, policy: policy)
                lodgingCost += stop.lodging?.nightlyRate ?? 0
            case .destination:
                stop.departure = nil
            case .rest, .origin:
                stop.departure = arrival.addingTimeInterval(plannedDwell)
            }
            stops[index] = stop
            clock = stop.departure ?? arrival
        }

        var result = itinerary
        result.stops = stops
        result.legs = legs
        let tolls = legs.compactMap(\.tollCostUSD).reduce(0, +)
        let purchases = stops.compactMap(\.fuelPurchase)
        let averagePurchasePrice = purchases.isEmpty ? nil : purchases.reduce(0) { $0 + $1.pricePerGallon } / Double(purchases.count)
        let referencePrice = itinerary.totals.referenceFuelPrice ?? averagePurchasePrice ?? 0
        let initialFuel = vehicle.tankCapacityGallons * vehicle.initialFuelFraction
        // All gas burned: purchases + fuel that was in the tank − fuel left at the end.
        fuelCost += (initialFuel - fuel) * referencePrice
        let gallonsBought = purchases.reduce(0) { $0 + $1.gallons }
        result.totals = TripTotals(
            distanceMeters: distance,
            drivingDuration: drivingDuration,
            elapsedDuration: (stops.last?.arrival ?? clock).timeIntervalSince(itinerary.request.departure),
            cost: CostBreakdown(fuel: fuelCost, lodging: lodgingCost, tolls: tolls > 0 ? tolls : itinerary.totals.cost.tolls),
            fuelGallonsUsed: initialFuel + gallonsBought - fuel,
            referenceFuelPrice: referencePrice
        )
        return result
    }

    /// Departure time from an overnight stop: the later of minimum rest and the next day start.
    public static func nextMorningDeparture(after arrival: Date, utcOffset: TimeInterval, policy: DrivingPolicy) -> Date {
        let arrivalLocal = arrival.timeIntervalSince1970 + utcOffset
        var nextStart = floor(arrivalLocal / Units.secondsPerDay) * Units.secondsPerDay + policy.dayStart.secondsFromMidnight
        if nextStart <= arrivalLocal { nextStart += Units.secondsPerDay }
        let departureLocal = max(arrivalLocal + policy.minimumOvernightRest, nextStart)
        return Date(timeIntervalSince1970: departureLocal - utcOffset)
    }
}
