import Foundation
import TripModels

/// Finds the few genuinely different, reasonable ways to drive a trip, e.g. San Jose → Denver
/// through Salt Lake City or through Las Vegas, but not through Idaho.
///
/// 1. **Where to look** (`viaHubs`): besides the routing provider's own alternatives, routes are
///    requested through highway hubs in the middle part of the trip, well away from the routes
///    already known, on both sides of the direct line, the least out of the way first.
/// 2. **Which to keep** (`select`): routes at most `maxDetour` slower (and not much longer) than
///    the quickest, of which no more than `maxSharedShare` runs alongside a route already kept.
/// 3. **How to show them** (`names`, `labelPoints`): each route is named after a place only it
///    passes, and labelled where it is farthest from the others.
public struct RouteAlternatives: Sendable {
    /// A distinct way to drive the trip: its route, plus near-copies kept for cost-conscious plans
    /// (a toll-free version).
    public struct Corridor: Equatable, Sendable {
        public var primary: ComputedRoute
        public var variants: [ComputedRoute]

        public init(primary: ComputedRoute, variants: [ComputedRoute] = []) {
            self.primary = primary
            self.variants = variants
        }

        public var routes: [ComputedRoute] { [primary] + variants }
    }

    /// Which side of the direct line a point is on, facing the destination.
    public enum Side: Hashable, Sendable {
        case left
        case right
    }

    public var maxRoutes = 3
    /// An alternative takes at most this much longer than the quickest route…
    public var maxDetour = 1.10
    /// …and is at most this much longer in distance.
    public var maxDistanceDetour = 1.15
    /// Two routes are different when no more than this share of either runs alongside the other.
    public var maxSharedShare = 0.6
    /// Closer than this to another route counts as running alongside it.
    public var alongsideDistance = 15_000.0
    /// Pass-through hubs tried per trip (each costs one routing request).
    public var maxViaHubs = 3
    /// Shorter trips (straight line) only use the provider's own alternatives.
    public var minimumTripForVias = 250_000.0
    /// A hub is tried only when going through it (in straight lines) is at most this much longer.
    public var maxHubDetour = 1.12
    /// …and when it lies in this part of the trip (where corridors differ most).
    public var hubSection = 0.25...0.75
    /// A hub closer than this to a known route (at least 40 km) would mostly give that route again.
    public var hubSeparation = 0.08
    public var hubClearance = 40_000.0
    /// Hubs tried are at least this share of the trip apart, so they lead to different corridors.
    public var hubSpacing = 0.2
    public var hubs = CorridorHubs.all

    public init() {}

    // MARK: Where to look

    public func side(of point: GeoCoordinate, from origin: GeoCoordinate, to destination: GeoCoordinate) -> Side {
        let course = GeoMath.bearing(from: origin, to: destination)
        let towardPoint = GeoMath.bearing(from: origin, to: point)
        return sin((towardPoint - course) * .pi / 180) >= 0 ? .right : .left
    }

    /// Hubs to request routes through: well away from the known routes (`avoiding`), in the middle
    /// part of the trip and not far out of the way; the least out of the way on each side of the
    /// direct line first, then the next least, all spread apart.
    public func viaHubs(from origin: GeoCoordinate, to destination: GeoCoordinate, avoiding routes: [[GeoCoordinate]]) -> [CorridorHub] {
        let direct = GeoMath.distance(origin, destination)
        guard direct >= minimumTripForVias, maxViaHubs > 0 else { return [] }
        let known = routes.filter { $0.count > 1 }.map(Self.geometry)
        let line = Self.geometry([origin, GeoMath.interpolate(origin, destination, fraction: 0.5), destination])
        let minimumSeparation = max(hubClearance, hubSeparation * direct)
        let ranked: [(hub: CorridorHub, detour: Double)] = hubs.compactMap { hub in
            let toHub = GeoMath.distance(origin, hub.coordinate)
            let fromHub = GeoMath.distance(hub.coordinate, destination)
            let detour = (toHub + fromHub) / direct
            guard detour <= maxHubDetour, hubSection.contains(toHub / (toHub + fromHub)) else { return nil }
            // How far it is from the known routes (from the direct line when none are known).
            let separation = (known.isEmpty ? [line] : known).map { $0.project(hub.coordinate)?.offsetMeters ?? .infinity }.min() ?? 0
            return separation >= minimumSeparation ? (hub, detour) : nil
        }.sorted { $0.detour < $1.detour }

        var picked: [CorridorHub] = []
        func isSpread(_ hub: CorridorHub) -> Bool {
            picked.allSatisfy { GeoMath.distance($0.coordinate, hub.coordinate) >= hubSpacing * direct }
        }
        for side in [Side.left, .right] {
            if let first = ranked.first(where: { self.side(of: $0.hub.coordinate, from: origin, to: destination) == side && isSpread($0.hub) }) {
                picked.append(first.hub)
            }
        }
        for candidate in ranked where picked.count < maxViaHubs && !picked.contains(candidate.hub) && isSpread(candidate.hub) {
            picked.append(candidate.hub)
        }
        return Array(picked.prefix(maxViaHubs))
    }

    // MARK: Which to keep

    /// The routes worth showing, quickest first: reasonable and noticeably different from each
    /// other. A toll-free near-copy of a tolled route is kept with it as a variant.
    public func select(_ candidates: [ComputedRoute]) -> [Corridor] {
        let sorted = candidates.filter { $0.duration > 0 }.sorted { $0.duration < $1.duration }
        guard let quickest = sorted.first else { return [] }
        var corridors: [Corridor] = []
        var shapes: [PolylineGeometry] = []
        for route in sorted {
            guard route.duration <= quickest.duration * maxDetour,
                  route.distanceMeters <= quickest.distanceMeters * maxDistanceDetour else { continue }
            let shape = Self.geometry(Self.coordinates(of: route))
            if let index = shapes.firstIndex(where: { !isDistinct(shape, $0) }) {
                let primary = corridors[index].primary
                if (primary.tollCostUSD ?? 0) > 0, (route.tollCostUSD ?? 0) == 0, corridors[index].variants.isEmpty, route != primary {
                    corridors[index].variants.append(route)
                }
                continue
            }
            guard corridors.count < maxRoutes else { continue }
            corridors.append(Corridor(primary: route))
            shapes.append(shape)
        }
        return corridors
    }

    private func isDistinct(_ lhs: PolylineGeometry, _ rhs: PolylineGeometry) -> Bool {
        max(Self.share(of: lhs, alongside: rhs, within: alongsideDistance),
            Self.share(of: rhs, alongside: lhs, within: alongsideDistance)) <= maxSharedShare
    }

    /// The share of `path`'s length that runs within `distance` of `other`.
    public static func share(of path: [GeoCoordinate], alongside other: [GeoCoordinate], within distance: Double) -> Double {
        share(of: geometry(path), alongside: geometry(other), within: distance)
    }

    static func share(of path: PolylineGeometry, alongside other: PolylineGeometry, within distance: Double) -> Double {
        let samples = samplePoints(path)
        guard !samples.isEmpty else { return 0 }
        let alongside = samples.filter { (other.project($0)?.offsetMeters ?? .infinity) <= distance }.count
        return Double(alongside) / Double(samples.count)
    }

    // MARK: How to show them

    /// "via Salt Lake City": a hub that this route passes and the others keep well away from.
    /// Nil for a single route, or when no such place is found.
    public func names(for routes: [[GeoCoordinate]]) -> [String?] {
        guard routes.count > 1 else { return routes.map { _ in nil } }
        let geometries = routes.map(Self.geometry)
        return routes.indices.map { index in
            guard let start = routes[index].first, let end = routes[index].last else { return nil }
            let others = geometries.indices.filter { $0 != index }.map { geometries[$0] }
            var best: (hub: CorridorHub, apart: Double)?
            for hub in hubs {
                guard GeoMath.distance(hub.coordinate, start) > 60_000, GeoMath.distance(hub.coordinate, end) > 60_000,
                      let onRoute = geometries[index].project(hub.coordinate), onRoute.offsetMeters <= 25_000 else { continue }
                let apart = others.map { $0.project(hub.coordinate)?.offsetMeters ?? .infinity }.min() ?? .infinity
                if apart > (best?.apart ?? 40_000) { best = (hub, apart) }
            }
            return best.map { "via \($0.hub.name)" }
        }
    }

    /// Where to put each route's label: the point (away from the ends) farthest from the other
    /// routes; the middle of a single route.
    public func labelPoints(for routes: [[GeoCoordinate]]) -> [GeoCoordinate] {
        let geometries = routes.map(Self.geometry)
        return geometries.indices.compactMap { index in
            let own = geometries[index]
            guard own.totalLength > 0 else { return routes[index].first }
            let others = geometries.indices.filter { $0 != index }.map { geometries[$0] }
            var best = (point: own.coordinate(atDistance: own.totalLength / 2), apart: -1.0)
            guard !others.isEmpty else { return best.point }
            for step in 0...40 {
                let point = own.coordinate(atDistance: own.totalLength * (0.2 + 0.6 * Double(step) / 40))
                let apart = others.map { $0.project(point)?.offsetMeters ?? .infinity }.min() ?? .infinity
                if apart > best.apart { best = (point, apart) }
            }
            return best.point
        }
    }

    // MARK: Geometry

    /// A route's shape, from its overview polyline (or its legs).
    public static func coordinates(of route: ComputedRoute) -> [GeoCoordinate] {
        let overview = (try? PolylineCodec.decode(route.encodedPolyline)) ?? []
        if overview.count > 1 { return overview }
        return route.legs.flatMap { (try? PolylineCodec.decode($0.encodedPolyline)) ?? [] }
    }

    static func geometry(_ coordinates: [GeoCoordinate]) -> PolylineGeometry {
        PolylineGeometry(coordinates: GeoMath.simplify(coordinates, minimumSpacingMeters: 2_000))
    }

    /// Evenly spaced points along a path (every ~5 km, at most 240).
    static func samplePoints(_ geometry: PolylineGeometry) -> [GeoCoordinate] {
        let length = geometry.totalLength
        guard length > 0 else { return [] }
        let count = min(240, max(10, Int(length / 5_000)))
        return (0...count).map { geometry.coordinate(atDistance: length * Double($0) / Double(count)) }
    }
}
