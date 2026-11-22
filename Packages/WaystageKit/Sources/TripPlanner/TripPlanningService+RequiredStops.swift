import Foundation
import TripModels

/// The traveler's own stops: where they are on the route, how they enter the candidates, and the
/// hotels near visits with nights.
extension TripPlanningService {
    /// Where each required stop is on a route through them: at the end of its leg (or, if the
    /// provider returned no legs, where it projects onto the route). In route order.
    static func requiredPositions(
        of stops: [RequiredStop], on route: ComputedRoute, profile: RouteProfile
    ) -> [(stop: RequiredStop, distance: Double, time: TimeInterval)] {
        guard !stops.isEmpty else { return [] }
        let total = profile.totalDistance
        var distances: [Double]
        let legTotal = route.legs.reduce(0) { $0 + $1.distanceMeters }
        if route.legs.count == stops.count + 1, legTotal > 0 {
            var sum = 0.0
            distances = route.legs.dropLast().map { leg in
                sum += leg.distanceMeters
                return sum / legTotal * total
            }
        } else {
            distances = stops.map { profile.geometry.project($0.place.coordinate)?.distanceAlong ?? 0 }
        }
        var previous = 0.0
        return zip(stops, distances).map { stop, distance in
            let clamped = min(max(distance, previous, 1), max(1, total - 1))
            previous = clamped
            return (stop, clamped, profile.time(atDistance: clamped))
        }
    }

    /// The candidates without the places the traveler removed, and with each required stop at its
    /// place on the route. A required stop found by a search keeps that search's live details.
    static func applyingRequirements(
        to candidates: [StopCandidate], request: TripRequest,
        positions: [(stop: RequiredStop, distance: Double, time: TimeInterval)],
        regionalFuelPrice: (GeoCoordinate) -> Double?, pricing: PricingDefaults
    ) -> [StopCandidate] {
        let avoided = Set(request.avoidedPlaceIDs ?? [])
        let required = Set(positions.map(\.stop.place.id))
        var result = candidates.filter { !avoided.contains($0.place.id) && !required.contains($0.place.id) }
        for (stop, distance, time) in positions {
            let found = candidates.first { $0.place.id == stop.place.id }
            var candidate = StopCandidate(
                id: stop.place.id, place: found?.place ?? stop.place, capabilities: [],
                distanceAlong: distance, timeAlong: time
            )
            switch stop.purpose {
            case .visit:
                candidate.requirement = .visit(stay: stop.stay ?? (stop.visitNights > 0 ? 0 : 3_600))
                candidate.visitNights = stop.visitNights
            case .rest:
                candidate.capabilities = [.rest]
                candidate.requirement = .rest
            case .fuel:
                candidate.capabilities = [.fuel, .rest]
                candidate.requirement = .refuel
                if let found, let price = found.fuelPricePerGallon {
                    candidate.fuelPricePerGallon = price
                    candidate.isFuelPriceEstimated = found.isFuelPriceEstimated
                    candidate.isFuelGradeConfirmed = found.isFuelGradeConfirmed
                } else {
                    candidate.fuelPricePerGallon = stop.fuelPricePerGallon
                        ?? regionalFuelPrice(stop.place.coordinate) ?? pricing.fuelPrice(for: request.vehicle.fuelType)
                    candidate.isFuelPriceEstimated = stop.fuelPricePerGallon == nil
                }
            case .lodging:
                candidate.capabilities = [.lodging]
                candidate.requirement = .overnight
                if let found, found.nightlyRate != nil {
                    candidate.nightlyRate = found.nightlyRate
                    candidate.isLodgingRateEstimated = found.isLodgingRateEstimated
                    candidate.lodgingProvider = found.lodgingProvider
                    candidate.bookingURL = found.bookingURL
                    candidate.rating = found.rating
                } else {
                    candidate.nightlyRate = stop.lodging?.nightlyRate ?? pricing.unknownNightlyRate
                    candidate.isLodgingRateEstimated = stop.lodging?.isRateEstimated ?? true
                    candidate.lodgingProvider = stop.lodging?.provider
                    candidate.bookingURL = stop.lodging?.bookingURL
                }
            }
            result.append(candidate)
        }
        return result
    }

    // MARK: - Hotels near visits

    /// Searched around a visit with nights in a hotel nearby (driving time either way along the route).
    static let visitHotelWindow: TimeInterval = 30 * 60
    /// How far from a visit its hotel may be.
    static let visitHotelRadius = 25_000.0

    /// Visits with nights in a hotel nearby get the best value hotel within `visitHotelRadius` of
    /// them (rate plus $2 a km), its rate for each night, and the cost of those nights; when none
    /// was found, the plan says so.
    static func withVisitHotels(_ itinerary: Itinerary, request: TripRequest, candidates: [StopCandidate]) -> Itinerary {
        let wanted = Set(request.requiredStops.filter { $0.overnight == .nearbyHotel }.map(\.place.id))
        guard !wanted.isEmpty else { return itinerary }
        let hotels = candidates.filter { $0.capabilities.contains(.lodging) && !$0.isSynthetic && $0.requirement == nil }
        var result = itinerary
        var added = 0.0
        for index in result.stops.indices where result.stops[index].kind == .visit && wanted.contains(result.stops[index].place.id) {
            let visit = result.stops[index]
            let nights = visit.nightsHere
            guard nights > 0 else { continue }
            func value(_ hotel: StopCandidate) -> Double {
                let rate: Double = hotel.nightlyRate ?? 150
                let meters: Double = GeoMath.distance(hotel.place.coordinate, visit.place.coordinate)
                return rate + meters / 500
            }
            let nearby = hotels.filter { GeoMath.distance($0.place.coordinate, visit.place.coordinate) <= visitHotelRadius }
            let best = nearby.min { value($0) < value($1) }
            guard let hotel = best else {
                result.warnings.append(PlanWarning(
                    code: .noHotelNearVisit,
                    message: "No hotel was found near \(visit.place.name) for its nights; look for one nearby."
                ))
                continue
            }
            let rate = hotel.nightlyRate ?? 150
            result.stops[index].hotel = hotel.place
            result.stops[index].lodging = LodgingStay(
                nightlyRate: rate, isRateEstimated: hotel.nightlyRate == nil || hotel.isLodgingRateEstimated,
                provider: hotel.lodgingProvider, bookingURL: hotel.bookingURL
            )
            added += rate * Double(nights)
        }
        result.totals.cost.lodging += added
        return result
    }

    /// Hotels near visits whose nights are spent in a hotel nearby: searched around the visit.
    static func visitHotelWindows(
        _ required: [(stop: RequiredStop, distance: Double, time: TimeInterval)], profile: RouteProfile, departure: Date
    ) -> [LodgingWindow] {
        required.filter { $0.stop.overnight == .nearbyHotel }.map { position in
            LodgingWindow(
                dayIndex: -1,
                routeTimeRange: max(0, position.time - visitHotelWindow)...min(profile.totalDuration, position.time + visitHotelWindow),
                checkIn: departure.addingTimeInterval(position.time)
            )
        }
    }
}
