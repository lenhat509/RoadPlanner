import Foundation
import TripModels

/// Turns raw places found along a route into optimizer candidates.
///
/// Responsibilities:
/// * project each place onto the route (distance/time along the route, lateral offset),
/// * compute the detour (from the provider's routing summary or a conservative estimate),
/// * keep as fuel stops only stations that sell the car's grade (`FuelOffer`); others are breaks,
/// * attach prices for that grade (live → regional average → national default, flagging estimates),
/// * merge duplicates and attach live lodging offers to matching places,
/// * thin dense clusters so the optimizer stays fast,
/// * add roadside pull-offs and lodging search areas so a feasible plan always exists.
public struct CandidateBuilder: Sendable {
    public struct Configuration: Hashable, Sendable {
        /// Places further than this from the route are ignored.
        public var maxOffRouteMeters: Double = 8_000
        /// Lodging may be a bit further away.
        public var maxLodgingOffRouteMeters: Double = 12_000
        /// Interval between generated roadside pull-offs.
        public var pullOffInterval: TimeInterval = 15 * 60
        /// Interval between generated lodging search areas.
        public var lodgingAreaInterval: TimeInterval = 30 * 60
        /// Average speed off the highway, used to estimate detours (m/s ≈ 30 mph).
        public var localSpeedMetersPerSecond: Double = 13.4
        /// Fixed cost of leaving and re-entering the highway.
        public var exitPenalty: TimeInterval = 2 * 60
        /// Detour assumed for a roadside pull-off.
        public var pullOffDetour: TimeInterval = 4 * 60
        /// Bucket size used when thinning dense clusters of candidates.
        public var thinningBucket: TimeInterval = 15 * 60
        /// Maximum candidates kept per capability per bucket.
        public var maxPerBucket: Int = 3
        /// Live lodging offers within this distance of a place are treated as the same property.
        public var lodgingMatchRadiusMeters: Double = 200

        public init() {}
    }

    public var configuration: Configuration
    public var pricing: PricingDefaults

    public init(configuration: Configuration = Configuration(), pricing: PricingDefaults = .standard) {
        self.configuration = configuration
        self.pricing = pricing
    }

    /// Builds the candidate list, sorted by position along the route.
    ///
    /// - Parameters:
    ///   - regionalFuelPrice: average price near a coordinate, used when a station has no live price.
    public func build(
        profile: RouteProfile,
        places: [FoundPlace],
        lodgingOffers: [LodgingOffer] = [],
        fuelType: FuelType,
        regionalFuelPrice: (GeoCoordinate) -> Double? = { _ in nil }
    ) -> [StopCandidate] {
        var merged = mergeDuplicates(places)
        merged = attach(lodgingOffers, to: merged)

        var candidates: [StopCandidate] = []
        for found in merged {
            guard let candidate = makeCandidate(
                from: found, profile: profile, fuelType: fuelType, regionalFuelPrice: regionalFuelPrice
            ) else { continue }
            candidates.append(candidate)
        }
        candidates = thin(candidates)
        candidates += pullOffs(profile: profile, existing: candidates)
        candidates += lodgingSearchAreas(profile: profile)
        return candidates.sorted { ($0.distanceAlong, $0.id) < ($1.distanceAlong, $1.id) }
    }

    // MARK: - Steps

    func mergeDuplicates(_ places: [FoundPlace]) -> [FoundPlace] {
        var byID: [String: FoundPlace] = [:]
        var order: [String] = []
        for place in places {
            if var existing = byID[place.place.id] {
                existing.categories.formUnion(place.categories)
                existing.fuelPrices.merge(place.fuelPrices) { current, _ in current }
                existing.nightlyRate = existing.nightlyRate ?? place.nightlyRate
                existing.priceLevel = existing.priceLevel ?? place.priceLevel
                existing.detourDuration = existing.detourDuration ?? place.detourDuration
                existing.detourDistance = existing.detourDistance ?? place.detourDistance
                byID[place.place.id] = existing
            } else {
                byID[place.place.id] = place
                order.append(place.place.id)
            }
        }
        return order.compactMap { byID[$0] }
    }

    func attach(_ offers: [LodgingOffer], to places: [FoundPlace]) -> [FoundPlace] {
        guard !offers.isEmpty else { return places }
        var result = places
        var unmatched: [LodgingOffer] = []
        for offer in offers {
            let match = result.indices
                .filter { result[$0].categories.contains(.lodging) }
                .map { ($0, GeoMath.distance(result[$0].place.coordinate, offer.coordinate)) }
                .filter { $0.1 <= configuration.lodgingMatchRadiusMeters }
                .min { $0.1 < $1.1 }
            if let (index, _) = match {
                if result[index].nightlyRate == nil || offer.nightlyRate < result[index].nightlyRate! {
                    result[index].nightlyRate = offer.nightlyRate
                    result[index].rateProvider = offer.provider
                    result[index].bookingURL = offer.bookingURL
                }
            } else {
                unmatched.append(offer)
            }
        }
        // Offers with no matching Google place become candidates of their own.
        result += unmatched.map { offer in
            FoundPlace(
                place: Place(id: "\(offer.provider.lowercased()):\(offer.propertyID)", name: offer.name, coordinate: offer.coordinate),
                categories: [.lodging],
                nightlyRate: offer.nightlyRate,
                rateProvider: offer.provider,
                bookingURL: offer.bookingURL
            )
        }
        return result
    }

    func makeCandidate(
        from found: FoundPlace,
        profile: RouteProfile,
        fuelType: FuelType,
        regionalFuelPrice: (GeoCoordinate) -> Double?
    ) -> StopCandidate? {
        let window = found.searchRange.map { ($0.lowerBound - 20_000)...($0.upperBound + 20_000) }
        guard let projection = profile.geometry.project(found.place.coordinate, within: window)
            ?? profile.geometry.project(found.place.coordinate) else { return nil }

        let isLodgingOnly = found.categories == [.lodging]
        let limit = isLodgingOnly ? configuration.maxLodgingOffRouteMeters : configuration.maxOffRouteMeters
        guard projection.offsetMeters <= limit else { return nil }

        var capabilities: StopCapabilities = []
        var fuelOffer = FuelOffer.unavailable
        if found.categories.contains(.rest) { capabilities.insert(.rest) }
        if found.categories.contains(.fuel) {
            // A gas station is always fine for a break; it's a fuel stop only if it sells the grade.
            capabilities.insert(.rest)
            fuelOffer = FuelOffer.at(found, for: fuelType)
            if fuelOffer != .unavailable { capabilities.insert(.fuel) }
        }
        if found.categories.contains(.lodging) { capabilities.insert(.lodging) }
        guard !capabilities.isEmpty else { return nil }

        let estimatedDetourDistance = 2 * projection.offsetMeters * 1.3 // road network is not straight
        let estimatedDetour = estimatedDetourDistance / configuration.localSpeedMetersPerSecond + configuration.exitPenalty
        let detourDuration = max(60, found.detourDuration ?? estimatedDetour)
        let detourDistance = max(0, found.detourDistance ?? estimatedDetourDistance)

        var fuelPrice: Double?
        var fuelEstimated = false
        switch fuelOffer {
        case let .confirmed(price):
            fuelPrice = price
        case .assumed:
            fuelPrice = regionalFuelPrice(found.place.coordinate) ?? pricing.fuelPrice(for: fuelType)
            fuelEstimated = true
        case .unavailable:
            break
        }

        var nightlyRate: Double?
        var rateEstimated = false
        if capabilities.contains(.lodging) {
            if let live = found.nightlyRate {
                nightlyRate = live
            } else {
                nightlyRate = pricing.nightlyRate(for: found.priceLevel)
                rateEstimated = true
            }
        }

        return StopCandidate(
            id: found.place.id,
            place: found.place,
            capabilities: capabilities,
            distanceAlong: projection.distanceAlong,
            timeAlong: profile.time(atDistance: projection.distanceAlong),
            detourDuration: detourDuration,
            detourDistance: detourDistance,
            fuelPricePerGallon: fuelPrice,
            isFuelPriceEstimated: fuelEstimated,
            isFuelGradeConfirmed: { if case .confirmed = fuelOffer { return true } else { return false } }(),
            nightlyRate: nightlyRate,
            isLodgingRateEstimated: rateEstimated,
            lodgingProvider: found.rateProvider ?? (capabilities.contains(.lodging) ? "Google" : nil),
            bookingURL: found.bookingURL,
            rating: found.rating
        )
    }

    /// Keeps, per time bucket and capability, the best few candidates (cheapest and closest).
    func thin(_ candidates: [StopCandidate]) -> [StopCandidate] {
        let bucket = configuration.thinningBucket
        var keep = Set<String>()
        let grouped = Dictionary(grouping: candidates) { Int($0.timeAlong / bucket) }
        for (_, group) in grouped {
            let fuel = group.filter { $0.capabilities.contains(.fuel) }
            keep.formUnion(fuel.sorted { ($0.fuelPricePerGallon ?? .infinity, $0.detourDuration) < ($1.fuelPricePerGallon ?? .infinity, $1.detourDuration) }
                .prefix(configuration.maxPerBucket).map(\.id))
            keep.formUnion(fuel.sorted { $0.detourDuration < $1.detourDuration }.prefix(1).map(\.id))

            let rest = group.filter { $0.capabilities.contains(.rest) && !$0.capabilities.contains(.fuel) }
            keep.formUnion(rest.sorted { $0.detourDuration < $1.detourDuration }.prefix(configuration.maxPerBucket).map(\.id))

            let lodging = group.filter { $0.capabilities.contains(.lodging) }
            keep.formUnion(lodging.sorted { ($0.nightlyRate ?? .infinity) < ($1.nightlyRate ?? .infinity) }
                .prefix(configuration.maxPerBucket).map(\.id))
            keep.formUnion(lodging.sorted { lodgingQuality($0) > lodgingQuality($1) }.prefix(1).map(\.id))
            keep.formUnion(lodging.sorted { $0.detourDuration < $1.detourDuration }.prefix(1).map(\.id))
        }
        return candidates.filter { keep.contains($0.id) }
    }

    private func lodgingQuality(_ candidate: StopCandidate) -> Double {
        (candidate.rating ?? 3.5) - (candidate.isLodgingRateEstimated ? 0.25 : 0)
    }

    /// Generated breaks in route sections without a real rest-capable place, so the
    /// "rest every N hours" rule can always be satisfied.
    func pullOffs(profile: RouteProfile, existing: [StopCandidate]) -> [StopCandidate] {
        let interval = configuration.pullOffInterval
        guard profile.totalDuration > interval else { return [] }
        let restTimes = existing.filter { $0.capabilities.contains(.rest) }.map(\.timeAlong).sorted()
        var result: [StopCandidate] = []
        var time = interval
        while time < profile.totalDuration - interval / 2 {
            let hasNearbyRest = restTimes.contains { abs($0 - time) <= interval / 2 }
            if !hasNearbyRest {
                let distance = profile.distance(atTime: time)
                let miles = Int(Units.miles(fromMeters: distance).rounded())
                result.append(StopCandidate(
                    id: "pulloff-\(Int(time))",
                    place: Place(
                        id: "pulloff-\(Int(time))",
                        name: "Roadside break",
                        address: "Take the next safe exit near mile \(miles)",
                        coordinate: profile.geometry.coordinate(atDistance: distance)
                    ),
                    capabilities: [.rest],
                    distanceAlong: distance,
                    timeAlong: time,
                    detourDuration: configuration.pullOffDetour,
                    detourDistance: 1_000,
                    isRoadsidePullOff: true
                ))
            }
            time += interval
        }
        return result
    }

    /// Placeholder overnight areas; the optimizer only uses them when no real lodging works.
    func lodgingSearchAreas(profile: RouteProfile) -> [StopCandidate] {
        let interval = configuration.lodgingAreaInterval
        guard profile.totalDuration > interval else { return [] }
        var result: [StopCandidate] = []
        var time = interval
        while time < profile.totalDuration - interval / 2 {
            let distance = profile.distance(atTime: time)
            let miles = Int(Units.miles(fromMeters: distance).rounded())
            result.append(StopCandidate(
                id: "lodging-area-\(Int(time))",
                place: Place(
                    id: "lodging-area-\(Int(time))",
                    name: "Lodging area",
                    address: "Search for lodging near mile \(miles)",
                    coordinate: profile.geometry.coordinate(atDistance: distance)
                ),
                capabilities: [.lodging],
                distanceAlong: distance,
                timeAlong: time,
                detourDuration: 10 * 60,
                detourDistance: 5_000,
                nightlyRate: pricing.unknownNightlyRate,
                isLodgingRateEstimated: true,
                isLodgingSearchArea: true
            ))
            time += interval
        }
        return result
    }
}
