import Foundation
import TripModels
import TripPlanner

/// Google Maps Platform **Places API (New)** adapter: search along route (with live fuel
/// prices and detour summaries), autocomplete and place details.
///
/// Docs: https://developers.google.com/maps/documentation/places/web-service/op-overview
public struct GooglePlacesClient: PlaceSearchProvider, PlaceAutocompleteProvider {
    public static let baseURL = URL(string: "https://places.googleapis.com/v1/")!

    public static let searchFieldMask = [
        "places.id",
        "places.displayName",
        "places.formattedAddress",
        "places.location",
        "places.types",
        "places.priceLevel",
        "places.rating",
        "places.utcOffsetMinutes",
        "places.businessStatus",
        "places.fuelOptions",
        "routingSummaries",
    ].joined(separator: ",")

    public static let detailsFieldMask = "id,displayName,formattedAddress,location,utcOffsetMinutes"

    private let configuration: GoogleMapsConfiguration
    private let transport: any HTTPTransport

    public init(configuration: GoogleMapsConfiguration, transport: any HTTPTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    // MARK: Search along route

    public func searchAlongRoute(_ search: AlongRouteSearch) async throws -> [FoundPlace] {
        guard !configuration.apiKey.isEmpty else { throw ServiceError.missingAPIKey }
        let response = try await transport.send(try makeSearchRequest(search)).validated()
        let decoded = try JSON.decode(SearchTextResponse.self, from: response.body)
        let sectionLength = (try? PolylineCodec.decode(search.encodedPolyline)).map(GeoMath.length(of:)) ?? 0
        let places = decoded.places ?? []
        let summaries = decoded.routingSummaries ?? []
        return places.enumerated().compactMap { index, place in
            Self.convert(
                place,
                summary: summaries.indices.contains(index) ? summaries[index] : nil,
                category: search.category,
                sectionDuration: search.sectionDuration,
                sectionLength: sectionLength
            )
        }
    }

    func makeSearchRequest(_ search: AlongRouteSearch) throws -> HTTPRequest {
        let (query, type): (String, String?) = switch search.category {
        case .fuel: ("gas station", "gas_station")
        case .rest: ("rest area", nil)
        case .lodging: ("hotel", "lodging")
        }
        let body = SearchTextRequest(
            textQuery: query,
            includedType: type,
            pageSize: 20,
            languageCode: configuration.languageCode,
            regionCode: configuration.regionCode,
            searchAlongRouteParameters: .init(polyline: .init(encodedPolyline: search.encodedPolyline)),
            routingParameters: .init(origin: GoogleLatLng(search.origin), travelMode: "DRIVE")
        )
        return HTTPRequest(
            method: .post,
            url: Self.baseURL.appendingPathComponent("places:searchText"),
            headers: configuration.headers(fieldMask: Self.searchFieldMask),
            body: try JSON.encoder.encode(body)
        )
    }

    static func convert(
        _ place: PlaceResource,
        summary: RoutingSummary?,
        category: PlaceCategory,
        sectionDuration: TimeInterval,
        sectionLength: Double
    ) -> FoundPlace? {
        guard let id = place.id, let location = place.location else { return nil }
        if let status = place.businessStatus, status != "OPERATIONAL" { return nil }

        var categories: Set<PlaceCategory> = [category]
        let types = Set(place.types ?? [])
        if types.contains("gas_station") { categories.insert(.fuel) }
        if types.contains("rest_stop") { categories.insert(.rest) }
        if !types.isDisjoint(with: ["lodging", "hotel", "motel"]) { categories.insert(.lodging) }

        var fuelPrices: [FuelType: Double] = [:]
        var otherDiesel: Double?
        for price in place.fuelOptions?.fuelPrices ?? [] {
            guard let money = price.price, (money.currencyCode ?? "USD") == "USD", money.amount > 0 else { continue }
            if let fuelType = fuelType(for: price.type) {
                fuelPrices[fuelType] = money.amount
            } else if ["DIESEL_PLUS", "TRUCK_DIESEL"].contains(price.type) {
                otherDiesel = min(otherDiesel ?? .infinity, money.amount)
            }
        }
        // Premium or truck-lane diesel still fuels a diesel car when plain diesel isn't listed.
        if fuelPrices[.diesel] == nil, let otherDiesel { fuelPrices[.diesel] = otherDiesel }

        var detourDuration: TimeInterval?
        var detourDistance: Double?
        if let legs = summary?.legs, legs.count == 2 {
            let durations = legs.compactMap { GoogleDuration.seconds($0.duration) }
            if durations.count == 2 { detourDuration = max(60, durations[0] + durations[1] - sectionDuration) }
            let distances = legs.compactMap(\.distanceMeters)
            if distances.count == 2 { detourDistance = max(0, Double(distances[0] + distances[1]) - sectionLength) }
        }

        return FoundPlace(
            place: Place(
                id: id,
                name: place.displayName?.text ?? "Unnamed place",
                address: place.formattedAddress,
                coordinate: location.coordinate,
                utcOffsetMinutes: place.utcOffsetMinutes
            ),
            categories: categories,
            fuelPrices: fuelPrices,
            priceLevel: priceLevel(place.priceLevel),
            rating: place.rating,
            detourDuration: detourDuration,
            detourDistance: detourDistance
        )
    }

    static func fuelType(for googleType: String?) -> FuelType? {
        switch googleType {
        case "REGULAR_UNLEADED": .regular
        case "MIDGRADE": .midgrade
        case "PREMIUM": .premium
        case "DIESEL": .diesel
        case "E85": .e85
        default: nil
        }
    }

    static func priceLevel(_ value: String?) -> PriceLevel? {
        switch value {
        case "PRICE_LEVEL_FREE": .free
        case "PRICE_LEVEL_INEXPENSIVE": .inexpensive
        case "PRICE_LEVEL_MODERATE": .moderate
        case "PRICE_LEVEL_EXPENSIVE": .expensive
        case "PRICE_LEVEL_VERY_EXPENSIVE": .veryExpensive
        default: nil
        }
    }

    // MARK: Autocomplete & details

    public func suggestions(for query: String, near bias: GeoCoordinate?, sessionToken: String) async throws -> [PlaceSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        guard !configuration.apiKey.isEmpty else { throw ServiceError.missingAPIKey }
        let body = AutocompleteRequest(
            input: trimmed,
            sessionToken: sessionToken,
            languageCode: configuration.languageCode,
            regionCode: configuration.regionCode,
            locationBias: bias.map { .init(circle: .init(center: GoogleLatLng($0), radius: 50_000)) }
        )
        let request = HTTPRequest(
            method: .post,
            url: Self.baseURL.appendingPathComponent("places:autocomplete"),
            headers: configuration.headers(fieldMask: nil),
            body: try JSON.encoder.encode(body)
        )
        let response = try await transport.send(request).validated()
        let decoded = try JSON.decode(AutocompleteResponse.self, from: response.body)
        return (decoded.suggestions ?? []).compactMap { suggestion in
            guard let prediction = suggestion.placePrediction, let placeID = prediction.placeId else { return nil }
            return PlaceSuggestion(
                placeID: placeID,
                primaryText: prediction.structuredFormat?.mainText?.text ?? prediction.text?.text ?? "",
                secondaryText: prediction.structuredFormat?.secondaryText?.text ?? ""
            )
        }
    }

    public func place(for placeID: String, sessionToken: String) async throws -> Place {
        guard !configuration.apiKey.isEmpty else { throw ServiceError.missingAPIKey }
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("places/\(placeID)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "sessionToken", value: sessionToken),
            URLQueryItem(name: "languageCode", value: configuration.languageCode),
        ]
        var headers = configuration.headers(fieldMask: Self.detailsFieldMask)
        headers.removeValue(forKey: "Content-Type")
        let response = try await transport.send(HTTPRequest(method: .get, url: components.url!, headers: headers)).validated()
        let resource = try JSON.decode(PlaceResource.self, from: response.body)
        guard let id = resource.id, let location = resource.location else {
            throw ServiceError.decoding("Place details missing id or location")
        }
        return Place(
            id: id,
            name: resource.displayName?.text ?? resource.formattedAddress ?? "Selected place",
            address: resource.formattedAddress,
            coordinate: location.coordinate,
            utcOffsetMinutes: resource.utcOffsetMinutes
        )
    }
}

// MARK: - Wire format

struct SearchTextRequest: Encodable {
    struct EncodedPolyline: Encodable { var encodedPolyline: String }
    struct AlongRoute: Encodable { var polyline: EncodedPolyline }
    struct Routing: Encodable {
        var origin: GoogleLatLng
        var travelMode: String
    }

    var textQuery: String
    var includedType: String?
    var pageSize: Int
    var languageCode: String
    var regionCode: String
    var searchAlongRouteParameters: AlongRoute
    var routingParameters: Routing
}

struct PlaceResource: Decodable {
    struct FuelPrice: Decodable {
        var type: String?
        var price: GoogleMoney?
    }

    struct FuelOptions: Decodable { var fuelPrices: [FuelPrice]? }

    var id: String?
    var displayName: GoogleLocalizedText?
    var formattedAddress: String?
    var location: GoogleLatLng?
    var types: [String]?
    var priceLevel: String?
    var rating: Double?
    var utcOffsetMinutes: Int?
    var businessStatus: String?
    var fuelOptions: FuelOptions?
}

struct RoutingSummary: Decodable {
    struct Leg: Decodable {
        var duration: String?
        var distanceMeters: Int?
    }

    var legs: [Leg]?
}

struct SearchTextResponse: Decodable {
    var places: [PlaceResource]?
    var routingSummaries: [RoutingSummary]?
}

struct AutocompleteRequest: Encodable {
    struct Circle: Encodable {
        var center: GoogleLatLng
        var radius: Double
    }

    struct LocationBias: Encodable { var circle: Circle }

    var input: String
    var sessionToken: String
    var languageCode: String
    var regionCode: String
    var locationBias: LocationBias?
}

struct AutocompleteResponse: Decodable {
    struct StructuredFormat: Decodable {
        var mainText: GoogleLocalizedText?
        var secondaryText: GoogleLocalizedText?
    }

    struct PlacePrediction: Decodable {
        var placeId: String?
        var text: GoogleLocalizedText?
        var structuredFormat: StructuredFormat?
    }

    struct Suggestion: Decodable { var placePrediction: PlacePrediction? }

    var suggestions: [Suggestion]?
}
