import Foundation
import Testing
@testable import TripModels

@Suite("PolylineGeometry")
struct PolylineGeometryTests {
    /// A straight east-west line along the equator, ~111 km long.
    private let line = PolylineGeometry(
        coordinates: (0...100).map { GeoCoordinate(latitude: 0, longitude: Double($0) * 0.01) }
    )

    @Test("Cumulative distances start at zero and increase monotonically")
    func cumulativeDistances() {
        #expect(line.cumulativeDistances.first == 0)
        #expect(abs(line.totalLength - 111_195) < 50)
        for index in 1..<line.cumulativeDistances.count {
            #expect(line.cumulativeDistances[index] > line.cumulativeDistances[index - 1])
        }
    }

    @Test("Coordinate at distance interpolates along the line")
    func coordinateAtDistance() {
        let halfway = line.coordinate(atDistance: line.totalLength / 2)
        #expect(abs(halfway.longitude - 0.5) < 1e-6)
        #expect(line.coordinate(atDistance: -10) == line.coordinates.first)
        #expect(line.coordinate(atDistance: line.totalLength + 10) == line.coordinates.last)
    }

    @Test("Projection finds distance along the line and lateral offset")
    func projection() throws {
        let offRoute = GeoCoordinate(latitude: 0.009, longitude: 0.255)
        let projection = try #require(line.project(offRoute))
        #expect(abs(projection.distanceAlong - 0.255 * 111_195) < 30)
        #expect(abs(projection.offsetMeters - 1_000) < 15)
    }

    @Test("Projection restricted to a window ignores the rest of the line")
    func windowedProjection() throws {
        // A U-shaped path where the return leg passes close to the outbound leg.
        let uPath = PolylineGeometry(coordinates: [
            GeoCoordinate(latitude: 0, longitude: 0),
            GeoCoordinate(latitude: 0, longitude: 1),
            GeoCoordinate(latitude: 0.002, longitude: 1),
            GeoCoordinate(latitude: 0.002, longitude: 0),
        ])
        let point = GeoCoordinate(latitude: 0.0015, longitude: 0.5)
        let global = try #require(uPath.project(point))
        #expect(global.distanceAlong > uPath.totalLength / 2) // closest to the return leg
        let outbound = try #require(uPath.project(point, within: 0...(uPath.totalLength / 2)))
        #expect(outbound.distanceAlong < uPath.totalLength / 2)
    }

    @Test("Slicing returns the sub-path between two distances")
    func slicing() {
        let slice = line.slice(from: 10_000, to: 20_000)
        #expect(abs(GeoMath.length(of: slice) - 10_000) < 1)
        #expect(abs(GeoMath.distance(slice.first!, line.coordinate(atDistance: 10_000))) < 0.01)
    }

    @Test("Degenerate geometries are handled")
    func degenerate() {
        let empty = PolylineGeometry(coordinates: [])
        #expect(empty.totalLength == 0)
        #expect(empty.project(GeoCoordinate(latitude: 0, longitude: 0)) == nil)
        let single = PolylineGeometry(coordinates: [GeoCoordinate(latitude: 1, longitude: 1)])
        #expect(single.totalLength == 0)
        #expect(single.project(GeoCoordinate(latitude: 1, longitude: 1.001))?.distanceAlong == 0)
    }
}
