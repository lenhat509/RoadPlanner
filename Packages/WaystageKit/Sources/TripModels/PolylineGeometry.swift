import Foundation

/// A point projected onto a polyline.
public struct PolylineProjection: Equatable, Sendable {
    /// Distance from the start of the polyline to the projected point, in meters.
    public var distanceAlong: Double
    /// Lateral distance between the input point and the polyline, in meters.
    public var offsetMeters: Double
    /// The projected point on the polyline.
    public var coordinate: GeoCoordinate
    /// Index of the segment (`coordinates[i] → coordinates[i + 1]`) containing the projection.
    public var segmentIndex: Int
}

/// An immutable polyline with pre-computed cumulative distances and a spatial index
/// for fast nearest-segment queries. Shared by the route profile and turn-by-turn guidance.
public struct PolylineGeometry: Sendable {
    public let coordinates: [GeoCoordinate]
    /// `cumulativeDistances[i]` is the distance in meters from the start to `coordinates[i]`.
    public let cumulativeDistances: [Double]
    private let grid: SegmentGrid

    public init(coordinates: [GeoCoordinate]) {
        self.coordinates = coordinates
        var cumulative = [Double]()
        cumulative.reserveCapacity(coordinates.count)
        var running = 0.0
        for index in coordinates.indices {
            if index > 0 { running += GeoMath.distance(coordinates[index - 1], coordinates[index]) }
            cumulative.append(running)
        }
        self.cumulativeDistances = cumulative
        self.grid = SegmentGrid(coordinates: coordinates)
    }

    /// Total length in meters.
    public var totalLength: Double { cumulativeDistances.last ?? 0 }

    /// Index of the segment containing `distance` (clamped to the valid range).
    public func segmentIndex(atDistance distance: Double) -> Int {
        guard coordinates.count > 1 else { return 0 }
        var low = 0, high = cumulativeDistances.count - 1
        while low < high - 1 {
            let mid = (low + high) / 2
            if cumulativeDistances[mid] <= distance { low = mid } else { high = mid }
        }
        return low
    }

    /// Coordinate located `distance` meters from the start (clamped to the ends).
    public func coordinate(atDistance distance: Double) -> GeoCoordinate {
        guard let first = coordinates.first, let last = coordinates.last else {
            return GeoCoordinate(latitude: 0, longitude: 0)
        }
        if distance <= 0 || coordinates.count == 1 { return first }
        if distance >= totalLength { return last }
        let index = segmentIndex(atDistance: distance)
        let segmentLength = cumulativeDistances[index + 1] - cumulativeDistances[index]
        let fraction = segmentLength > 0 ? (distance - cumulativeDistances[index]) / segmentLength : 0
        return GeoMath.interpolate(coordinates[index], coordinates[index + 1], fraction: fraction)
    }

    /// Projects `point` onto the polyline. When `window` is given only segments overlapping
    /// that distance range are considered (useful to disambiguate self-overlapping routes).
    public func project(_ point: GeoCoordinate, within window: ClosedRange<Double>? = nil) -> PolylineProjection? {
        guard let first = coordinates.first else { return nil }
        guard coordinates.count > 1 else {
            return PolylineProjection(
                distanceAlong: 0, offsetMeters: GeoMath.distance(point, first), coordinate: first, segmentIndex: 0
            )
        }
        if let window {
            let lower = segmentIndex(atDistance: window.lowerBound)
            let upper = min(coordinates.count - 2, segmentIndex(atDistance: window.upperBound))
            return bestProjection(of: point, segments: lower...upper)
        }
        // Try the spatial index first (cheap), then fall back to a full scan.
        let nearby = grid.segments(near: point)
        if !nearby.isEmpty, let best = bestProjection(of: point, segments: nearby),
           best.offsetMeters <= grid.guaranteedRadiusMeters(at: point) {
            return best
        }
        return bestProjection(of: point, segments: 0...(coordinates.count - 2))
    }

    /// The sub-path between two distances, including interpolated end points.
    public func slice(from start: Double, to end: Double) -> [GeoCoordinate] {
        guard coordinates.count > 1, end > start else { return [] }
        let clampedStart = max(0, start), clampedEnd = min(totalLength, end)
        var result = [coordinate(atDistance: clampedStart)]
        let firstIndex = segmentIndex(atDistance: clampedStart) + 1
        let lastIndex = segmentIndex(atDistance: clampedEnd)
        if firstIndex <= lastIndex {
            for index in firstIndex...lastIndex where cumulativeDistances[index] < clampedEnd {
                result.append(coordinates[index])
            }
        }
        result.append(coordinate(atDistance: clampedEnd))
        return result
    }

    private func bestProjection<S: Sequence>(of point: GeoCoordinate, segments: S) -> PolylineProjection?
    where S.Element == Int {
        var best: PolylineProjection?
        for index in segments {
            let start = coordinates[index], end = coordinates[index + 1]
            let projection = GeoMath.project(point, ontoSegmentFrom: start, to: end)
            if best == nil || projection.distanceMeters < best!.offsetMeters {
                let segmentLength = cumulativeDistances[index + 1] - cumulativeDistances[index]
                best = PolylineProjection(
                    distanceAlong: cumulativeDistances[index] + projection.fraction * segmentLength,
                    offsetMeters: projection.distanceMeters,
                    coordinate: projection.closestPoint,
                    segmentIndex: index
                )
            }
        }
        return best
    }
}

/// Uniform latitude/longitude grid mapping cells to the segments whose bounding box touches them.
struct SegmentGrid: Sendable {
    private struct Cell: Hashable, Sendable { let row: Int, column: Int }
    /// Cell size in degrees (~5.5 km of latitude).
    private let cellSize = 0.05
    /// Number of neighbouring cells searched in each direction.
    private let searchRadius = 1
    private let cells: [Cell: [Int]]
    /// Segments too long to index; they are checked on every query.
    private let longSegments: [Int]

    init(coordinates: [GeoCoordinate]) {
        var cells: [Cell: [Int]] = [:]
        var longSegments: [Int] = []
        if coordinates.count > 1 {
            for index in 0..<(coordinates.count - 1) {
                let a = coordinates[index], b = coordinates[index + 1]
                let minRow = Int(floor(min(a.latitude, b.latitude) / cellSize))
                let maxRow = Int(floor(max(a.latitude, b.latitude) / cellSize))
                let minColumn = Int(floor(min(a.longitude, b.longitude) / cellSize))
                let maxColumn = Int(floor(max(a.longitude, b.longitude) / cellSize))
                guard (maxRow - minRow + 1) * (maxColumn - minColumn + 1) <= 64 else {
                    longSegments.append(index)
                    continue
                }
                for row in minRow...maxRow {
                    for column in minColumn...maxColumn {
                        cells[Cell(row: row, column: column), default: []].append(index)
                    }
                }
            }
        }
        self.cells = cells
        self.longSegments = longSegments
    }

    func segments(near point: GeoCoordinate) -> [Int] {
        let row = Int(floor(point.latitude / cellSize))
        let column = Int(floor(point.longitude / cellSize))
        var result = Set<Int>(longSegments)
        for dRow in -searchRadius...searchRadius {
            for dColumn in -searchRadius...searchRadius {
                if let segments = cells[Cell(row: row + dRow, column: column + dColumn)] {
                    result.formUnion(segments)
                }
            }
        }
        return result.sorted()
    }

    /// Any segment closer than this radius is guaranteed to be found by `segments(near:)`.
    func guaranteedRadiusMeters(at point: GeoCoordinate) -> Double {
        let latitudeMeters = cellSize * Double(searchRadius) * 111_000
        let longitudeMeters = latitudeMeters * cos(point.latitude.radians)
        return min(latitudeMeters, longitudeMeters)
    }
}
