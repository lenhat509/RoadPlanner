import Foundation
import Testing
import TripModels
@testable import TripPlanner

@Suite("RouteProfile")
struct RouteProfileTests {
    private let path = (0...200).map { GeoCoordinate(latitude: 39, longitude: -100 + Double($0) * 0.01) }

    @Test("Constant-speed profile maps distance to time linearly")
    func uniformProfile() {
        let profile = RouteProfile(coordinates: path, totalDuration: 7_200)
        #expect(abs(profile.time(atDistance: profile.totalDistance / 2) - 3_600) < 1)
        #expect(profile.time(atDistance: -1) == 0)
        #expect(profile.time(atDistance: profile.totalDistance + 1) == 7_200)
    }

    @Test("Step timings give slow and fast sections different speeds")
    func stepTimings() {
        let first = Array(path[0...100]), second = Array(path[100...200])
        // First half takes 3× longer than the second half.
        let profile = RouteProfile(steps: [
            .init(coordinates: first, duration: 5_400),
            .init(coordinates: second, duration: 1_800),
        ])
        #expect(abs(profile.totalDuration - 7_200) < 1e-6)
        #expect(abs(profile.time(atDistance: profile.totalDistance / 2) - 5_400) < 5)
        #expect(profile.geometry.coordinates.count == 201) // shared vertex de-duplicated
    }

    @Test("distance(atTime:) inverts time(atDistance:)")
    func inverse() {
        let profile = RouteProfile(steps: [
            .init(coordinates: Array(path[0...50]), duration: 2_000),
            .init(coordinates: Array(path[50...200]), duration: 3_000),
        ])
        for fraction in stride(from: 0.0, through: 1.0, by: 0.1) {
            let distance = profile.totalDistance * fraction
            #expect(abs(profile.distance(atTime: profile.time(atDistance: distance)) - distance) < 1)
        }
    }

    @Test("Chunks cover the route without gaps and respect the max duration")
    func chunks() {
        let profile = RouteProfile(coordinates: path, totalDuration: 10 * 3_600)
        let chunks = profile.chunks(maxDuration: 3 * 3_600)
        #expect(chunks.count == 4)
        #expect(chunks.first?.startDistance == 0)
        #expect(abs((chunks.last?.endDistance ?? 0) - profile.totalDistance) < 1e-6)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(abs(previous.endDistance - next.startDistance) < 1e-6)
        }
        for chunk in chunks { #expect(chunk.endTime - chunk.startTime <= 3 * 3_600 + 1e-6) }
    }

    @Test("ComputedRoute builds a profile from its steps scaled to the route duration")
    func computedRouteProfile() {
        let step = NavigationStep(
            instruction: "Go", maneuver: .depart, distanceMeters: 0, duration: 1_000,
            encodedPolyline: PolylineCodec.encode(path)
        )
        let leg = RouteLeg(distanceMeters: 0, duration: 1_000, encodedPolyline: "", steps: [step])
        let route = ComputedRoute(summary: "I-70", distanceMeters: 0, duration: 1_500, encodedPolyline: "", legs: [leg])
        let profile = route.profile()
        #expect(abs(profile.totalDuration - 1_500) < 1e-6)
        #expect(profile.summary == "I-70")
    }
}
