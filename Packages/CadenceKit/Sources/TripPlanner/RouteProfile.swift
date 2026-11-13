import Foundation
import TripModels

/// A route's geometry plus a mapping between distance along the route and driving time.
///
/// Travel time is distributed along the geometry using per-step durations when available,
/// so slow urban sections and fast interstates are represented faithfully.
public struct RouteProfile: Sendable {
    public let geometry: PolylineGeometry
    /// `cumulativeTimes[i]` is the driving time in seconds from the start to `geometry.coordinates[i]`.
    public let cumulativeTimes: [TimeInterval]
    /// Estimated tolls for the whole route in USD.
    public let tollCostUSD: Double
    /// Short description such as "I-80 E".
    public let summary: String

    /// A route section produced by `chunks(maxDuration:)`.
    public struct Chunk: Sendable, Equatable {
        public var startDistance: Double
        public var endDistance: Double
        public var startTime: TimeInterval
        public var endTime: TimeInterval
        public var coordinates: [GeoCoordinate]
    }

    /// Geometry and duration of one step, used to build a profile.
    public struct StepTiming: Sendable {
        public var coordinates: [GeoCoordinate]
        public var duration: TimeInterval

        public init(coordinates: [GeoCoordinate], duration: TimeInterval) {
            self.coordinates = coordinates
            self.duration = duration
        }
    }

    /// Builds a profile assuming constant speed along the whole geometry.
    public init(coordinates: [GeoCoordinate], totalDuration: TimeInterval, tollCostUSD: Double = 0, summary: String = "") {
        let geometry = PolylineGeometry(coordinates: coordinates)
        let total = geometry.totalLength
        self.geometry = geometry
        self.cumulativeTimes = geometry.cumulativeDistances.map { total > 0 ? $0 / total * totalDuration : 0 }
        self.tollCostUSD = tollCostUSD
        self.summary = summary
    }

    /// Builds a profile from consecutive steps, distributing each step's duration over its geometry.
    public init(steps: [StepTiming], tollCostUSD: Double = 0, summary: String = "") {
        var coordinates: [GeoCoordinate] = []
        var times: [TimeInterval] = []
        var elapsed: TimeInterval = 0
        for step in steps where !step.coordinates.isEmpty {
            let stepLength = GeoMath.length(of: step.coordinates)
            var walked = 0.0
            for (index, coordinate) in step.coordinates.enumerated() {
                if index > 0 { walked += GeoMath.distance(step.coordinates[index - 1], coordinate) }
                let time = elapsed + (stepLength > 0 ? walked / stepLength * step.duration : 0)
                // Steps share their boundary vertex; skip the duplicate.
                if let last = coordinates.last, index == 0, GeoMath.distance(last, coordinate) < 0.5 { continue }
                coordinates.append(coordinate)
                times.append(max(time, times.last ?? 0))
            }
            elapsed += step.duration
        }
        self.geometry = PolylineGeometry(coordinates: coordinates)
        self.cumulativeTimes = times
        self.tollCostUSD = tollCostUSD
        self.summary = summary
    }

    public var totalDistance: Double { geometry.totalLength }
    public var totalDuration: TimeInterval { cumulativeTimes.last ?? 0 }
    public var start: GeoCoordinate? { geometry.coordinates.first }
    public var end: GeoCoordinate? { geometry.coordinates.last }

    /// Driving time from the start to `distance` meters along the route.
    public func time(atDistance distance: Double) -> TimeInterval {
        guard geometry.coordinates.count > 1 else { return 0 }
        if distance <= 0 { return 0 }
        if distance >= totalDistance { return totalDuration }
        let index = geometry.segmentIndex(atDistance: distance)
        let d0 = geometry.cumulativeDistances[index], d1 = geometry.cumulativeDistances[index + 1]
        let fraction = d1 > d0 ? (distance - d0) / (d1 - d0) : 0
        return cumulativeTimes[index] + fraction * (cumulativeTimes[index + 1] - cumulativeTimes[index])
    }

    /// Distance along the route reached after driving `time` seconds.
    public func distance(atTime time: TimeInterval) -> Double {
        guard geometry.coordinates.count > 1 else { return 0 }
        if time <= 0 { return 0 }
        if time >= totalDuration { return totalDistance }
        var low = 0, high = cumulativeTimes.count - 1
        while low < high - 1 {
            let mid = (low + high) / 2
            if cumulativeTimes[mid] <= time { low = mid } else { high = mid }
        }
        let t0 = cumulativeTimes[low], t1 = cumulativeTimes[high]
        let fraction = t1 > t0 ? (time - t0) / (t1 - t0) : 0
        let d0 = geometry.cumulativeDistances[low], d1 = geometry.cumulativeDistances[high]
        return d0 + fraction * (d1 - d0)
    }

    /// Coordinate reached after driving `time` seconds.
    public func coordinate(atTime time: TimeInterval) -> GeoCoordinate {
        geometry.coordinate(atDistance: distance(atTime: time))
    }

    /// Splits the route into consecutive chunks of at most `maxDuration` driving time.
    public func chunks(maxDuration: TimeInterval) -> [Chunk] {
        guard totalDuration > 0, maxDuration > 0 else { return [] }
        let count = Int((totalDuration / maxDuration).rounded(.up))
        return (0..<count).map { index in
            let startTime = Double(index) * maxDuration
            let endTime = min(totalDuration, Double(index + 1) * maxDuration)
            let startDistance = distance(atTime: startTime)
            let endDistance = distance(atTime: endTime)
            return Chunk(
                startDistance: startDistance,
                endDistance: endDistance,
                startTime: startTime,
                endTime: endTime,
                coordinates: geometry.slice(from: startDistance, to: endDistance)
            )
        }
    }
}
