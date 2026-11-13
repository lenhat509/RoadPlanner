import Foundation
import Testing
import TripModels
import TripPlanner
import TripSandbox
@testable import TripServices

@Suite("GoogleRoutesClient")
struct GoogleRoutesClientTests {
    private let configuration = GoogleMapsConfiguration(apiKey: "test-key", iosBundleIdentifier: "com.example.cadence")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let origin = GeoCoordinate(latitude: 37.7749, longitude: -122.4194)
    private let destination = GeoCoordinate(latitude: 38.0, longitude: -121.9)

    private func client(_ transport: StubHTTPTransport) -> GoogleRoutesClient {
        GoogleRoutesClient(configuration: configuration, transport: transport, now: { [now] in now })
    }

    @Test("Sends a POST with the API key, bundle ID and a field mask")
    func requestHeaders() async throws {
        let transport = StubHTTPTransport()
        transport.stub("computeRoutes", body: try FixtureLoader.data("routes_compute_response"))
        _ = try await client(transport).computeRoutes(RouteQuery(origin: origin, destination: destination))
        let request = try #require(transport.requests.first)
        #expect(request.method == .post)
        #expect(request.url == GoogleRoutesClient.endpoint)
        #expect(request.headers["X-Goog-Api-Key"] == "test-key")
        #expect(request.headers["X-Ios-Bundle-Identifier"] == "com.example.cadence")
        let mask = try #require(request.headers["X-Goog-FieldMask"])
        #expect(mask.contains("routes.legs.steps.navigationInstruction"))
        #expect(mask.contains("routes.travelAdvisory.tollInfo"))
    }

    @Test("Encodes waypoints, departure time, alternatives and toll avoidance")
    func requestBody() throws {
        let departure = now.addingTimeInterval(3_600)
        let request = try client(StubHTTPTransport()).makeRequest(for: RouteQuery(
            origin: origin, destination: destination, departure: departure, avoidTolls: true, computeAlternatives: true
        ))
        let body = try #require(request.body).jsonObject()
        #expect(body["travelMode"] as? String == "DRIVE")
        #expect(body["routingPreference"] as? String == "TRAFFIC_AWARE")
        #expect(body["computeAlternativeRoutes"] as? Bool == true)
        #expect((body["routeModifiers"] as? [String: Any])?["avoidTolls"] as? Bool == true)
        #expect(body["departureTime"] as? String == GoogleRoutesClient.timestamp(departure))
        #expect(body["polylineQuality"] as? String == "HIGH_QUALITY")
        let originLatLng = ((body["origin"] as? [String: Any])?["location"] as? [String: Any])?["latLng"] as? [String: Any]
        #expect(originLatLng?["latitude"] as? Double == origin.latitude)
    }

    @Test("Omits past departure times and disables alternatives with intermediates")
    func requestBodyConstraints() throws {
        let request = try client(StubHTTPTransport()).makeRequest(for: RouteQuery(
            origin: origin, destination: destination,
            intermediates: [GeoCoordinate(latitude: 37.9, longitude: -122.1)],
            departure: now.addingTimeInterval(-600),
            computeAlternatives: true
        ))
        let body = try #require(request.body).jsonObject()
        #expect(body["departureTime"] == nil)
        #expect(body["computeAlternativeRoutes"] as? Bool == false)
        #expect((body["intermediates"] as? [Any])?.count == 1)
    }

    @Test("Decodes routes, legs, steps, durations, maneuvers and tolls")
    func decoding() async throws {
        let transport = StubHTTPTransport()
        transport.stub("computeRoutes", body: try FixtureLoader.data("routes_compute_response"))
        let routes = try await client(transport).computeRoutes(RouteQuery(origin: origin, destination: destination))
        #expect(routes.count == 2)
        let route = try #require(routes.first)
        #expect(route.summary == "I-80 E")
        #expect(route.distanceMeters == 45_210)
        #expect(route.duration == 2_875)
        #expect(route.tollCostUSD == 7.5)
        let steps = try #require(route.legs.first?.steps)
        #expect(steps.map(\.maneuver) == [.depart, .rampRight])
        #expect(steps[1].instruction == "Take the ramp onto I-80 E toward Oakland")
        #expect(steps[1].duration == 2_400)
        #expect(routes[1].tollCostUSD == nil)
        // The step geometry builds a usable profile.
        let profile = route.profile()
        #expect(abs(profile.totalDuration - 2_875) < 1e-6)
        #expect(profile.totalDistance > 40_000)
    }

    @Test("Maps Google error envelopes to service errors", arguments: [
        (400, ServiceError.invalidRequest("INVALID_ARGUMENT: Invalid value at 'origin.location'")),
        (403, ServiceError.unauthorized("INVALID_ARGUMENT: Invalid value at 'origin.location'")),
        (429, ServiceError.rateLimited),
        (503, ServiceError.server(status: 503, message: "INVALID_ARGUMENT: Invalid value at 'origin.location'")),
    ])
    func errors(status: Int, expected: ServiceError) async throws {
        let transport = StubHTTPTransport()
        transport.stub("computeRoutes", status: status, body: try FixtureLoader.data("google_error_response"))
        await #expect(throws: expected) {
            _ = try await client(transport).computeRoutes(RouteQuery(origin: origin, destination: destination))
        }
    }

    @Test("Refuses to call the API without a key")
    func missingKey() async {
        let client = GoogleRoutesClient(configuration: GoogleMapsConfiguration(apiKey: ""), transport: StubHTTPTransport())
        await #expect(throws: ServiceError.missingAPIKey) {
            _ = try await client.computeRoutes(RouteQuery(origin: origin, destination: destination))
        }
    }

    @Test("Parses protobuf duration strings")
    func durations() {
        #expect(GoogleDuration.seconds("3600s") == 3_600)
        #expect(GoogleDuration.seconds("12.5s") == 12.5)
        #expect(GoogleDuration.seconds("0s") == 0)
        #expect(GoogleDuration.seconds("12") == nil)
        #expect(GoogleDuration.seconds(nil) == nil)
    }
}
