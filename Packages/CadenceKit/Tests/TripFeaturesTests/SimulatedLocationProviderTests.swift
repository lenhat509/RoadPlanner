import Foundation
import Testing
import TripModels
import TripNavigation
import TripSandbox

@MainActor
@Suite("Simulated location provider")
struct SimulatedLocationProviderTests {
    /// About 111 km due north.
    private let leg = [GeoCoordinate(latitude: 34.0, longitude: -118.0), GeoCoordinate(latitude: 35.0, longitude: -118.0)]

    /// Follows the leg until the car is within a metre of `target` (or 10 s pass), then lets it
    /// tick a little longer to show whether it stays there.
    private func drive(_ provider: SimulatedLocationProvider, until target: GeoCoordinate) async -> GeoCoordinate? {
        _ = provider.startUpdates()
        provider.follow(leg)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, provider.lastKnownLocation.map({ GeoMath.distance($0, target) > 1 }) ?? true {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        provider.stopUpdates()
        return provider.lastKnownLocation
    }

    @Test("Drives the whole leg by default")
    func drivesWholeLeg() async throws {
        let provider = SimulatedLocationProvider(autoDrive: true, metersPerTick: 20_000, tickInterval: 0.001)
        let last = try #require(await drive(provider, until: leg[1]))
        #expect(GeoMath.distance(last, leg[1]) < 1)
    }

    @Test("Picks up from its position on the leg instead of jumping back to the start")
    func resumesMidLeg() async throws {
        let midway = PolylineGeometry(coordinates: leg).coordinate(atDistance: 60_000)
        let provider = SimulatedLocationProvider(start: midway, autoDrive: true, metersPerTick: 20_000, tickInterval: 0.001)
        provider.parksAfterMeters = 20_000
        let parkingSpot = PolylineGeometry(coordinates: leg).coordinate(atDistance: 80_000)
        let last = try #require(await drive(provider, until: parkingSpot))
        #expect(GeoMath.distance(last, parkingSpot) < 1)
    }

    @Test("Waits before driving off when a departure delay is set")
    func departureDelay() async throws {
        let provider = SimulatedLocationProvider(start: leg[0], autoDrive: true, metersPerTick: 20_000, tickInterval: 0.001)
        provider.departureDelay = 0.3
        _ = provider.startUpdates()
        provider.follow(leg)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(GeoMath.distance(try #require(provider.lastKnownLocation), leg[0]) < 1, "still waiting")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, GeoMath.distance(provider.lastKnownLocation ?? leg[0], leg[1]) > 1 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        provider.stopUpdates()
        #expect(GeoMath.distance(try #require(provider.lastKnownLocation), leg[1]) < 1, "then drives the leg")
    }

    @Test("Parks after the configured distance")
    func parks() async throws {
        let provider = SimulatedLocationProvider(autoDrive: true, metersPerTick: 20_000, tickInterval: 0.001)
        provider.parksAfterMeters = 40_000
        let parkingSpot = PolylineGeometry(coordinates: leg).coordinate(atDistance: 40_000)
        let last = try #require(await drive(provider, until: parkingSpot))
        #expect(GeoMath.distance(last, parkingSpot) < 1, "the car should stay parked")
    }
}
