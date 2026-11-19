import Foundation
import Testing
@testable import TripPlanner
import TripModels
import TripSandbox

@Suite("Shared searches")
struct SharedSearchesTests {
    /// A straight stretch of road heading east from `start`, `kilometers` long.
    private func section(from start: GeoCoordinate, kilometers: Double, heading: Double = 90) -> [GeoCoordinate] {
        stride(from: 0.0, through: kilometers * 1_000, by: 250).map { GeoMath.destination(from: start, bearing: heading, distance: $0) }
    }

    private func search(_ category: PlaceCategory, _ points: [GeoCoordinate]) -> AlongRouteSearch {
        AlongRouteSearch(category: category, encodedPolyline: PolylineCodec.encode(points), origin: points[0], sectionDuration: 3_600)
    }

    private let denver = GeoCoordinate(latitude: 39.74, longitude: -104.99)

    /// One 250 km road east of Denver (a point every 250 m); sections are slices of it.
    private var road: [GeoCoordinate] { section(from: denver, kilometers: 250) }

    /// The road from `start` to `end` kilometers.
    private func stretch(_ start: Double, _ end: Double) -> [GeoCoordinate] {
        Array(road[Int(start * 4)...Int(end * 4)])
    }

    @Test("A section another route already searched isn't searched again")
    func sameSection() {
        let shared = SharedSearches(routes: [[search(.fuel, stretch(0, 150))], [search(.fuel, stretch(0, 150))]])
        #expect(shared.unique.count == 1)
        #expect(shared.sources == [[[0]], [[0]]])
    }

    @Test("A section covered by two searched sections uses both, each place once")
    func coveredByNeighbours() {
        let first = stretch(0, 100), second = stretch(100, 200)
        // The other route's section straddles both (its chunks start elsewhere).
        let middle = stretch(50, 150)
        let shared = SharedSearches(routes: [[search(.rest, first), search(.rest, second)], [search(.rest, middle)]])
        #expect(shared.unique.count == 2)
        #expect(shared.sources[1] == [[0, 1]])

        func place(_ id: String) -> FoundPlace {
            FoundPlace(place: Place(id: id, name: id, coordinate: denver), categories: [.rest])
        }
        let results: [Result<[FoundPlace], Error>] = [.success([place("a"), place("b")]), .success([place("b"), place("c")])]
        let merged = try? shared.results(forRoute: 1, from: results)[0].get()
        #expect(merged?.map(\.place.id) == ["a", "b", "c"])
    }

    @Test("Different road, or a different kind of place, is searched")
    func differentRoadOrKind() {
        let searched = stretch(0, 100)
        let elsewhere = section(from: GeoMath.destination(from: denver, bearing: 0, distance: 20_000), kilometers: 100)
        let shared = SharedSearches(routes: [
            [search(.fuel, searched), search(.rest, searched)],
            [search(.fuel, elsewhere), search(.lodging, searched)],
        ])
        #expect(shared.unique.count == 4, "a parallel road 20 km away, and hotels on the same road, are new searches")
    }

    @Test("A section only partly on searched road is searched")
    func partlyCovered() {
        let searched = stretch(0, 100)
        let half = stretch(50, 100) + section(from: searched.last!, kilometers: 50, heading: 0)
        let shared = SharedSearches(routes: [[search(.fuel, searched)], [search(.fuel, half)]])
        #expect(shared.unique.count == 2)
    }

    @Test("A reused section fails only if every search it uses failed")
    func failures() {
        let shared = SharedSearches(routes: [
            [search(.fuel, stretch(0, 100)), search(.fuel, stretch(100, 200))], [search(.fuel, stretch(50, 150))],
        ])
        #expect(shared.sources[1] == [[0, 1]])
        let place = FoundPlace(place: Place(id: "a", name: "a", coordinate: denver), categories: [.fuel])
        let oneFailed: [Result<[FoundPlace], Error>] = [.failure(URLError(.timedOut)), .success([place])]
        #expect((try? shared.results(forRoute: 1, from: oneFailed)[0].get())?.count == 1)
        let bothFailed: [Result<[FoundPlace], Error>] = [.failure(URLError(.timedOut)), .failure(URLError(.timedOut))]
        #expect((try? shared.results(forRoute: 1, from: bothFailed)[0].get()) == nil)
    }

    /// Counts the searches sent.
    final class CountingPlaces: PlaceSearchProvider, @unchecked Sendable {
        let inner = FakePlaceSearchProvider()
        private let lock = NSLock()
        private var count = 0
        var sent: Int { lock.withLock { count } }

        func searchAlongRoute(_ search: AlongRouteSearch) async throws -> [FoundPlace] {
            lock.withLock { count += 1 }
            return try await inner.searchAlongRoute(search)
        }
    }

    /// One road between any two places: tolled, and a slightly slower toll-free version of the
    /// same road when asked to avoid tolls (no other routes).
    struct OneRoad: RoutingProvider {
        let tolls: Double?

        func computeRoutes(_ query: RouteQuery) async throws -> [ComputedRoute] {
            guard query.vias.isEmpty else { return [] }
            var single = query
            single.computeAlternatives = false
            let road = query.avoidTolls ? FakeRoutingProvider(speedMPH: 60) : FakeRoutingProvider(speedMPH: 62, tollCostUSD: tolls)
            return try await road.computeRoutes(single)
        }
    }

    @Test("A route's toll-free version on the same road reuses its searches")
    func tollFreeVersionReusesSearches() async throws {
        func plan(tolls: Double?) async throws -> (searches: Int, result: PlanResult) {
            let places = CountingPlaces()
            let service = TripPlanningService(routing: OneRoad(tolls: tolls), places: places)
            let result = try await service.plan(SampleTrips.request(from: "sf", to: "den")) { _ in }
            return (places.sent, result)
        }
        // Without tolls, one route is planned (20 searches); with tolls, the same road twice:
        // tolled, and toll-free as its variant. Searched separately that is 40; shared, the
        // toll-free version only adds what the tolled one didn't search, here hotels on the
        // stretch where the slower drive likely stops for the night earlier (1 search).
        let oneRoute = try await plan(tolls: nil)
        let twoRoutes = try await plan(tolls: 14)
        #expect(oneRoute.searches > 0)
        #expect(twoRoutes.searches <= oneRoute.searches + 2, "the toll-free version reuses the tolled route's searches")
        #expect(twoRoutes.result.recommended?.stops.count ?? 0 > 2, "stops are still found")
    }
}
