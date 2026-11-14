import Foundation
import Testing
import TripModels
import TripPlanner
import TripSandbox
@testable import TripServices

@Suite("GooglePlacesClient")
struct GooglePlacesClientTests {
    private let configuration = GoogleMapsConfiguration(apiKey: "test-key", iosBundleIdentifier: "com.example.waystage")
    private let section = PolylineCodec.encode([
        GeoCoordinate(latitude: 38.0, longitude: -122.2),
        GeoCoordinate(latitude: 38.4, longitude: -121.9),
    ])

    private func search(_ category: PlaceCategory) -> AlongRouteSearch {
        AlongRouteSearch(category: category, encodedPolyline: section, origin: GeoCoordinate(latitude: 38, longitude: -122.2), sectionDuration: 2_700)
    }

    @Test("Builds a search-along-route request per category", arguments: [
        (PlaceCategory.fuel, "gas station", "gas_station"),
        (PlaceCategory.lodging, "hotel", "lodging"),
        (PlaceCategory.rest, "rest area", nil),
    ] as [(PlaceCategory, String, String?)])
    func searchRequest(category: PlaceCategory, query: String, type: String?) throws {
        let request = try GooglePlacesClient(configuration: configuration, transport: StubHTTPTransport()).makeSearchRequest(search(category))
        #expect(request.url.absoluteString == "https://places.googleapis.com/v1/places:searchText")
        #expect(request.headers["X-Goog-FieldMask"]?.contains("places.fuelOptions") == true)
        #expect(request.headers["X-Goog-FieldMask"]?.contains("routingSummaries") == true)
        let body = try #require(request.body).jsonObject()
        #expect(body["textQuery"] as? String == query)
        #expect(body["includedType"] as? String == type)
        #expect(body["pageSize"] as? Int == 20)
        let polyline = ((body["searchAlongRouteParameters"] as? [String: Any])?["polyline"] as? [String: Any])?["encodedPolyline"] as? String
        #expect(polyline == section)
        #expect(((body["routingParameters"] as? [String: Any])?["origin"] as? [String: Any])?["latitude"] as? Double == 38)
    }

    @Test("Decodes stations with live fuel prices and detours; drops closed businesses")
    func fuelSearch() async throws {
        let transport = StubHTTPTransport()
        transport.stub("places:searchText", body: try FixtureLoader.data("places_search_fuel_response"))
        let places = try await GooglePlacesClient(configuration: configuration, transport: transport).searchAlongRoute(search(.fuel))
        #expect(places.map(\.place.id) == ["ChIJshell", "ChIJarco"])
        let shell = places[0]
        #expect(shell.place.name == "Shell")
        #expect(shell.place.utcOffsetMinutes == -480)
        #expect(abs((shell.fuelPrices[.regular] ?? 0) - 4.599) < 1e-9)
        #expect(abs((shell.fuelPrices[.diesel] ?? 0) - 5.049) < 1e-9)
        #expect(shell.fuelPrices[.midgrade] == nil)
        #expect(shell.categories == [.fuel])
        // 1260 + 1800 − 2700 = 360 s detour.
        #expect(shell.detourDuration == 360)
        #expect(places[1].fuelPrices.isEmpty)
        // 900 + 2100 − 2700 = 300 s.
        #expect(places[1].detourDuration == 300)
    }

    @Test("Reads E85, and premium or truck-lane diesel when plain diesel isn't listed")
    func fuelGrades() async throws {
        func price(_ type: String, _ units: Int, _ nanos: Int) -> String {
            #"{"type": "\#(type)", "price": {"currencyCode": "USD", "units": "\#(units)", "nanos": \#(nanos)}}"#
        }
        func station(_ id: String, _ prices: [String]) -> String {
            #"{"id": "\#(id)", "displayName": {"text": "\#(id)"}, "location": {"latitude": 41.6, "longitude": -93.6}, "#
                + #""types": ["gas_station"], "fuelOptions": {"fuelPrices": [\#(prices.joined(separator: ","))]}}"#
        }
        let body = #"{"places": ["# + [
            station("flex", [price("REGULAR_UNLEADED", 3, 190_000_000), price("E85", 2, 590_000_000), price("TRUCK_DIESEL", 3, 890_000_000)]),
            station("both", [price("DIESEL", 3, 790_000_000), price("DIESEL_PLUS", 3, 990_000_000)]),
        ].joined(separator: ",") + "]}"
        let transport = StubHTTPTransport()
        transport.stub("places:searchText", body: Data(body.utf8))
        let places = try await GooglePlacesClient(configuration: configuration, transport: transport).searchAlongRoute(search(.fuel))
        let flex = try #require(places.first { $0.place.id == "flex" })
        #expect(abs((flex.fuelPrices[.e85] ?? 0) - 2.59) < 1e-9)
        #expect(abs((flex.fuelPrices[.diesel] ?? 0) - 3.89) < 1e-9, "truck-lane diesel when plain diesel isn't listed")
        let both = try #require(places.first { $0.place.id == "both" })
        #expect(abs((both.fuelPrices[.diesel] ?? 0) - 3.79) < 1e-9, "plain diesel wins")
    }

    @Test("Decodes lodging with its price level")
    func lodgingSearch() async throws {
        let transport = StubHTTPTransport()
        transport.stub("places:searchText", body: try FixtureLoader.data("places_search_lodging_response"))
        let places = try await GooglePlacesClient(configuration: configuration, transport: transport).searchAlongRoute(search(.lodging))
        let hotel = try #require(places.first)
        #expect(hotel.priceLevel == .moderate)
        #expect(hotel.categories.contains(.lodging))
        #expect(hotel.detourDuration == nil)
    }

    @Test("Autocomplete returns place predictions and skips query predictions")
    func autocomplete() async throws {
        let transport = StubHTTPTransport()
        transport.stub("places:autocomplete", body: try FixtureLoader.data("places_autocomplete_response"))
        let client = GooglePlacesClient(configuration: configuration, transport: transport)
        let suggestions = try await client.suggestions(for: "Denv", near: GeoCoordinate(latitude: 39, longitude: -105), sessionToken: "session-1")
        #expect(suggestions.map(\.placeID) == ["ChIJden", "ChIJdenint"])
        #expect(suggestions[0].primaryText == "Denver")
        #expect(suggestions[0].secondaryText == "CO, USA")
        #expect(suggestions[1].primaryText == "Denver International Airport")
        let body = try #require(transport.requests.first?.body).jsonObject()
        #expect(body["sessionToken"] as? String == "session-1")
        #expect(body["locationBias"] != nil)
    }

    @Test("Autocomplete skips the network for very short input")
    func autocompleteShortInput() async throws {
        let transport = StubHTTPTransport()
        let suggestions = try await GooglePlacesClient(configuration: configuration, transport: transport)
            .suggestions(for: " D ", near: nil, sessionToken: "s")
        #expect(suggestions.isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test("Place details resolve coordinates and UTC offset")
    func details() async throws {
        let transport = StubHTTPTransport()
        transport.stub("places/ChIJden", body: try FixtureLoader.data("place_details_response"))
        let place = try await GooglePlacesClient(configuration: configuration, transport: transport).place(for: "ChIJden", sessionToken: "s")
        #expect(place.name == "Denver")
        #expect(place.utcOffsetMinutes == -420)
        #expect(abs(place.coordinate.latitude - 39.7392358) < 1e-9)
        let request = try #require(transport.requests.first)
        #expect(request.method == .get)
        #expect(request.url.query?.contains("sessionToken=s") == true)
        #expect(request.headers["X-Goog-FieldMask"] == GooglePlacesClient.detailsFieldMask)
    }
}
