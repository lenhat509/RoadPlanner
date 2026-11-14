import Foundation
import TripModels
import TripPlanner
import TripServices

/// An in-process HTTP backend that speaks the Google Routes API, Places API (New) and the
/// Waystage gateway wire formats, backed by the synthetic fakes. It lets integration tests and
/// UI-test sandbox mode exercise the *real* production adapters (request encoding, response
/// decoding, error handling) fully offline and deterministically.
public struct SimulatedGoogleBackend: HTTPTransport {
    public static let gatewayURL = URL(string: "https://gateway.sandbox.waystage.invalid")!

    public var routing: FakeRoutingProvider
    public var places: FakePlaceSearchProvider
    public var lodging: FakeLodgingRateProvider
    public var fuel: FakeRegionalFuelPriceProvider
    public var autocomplete: FakeAutocompleteProvider
    /// Artificial latency per request (seconds), useful for UI demos.
    public var latency: TimeInterval

    public init(
        routing: FakeRoutingProvider = FakeRoutingProvider(),
        places: FakePlaceSearchProvider = FakePlaceSearchProvider(),
        lodging: FakeLodgingRateProvider = FakeLodgingRateProvider(),
        fuel: FakeRegionalFuelPriceProvider = FakeRegionalFuelPriceProvider(),
        autocomplete: FakeAutocompleteProvider = FakeAutocompleteProvider(),
        latency: TimeInterval = 0
    ) {
        self.routing = routing
        self.places = places
        self.lodging = lodging
        self.fuel = fuel
        self.autocomplete = autocomplete
        self.latency = latency
    }

    /// Production services wired to this simulated backend.
    public static func services(backend: SimulatedGoogleBackend = SimulatedGoogleBackend()) -> ServiceFactory.Services {
        ServiceFactory.make(
            settings: ServiceFactory.Settings(
                google: GoogleMapsConfiguration(apiKey: "sandbox-key", iosBundleIdentifier: "com.waystage.sandbox"),
                gateway: WaystageGatewayClient.Configuration(baseURL: gatewayURL, appToken: "sandbox-token")
            ),
            transport: backend
        )
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if latency > 0 { try await Task.sleep(nanoseconds: UInt64(latency * 1e9)) }
        let path = request.url.path
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        do {
            switch (request.url.host ?? "", path) {
            case ("routes.googleapis.com", "/directions/v2:computeRoutes"):
                return try await computeRoutes(body)
            case ("places.googleapis.com", "/v1/places:searchText"):
                return try await searchText(body)
            case ("places.googleapis.com", "/v1/places:autocomplete"):
                return try await autocompleteResponse(body)
            case let ("places.googleapis.com", detailsPath) where detailsPath.hasPrefix("/v1/places/"):
                return try await details(placeID: String(detailsPath.dropFirst("/v1/places/".count)))
            case (Self.gatewayURL.host ?? "", "/v1/lodging/rates"):
                return try await lodgingRates(request.url)
            case (Self.gatewayURL.host ?? "", "/v1/fuel/average"):
                return try await fuelAverage(request.url)
            default:
                return Self.json(["error": ["code": 404, "message": "Unknown endpoint \(path)", "status": "NOT_FOUND"]], status: 404)
            }
        } catch {
            return Self.json(["error": ["code": 500, "message": "\(error)", "status": "INTERNAL"]], status: 500)
        }
    }

    // MARK: Routes API

    private func computeRoutes(_ body: [String: Any]) async throws -> HTTPResponse {
        func coordinate(_ waypoint: Any?) -> GeoCoordinate? {
            guard let waypoint = waypoint as? [String: Any],
                  let location = waypoint["location"] as? [String: Any],
                  let latLng = location["latLng"] as? [String: Any],
                  let latitude = latLng["latitude"] as? Double,
                  let longitude = latLng["longitude"] as? Double else { return nil }
            return GeoCoordinate(latitude: latitude, longitude: longitude)
        }
        guard let origin = coordinate(body["origin"]), let destination = coordinate(body["destination"]) else {
            return Self.json(["error": ["code": 400, "message": "origin and destination are required", "status": "INVALID_ARGUMENT"]], status: 400)
        }
        let waypoints = body["intermediates"] as? [[String: Any]] ?? []
        let intermediates = waypoints.filter { ($0["via"] as? Bool) != true }.compactMap(coordinate)
        let vias = waypoints.filter { ($0["via"] as? Bool) == true }.compactMap(coordinate)
        let avoidTolls = ((body["routeModifiers"] as? [String: Any])?["avoidTolls"] as? Bool) ?? false
        let alternatives = (body["computeAlternativeRoutes"] as? Bool) ?? false
        let routes = try await routing.computeRoutes(RouteQuery(
            origin: origin, destination: destination, intermediates: intermediates, vias: vias,
            avoidTolls: avoidTolls, computeAlternatives: alternatives
        ))
        return Self.json(["routes": routes.map(Self.encode)])
    }

    static func encode(_ route: ComputedRoute) -> [String: Any] {
        var json: [String: Any] = [
            "description": route.summary,
            "distanceMeters": Int(route.distanceMeters),
            "duration": "\(Int(route.duration))s",
            "polyline": ["encodedPolyline": route.encodedPolyline],
            "legs": route.legs.map { leg -> [String: Any] in
                var legJSON: [String: Any] = [
                    "distanceMeters": Int(leg.distanceMeters),
                    "duration": "\(Int(leg.duration))s",
                    "polyline": ["encodedPolyline": leg.encodedPolyline],
                    "steps": leg.steps.map { step -> [String: Any] in
                        [
                            "distanceMeters": Int(step.distanceMeters),
                            "staticDuration": "\(Int(step.duration))s",
                            "polyline": ["encodedPolyline": step.encodedPolyline],
                            "navigationInstruction": ["maneuver": step.maneuver.googleValue, "instructions": step.instruction],
                        ]
                    },
                ]
                if let tolls = leg.tollCostUSD { legJSON["travelAdvisory"] = tollInfo(tolls) }
                return legJSON
            },
        ]
        if let tolls = route.tollCostUSD { json["travelAdvisory"] = tollInfo(tolls) }
        return json
    }

    static func tollInfo(_ amount: Double) -> [String: Any] {
        ["tollInfo": ["estimatedPrice": [money(amount)]]]
    }

    static func money(_ amount: Double) -> [String: Any] {
        let units = floor(amount)
        return ["currencyCode": "USD", "units": String(Int(units)), "nanos": Int(((amount - units) * 1e9).rounded())]
    }

    // MARK: Places API (New)

    private func searchText(_ body: [String: Any]) async throws -> HTTPResponse {
        let includedType = body["includedType"] as? String
        let category: PlaceCategory = switch includedType {
        case "gas_station": .fuel
        case "lodging": .lodging
        default: .rest
        }
        let polyline = ((body["searchAlongRouteParameters"] as? [String: Any])?["polyline"] as? [String: Any])?["encodedPolyline"] as? String ?? ""
        let coordinates = try PolylineCodec.decode(polyline)
        let speed = routing.speedMPH * Units.metersPerMile / 3_600
        let sectionLength = GeoMath.length(of: coordinates)
        let sectionDuration = sectionLength / speed
        let found = try await places.searchAlongRoute(AlongRouteSearch(
            category: category, encodedPolyline: polyline,
            origin: coordinates.first ?? GeoCoordinate(latitude: 0, longitude: 0), sectionDuration: sectionDuration
        ))
        let profile = RouteProfile(coordinates: coordinates, totalDuration: sectionDuration)
        var placesJSON: [[String: Any]] = []
        var summaries: [[String: Any]] = []
        for item in found {
            var place: [String: Any] = [
                "id": item.place.id,
                "displayName": ["text": item.place.name, "languageCode": "en"],
                "formattedAddress": item.place.address ?? "",
                "location": ["latitude": item.place.coordinate.latitude, "longitude": item.place.coordinate.longitude],
                "types": category == .fuel ? ["gas_station"] : category == .lodging ? ["lodging", "hotel"] : ["rest_stop"],
                "businessStatus": "OPERATIONAL",
            ]
            if let offset = item.place.utcOffsetMinutes { place["utcOffsetMinutes"] = offset }
            if let rating = item.rating { place["rating"] = rating }
            if let level = item.priceLevel { place["priceLevel"] = level.googleValue }
            if !item.fuelPrices.isEmpty {
                place["fuelOptions"] = ["fuelPrices": item.fuelPrices.map { type, price in
                    ["type": type.googleValue, "price": Self.money(price), "updateTime": "2026-11-12T12:00:00Z"]
                }]
            }
            placesJSON.append(place)
            let along = profile.geometry.project(item.place.coordinate)?.distanceAlong ?? 0
            let detour = item.detourDuration ?? 300
            let toPlace = along / speed + detour / 2
            let fromPlace = (sectionLength - along) / speed + detour / 2
            let detourDistance = item.detourDistance ?? 2_000
            summaries.append(["legs": [
                ["duration": "\(Int(toPlace.rounded()))s", "distanceMeters": Int(along + detourDistance / 2)],
                ["duration": "\(Int(fromPlace.rounded()))s", "distanceMeters": Int(sectionLength - along + detourDistance / 2)],
            ]])
        }
        return Self.json(["places": placesJSON, "routingSummaries": summaries])
    }

    private func autocompleteResponse(_ body: [String: Any]) async throws -> HTTPResponse {
        let input = body["input"] as? String ?? ""
        let suggestions = try await autocomplete.suggestions(for: input, near: nil, sessionToken: "")
        return Self.json(["suggestions": suggestions.map { suggestion in
            ["placePrediction": [
                "placeId": suggestion.placeID,
                "text": ["text": "\(suggestion.primaryText), \(suggestion.secondaryText)"],
                "structuredFormat": ["mainText": ["text": suggestion.primaryText], "secondaryText": ["text": suggestion.secondaryText]],
            ]]
        }])
    }

    private func details(placeID: String) async throws -> HTTPResponse {
        guard let place = try? await autocomplete.place(for: placeID, sessionToken: "") else {
            return Self.json(["error": ["code": 404, "message": "Place not found", "status": "NOT_FOUND"]], status: 404)
        }
        var json: [String: Any] = [
            "id": place.id,
            "displayName": ["text": place.name],
            "formattedAddress": place.address ?? place.name,
            "location": ["latitude": place.coordinate.latitude, "longitude": place.coordinate.longitude],
        ]
        if let offset = place.utcOffsetMinutes { json["utcOffsetMinutes"] = offset }
        return Self.json(json)
    }

    // MARK: Gateway

    private func lodgingRates(_ url: URL) async throws -> HTTPResponse {
        let items = Self.query(url)
        let center = GeoCoordinate(latitude: Double(items["lat"] ?? "") ?? 0, longitude: Double(items["lng"] ?? "") ?? 0)
        let offers = try await lodging.offers(for: LodgingQuery(
            center: center, radiusMeters: (Double(items["radiusKm"] ?? "") ?? 25) * 1_000,
            checkIn: Date(), checkOut: Date(), adults: Int(items["adults"] ?? "") ?? 2
        ))
        return Self.json(["offers": offers.map { offer in
            [
                "propertyId": offer.propertyID, "name": offer.name,
                "latitude": offer.coordinate.latitude, "longitude": offer.coordinate.longitude,
                "nightlyRate": offer.nightlyRate, "currency": offer.currencyCode, "provider": offer.provider,
                "bookingUrl": offer.bookingURL?.absoluteString ?? "",
            ]
        }])
    }

    private func fuelAverage(_ url: URL) async throws -> HTTPResponse {
        let items = Self.query(url)
        let coordinate = GeoCoordinate(latitude: Double(items["lat"] ?? "") ?? 0, longitude: Double(items["lng"] ?? "") ?? 0)
        let price = try await fuel.averagePrice(near: coordinate, fuelType: FuelType(rawValue: items["fuelType"] ?? "") ?? .regular)
        return Self.json(["pricePerGallon": price as Any, "region": "Sandbox", "period": "2026-11-09", "source": "EIA"])
    }

    // MARK: Helpers

    static func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: data)
    }
}

extension Maneuver {
    /// The Google Routes API enum string for this maneuver.
    var googleValue: String {
        switch self {
        case .depart: "DEPART"
        case .straight: "STRAIGHT"
        case .turnLeft: "TURN_LEFT"
        case .turnRight: "TURN_RIGHT"
        case .turnSlightLeft: "TURN_SLIGHT_LEFT"
        case .turnSlightRight: "TURN_SLIGHT_RIGHT"
        case .turnSharpLeft: "TURN_SHARP_LEFT"
        case .turnSharpRight: "TURN_SHARP_RIGHT"
        case .uturnLeft: "UTURN_LEFT"
        case .uturnRight: "UTURN_RIGHT"
        case .rampLeft: "RAMP_LEFT"
        case .rampRight: "RAMP_RIGHT"
        case .merge: "MERGE"
        case .forkLeft: "FORK_LEFT"
        case .forkRight: "FORK_RIGHT"
        case .roundaboutLeft: "ROUNDABOUT_LEFT"
        case .roundaboutRight: "ROUNDABOUT_RIGHT"
        case .ferry: "FERRY"
        case .nameChange: "NAME_CHANGE"
        case .arrive, .unknown: "MANEUVER_UNSPECIFIED"
        }
    }
}

extension FuelType {
    var googleValue: String {
        switch self {
        case .regular: "REGULAR_UNLEADED"
        case .midgrade: "MIDGRADE"
        case .premium: "PREMIUM"
        case .diesel: "DIESEL"
        }
    }
}

extension PriceLevel {
    var googleValue: String {
        switch self {
        case .free: "PRICE_LEVEL_FREE"
        case .inexpensive: "PRICE_LEVEL_INEXPENSIVE"
        case .moderate: "PRICE_LEVEL_MODERATE"
        case .expensive: "PRICE_LEVEL_EXPENSIVE"
        case .veryExpensive: "PRICE_LEVEL_VERY_EXPENSIVE"
        }
    }
}
