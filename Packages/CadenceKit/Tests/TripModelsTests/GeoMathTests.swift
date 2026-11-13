import Foundation
import Testing
@testable import TripModels

@Suite("GeoMath")
struct GeoMathTests {
    private let sanFrancisco = GeoCoordinate(latitude: 37.7749, longitude: -122.4194)
    private let losAngeles = GeoCoordinate(latitude: 34.0522, longitude: -118.2437)

    @Test("Haversine distance matches the known SF→LA great-circle distance")
    func haversineDistance() {
        let meters = GeoMath.distance(sanFrancisco, losAngeles)
        // Published great-circle distance is ≈ 559 km.
        #expect(abs(meters - 559_000) < 2_000)
    }

    @Test("Distance from a point to itself is zero")
    func zeroDistance() {
        #expect(GeoMath.distance(sanFrancisco, sanFrancisco) == 0)
    }

    @Test("Bearing due north and due east")
    func bearing() {
        let origin = GeoCoordinate(latitude: 0, longitude: 0)
        let north = GeoCoordinate(latitude: 1, longitude: 0)
        let east = GeoCoordinate(latitude: 0, longitude: 1)
        #expect(abs(GeoMath.bearing(from: origin, to: north) - 0) < 0.01)
        #expect(abs(GeoMath.bearing(from: origin, to: east) - 90) < 0.01)
    }

    @Test("Interpolation returns endpoints and midpoint")
    func interpolation() {
        let start = GeoCoordinate(latitude: 10, longitude: 20)
        let end = GeoCoordinate(latitude: 12, longitude: 24)
        #expect(GeoMath.interpolate(start, end, fraction: 0) == start)
        #expect(GeoMath.interpolate(start, end, fraction: 1) == end)
        let mid = GeoMath.interpolate(start, end, fraction: 0.5)
        #expect(abs(mid.latitude - 11) < 1e-9)
        #expect(abs(mid.longitude - 22) < 1e-9)
    }

    @Test("Projection onto a segment clamps to the segment ends")
    func projectionClamps() {
        let start = GeoCoordinate(latitude: 0, longitude: 0)
        let end = GeoCoordinate(latitude: 0, longitude: 1)
        let before = GeoMath.project(GeoCoordinate(latitude: 0, longitude: -0.5), ontoSegmentFrom: start, to: end)
        #expect(before.fraction == 0)
        let after = GeoMath.project(GeoCoordinate(latitude: 0, longitude: 1.5), ontoSegmentFrom: start, to: end)
        #expect(after.fraction == 1)
        let middle = GeoMath.project(GeoCoordinate(latitude: 0.01, longitude: 0.5), ontoSegmentFrom: start, to: end)
        #expect(abs(middle.fraction - 0.5) < 0.001)
        // 0.01° of latitude ≈ 1.11 km.
        #expect(abs(middle.distanceMeters - 1_112) < 15)
    }

    @Test("Coordinate validity rejects out-of-range and non-finite values")
    func validity() {
        #expect(GeoCoordinate(latitude: 45, longitude: 90).isValid)
        #expect(!GeoCoordinate(latitude: 91, longitude: 0).isValid)
        #expect(!GeoCoordinate(latitude: 0, longitude: -181).isValid)
        #expect(!GeoCoordinate(latitude: .nan, longitude: 0).isValid)
    }

    @Test("Path length sums segment lengths")
    func pathLength() {
        let path = [
            GeoCoordinate(latitude: 0, longitude: 0),
            GeoCoordinate(latitude: 0, longitude: 1),
            GeoCoordinate(latitude: 0, longitude: 2),
        ]
        let expected = GeoMath.distance(path[0], path[1]) * 2
        #expect(abs(GeoMath.length(of: path) - expected) < 0.001)
    }

    @Test("Simplification keeps endpoints and enforces minimum spacing")
    func simplification() {
        let dense = (0...1_000).map { GeoCoordinate(latitude: 0, longitude: Double($0) * 0.0001) }
        let simplified = GeoMath.simplify(dense, minimumSpacingMeters: 500)
        #expect(simplified.first == dense.first)
        #expect(simplified.last == dense.last)
        #expect(simplified.count < 30)
        for index in 1..<(simplified.count - 1) {
            #expect(GeoMath.distance(simplified[index - 1], simplified[index]) >= 499)
        }
    }
}
