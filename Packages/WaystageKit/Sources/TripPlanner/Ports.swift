import Foundation
import TripModels

// Ports (hexagonal architecture): the planner depends on these protocols; `TripServices`
// provides Google Maps Platform / gateway adapters, `TripSandbox` provides offline fakes.

/// A request for driving directions.
public struct RouteQuery: Hashable, Sendable {
    public var origin: GeoCoordinate
    public var destination: GeoCoordinate
    /// Stop-over waypoints, in order. Each produces a separate leg.
    public var intermediates: [GeoCoordinate]
    /// Pass-through points, in order: the route goes through them without stopping (one leg).
    /// Used to ask for a route along a different corridor ("via Las Vegas").
    public var vias: [GeoCoordinate]
    /// Departure time used for traffic-aware estimates (`nil` = now).
    public var departure: Date?
    public var avoidTolls: Bool
    public var computeAlternatives: Bool

    public init(
        origin: GeoCoordinate,
        destination: GeoCoordinate,
        intermediates: [GeoCoordinate] = [],
        vias: [GeoCoordinate] = [],
        departure: Date? = nil,
        avoidTolls: Bool = false,
        computeAlternatives: Bool = false
    ) {
        self.origin = origin
        self.destination = destination
        self.intermediates = intermediates
        self.vias = vias
        self.departure = departure
        self.avoidTolls = avoidTolls
        self.computeAlternatives = computeAlternatives
    }
}

/// A route returned by a routing provider.
public struct ComputedRoute: Hashable, Sendable {
    public var summary: String
    public var distanceMeters: Double
    public var duration: TimeInterval
    public var encodedPolyline: String
    public var legs: [RouteLeg]
    public var tollCostUSD: Double?

    public init(
        summary: String,
        distanceMeters: Double,
        duration: TimeInterval,
        encodedPolyline: String,
        legs: [RouteLeg],
        tollCostUSD: Double? = nil
    ) {
        self.summary = summary
        self.distanceMeters = distanceMeters
        self.duration = duration
        self.encodedPolyline = encodedPolyline
        self.legs = legs
        self.tollCostUSD = tollCostUSD
    }

    /// Builds a time/distance profile from the step geometry (falls back to the overview polyline).
    public func profile() -> RouteProfile {
        let steps = legs.flatMap(\.steps).compactMap { step -> RouteProfile.StepTiming? in
            guard let coordinates = try? PolylineCodec.decode(step.encodedPolyline), !coordinates.isEmpty else {
                return nil
            }
            return RouteProfile.StepTiming(coordinates: coordinates, duration: step.duration)
        }
        if !steps.isEmpty {
            let stepDuration = steps.reduce(0) { $0 + $1.duration }
            // Step durations are traffic-unaware; scale them to the route's (traffic-aware) total.
            let scale = stepDuration > 0 && duration > 0 ? duration / stepDuration : 1
            let scaled = steps.map { RouteProfile.StepTiming(coordinates: $0.coordinates, duration: $0.duration * scale) }
            return RouteProfile(steps: scaled, tollCostUSD: tollCostUSD ?? 0, summary: summary)
        }
        let coordinates = (try? PolylineCodec.decode(encodedPolyline)) ?? []
        return RouteProfile(coordinates: coordinates, totalDuration: duration, tollCostUSD: tollCostUSD ?? 0, summary: summary)
    }
}

public protocol RoutingProvider: Sendable {
    /// Returns one or more routes (the first is the recommended one).
    func computeRoutes(_ query: RouteQuery) async throws -> [ComputedRoute]
}

/// Kinds of places the planner searches for.
public enum PlaceCategory: String, Codable, CaseIterable, Sendable {
    case fuel
    case rest
    case lodging
}

/// Google's coarse price level for a place.
public enum PriceLevel: Int, Codable, Sendable, Comparable {
    case free = 0, inexpensive, moderate, expensive, veryExpensive

    public static func < (lhs: PriceLevel, rhs: PriceLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A search for places along part of a route.
public struct AlongRouteSearch: Hashable, Sendable {
    public var category: PlaceCategory
    /// Encoded polyline of the route section to search.
    public var encodedPolyline: String
    /// Start of the section (used to compute detours).
    public var origin: GeoCoordinate
    /// Driving time of the section (used to compute detours).
    public var sectionDuration: TimeInterval

    public init(category: PlaceCategory, encodedPolyline: String, origin: GeoCoordinate, sectionDuration: TimeInterval) {
        self.category = category
        self.encodedPolyline = encodedPolyline
        self.origin = origin
        self.sectionDuration = sectionDuration
    }
}

/// A place found near the route.
public struct FoundPlace: Hashable, Sendable {
    public var place: Place
    public var categories: Set<PlaceCategory>
    /// Live fuel prices (USD per gallon) by grade.
    public var fuelPrices: [FuelType: Double]
    public var priceLevel: PriceLevel?
    /// Live nightly rate in USD (lodging only).
    public var nightlyRate: Double?
    /// Who supplied the nightly rate (e.g. "Expedia").
    public var rateProvider: String?
    public var bookingURL: URL?
    public var rating: Double?
    /// Extra driving time to visit the place and return to the route, if the provider computed it.
    public var detourDuration: TimeInterval?
    /// Extra driving distance to visit the place and return to the route, if computed.
    public var detourDistance: Double?
    /// Route distance range of the search section that found this place.
    public var searchRange: ClosedRange<Double>?

    public init(
        place: Place,
        categories: Set<PlaceCategory>,
        fuelPrices: [FuelType: Double] = [:],
        priceLevel: PriceLevel? = nil,
        nightlyRate: Double? = nil,
        rateProvider: String? = nil,
        bookingURL: URL? = nil,
        rating: Double? = nil,
        detourDuration: TimeInterval? = nil,
        detourDistance: Double? = nil,
        searchRange: ClosedRange<Double>? = nil
    ) {
        self.place = place
        self.categories = categories
        self.fuelPrices = fuelPrices
        self.priceLevel = priceLevel
        self.nightlyRate = nightlyRate
        self.rateProvider = rateProvider
        self.bookingURL = bookingURL
        self.rating = rating
        self.detourDuration = detourDuration
        self.detourDistance = detourDistance
        self.searchRange = searchRange
    }
}

public protocol PlaceSearchProvider: Sendable {
    func searchAlongRoute(_ search: AlongRouteSearch) async throws -> [FoundPlace]
}

/// A request for live lodging rates around a point.
public struct LodgingQuery: Hashable, Sendable {
    public var center: GeoCoordinate
    public var radiusMeters: Double
    public var checkIn: Date
    public var checkOut: Date
    public var adults: Int

    public init(center: GeoCoordinate, radiusMeters: Double, checkIn: Date, checkOut: Date, adults: Int) {
        self.center = center
        self.radiusMeters = radiusMeters
        self.checkIn = checkIn
        self.checkOut = checkOut
        self.adults = adults
    }
}

/// A bookable lodging rate.
public struct LodgingOffer: Hashable, Sendable {
    public var propertyID: String
    public var name: String
    public var coordinate: GeoCoordinate
    public var nightlyRate: Double
    public var currencyCode: String
    public var provider: String
    public var bookingURL: URL?

    public init(
        propertyID: String,
        name: String,
        coordinate: GeoCoordinate,
        nightlyRate: Double,
        currencyCode: String = "USD",
        provider: String,
        bookingURL: URL? = nil
    ) {
        self.propertyID = propertyID
        self.name = name
        self.coordinate = coordinate
        self.nightlyRate = nightlyRate
        self.currencyCode = currencyCode
        self.provider = provider
        self.bookingURL = bookingURL
    }
}

public protocol LodgingRateProvider: Sendable {
    func offers(for query: LodgingQuery) async throws -> [LodgingOffer]
}

public protocol RegionalFuelPriceProvider: Sendable {
    /// Average retail price (USD/gal) for the region around `coordinate`, if known.
    func averagePrice(near coordinate: GeoCoordinate, fuelType: FuelType) async throws -> Double?
}

/// An autocomplete suggestion for the origin/destination fields.
public struct PlaceSuggestion: Hashable, Sendable, Identifiable {
    public var placeID: String
    public var primaryText: String
    public var secondaryText: String
    public var id: String { placeID }

    public init(placeID: String, primaryText: String, secondaryText: String) {
        self.placeID = placeID
        self.primaryText = primaryText
        self.secondaryText = secondaryText
    }
}

public protocol PlaceAutocompleteProvider: Sendable {
    func suggestions(for query: String, near bias: GeoCoordinate?, sessionToken: String) async throws -> [PlaceSuggestion]
    func place(for placeID: String, sessionToken: String) async throws -> Place
}
