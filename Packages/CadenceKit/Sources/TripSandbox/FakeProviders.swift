import Foundation
import TripModels
import TripPlanner

/// Offline routing: synthetic routes between any coordinates.
public struct FakeRoutingProvider: RoutingProvider {
    public var speedMPH: Double
    public var summary: String
    public var tollCostUSD: Double?
    public var failure: (any Error & Sendable)?

    public init(speedMPH: Double = 62, summary: String = "I-80", tollCostUSD: Double? = nil, failure: (any Error & Sendable)? = nil) {
        self.speedMPH = speedMPH
        self.summary = summary
        self.tollCostUSD = tollCostUSD
        self.failure = failure
    }

    public func computeRoutes(_ query: RouteQuery) async throws -> [ComputedRoute] {
        if let failure { throw failure }
        if query.intermediates.isEmpty {
            var routes = [SyntheticRoute.make(
                from: query.origin, to: query.destination, speedMPH: speedMPH, summary: summary,
                tollCostUSD: query.avoidTolls ? nil : tollCostUSD
            )]
            if query.computeAlternatives {
                routes.append(SyntheticRoute.make(
                    from: query.origin, to: query.destination, speedMPH: speedMPH * 0.93,
                    summary: "US-50", tollCostUSD: nil, curvature: 0.05
                ))
            }
            return routes
        }
        return [SyntheticRoute.make(
            through: [query.origin] + query.intermediates + [query.destination], speedMPH: speedMPH, summary: summary
        )]
    }
}

/// Offline place search: synthetic places along the searched polyline section.
public struct FakePlaceSearchProvider: PlaceSearchProvider {
    public var density: SyntheticPlaces.Density
    public var failingCategories: Set<PlaceCategory>
    public var seed: UInt64

    public init(density: SyntheticPlaces.Density = .interstate, failingCategories: Set<PlaceCategory> = [], seed: UInt64 = 7) {
        self.density = density
        self.failingCategories = failingCategories
        self.seed = seed
    }

    public struct SearchFailed: Error {
        public init() {}
    }

    public func searchAlongRoute(_ search: AlongRouteSearch) async throws -> [FoundPlace] {
        if failingCategories.contains(search.category) { throw SearchFailed() }
        let coordinates = try PolylineCodec.decode(search.encodedPolyline)
        let profile = RouteProfile(coordinates: coordinates, totalDuration: search.sectionDuration)
        let every: Double = switch search.category {
        case .fuel: density.fuelEveryMinutes
        case .rest: density.restEveryMinutes
        case .lodging: density.lodgingEveryMinutes
        }
        // Seed by section start so repeated searches return the same places.
        let sectionSeed = seed &+ UInt64(abs(Int(coordinates.first.map { $0.latitude * 1_000 + $0.longitude * 10 } ?? 0)))
        return SyntheticPlaces.along(profile, category: search.category, everyMinutes: every, seed: sectionSeed)
    }
}

/// Offline lodging rates.
public struct FakeLodgingRateProvider: LodgingRateProvider {
    public init() {}

    public func offers(for query: LodgingQuery) async throws -> [LodgingOffer] {
        [
            LodgingOffer(
                propertyID: "exp-\(Int(query.center.latitude * 100))-\(Int(query.center.longitude * 100))",
                name: "Roadside Suites",
                coordinate: GeoCoordinate(latitude: query.center.latitude + 0.01, longitude: query.center.longitude),
                nightlyRate: 89,
                provider: "Expedia",
                bookingURL: URL(string: "https://www.expedia.com/")
            ),
        ]
    }
}

/// Offline regional fuel prices.
public struct FakeRegionalFuelPriceProvider: RegionalFuelPriceProvider {
    public var price: Double

    public init(price: Double = 3.49) { self.price = price }

    public func averagePrice(near coordinate: GeoCoordinate, fuelType: FuelType) async throws -> Double? { price }
}

/// Offline autocomplete with a few well-known cities.
public struct FakeAutocompleteProvider: PlaceAutocompleteProvider {
    public static let cities: [Place] = [
        Place(
            id: "sf", name: "San Francisco", address: "San Francisco, CA, USA",
            coordinate: GeoCoordinate(latitude: 37.7749, longitude: -122.4194), utcOffsetMinutes: -480
        ),
        Place(
            id: "la", name: "Los Angeles", address: "Los Angeles, CA, USA",
            coordinate: GeoCoordinate(latitude: 34.0522, longitude: -118.2437), utcOffsetMinutes: -480
        ),
        Place(
            id: "lv", name: "Las Vegas", address: "Las Vegas, NV, USA",
            coordinate: GeoCoordinate(latitude: 36.1699, longitude: -115.1398), utcOffsetMinutes: -480
        ),
        Place(
            id: "den", name: "Denver", address: "Denver, CO, USA",
            coordinate: GeoCoordinate(latitude: 39.7392, longitude: -104.9903), utcOffsetMinutes: -420
        ),
        Place(
            id: "chi", name: "Chicago", address: "Chicago, IL, USA",
            coordinate: GeoCoordinate(latitude: 41.8781, longitude: -87.6298), utcOffsetMinutes: -360
        ),
        Place(
            id: "nyc", name: "New York", address: "New York, NY, USA",
            coordinate: GeoCoordinate(latitude: 40.7128, longitude: -74.0060), utcOffsetMinutes: -300
        ),
    ]

    public init() {}

    public func suggestions(for query: String, near bias: GeoCoordinate?, sessionToken: String) async throws -> [PlaceSuggestion] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return Self.cities
            .filter { $0.name.lowercased().contains(needle) || ($0.address ?? "").lowercased().contains(needle) }
            .map { PlaceSuggestion(placeID: $0.id, primaryText: $0.name, secondaryText: $0.address ?? "") }
    }

    public struct UnknownPlace: Error {}

    public func place(for placeID: String, sessionToken: String) async throws -> Place {
        guard let place = Self.cities.first(where: { $0.id == placeID }) else { throw UnknownPlace() }
        return place
    }
}

/// Ready-made requests for tests and previews.
public enum SampleTrips {
    public static func city(_ id: String) -> Place {
        FakeAutocompleteProvider.cities.first { $0.id == id }!
    }

    /// A fixed departure: Monday 2027-05-03 16:00 UTC, i.e. 08:00 at the sandbox's San Francisco offset (UTC-8).
    public static let departure = Date(timeIntervalSince1970: 1_809_360_000)

    public static func request(
        from origin: String = "sf",
        to destination: String = "nyc",
        goal: OptimizationGoal = .balanced,
        arriveBy: Date? = nil,
        mpg: Double = 30,
        policy: DrivingPolicy = .standard
    ) -> TripRequest {
        TripRequest(
            origin: city(origin),
            destination: city(destination),
            departure: departure,
            arriveBy: arriveBy,
            vehicle: Vehicle(milesPerGallon: mpg),
            policy: policy,
            goal: goal
        )
    }

    /// A full offline planning service.
    public static func planningService(
        places: FakePlaceSearchProvider = FakePlaceSearchProvider(),
        routing: FakeRoutingProvider = FakeRoutingProvider()
    ) -> TripPlanningService {
        TripPlanningService(
            routing: routing,
            places: places,
            lodging: FakeLodgingRateProvider(),
            fuelPrices: FakeRegionalFuelPriceProvider()
        )
    }
}
