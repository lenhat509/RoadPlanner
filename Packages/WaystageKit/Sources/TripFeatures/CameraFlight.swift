import Foundation
import TripModels

/// A map camera move that starts from the view on screen and keeps its subject in sight the whole
/// way, so the map never sweeps over unrelated places.
///
/// * `.frame` (e.g. from the whole trip into the next leg, north-up): the centre moves in step with
///   the zoom, so whatever both the start and the end view show stays in view throughout.
/// * `.anchored(car)` (from a leg down to the car): the car's place on screen glides in a straight
///   line from where it is to where it ends up, so it never leaves the screen while the map zooms,
///   turns and tilts around it.
///
/// The zoom changes evenly (the same factor per unit of time), eased in and out. The math is
/// engine-independent: Apple Maps samples it into keyframes, Google Maps steps it every frame.
public struct CameraFlight: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case frame
        case anchored(GeoCoordinate)
    }

    /// A camera, independent of the map engine.
    public struct Camera: Equatable, Sendable {
        public var center: GeoCoordinate
        /// Proportional to the ground one screen point covers: Apple's camera distance in meters,
        /// Google's 2^-zoom.
        public var scale: Double
        /// Degrees clockwise from north.
        public var heading: Double
        public var pitch: Double

        public init(center: GeoCoordinate, scale: Double, heading: Double = 0, pitch: Double = 0) {
            self.center = center
            self.scale = scale
            self.heading = heading
            self.pitch = pitch
        }
    }

    /// Flights take longer the more they zoom, within these bounds.
    public static let minimumDuration: TimeInterval = 0.8
    public static let maximumDuration: TimeInterval = 2.2
    public static let secondsPerZoomLevel: TimeInterval = 0.15

    public var start: Camera
    public var end: Camera
    public var kind: Kind

    public init(from start: Camera, to end: Camera, kind: Kind) {
        self.start = start
        self.end = end
        self.kind = kind
    }

    /// Longer for bigger zooms (the scale halving or doubling is one zoom level).
    public var duration: TimeInterval { Self.duration(fromScale: start.scale, toScale: end.scale) }

    public static func duration(fromScale start: Double, toScale end: Double) -> TimeInterval {
        guard start > 0, end > 0 else { return minimumDuration }
        return min(maximumDuration, minimumDuration + secondsPerZoomLevel * abs(log2(end / start)))
    }

    /// The camera `time` (0...1) of the way through.
    public func camera(at time: Double) -> Camera {
        let t = min(1, max(0, time))
        let eased = t * t * (3 - 2 * t)
        let scale = start.scale > 0 && end.scale > 0
            ? start.scale * pow(end.scale / start.scale, eased)
            : start.scale + (end.scale - start.scale) * eased
        let heading = start.heading + Self.turn(from: start.heading, to: end.heading) * eased
        let pitch = start.pitch + (end.pitch - start.pitch) * eased
        let center: GeoCoordinate
        switch kind {
        case .frame:
            // The centre moves as far, proportionally, as the scale has: the visible area's edges
            // then move in straight lines between where they start and end, so anything inside
            // both views stays inside throughout.
            let change = end.scale - start.scale
            let share = abs(change) > 1e-9 * max(start.scale, end.scale) ? (scale - start.scale) / change : eased
            center = Self.interpolate(start.center, end.center, share)
        case let .anchored(anchor):
            // The centre's offset from the anchor, in screen units, moves in a straight line.
            let from = Self.screenOffset(of: start.center, from: anchor, heading: start.heading, scale: start.scale)
            let to = Self.screenOffset(of: end.center, from: anchor, heading: end.heading, scale: end.scale)
            let offset = ScreenOffset(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
            center = Self.ground(from: anchor, offset: offset, heading: heading, scale: scale)
        }
        return Camera(center: center, scale: scale, heading: heading, pitch: pitch)
    }

    /// Evenly spaced cameras through the flight, both ends included.
    public func samples(count: Int) -> [Camera] {
        let count = max(2, count)
        return (0..<count).map { camera(at: Double($0) / Double(count - 1)) }
    }

    // MARK: Geometry

    /// A position on screen relative to the centre, in screen units (x right, y up).
    public struct ScreenOffset: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Where `point` is from `anchor` on a map turned to `heading`, in screen units of a map at
    /// `scale`.
    public static func screenOffset(of point: GeoCoordinate, from anchor: GeoCoordinate, heading: Double, scale: Double) -> ScreenOffset {
        let distance = GeoMath.distance(anchor, point)
        guard distance > 0, scale > 0 else { return ScreenOffset(x: 0, y: 0) }
        let angle = (GeoMath.bearing(from: anchor, to: point) - heading) * .pi / 180
        return ScreenOffset(x: distance * sin(angle) / scale, y: distance * cos(angle) / scale)
    }

    /// The inverse of `screenOffset(of:from:heading:scale:)`.
    public static func ground(from anchor: GeoCoordinate, offset: ScreenOffset, heading: Double, scale: Double) -> GeoCoordinate {
        let distance = hypot(offset.x, offset.y) * scale
        guard distance > 0 else { return anchor }
        let bearing = heading + atan2(offset.x, offset.y) * 180 / .pi
        return GeoMath.destination(from: anchor, bearing: bearing, distance: distance)
    }

    /// The signed turn from one heading to another, the short way round (-180...180).
    public static func turn(from: Double, to: Double) -> Double {
        let difference = (to - from).truncatingRemainder(dividingBy: 360)
        if difference > 180 { return difference - 360 }
        if difference < -180 { return difference + 360 }
        return difference
    }

    private static func interpolate(_ a: GeoCoordinate, _ b: GeoCoordinate, _ share: Double) -> GeoCoordinate {
        GeoCoordinate(
            latitude: a.latitude + (b.latitude - a.latitude) * share,
            longitude: a.longitude + turn(from: a.longitude, to: b.longitude) * share
        )
    }
}
