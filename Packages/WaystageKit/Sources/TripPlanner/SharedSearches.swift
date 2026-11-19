import Foundation
import TripModels

/// Along-route searches for several routes, without paying twice for the same stretch of road.
///
/// The routes of one plan often share road: each corridor's toll-free version, and the first and
/// last hours of every route. Each route's sections are searched in order; a section that is
/// (nearly) all within `tolerance` of sections already searched for the same kind of place reuses
/// their results instead of being searched again. Which searches run depends only on geometry, so
/// it's decided before any request is sent.
struct SharedSearches: Sendable {
    /// The searches to send.
    let unique: [AlongRouteSearch]
    /// For each route, for each of its searches (in order): the unique searches whose results it
    /// uses (its own, or those covering its section).
    let sources: [[[Int]]]

    /// - Parameters:
    ///   - tolerance: how far apart two sections' lines may be and still count as the same road.
    ///   - coverage: the share of a section's points that must lie on searched road for it to
    ///     reuse their results.
    init(routes: [[AlongRouteSearch]], tolerance: Double = 300, coverage: Double = 0.95) {
        var unique: [AlongRouteSearch] = []
        var geometries: [PolylineGeometry] = []
        var boxes: [Box] = []
        var sources: [[[Int]]] = []
        for searches in routes {
            var routeSources: [[Int]] = []
            for search in searches {
                let points = (try? PolylineCodec.decode(search.encodedPolyline)) ?? []
                let box = Box(points, margin: tolerance)
                let covering = Self.covering(
                    points, box: box, candidates: unique.indices.filter { unique[$0].category == search.category && boxes[$0].overlaps(box) },
                    geometries: geometries, boxes: boxes, tolerance: tolerance, coverage: coverage
                )
                if let covering {
                    routeSources.append(covering)
                } else {
                    unique.append(search)
                    geometries.append(PolylineGeometry(coordinates: points))
                    boxes.append(box)
                    routeSources.append([unique.count - 1])
                }
            }
            sources.append(routeSources)
        }
        self.unique = unique
        self.sources = sources
    }

    /// The searched sections that together cover `points` (at least `coverage` of them within
    /// `tolerance`), or nil. Checks about 60 points per section, and stops as soon as too many
    /// are off searched road.
    private static func covering(
        _ points: [GeoCoordinate], box: Box, candidates: [Int], geometries: [PolylineGeometry], boxes: [Box],
        tolerance: Double, coverage: Double
    ) -> [Int]? {
        guard points.count >= 2, !candidates.isEmpty else { return nil }
        let step = max(1, points.count / 60)
        let sample = Array(stride(from: 0, to: points.count, by: step).map { points[$0] }) + [points[points.count - 1]]
        let allowedMisses = Int((1 - coverage) * Double(sample.count))
        var misses = 0
        var covering = Set<Int>()
        for point in sample {
            var onSearchedRoad = false
            for index in candidates where boxes[index].contains(point) {
                if let projection = geometries[index].project(point), projection.offsetMeters <= tolerance {
                    covering.insert(index)
                    onSearchedRoad = true
                }
            }
            if !onSearchedRoad {
                misses += 1
                if misses > allowedMisses { return nil }
            }
        }
        return covering.isEmpty ? nil : covering.sorted()
    }

    /// A section's bounding box, widened by a margin in meters.
    struct Box: Sendable {
        let minLatitude, maxLatitude, minLongitude, maxLongitude: Double

        init(_ points: [GeoCoordinate], margin: Double) {
            let latitudes = points.map(\.latitude), longitudes = points.map(\.longitude)
            let latitudeMargin = margin / 111_000
            let longitudeMargin = margin / (111_000 * max(0.1, cos((latitudes.first ?? 0) * .pi / 180)))
            minLatitude = (latitudes.min() ?? 0) - latitudeMargin
            maxLatitude = (latitudes.max() ?? 0) + latitudeMargin
            minLongitude = (longitudes.min() ?? 0) - longitudeMargin
            maxLongitude = (longitudes.max() ?? 0) + longitudeMargin
        }

        func contains(_ point: GeoCoordinate) -> Bool {
            (minLatitude...maxLatitude).contains(point.latitude) && (minLongitude...maxLongitude).contains(point.longitude)
        }

        func overlaps(_ other: Box) -> Bool {
            minLatitude <= other.maxLatitude && other.minLatitude <= maxLatitude
                && minLongitude <= other.maxLongitude && other.minLongitude <= maxLongitude
        }
    }

    /// A route's search results (one per search, in order) from the unique searches' results:
    /// the places of all the searches it uses, each once. It fails only if all of those failed.
    func results(forRoute route: Int, from results: [Result<[FoundPlace], Error>]) -> [Result<[FoundPlace], Error>] {
        sources[route].map { indices in
            var places: [FoundPlace] = []
            var seen = Set<String>()
            var failure: Error?
            var anySucceeded = false
            for index in indices {
                switch results[index] {
                case let .success(found):
                    anySucceeded = true
                    for place in found where seen.insert(place.place.id).inserted { places.append(place) }
                case let .failure(error):
                    failure = failure ?? error
                }
            }
            if !anySucceeded, let failure { return .failure(failure) }
            return .success(places)
        }
    }
}
