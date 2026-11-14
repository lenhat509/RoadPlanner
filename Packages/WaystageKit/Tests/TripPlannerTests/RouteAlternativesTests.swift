import Foundation
import Testing
@testable import TripPlanner
import TripModels
import TripSandbox

@Suite("RouteAlternatives")
struct RouteAlternativesTests {
    private let sanJose = GeoCoordinate(latitude: 37.34, longitude: -121.89)
    private let denver = GeoCoordinate(latitude: 39.74, longitude: -104.99)
    private let losAngeles = GeoCoordinate(latitude: 34.05, longitude: -118.24)
    private let lasVegas = GeoCoordinate(latitude: 36.17, longitude: -115.14)
    private let saltLake = GeoCoordinate(latitude: 40.76, longitude: -111.89)
    private let boise = GeoCoordinate(latitude: 43.62, longitude: -116.20)
    private let alternatives = RouteAlternatives()

    private func route(_ points: GeoCoordinate..., tolls: Double? = nil) -> ComputedRoute {
        var route = SyntheticRoute.make(via: points)
        route.tollCostUSD = tolls
        return route
    }

    private func coordinates(_ route: ComputedRoute) -> [GeoCoordinate] {
        (try? PolylineCodec.decode(route.encodedPolyline)) ?? []
    }

    // MARK: Where to look

    @Test("A long trip tries hubs on both sides, spread apart, never far out of the way")
    func viaHubs() {
        let direct = GeoMath.distance(sanJose, denver)
        let known = coordinates(route(sanJose, saltLake, denver))
        let hubs = alternatives.viaHubs(from: sanJose, to: denver, avoiding: [known])
        #expect((2...alternatives.maxViaHubs).contains(hubs.count), "\(hubs.map(\.name))")
        for hub in hubs {
            let detour = (GeoMath.distance(sanJose, hub.coordinate) + GeoMath.distance(hub.coordinate, denver)) / direct
            #expect(detour <= alternatives.maxHubDetour, "\(hub.name) is out of the way (\(detour))")
            let offset = PolylineGeometry(coordinates: known).project(hub.coordinate)?.offsetMeters ?? 0
            #expect(offset >= max(alternatives.hubClearance, alternatives.hubSeparation * direct), "\(hub.name) is near the route already known")
        }
        #expect(!hubs.contains { $0.name == "Boise" }, "Idaho is too far out of the way")
        let sides = Set(hubs.map { alternatives.side(of: $0.coordinate, from: sanJose, to: denver) })
        #expect(sides.count == 2, "both sides of the direct line: \(hubs.map(\.name))")
        for (index, hub) in hubs.enumerated() {
            for other in hubs[(index + 1)...] {
                #expect(GeoMath.distance(hub.coordinate, other.coordinate) >= alternatives.hubSpacing * direct)
            }
        }
    }

    @Test("A short trip only uses the routing provider's own alternatives")
    func shortTrip() {
        let anaheim = GeoCoordinate(latitude: 33.84, longitude: -117.91)
        #expect(alternatives.viaHubs(from: losAngeles, to: anaheim, avoiding: []).isEmpty)
    }

    // MARK: Which routes to show

    @Test("Keeps reasonable, noticeably different routes; drops near-copies and long detours")
    func selection() throws {
        let north = route(sanJose, saltLake, denver)
        let south = route(sanJose, lasVegas, denver)
        var nearCopy = route(sanJose, GeoMath.destination(from: saltLake, bearing: 90, distance: 4_000), denver)
        nearCopy.duration = north.duration + 300
        let idaho = route(sanJose, boise, denver)
        #expect(idaho.duration > north.duration * alternatives.maxDetour, "the Idaho route is the long one")

        let corridors = alternatives.select([idaho, nearCopy, south, north])
        #expect(corridors.count == 2)
        #expect(corridors[0].primary == north, "the quickest first")
        #expect(corridors[1].primary == south)
        #expect(corridors.allSatisfy { $0.variants.isEmpty })
    }

    @Test("When nothing else is reasonable, the best route is the only one")
    func singleRoute() {
        let north = route(sanJose, saltLake, denver)
        let idaho = route(sanJose, boise, denver)
        let corridors = alternatives.select([north, idaho])
        #expect(corridors.map(\.primary) == [north])
    }

    @Test("At most three routes")
    func cap() {
        let hubs = [saltLake, lasVegas, GeoCoordinate(latitude: 39.25, longitude: -114.89), GeoCoordinate(latitude: 38.99, longitude: -110.16)]
        let routes = hubs.map { route(sanJose, $0, denver) }
        #expect(alternatives.select(routes).count <= alternatives.maxRoutes)
    }

    @Test("A toll-free near-copy stays with its route, for cost-conscious plans")
    func tollFreeVariant() {
        let tolled = route(sanJose, saltLake, denver, tolls: 12)
        var tollFree = route(sanJose, GeoMath.destination(from: saltLake, bearing: 90, distance: 4_000), denver)
        tollFree.duration = tolled.duration + 600
        let corridors = alternatives.select([tolled, tollFree])
        #expect(corridors.count == 1)
        #expect(corridors[0].variants == [tollFree])
    }

    @Test("Measures how much of a route runs alongside another")
    func sharedShare() {
        let north = coordinates(route(sanJose, saltLake, denver))
        let south = coordinates(route(sanJose, lasVegas, denver))
        #expect(RouteAlternatives.share(of: north, alongside: north, within: 15_000) > 0.99)
        #expect(RouteAlternatives.share(of: north, alongside: south, within: 15_000) < 0.3)
    }

    // MARK: How to show them

    @Test("Routes are named after a place only they pass, labelled where they differ most")
    func namesAndLabels() throws {
        let north = coordinates(route(sanJose, saltLake, denver))
        let south = coordinates(route(sanJose, lasVegas, denver))
        let names = alternatives.names(for: [north, south])
        #expect(names == ["via Salt Lake City", "via Las Vegas"])
        #expect(alternatives.names(for: [north]) == [nil], "one route needs no name")

        let labels = alternatives.labelPoints(for: [north, south])
        #expect(labels.count == 2)
        let southGeometry = PolylineGeometry(coordinates: south)
        let northGeometry = PolylineGeometry(coordinates: north)
        #expect(try #require(northGeometry.project(labels[0])).offsetMeters < 1_000, "on its own route")
        #expect(try #require(southGeometry.project(labels[0])).offsetMeters > 150_000, "away from the other route")
        #expect(try #require(northGeometry.project(labels[1])).offsetMeters > 150_000)
    }

    @Test("Shown routes are named by a place, else by a unique highway name, else by number")
    func routeNames() {
        #expect(TripPlanningService.routeNames(places: [nil], summaries: ["I-80"]) == [nil], "one route needs no name")
        #expect(TripPlanningService.routeNames(places: ["via Las Vegas", nil], summaries: ["I-15", "I-80"]) == ["via Las Vegas", "via I-80"])
        #expect(TripPlanningService.routeNames(places: [nil, nil], summaries: ["I-80", "I-80"]) == ["Route 1", "Route 2"])
    }
}
