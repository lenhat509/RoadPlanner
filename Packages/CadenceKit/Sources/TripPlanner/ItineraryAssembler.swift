import Foundation
import TripModels

/// Converts an optimizer schedule into the user-facing `Itinerary`.
public struct ItineraryAssembler: Sendable {
    public init() {}

    public func assemble(
        request: TripRequest,
        goal: OptimizationGoal,
        profile: RouteProfile,
        feasible: FeasibleSchedule,
        overviewPolyline: String,
        additionalWarnings: [PlanWarning] = []
    ) -> Itinerary {
        let schedule = feasible.schedule
        var stops: [ItineraryStop] = [ItineraryStop(
            id: "origin",
            kind: .origin,
            place: request.origin,
            arrival: nil,
            departure: request.departure,
            distanceFromStartMeters: 0,
            fuelOnArrivalGallons: request.vehicle.tankCapacityGallons * request.vehicle.initialFuelFraction,
            dayIndex: 0
        )]
        var usesEstimatedPrices = false
        for (index, scheduled) in schedule.stops.enumerated() {
            let candidate = scheduled.candidate
            var stop = ItineraryStop(
                id: "\(index + 1)-\(candidate.id)",
                kind: .rest,
                place: candidate.place,
                arrival: scheduled.arrival,
                departure: scheduled.departure,
                distanceFromStartMeters: candidate.distanceAlong,
                fuelOnArrivalGallons: scheduled.fuelOnArrival,
                isRoadsidePullOff: candidate.isRoadsidePullOff,
                dayIndex: scheduled.dayIndex
            )
            switch scheduled.action {
            case .rest:
                stop.kind = .rest
            case let .refuel(gallons, price):
                stop.kind = .fuel
                stop.fuelPurchase = FuelPurchase(
                    gallons: gallons,
                    pricePerGallon: price,
                    isPriceEstimated: candidate.isFuelPriceEstimated || candidate.fuelPricePerGallon == nil
                )
                usesEstimatedPrices = usesEstimatedPrices || stop.fuelPurchase!.isPriceEstimated
            case let .overnight(rate):
                stop.kind = .lodging
                stop.lodging = LodgingStay(
                    nightlyRate: rate,
                    isRateEstimated: candidate.isLodgingRateEstimated,
                    provider: candidate.lodgingProvider,
                    bookingURL: candidate.bookingURL
                )
                usesEstimatedPrices = usesEstimatedPrices || candidate.isLodgingRateEstimated
            }
            stops.append(stop)
        }
        stops.append(ItineraryStop(
            id: "destination",
            kind: .destination,
            place: request.destination,
            arrival: schedule.arrival,
            departure: nil,
            distanceFromStartMeters: profile.totalDistance,
            fuelOnArrivalGallons: schedule.fuelOnArrival,
            dayIndex: schedule.finalDayIndex
        ))

        var warnings = feasible.warnings + additionalWarnings
        if usesEstimatedPrices {
            warnings.append(PlanWarning(
                code: .estimatedPrices,
                message: "Some fuel or lodging prices are estimates; live prices weren't available for every stop."
            ))
        }

        let detourDistance = schedule.stops.reduce(0) { $0 + $1.candidate.detourDistance }
        return Itinerary(
            goal: goal,
            request: request,
            stops: stops,
            legs: [],
            totals: TripTotals(
                distanceMeters: profile.totalDistance + detourDistance,
                drivingDuration: schedule.drivingDuration,
                elapsedDuration: schedule.arrival.timeIntervalSince(request.departure),
                cost: CostBreakdown(fuel: schedule.fuelCost, lodging: schedule.lodgingCost, tolls: schedule.tollCost),
                fuelGallonsUsed: schedule.fuelGallonsUsed,
                referenceFuelPrice: schedule.referenceFuelPrice
            ),
            warnings: warnings,
            routeSummary: profile.summary,
            overviewPolyline: overviewPolyline,
            appliedPolicy: feasible.appliedPolicy
        )
    }
}
