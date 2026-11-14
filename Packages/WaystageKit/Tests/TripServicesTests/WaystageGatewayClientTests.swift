import Foundation
import Testing
import TripModels
import TripPlanner
import TripSandbox
@testable import TripServices

@Suite("WaystageGatewayClient")
struct WaystageGatewayClientTests {
    private let configuration = WaystageGatewayClient.Configuration(
        baseURL: URL(string: "https://gateway.example.com")!, appToken: "app-token"
    )

    @Test("Requests lodging rates with the app token and query parameters")
    func lodgingRequest() async throws {
        let transport = StubHTTPTransport()
        transport.stub("/v1/lodging/rates", body: try FixtureLoader.data("gateway_lodging_response"))
        let checkIn = Date(timeIntervalSince1970: 1_809_396_000) // 2027-05-04 02:00Z
        _ = try await WaystageGatewayClient(configuration: configuration, transport: transport).offers(for: LodgingQuery(
            center: GeoCoordinate(latitude: 39.5296, longitude: -119.8138), radiusMeters: 25_000,
            checkIn: checkIn, checkOut: checkIn.addingTimeInterval(86_400), adults: 2
        ))
        let request = try #require(transport.requests.first)
        #expect(request.headers["X-Waystage-App-Token"] == "app-token")
        let query = try #require(request.url.query)
        #expect(query.contains("checkin=2027-05-04"))
        #expect(query.contains("checkout=2027-05-05"))
        #expect(query.contains("radiusKm=25.0"))
        #expect(query.contains("adults=2"))
    }

    @Test("Keeps only bookable USD offers")
    func lodgingDecoding() async throws {
        let transport = StubHTTPTransport()
        transport.stub("/v1/lodging/rates", body: try FixtureLoader.data("gateway_lodging_response"))
        let offers = try await WaystageGatewayClient(configuration: configuration, transport: transport).offers(for: LodgingQuery(
            center: GeoCoordinate(latitude: 39.5, longitude: -119.8), radiusMeters: 10_000,
            checkIn: Date(), checkOut: Date(), adults: 1
        ))
        #expect(offers.count == 1)
        #expect(offers.first?.nightlyRate == 129)
        #expect(offers.first?.provider == "Expedia")
        #expect(offers.first?.bookingURL?.host == "www.expedia.com")
    }

    @Test("Returns the regional average fuel price, or nil when unknown")
    func fuelAverage() async throws {
        let transport = StubHTTPTransport()
        transport.stub("/v1/fuel/average", body: try FixtureLoader.data("gateway_fuel_response"))
        let client = WaystageGatewayClient(configuration: configuration, transport: transport)
        #expect(try await client.averagePrice(near: GeoCoordinate(latitude: 37, longitude: -120), fuelType: .diesel) == 3.879)
        #expect(transport.requests.first?.url.query?.contains("fuelType=diesel") == true)

        let unknown = StubHTTPTransport()
        unknown.stub("/v1/fuel/average", body: try FixtureLoader.data("gateway_fuel_unknown_response"))
        #expect(try await WaystageGatewayClient(configuration: configuration, transport: unknown)
            .averagePrice(near: GeoCoordinate(latitude: 0, longitude: 0), fuelType: .regular) == nil)
    }

    @Test("Any grade uses regular's regional average; E85 has none, so nothing is requested")
    func fuelAverageGrades() async throws {
        let transport = StubHTTPTransport()
        transport.stub("/v1/fuel/average", body: try FixtureLoader.data("gateway_fuel_response"))
        let client = WaystageGatewayClient(configuration: configuration, transport: transport)
        _ = try await client.averagePrice(near: GeoCoordinate(latitude: 37, longitude: -120), fuelType: .any)
        #expect(transport.requests.last?.url.query?.contains("fuelType=regular") == true)
        let before = transport.requests.count
        #expect(try await client.averagePrice(near: GeoCoordinate(latitude: 37, longitude: -120), fuelType: .e85) == nil)
        #expect(transport.requests.count == before)
    }

    @Test("Surfaces authorization failures")
    func unauthorized() async {
        let transport = StubHTTPTransport()
        transport.stub("/v1/fuel/average", status: 401, body: Data("{\"error\":{\"message\":\"bad token\"}}".utf8))
        await #expect(throws: ServiceError.unauthorized("bad token")) {
            _ = try await WaystageGatewayClient(configuration: configuration, transport: transport)
                .averagePrice(near: GeoCoordinate(latitude: 0, longitude: 0), fuelType: .regular)
        }
    }
}
