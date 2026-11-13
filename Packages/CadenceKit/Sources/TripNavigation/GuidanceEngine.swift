import Foundation
import TripModels

/// Tunables for turn-by-turn guidance.
public struct GuidanceConfiguration: Hashable, Sendable {
    /// Distance from the route beyond which a fix counts as off-route.
    public var offRouteDistance: Double = 60
    /// Consecutive off-route fixes required before rerouting (filters GPS noise).
    public var offRouteConfirmations: Int = 3
    /// Within this distance of the stop the driver has arrived.
    public var arrivalRadius: Double = 75
    /// Within this distance of the stop the "next stop" option is offered.
    public var approachRadius: Double = 800
    /// Voice prompt distances before a maneuver: 2 mi, ½ mi, 500 ft.
    public var announcementDistances: [Double] = [3_218.7, 804.7, 152.4]
    /// How far backwards a fix may move along the route before it is treated as noise.
    public var backtrackTolerance: Double = 75

    public init() {}
}

/// Where the driver is relative to the next stop.
public enum ArrivalState: String, Hashable, Sendable {
    case enRoute
    case approaching
    case arrived
}

/// Guidance shown on screen and spoken after each location fix.
public struct GuidanceUpdate: Hashable, Sendable {
    public var stepIndex: Int
    /// The next maneuver the driver must make (`.arrive` on the final step).
    public var upcomingManeuver: Maneuver
    public var upcomingInstruction: String
    public var distanceToManeuver: Double
    public var distanceRemaining: Double
    public var timeRemaining: TimeInterval
    public var isOffRoute: Bool
    public var arrival: ArrivalState
    /// Text to speak now, if any.
    public var announcement: String?
    /// The fix snapped onto the route.
    public var snappedCoordinate: GeoCoordinate
    /// Progress along the leg, `0...1`.
    public var progress: Double
}

/// Follows the driver along one leg: snaps fixes to the route, tracks the current step,
/// schedules voice prompts, and detects arrival and off-route driving.
public struct GuidanceEngine: Sendable {
    public let configuration: GuidanceConfiguration
    public let destinationName: String
    private let steps: [NavigationStep]
    private let geometry: PolylineGeometry
    /// Distance along the leg at which each step starts.
    private let stepStarts: [Double]
    private var alongDistance: Double = 0
    private var offRouteCount = 0
    private var announced = Set<String>()
    private var arrived = false
    private var approachAnnounced = false

    public init(leg: RouteLeg, destinationName: String, configuration: GuidanceConfiguration = GuidanceConfiguration()) {
        self.configuration = configuration
        self.destinationName = destinationName
        var steps = leg.steps.filter { !$0.encodedPolyline.isEmpty }
        if steps.isEmpty {
            steps = [NavigationStep(
                instruction: "Drive to \(destinationName)", maneuver: .depart,
                distanceMeters: leg.distanceMeters, duration: leg.duration, encodedPolyline: leg.encodedPolyline
            )]
        }
        // Concatenate step geometries (dropping shared boundary vertices) and record where
        // each step starts along the combined polyline.
        var coordinates: [GeoCoordinate] = []
        var starts: [Double] = []
        var running = 0.0
        for step in steps {
            let points = (try? PolylineCodec.decode(step.encodedPolyline)) ?? []
            starts.append(running)
            running += GeoMath.length(of: points)
            if let last = coordinates.last, let first = points.first, GeoMath.distance(last, first) < 1 {
                coordinates += points.dropFirst()
            } else {
                coordinates += points
            }
        }
        self.steps = steps
        self.geometry = PolylineGeometry(coordinates: coordinates)
        let total = geometry.totalLength
        self.stepStarts = starts.map { min($0, total) }
    }

    /// Total length of the leg in meters.
    public var totalDistance: Double { geometry.totalLength }

    /// The leg geometry (for drawing).
    public var coordinates: [GeoCoordinate] { geometry.coordinates }

    /// Guidance before the first fix (speaks the departure instruction).
    public mutating func start() -> GuidanceUpdate {
        var update = makeUpdate(snapped: geometry.coordinates.first ?? GeoCoordinate(latitude: 0, longitude: 0), offRoute: false)
        update.announcement = steps.first.map { "\($0.instruction)." }
        return update
    }

    /// Processes a location fix.
    public mutating func update(with sample: LocationSample) -> GuidanceUpdate {
        let window = max(0, alongDistance - 300)...(alongDistance + max(2_000, max(0, sample.speed) * 60))
        var projection = geometry.project(sample.coordinate, within: window)
        if projection == nil || projection!.offsetMeters > configuration.offRouteDistance,
           let global = geometry.project(sample.coordinate),
           global.offsetMeters < (projection?.offsetMeters ?? .infinity) {
            projection = global
        }
        guard let projection else { return makeUpdate(snapped: sample.coordinate, offRoute: false) }

        let threshold = max(configuration.offRouteDistance, sample.horizontalAccuracy * 1.5)
        if projection.offsetMeters > threshold {
            offRouteCount += 1
        } else {
            offRouteCount = 0
            // Never jump backwards more than the tolerance (GPS jitter at low speed).
            alongDistance = max(projection.distanceAlong, alongDistance - configuration.backtrackTolerance)
        }
        let offRoute = offRouteCount >= configuration.offRouteConfirmations

        let remaining = max(0, totalDistance - alongDistance)
        let toEnd = geometry.coordinates.last.map { GeoMath.distance(sample.coordinate, $0) } ?? .infinity
        if remaining <= configuration.arrivalRadius || toEnd <= configuration.arrivalRadius {
            arrived = true
        }

        var update = makeUpdate(snapped: projection.coordinate, offRoute: offRoute)
        update.announcement = offRoute ? nil : nextAnnouncement(for: update)
        return update
    }

    /// The step containing the current position.
    private var stepIndex: Int {
        var index = 0
        for (candidate, start) in stepStarts.enumerated() where start <= alongDistance + 0.5 {
            index = candidate
        }
        return index
    }

    private func stepEnd(_ index: Int) -> Double {
        index + 1 < stepStarts.count ? stepStarts[index + 1] : totalDistance
    }

    private func makeUpdate(snapped: GeoCoordinate, offRoute: Bool) -> GuidanceUpdate {
        let index = stepIndex
        let remaining = max(0, totalDistance - alongDistance)
        let maneuver: Maneuver
        let instruction: String
        if index + 1 < steps.count {
            maneuver = steps[index + 1].maneuver
            instruction = steps[index + 1].instruction
        } else {
            maneuver = .arrive
            instruction = "Arrive at \(destinationName)"
        }
        let distanceToManeuver = index + 1 < steps.count ? max(0, stepEnd(index) - alongDistance) : remaining

        // Time: remainder of the current step plus all later steps.
        let stepLength = max(1, stepEnd(index) - stepStarts[index])
        let stepFraction = min(1, max(0, (stepEnd(index) - alongDistance) / stepLength))
        let later = steps.dropFirst(index + 1).reduce(0) { $0 + $1.duration }
        let timeRemaining = steps[index].duration * stepFraction + later

        let arrival: ArrivalState = arrived ? .arrived : (remaining <= configuration.approachRadius ? .approaching : .enRoute)
        return GuidanceUpdate(
            stepIndex: index,
            upcomingManeuver: maneuver,
            upcomingInstruction: instruction,
            distanceToManeuver: distanceToManeuver,
            distanceRemaining: remaining,
            timeRemaining: timeRemaining,
            isOffRoute: offRoute,
            arrival: arrival,
            announcement: nil,
            snappedCoordinate: snapped,
            progress: totalDistance > 0 ? min(1, alongDistance / totalDistance) : 1
        )
    }

    private mutating func nextAnnouncement(for update: GuidanceUpdate) -> String? {
        if update.arrival == .arrived {
            return announceOnce("arrived", "You have arrived at \(destinationName).")
        }
        if update.arrival == .approaching && !approachAnnounced {
            approachAnnounced = true
            return "\(destinationName) is ahead in \(DistanceText.spoken(update.distanceRemaining))."
        }
        guard update.upcomingManeuver != .arrive else { return nil }
        let stepLength = stepEnd(update.stepIndex) - stepStarts[update.stepIndex]
        // Announce the closest threshold already crossed (skip thresholds longer than the step).
        for (index, threshold) in configuration.announcementDistances.enumerated().reversed()
        where update.distanceToManeuver <= threshold && threshold < stepLength + 1 {
            let key = "\(update.stepIndex)-\(index)"
            guard !announced.contains(key) else { return nil }
            // Mark this and all larger thresholds as done so they aren't spoken late.
            for larger in 0...index { announced.insert("\(update.stepIndex)-\(larger)") }
            if index == configuration.announcementDistances.count - 1 {
                return "\(update.upcomingInstruction)."
            }
            return "In \(DistanceText.spoken(update.distanceToManeuver)), \(lowercasedFirst(update.upcomingInstruction))."
        }
        return nil
    }

    private mutating func announceOnce(_ key: String, _ text: String) -> String? {
        guard !announced.contains(key) else { return nil }
        announced.insert(key)
        return text
    }

    private func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
