import Foundation

/// A WGS-84 latitude/longitude pair in decimal degrees.
public struct GeoCoordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// `true` when both components are finite and inside their valid ranges.
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    /// `"lat,lng"` with six decimals, the format used by Google Maps URLs.
    public var urlValue: String {
        String(format: "%.6f,%.6f", latitude, longitude)
    }
}

/// Result of projecting a point onto a line segment.
public struct SegmentProjection: Equatable, Sendable {
    /// Position of the closest point along the segment, in `0...1`.
    public var fraction: Double
    /// Great-circle distance from the point to the closest point, in meters.
    public var distanceMeters: Double
    /// The closest point on the segment.
    public var closestPoint: GeoCoordinate
}

/// Spherical-earth geometry helpers. Accuracy is well within GPS error for road-trip distances.
public enum GeoMath {
    /// Mean earth radius (IUGG) in meters.
    public static let earthRadiusMeters = 6_371_008.8

    /// Great-circle (haversine) distance in meters.
    public static func distance(_ from: GeoCoordinate, _ to: GeoCoordinate) -> Double {
        let lat1 = from.latitude.radians
        let lat2 = to.latitude.radians
        let deltaLat = (to.latitude - from.latitude).radians
        let deltaLon = (to.longitude - from.longitude).radians
        let sinLat = sin(deltaLat / 2)
        let sinLon = sin(deltaLon / 2)
        let a = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
        return 2 * earthRadiusMeters * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    /// Initial bearing in degrees clockwise from true north, in `0..<360`.
    public static func bearing(from: GeoCoordinate, to: GeoCoordinate) -> Double {
        let lat1 = from.latitude.radians
        let lat2 = to.latitude.radians
        let deltaLon = (to.longitude - from.longitude).radians
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let degrees = atan2(y, x).degrees
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The point `distance` meters from `origin` along the initial `bearing` (degrees from north).
    public static func destination(from origin: GeoCoordinate, bearing: Double, distance: Double) -> GeoCoordinate {
        let angular = distance / earthRadiusMeters
        let theta = bearing.radians
        let lat1 = origin.latitude.radians, lon1 = origin.longitude.radians
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(theta))
        let lon2 = lon1 + atan2(sin(theta) * sin(angular) * cos(lat1), cos(angular) - sin(lat1) * sin(lat2))
        let longitude = (lon2.degrees + 540).truncatingRemainder(dividingBy: 360) - 180
        return GeoCoordinate(latitude: lat2.degrees, longitude: longitude)
    }

    /// Linear interpolation in latitude/longitude space (adequate for short segments).
    public static func interpolate(_ from: GeoCoordinate, _ to: GeoCoordinate, fraction: Double) -> GeoCoordinate {
        if fraction <= 0 { return from }
        if fraction >= 1 { return to }
        return GeoCoordinate(
            latitude: from.latitude + (to.latitude - from.latitude) * fraction,
            longitude: from.longitude + (to.longitude - from.longitude) * fraction
        )
    }

    /// Projects `point` onto the segment `start → end` using a local equirectangular approximation.
    public static func project(
        _ point: GeoCoordinate,
        ontoSegmentFrom start: GeoCoordinate,
        to end: GeoCoordinate
    ) -> SegmentProjection {
        let scale = cos(point.latitude.radians)
        let ax = start.longitude * scale, ay = start.latitude
        let bx = end.longitude * scale, by = end.latitude
        let px = point.longitude * scale, py = point.latitude
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        var fraction = 0.0
        if lengthSquared > 0 {
            fraction = ((px - ax) * dx + (py - ay) * dy) / lengthSquared
            fraction = min(1, max(0, fraction))
        }
        let closest = interpolate(start, end, fraction: fraction)
        return SegmentProjection(fraction: fraction, distanceMeters: distance(point, closest), closestPoint: closest)
    }

    /// Total length of a path in meters.
    public static func length(of path: [GeoCoordinate]) -> Double {
        guard path.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<path.count {
            total += distance(path[index - 1], path[index])
        }
        return total
    }

    /// Drops vertices closer than `minimumSpacingMeters` to the previously kept vertex.
    /// Endpoints are always preserved. Used to keep API request payloads small.
    public static func simplify(_ path: [GeoCoordinate], minimumSpacingMeters: Double) -> [GeoCoordinate] {
        guard path.count > 2, let first = path.first, let last = path.last else { return path }
        var result = [first]
        for coordinate in path.dropFirst().dropLast()
        where distance(result[result.count - 1], coordinate) >= minimumSpacingMeters {
            result.append(coordinate)
        }
        if let previous = result.last, distance(previous, last) < minimumSpacingMeters, result.count > 1 {
            result.removeLast()
        }
        result.append(last)
        return result
    }
}

extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}
