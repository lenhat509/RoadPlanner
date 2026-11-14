import Foundation
import TripModels
import TripPlanner

/// Deterministic, offline route generator used by tests, SwiftUI previews and the
/// UI-test sandbox. Routes follow a gently curving path between two points, are split into
/// steps with realistic instructions and travel at a constant highway speed.
public enum SyntheticRoute {
    /// Builds a route from `origin` to `destination`.
    ///
    /// - Parameters:
    ///   - speedMPH: average driving speed.
    ///   - stepLengthMeters: approximate length of each navigation step.
    ///   - vertexSpacingMeters: spacing of geometry vertices.
    ///   - tollCostUSD: tolls reported for the route.
    public static func make(
        from origin: GeoCoordinate,
        to destination: GeoCoordinate,
        speedMPH: Double = 62,
        stepLengthMeters: Double = 40_000,
        vertexSpacingMeters: Double = 1_000,
        summary: String = "I-80",
        tollCostUSD: Double? = nil,
        curvature: Double = 0.02
    ) -> ComputedRoute {
        let path = curvedPath(from: origin, to: destination, spacing: vertexSpacingMeters, curvature: curvature)
        let speed = speedMPH * Units.metersPerMile / 3_600
        let leg = makeLeg(path: path, speed: speed, stepLength: stepLengthMeters, summary: summary, tollCostUSD: tollCostUSD)
        return ComputedRoute(
            summary: summary,
            distanceMeters: leg.distanceMeters,
            duration: leg.duration,
            encodedPolyline: PolylineCodec.encode(GeoMath.simplify(path, minimumSpacingMeters: 2_000)),
            legs: [leg],
            tollCostUSD: tollCostUSD
        )
    }

    /// Builds a multi-leg route through `waypoints` (first = origin, last = destination).
    public static func make(through waypoints: [GeoCoordinate], speedMPH: Double = 62, summary: String = "I-80") -> ComputedRoute {
        precondition(waypoints.count >= 2, "A route needs at least two waypoints")
        let speed = speedMPH * Units.metersPerMile / 3_600
        var legs: [RouteLeg] = []
        for index in 1..<waypoints.count {
            let path = curvedPath(from: waypoints[index - 1], to: waypoints[index], spacing: 1_000, curvature: 0.02)
            legs.append(makeLeg(path: path, speed: speed, stepLength: 40_000, summary: summary, tollCostUSD: nil))
        }
        let overview = legs.flatMap { (try? PolylineCodec.decode($0.encodedPolyline)) ?? [] }
        return ComputedRoute(
            summary: summary,
            distanceMeters: legs.reduce(0) { $0 + $1.distanceMeters },
            duration: legs.reduce(0) { $0 + $1.duration },
            encodedPolyline: PolylineCodec.encode(GeoMath.simplify(overview, minimumSpacingMeters: 2_000)),
            legs: legs
        )
    }

    /// Builds a single-leg route that passes through `points` (first = origin, last =
    /// destination) without stopping.
    public static func make(via points: [GeoCoordinate], speedMPH: Double = 62, summary: String = "I-80") -> ComputedRoute {
        precondition(points.count >= 2, "A route needs at least two points")
        var path: [GeoCoordinate] = []
        for index in 1..<points.count {
            let section = curvedPath(from: points[index - 1], to: points[index], spacing: 1_000, curvature: 0.02)
            path += path.isEmpty ? section : Array(section.dropFirst())
        }
        let speed = speedMPH * Units.metersPerMile / 3_600
        let leg = makeLeg(path: path, speed: speed, stepLength: 40_000, summary: summary, tollCostUSD: nil)
        return ComputedRoute(
            summary: summary,
            distanceMeters: leg.distanceMeters,
            duration: leg.duration,
            encodedPolyline: PolylineCodec.encode(GeoMath.simplify(path, minimumSpacingMeters: 2_000)),
            legs: [leg]
        )
    }

    static func curvedPath(from origin: GeoCoordinate, to destination: GeoCoordinate, spacing: Double, curvature: Double) -> [GeoCoordinate] {
        let distance = GeoMath.distance(origin, destination)
        let count = max(2, Int((distance / spacing).rounded(.up)) + 1)
        let dLat = destination.latitude - origin.latitude
        let dLon = destination.longitude - origin.longitude
        return (0..<count).map { index in
            let t = Double(index) / Double(count - 1)
            // A gentle S-curve perpendicular to the straight line keeps routes realistic but deterministic.
            let bend = sin(t * .pi * 2) * curvature * sqrt(dLat * dLat + dLon * dLon)
            return GeoCoordinate(
                latitude: origin.latitude + dLat * t + bend * (-dLon) / max(1e-9, sqrt(dLat * dLat + dLon * dLon)),
                longitude: origin.longitude + dLon * t + bend * dLat / max(1e-9, sqrt(dLat * dLat + dLon * dLon))
            )
        }
    }

    static func makeLeg(path: [GeoCoordinate], speed: Double, stepLength: Double, summary: String, tollCostUSD: Double?) -> RouteLeg {
        let geometry = PolylineGeometry(coordinates: path)
        let total = geometry.totalLength
        let stepCount = max(1, Int((total / stepLength).rounded()))
        let maneuvers: [Maneuver] = [.rampRight, .merge, .forkLeft, .straight, .turnSlightRight, .nameChange]
        var steps: [NavigationStep] = []
        for index in 0..<stepCount {
            let start = total * Double(index) / Double(stepCount)
            let end = total * Double(index + 1) / Double(stepCount)
            let coordinates = geometry.slice(from: start, to: end)
            let maneuver: Maneuver = index == 0 ? .depart : maneuvers[index % maneuvers.count]
            steps.append(NavigationStep(
                instruction: instruction(for: maneuver, summary: summary, index: index),
                maneuver: maneuver,
                distanceMeters: end - start,
                duration: (end - start) / speed,
                encodedPolyline: PolylineCodec.encode(coordinates)
            ))
        }
        return RouteLeg(
            distanceMeters: total,
            duration: total / speed,
            encodedPolyline: PolylineCodec.encode(path),
            steps: steps,
            tollCostUSD: tollCostUSD
        )
    }

    static func instruction(for maneuver: Maneuver, summary: String, index: Int) -> String {
        switch maneuver {
        case .depart: "Head toward \(summary)"
        case .rampRight: "Take the ramp onto \(summary)"
        case .merge: "Merge onto \(summary)"
        case .forkLeft: "Keep left to stay on \(summary)"
        case .straight: "Continue straight on \(summary)"
        case .turnSlightRight: "Slight right to stay on \(summary)"
        case .nameChange: "Continue onto \(summary) (exit \(100 + index))"
        default: "Continue on \(summary)"
        }
    }
}
