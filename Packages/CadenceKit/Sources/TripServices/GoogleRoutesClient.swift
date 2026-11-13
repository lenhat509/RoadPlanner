import Foundation
import TripModels
import TripPlanner

/// Google Maps Platform **Routes API** (`directions/v2:computeRoutes`) adapter.
///
/// Docs: https://developers.google.com/maps/documentation/routes/compute_route_directions
public struct GoogleRoutesClient: RoutingProvider {
    public static let endpoint = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!

    /// Only the fields the app uses (keeps responses small and billing at the right SKU).
    public static let fieldMask = [
        "routes.description",
        "routes.distanceMeters",
        "routes.duration",
        "routes.polyline.encodedPolyline",
        "routes.travelAdvisory.tollInfo",
        "routes.legs.distanceMeters",
        "routes.legs.duration",
        "routes.legs.polyline.encodedPolyline",
        "routes.legs.travelAdvisory.tollInfo",
        "routes.legs.steps.distanceMeters",
        "routes.legs.steps.staticDuration",
        "routes.legs.steps.polyline.encodedPolyline",
        "routes.legs.steps.navigationInstruction",
    ].joined(separator: ",")

    private let configuration: GoogleMapsConfiguration
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        configuration: GoogleMapsConfiguration,
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.transport = transport
        self.now = now
    }

    public func computeRoutes(_ query: RouteQuery) async throws -> [ComputedRoute] {
        guard !configuration.apiKey.isEmpty else { throw ServiceError.missingAPIKey }
        let response = try await transport.send(try makeRequest(for: query)).validated()
        let decoded = try JSON.decode(ComputeRoutesResponse.self, from: response.body)
        return (decoded.routes ?? []).map(Self.convert)
    }

    func makeRequest(for query: RouteQuery) throws -> HTTPRequest {
        let body = ComputeRoutesRequest(
            origin: .init(query.origin),
            destination: .init(query.destination),
            intermediates: query.intermediates.isEmpty ? nil : query.intermediates.map(Waypoint.init),
            travelMode: "DRIVE",
            routingPreference: "TRAFFIC_AWARE",
            // The API rejects departure times in the past; omit them and get "now".
            departureTime: query.departure.flatMap { $0 > now().addingTimeInterval(60) ? Self.timestamp($0) : nil },
            // Alternatives are not supported together with intermediate waypoints.
            computeAlternativeRoutes: query.computeAlternatives && query.intermediates.isEmpty,
            routeModifiers: query.avoidTolls ? .init(avoidTolls: true) : nil,
            extraComputations: ["TOLLS"],
            polylineQuality: "HIGH_QUALITY",
            languageCode: configuration.languageCode,
            units: "IMPERIAL"
        )
        return HTTPRequest(
            method: .post,
            url: Self.endpoint,
            headers: configuration.headers(fieldMask: Self.fieldMask),
            body: try JSON.encoder.encode(body)
        )
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func convert(_ route: ComputeRoutesResponse.Route) -> ComputedRoute {
        let legs = (route.legs ?? []).map { leg in
            RouteLeg(
                distanceMeters: Double(leg.distanceMeters ?? 0),
                duration: GoogleDuration.seconds(leg.duration) ?? 0,
                encodedPolyline: leg.polyline?.encodedPolyline ?? "",
                steps: (leg.steps ?? []).map { step in
                    NavigationStep(
                        instruction: step.navigationInstruction?.instructions ?? "Continue",
                        maneuver: Maneuver(googleValue: step.navigationInstruction?.maneuver),
                        distanceMeters: Double(step.distanceMeters ?? 0),
                        duration: GoogleDuration.seconds(step.staticDuration) ?? 0,
                        encodedPolyline: step.polyline?.encodedPolyline ?? ""
                    )
                },
                tollCostUSD: tolls(leg.travelAdvisory)
            )
        }
        return ComputedRoute(
            summary: route.description ?? "",
            distanceMeters: Double(route.distanceMeters ?? 0),
            duration: GoogleDuration.seconds(route.duration) ?? 0,
            encodedPolyline: route.polyline?.encodedPolyline ?? "",
            legs: legs,
            tollCostUSD: tolls(route.travelAdvisory)
        )
    }

    /// Sums USD toll estimates; `nil` when the API reported no toll info.
    static func tolls(_ advisory: ComputeRoutesResponse.TravelAdvisory?) -> Double? {
        guard let prices = advisory?.tollInfo?.estimatedPrice else { return nil }
        let usd = prices.filter { ($0.currencyCode ?? "USD") == "USD" }
        return usd.isEmpty ? nil : usd.reduce(0) { $0 + $1.amount }
    }
}

// MARK: - Wire format

struct ComputeRoutesRequest: Encodable {
    var origin: Waypoint
    var destination: Waypoint
    var intermediates: [Waypoint]?
    var travelMode: String
    var routingPreference: String
    var departureTime: String?
    var computeAlternativeRoutes: Bool
    var routeModifiers: RouteModifiers?
    var extraComputations: [String]
    var polylineQuality: String
    var languageCode: String
    var units: String

    struct RouteModifiers: Encodable {
        var avoidTolls: Bool
    }
}

struct Waypoint: Encodable {
    struct Location: Encodable { var latLng: GoogleLatLng }
    var location: Location

    init(_ coordinate: GeoCoordinate) {
        location = Location(latLng: GoogleLatLng(coordinate))
    }
}

struct ComputeRoutesResponse: Decodable {
    struct Polyline: Decodable { var encodedPolyline: String? }
    struct TollInfo: Decodable { var estimatedPrice: [GoogleMoney]? }
    struct TravelAdvisory: Decodable { var tollInfo: TollInfo? }
    struct NavigationInstruction: Decodable {
        var maneuver: String?
        var instructions: String?
    }

    struct Step: Decodable {
        var distanceMeters: Int?
        var staticDuration: String?
        var polyline: Polyline?
        var navigationInstruction: NavigationInstruction?
    }

    struct Leg: Decodable {
        var distanceMeters: Int?
        var duration: String?
        var polyline: Polyline?
        var travelAdvisory: TravelAdvisory?
        var steps: [Step]?
    }

    struct Route: Decodable {
        var description: String?
        var distanceMeters: Int?
        var duration: String?
        var polyline: Polyline?
        var travelAdvisory: TravelAdvisory?
        var legs: [Leg]?
    }

    var routes: [Route]?
}
