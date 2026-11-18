import Foundation
import Observation
import TripModels
import TripNavigation
import TripPlanner

/// Drive mode: takes the driver from stop to stop, offers "Continue to next stop" when close to /
/// at a stop, and auto-saves progress.
///
/// Each leg is handed to the navigation engine (`TurnByTurnGuidance`): in the App Store build
/// Google's Navigation SDK computes the route, guides turn by turn (voice included), reroutes and
/// detects arrival. This model decides *where* to go next and keeps the trip's progress.
///
/// Every leg opens as a silent *preview* (the route from the car to the next stop and a Start
/// button) — starting a trip, resuming one, continuing from a stop — and guidance begins on Start.
/// A new trip only counts as started then.
///
/// The plan's start and the car's position are kept apart: when a trip that hasn't started is
/// opened far from its start (`farFromStartDistance`), the first leg is from the car *to the
/// start* ("heading to start"); reaching it starts the trip. The driver can instead start the
/// trip from where they are.
@MainActor
@Observable
public final class DriveViewModel: Identifiable {
    public struct Banner: Equatable, Sendable {
        public var symbolName: String
        public var distanceText: String
        public var instruction: String
        /// The turn right after this one, when it comes soon ("Then ↰").
        public var thenSymbolName: String?

        public init(symbolName: String, distanceText: String, instruction: String, thenSymbolName: String? = nil) {
            self.symbolName = symbolName
            self.distanceText = distanceText
            self.instruction = instruction
            self.thenSymbolName = thenSymbolName
        }
    }

    public struct NextStopInfo: Equatable, Sendable {
        public var kind: StopKind
        public var isPullOff: Bool
        public var name: String
        public var kindTitle: String
        public var symbolName: String
        public var etaText: String
        public var remainingText: String
        /// Driving time left to the stop ("1 h 12 min"); empty at a stop.
        public var durationText: String
        public var plannedAction: String?
        public var isDestination: Bool

        public init(
            kind: StopKind,
            isPullOff: Bool,
            name: String,
            kindTitle: String,
            symbolName: String,
            etaText: String,
            remainingText: String,
            durationText: String = "",
            plannedAction: String?,
            isDestination: Bool
        ) {
            self.kind = kind
            self.isPullOff = isPullOff
            self.name = name
            self.kindTitle = kindTitle
            self.symbolName = symbolName
            self.etaText = etaText
            self.remainingText = remainingText
            self.durationText = durationText
            self.plannedAction = plannedAction
            self.isDestination = isDestination
        }
    }

    /// What's left of the leg, from the navigation engine.
    public struct LegProgress: Equatable, Sendable {
        public var distanceRemaining: Double
        public var timeRemaining: TimeInterval

        public init(distanceRemaining: Double, timeRemaining: TimeInterval) {
            self.distanceRemaining = distanceRemaining
            self.timeRemaining = timeRemaining
        }
    }

    public enum Mode: Equatable, Sendable {
        case driving
        case atStop
        case completed
    }

    /// Whether a leg is being previewed or guided.
    public enum Stage: Equatable, Sendable {
        /// The route to the next stop with a Start button: no guidance yet.
        case preview
        /// Turn-by-turn guidance.
        case navigating
    }

    /// The trip's ID.
    public nonisolated let id: UUID
    public private(set) var trip: ActiveTrip
    /// Drive mode is open (`start()` ran and `stop()` hasn't).
    public private(set) var isStarted = false
    public private(set) var currentLocation: GeoCoordinate?
    public private(set) var currentCourse: Double?
    public private(set) var stage: Stage
    /// Driving to the plan's start before the trip begins (the car was far from it).
    public private(set) var isHeadingToStart: Bool
    /// The route the navigation engine is following to the next stop (or the start), from where
    /// the car was when it loaded. Kept in memory only.
    public private(set) var route: GuidanceRoute?
    /// Distance and time left to the stop being driven to.
    public private(set) var legProgress: LegProgress?
    /// The next maneuver, from engines that don't draw their own (the offline simulation).
    public private(set) var instruction: GuidanceInstruction?
    /// The route still to drive to the target stop, starting at the car (at a stop: the next leg).
    public private(set) var routeToTarget: [GeoCoordinate] = []
    /// The rest of the trip after that, drawn lighter.
    public private(set) var routeAfterTarget: [GeoCoordinate] = []
    /// What the map frames in a preview and at a stop: the route to the next stop as it was when
    /// the leg was loaded (it doesn't follow the car, so the user can zoom and pan freely).
    public private(set) var previewFrame: [GeoCoordinate] = []
    public private(set) var isRerouting = false
    public private(set) var isLoadingDirections = false
    /// The navigation engine is ready (Google's terms accepted).
    public private(set) var isGuidanceReady = false
    /// Night where the car is, as the navigation engine sees it (nil when it has no day and night
    /// looks, offline: drive mode then follows the phone's appearance).
    public private(set) var isNight: Bool?
    public private(set) var statusMessage: String?
    public var isMuted: Bool {
        didSet {
            dependencies.guidance.isMuted = isMuted
            var preferences = dependencies.preferences.load()
            preferences.voiceGuidanceEnabled = !isMuted
            dependencies.preferences.save(preferences)
        }
    }

    private let dependencies: AppDependencies
    private var guidance: any TurnByTurnGuidance { dependencies.guidance }
    private var updatesTask: Task<Void, Never>?
    private var lastSave: Date?
    /// When loading directions last failed (they're retried on later fixes).
    private var lastLoadFailure: Date?
    private var routeGeometry: PolylineGeometry?
    /// The leg's length for the progress ribbon: the planned leg, or the first route loaded.
    private var legReferenceDistance: Double?

    /// How often location-only progress is persisted.
    public var saveInterval: TimeInterval = 30
    /// How long to wait before retrying directions that failed to load.
    public var loadRetryInterval: TimeInterval = 15
    /// Driving this far from a stop (at speed) counts as leaving it.
    public var autoDepartureDistance: Double = 400
    /// Within this distance of a stop, "Continue to next stop" is offered.
    public static let approachDistance: Double = 800
    /// Farther than this from the plan's start, the car first drives to it (or the driver chooses
    /// to start from where they are). Closer, the trip simply starts from the car.
    public static let farFromStartDistance: Double = 50_000

    /// Opens on a preview of the next leg (for a trip that hasn't started and is far away, the way
    /// to its start).
    public init(trip: ActiveTrip, dependencies: AppDependencies) {
        self.id = trip.id
        self.trip = trip
        self.dependencies = dependencies
        self.isMuted = !dependencies.preferences.load().voiceGuidanceEnabled
        let car = dependencies.location.lastKnownLocation ?? trip.progress.lastKnownLocation
        let farFromStart = trip.progress.phase == .notStarted && car.map { Self.isFar($0, fromStartOf: trip) } == true
        self.isHeadingToStart = farFromStart
        self.stage = .preview
        self.currentLocation = car
        // Planned geometry right away, so the map opens on the right area, and the plan's time
        // and distance until the navigation engine's route arrives.
        refreshRouteAfterTarget()
        updateRouteToTarget()
        previewFrame = legFrame
        legProgress = plannedProgress()
    }

    /// Whether `location` is far from where `trip` starts.
    public static func isFar(_ location: GeoCoordinate, fromStartOf trip: ActiveTrip) -> Bool {
        guard let start = trip.itinerary.stops.first else { return false }
        return GeoMath.distance(location, start.place.coordinate) > farFromStartDistance
    }

    /// The stop guidance leads to: the trip's start while heading there, otherwise the target.
    public var guidedStop: ItineraryStop? {
        isHeadingToStart ? trip.itinerary.stops.first : trip.targetStop
    }

    /// Whether a leg is being driven or previewed (to the next stop, or to the start).
    private var isOnLeg: Bool { trip.progress.phase == .enRoute || trip.progress.phase == .notStarted }

    // MARK: Derived state

    public var mode: Mode {
        switch trip.progress.phase {
        case .completed: .completed
        case .atStop: .atStop
        case .enRoute, .notStarted: .driving
        }
    }

    /// The navigation engine draws the route, the car and the turn instructions on its own map
    /// (Google's Navigation SDK).
    public var engineDrawsGuidance: Bool { guidance.drawsOwnGuidance }

    /// Whether drive mode draws `routeToTarget` itself (not when the engine has drawn its route).
    public var drawsRouteToTarget: Bool { !(engineDrawsGuidance && route != nil && isOnLeg) }

    /// The "Continue to next stop" option: shown at a stop and when approaching one.
    public var canContinueToNextStop: Bool {
        switch trip.progress.phase {
        case .atStop:
            return true
        case .enRoute:
            guard !trip.isFinalTarget, !isHeadingToStart, let legProgress else { return false }
            return legProgress.distanceRemaining <= Self.approachDistance
        default:
            return false
        }
    }

    /// Show "Then …" when the turn after the next one is at most this far after it.
    public static let thenManeuverDistance: Double = 1_000

    /// The next turn, for engines that don't draw their own header.
    public var banner: Banner? {
        guard mode == .driving, stage == .navigating, !engineDrawsGuidance, let instruction else { return nil }
        var then: String?
        if let following = instruction.followingManeuver, let between = instruction.distanceBetweenManeuvers,
           between <= Self.thenManeuverDistance, instruction.maneuver != .arrive {
            then = following.symbolName
        }
        return Banner(
            symbolName: instruction.maneuver.symbolName,
            distanceText: DistanceText.short(instruction.distanceToManeuver),
            instruction: instruction.text,
            thenSymbolName: then
        )
    }

    public var nextStop: NextStopInfo? {
        guard let target = guidedStop else { return nil }
        let formatters = dependencies.formatters
        let now = dependencies.now()
        let eta: Date? = isOnLeg
            ? legProgress.map { now.addingTimeInterval($0.timeRemaining) } ?? target.arrival
            : trip.progress.actualArrivals[target.id] ?? target.arrival
        let presentation = StopPresentation(
            stop: target, formatters: formatters, tankCapacityGallons: trip.itinerary.request.vehicle.tankCapacityGallons
        )
        var plannedAction = presentation.detail
        if isHeadingToStart {
            let departure = target.departure.map { formatters.dateTime($0, utcOffsetSeconds: target.place.utcOffsetSeconds) }
            plannedAction = "Your trip begins here" + (departure.map { " · planned departure \($0)" } ?? "")
        }
        let onLeg = isOnLeg ? legProgress : nil
        return NextStopInfo(
            kind: target.kind,
            isPullOff: target.isRoadsidePullOff,
            name: target.place.name,
            kindTitle: isHeadingToStart ? "Trip start" : target.isRoadsidePullOff ? "Rest break" : target.kind.displayName,
            symbolName: presentation.symbolName,
            etaText: eta.map { formatters.clockTime($0, utcOffsetSeconds: target.place.utcOffsetSeconds) } ?? "—",
            remainingText: onLeg.map { formatters.distance($0.distanceRemaining) } ?? "",
            durationText: onLeg.map { formatters.duration($0.timeRemaining) } ?? "",
            plannedAction: plannedAction,
            isDestination: target.kind == .destination
        )
    }

    /// Stops after the target, with times adjusted for the current delay.
    public var upcomingStops: [StopPresentation] {
        let remaining = isOnLeg ? legProgress?.timeRemaining : nil
        let projected = trip.projectedSchedule(now: dependencies.now(), remainingToTarget: remaining)
        let byID = Dictionary(uniqueKeysWithValues: projected.map { ($0.stopID, $0) })
        return trip.itinerary.stops.enumerated()
            .filter { $0.offset > trip.progress.targetStopIndex && !trip.progress.skippedStopIDs.contains($0.element.id) }
            .map { _, stop in
                var adjusted = stop
                if let projection = byID[stop.id] {
                    adjusted.arrival = projection.arrival
                    adjusted.departure = projection.departure
                }
                return StopPresentation(
                    stop: adjusted, formatters: dependencies.formatters,
                    tankCapacityGallons: trip.itinerary.request.vehicle.tankCapacityGallons
                )
            }
    }

    /// Stops along the whole trip, for the progress ribbon.
    public var ribbonMarks: [RibbonMark] { TripRibbon.marks(for: trip.itinerary) }

    /// Fraction of the current leg already driven, `0...1`, when known.
    public var legFraction: Double? {
        guard isOnLeg, !isHeadingToStart, let legProgress, let reference = legReferenceDistance, reference > 0 else { return nil }
        return min(1, max(0, 1 - legProgress.distanceRemaining / reference))
    }

    /// Fraction of the trip already driven, `0...1`.
    public var tripProgress: Double { TripRibbon.progress(of: trip, legProgress: legFraction) }

    /// Hand-off link to the Google Maps app for the current leg.
    public var googleMapsURL: URL? {
        guard let target = guidedStop else { return nil }
        return ExternalLinks.googleMapsDirections(from: currentLocation, to: target.place)
    }

    // MARK: Lifecycle

    /// Opens drive mode (or resumes it): readies the navigation engine (Google's terms, the first
    /// time), loads the route to the next stop for its preview and begins location updates.
    /// Does nothing when drive mode is already open (the iPhone and CarPlay share one drive).
    public func start() async {
        guard !isStarted else { return }
        isStarted = true
        if dependencies.location.authorization != .authorized {
            let authorization = await dependencies.location.requestAuthorization()
            if authorization == .denied {
                statusMessage = "Location access is off. Turn it on in Settings for turn-by-turn guidance."
            }
        }
        // Where the car is decides how the leg starts (and whether the trip starts far away), so
        // ask the device rather than wait for the first update.
        var here = dependencies.location.lastKnownLocation
        if here == nil, dependencies.location.authorization == .authorized {
            here = await dependencies.location.requestLocation()
        }
        currentLocation = here ?? trip.progress.lastKnownLocation ?? currentLocation
        if trip.progress.phase == .notStarted {
            // Far from the plan's start: the first leg goes there. Otherwise it's the trip's first
            // leg, from the car. Either way the trip starts on Start.
            isHeadingToStart = currentLocation.map { Self.isFar($0, fromStartOf: trip) } ?? false
            await persist()
        }
        guidance.isMuted = isMuted
        guidance.eventHandler = { [weak self] event in await self?.apply(event) }
        await readyGuidance()
        await prepareLeg()
        let stream = dependencies.location.startUpdates()
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            for await sample in stream {
                guard !Task.isCancelled else { break }
                await self?.handle(sample)
            }
        }
    }

    /// Leaves drive mode: stops guidance and location updates (progress is saved).
    public func stop() async {
        guard isStarted else { return }
        isStarted = false
        updatesTask?.cancel()
        updatesTask = nil
        dependencies.location.stopUpdates()
        guidance.stopGuidance()
        guidance.eventHandler = nil
        await persist()
    }

    // MARK: Location updates

    /// Processes one location fix. Public so tests can drive the model deterministically.
    public func handle(_ sample: LocationSample) async {
        currentLocation = sample.coordinate
        if sample.course >= 0 { currentCourse = sample.course }
        trip.record(location: sample.coordinate, at: sample.timestamp)

        switch trip.progress.phase {
        case .completed:
            break
        case .atStop:
            // Driving away from the stop starts the next leg automatically.
            if let stop = trip.targetStop, sample.speed > 4,
               GeoMath.distance(sample.coordinate, stop.place.coordinate) > autoDepartureDistance {
                await continueToNextStop(startNavigating: true)
                return
            }
        case .notStarted, .enRoute:
            if route == nil, isRetryDue, let target = guidedStop {
                // Directions couldn't load (no position or connection yet): try again from here.
                await loadDirections(to: target)
            } else {
                await guidance.didUpdateLocation(sample)
            }
            updateRouteToTarget()
        }
        await persistIfDue()
    }

    private var isRetryDue: Bool {
        guard isGuidanceReady, !isLoadingDirections else { return false }
        guard let lastLoadFailure else { return false }
        return dependencies.now().timeIntervalSince(lastLoadFailure) >= loadRetryInterval
    }

    /// Applies an event from the navigation engine.
    private func apply(_ event: GuidanceEvent) async {
        switch event {
        case let .progress(distance, time):
            guard isOnLeg else { return }
            legProgress = LegProgress(distanceRemaining: distance, timeRemaining: time)
            updateRouteToTarget()
        case let .routeChanged(newRoute):
            guard isOnLeg else { return }
            route = newRoute
            routeGeometry = PolylineGeometry(coordinates: newRoute.coordinates)
            updateRouteToTarget()
        case let .rerouting(active):
            isRerouting = active
        case let .instruction(next):
            instruction = next
        case .arrived:
            if isHeadingToStart { await reachStart() } else { await arriveAtTarget() }
        case let .lighting(night):
            isNight = night
        }
    }

    // MARK: Driver actions

    /// Starts guidance from a preview ("Start"): starts a new trip (unless heading to its start)
    /// and hands the leg to the navigation engine.
    public func beginNavigation() async {
        guard stage == .preview else { return }
        if !isGuidanceReady {
            // Google's terms were declined: they're shown again, and guidance needs them.
            await readyGuidance()
            guard isGuidanceReady else { return }
        }
        stage = .navigating
        if trip.progress.phase == .notStarted, !isHeadingToStart {
            try? trip.start(at: dependencies.now())
            await persist()
        }
        guard isOnLeg else { return }
        if route != nil {
            await guidance.startGuidance()
        } else if !isLoadingDirections, let target = guidedStop {
            // Starts guidance once loaded.
            await loadDirections(to: target)
        }
    }

    /// Ends guidance but stays on the leg, back in its preview (CarPlay's "end navigation", or the
    /// car's own navigation taking over).
    public func pauseGuidance() async {
        guard stage == .navigating else { return }
        guidance.stopGuidance()
        stage = .preview
        instruction = nil
        isRerouting = false
        // The route is loaded again for the preview.
        route = nil
        routeGeometry = nil
        legProgress = nil
        updateRouteToTarget()
        previewFrame = legFrame
        await prepareLeg()
    }

    /// "I'm here": records arrival at the target stop (or at the trip's start).
    public func confirmArrival() async {
        guidance.stopGuidance()
        if isHeadingToStart { await reachStart() } else { await arriveAtTarget() }
    }

    /// Starts the trip where the car is, instead of driving to the plan's start first. Directions
    /// to the first stop come from the car.
    public func startTripFromHere() async {
        guard isHeadingToStart else { return }
        guidance.stopGuidance()
        isHeadingToStart = false
        clearLeg()
        try? trip.start(at: dependencies.now())
        await persist()
        await prepareLeg()
    }

    /// At the plan's start: the trip begins and guidance carries on to the first stop.
    private func reachStart() async {
        guard isHeadingToStart else { return }
        isHeadingToStart = false
        clearLeg()
        try? trip.start(at: dependencies.now())
        await persist()
        await prepareLeg()
    }

    /// Leaves the current stop (or the one being approached) for the next one. Shows the next leg
    /// as a preview unless the car is already driving away (`startNavigating`).
    public func continueToNextStop(startNavigating: Bool = false) async {
        do {
            try trip.continueToNextStop(at: dependencies.now())
        } catch {
            return
        }
        guidance.stopGuidance()
        clearLeg()
        stage = startNavigating ? .navigating : .preview
        await persist()
        await prepareLeg()
    }

    /// Skips the stop being driven to; guidance carries on to the following one.
    public func skipTargetStop() async {
        guard (try? trip.skipTargetStop(at: dependencies.now())) != nil else { return }
        guidance.stopGuidance()
        clearLeg()
        await persist()
        await prepareLeg()
    }

    /// Ends the trip and clears the saved progress.
    public func endTrip() async {
        await stop()
        try? await dependencies.repository.clearActiveTrip()
    }

    public func dismissStatus() {
        statusMessage = nil
    }

    // MARK: Internals

    private func readyGuidance() async {
        do {
            try await guidance.prepare()
            isGuidanceReady = true
        } catch {
            isGuidanceReady = false
            statusMessage = (error as? GuidanceError ?? .failed("\(error)")).message
        }
    }

    private func arriveAtTarget() async {
        guard trip.progress.phase == .enRoute else { return }
        guidance.stopGuidance()
        try? trip.markArrived(at: dependencies.now())
        clearLeg()
        refreshRouteAfterTarget()
        updateRouteToTarget()
        previewFrame = legFrame
        await persist()
    }

    private func clearLeg() {
        route = nil
        routeGeometry = nil
        legProgress = nil
        legReferenceDistance = nil
        instruction = nil
        isRerouting = false
        lastLoadFailure = nil
    }

    /// Shows the next leg (planned geometry, time and distance first) and, on a leg, has the
    /// engine load its route.
    private func prepareLeg() async {
        refreshRouteAfterTarget()
        updateRouteToTarget()
        previewFrame = legFrame
        if route == nil { legProgress = plannedProgress() }
        guard isOnLeg, let target = guidedStop, isGuidanceReady else { return }
        await loadDirections(to: target)
    }

    private func loadDirections(to target: ItineraryStop) async {
        isLoadingDirections = true
        defer { isLoadingDirections = false }
        // The simulation starts where the car is (or, not known yet, at the previous stop).
        let previous = trip.itinerary.stops[max(0, trip.progress.targetStopIndex - 1)].place.coordinate
        let origin = currentLocation ?? (isHeadingToStart ? nil : previous)
        do {
            let loaded = try await guidance.setDestination(GuidanceDestination(target.place), from: origin)
            // The trip may have moved on while directions were loading.
            guard guidedStop?.id == target.id, isOnLeg else { return }
            lastLoadFailure = nil
            statusMessage = nil
            route = loaded
            routeGeometry = PolylineGeometry(coordinates: loaded.coordinates)
            legProgress = LegProgress(distanceRemaining: loaded.distanceMeters, timeRemaining: loaded.duration)
            let planned = isHeadingToStart ? nil : trip.legToTarget?.distanceMeters
            legReferenceDistance = max(planned ?? 0, loaded.distanceMeters)
            updateRouteToTarget()
            previewFrame = legFrame
            if stage == .navigating { await guidance.startGuidance() }
        } catch GuidanceError.canceled {
            return
        } catch {
            lastLoadFailure = dependencies.now()
            statusMessage = (error as? GuidanceError ?? .failed("\(error)")).message
        }
    }

    /// The route from the car (or, at a stop, from the stop) to the next stop.
    private func updateRouteToTarget() {
        if isOnLeg {
            guard let routeGeometry, routeGeometry.coordinates.count > 1 else {
                // No directions yet: the planned leg, or a straight line to the start.
                if isHeadingToStart {
                    routeToTarget = [currentLocation, trip.itinerary.stops.first?.place.coordinate].compactMap { $0 }
                } else {
                    let planned = trip.legToTarget.flatMap { try? PolylineCodec.decode($0.encodedPolyline) } ?? []
                    routeToTarget = Self.remaining(of: planned, from: currentLocation)
                }
                return
            }
            let remaining = legProgress?.distanceRemaining ?? routeGeometry.totalLength
            let along = max(0, routeGeometry.totalLength - remaining)
            var ahead = routeGeometry.slice(from: along, to: routeGeometry.totalLength)
            if ahead.isEmpty, let last = routeGeometry.coordinates.last { ahead = [last] }
            if let car = currentLocation, let first = ahead.first, GeoMath.distance(car, first) > 1 {
                ahead.insert(car, at: 0)
            }
            routeToTarget = ahead
        } else if trip.progress.phase == .atStop {
            routeToTarget = trip.itinerary.leg(after: trip.progress.targetStopIndex)
                .flatMap { try? PolylineCodec.decode($0.encodedPolyline) } ?? []
        } else {
            routeToTarget = []
        }
    }

    /// The plan's time and distance for what's left of the leg (from where the car is on it),
    /// shown until the navigation engine's route arrives with live ones. Nil without a planned
    /// leg (heading to the trip's start).
    private func plannedProgress() -> LegProgress? {
        guard isOnLeg, !isHeadingToStart, let leg = trip.legToTarget, leg.distanceMeters > 0 else { return nil }
        var remaining = 1.0
        let planned = (try? PolylineCodec.decode(leg.encodedPolyline)) ?? []
        if planned.count > 1, let car = currentLocation {
            let geometry = PolylineGeometry(coordinates: planned)
            if geometry.totalLength > 0, let projection = geometry.project(car), projection.offsetMeters < 2_000 {
                remaining = max(0, 1 - projection.distanceAlong / geometry.totalLength)
            }
        }
        return LegProgress(distanceRemaining: leg.distanceMeters * remaining, timeRemaining: leg.duration * remaining)
    }

    /// What a preview frames: the route to the next stop and, on a leg, the car (so directions
    /// from the car, when they load, change the view as little as possible).
    private var legFrame: [GeoCoordinate] {
        guard isOnLeg, let car = currentLocation, let first = routeToTarget.first, GeoMath.distance(car, first) > 1 else {
            return routeToTarget
        }
        return [car] + routeToTarget
    }

    /// The part of a planned leg still ahead of `car` (resuming mid-leg), starting at the car, or
    /// the whole leg when the car isn't on it.
    static func remaining(of planned: [GeoCoordinate], from car: GeoCoordinate?) -> [GeoCoordinate] {
        guard let car, planned.count > 1 else { return planned }
        let geometry = PolylineGeometry(coordinates: planned)
        guard let projection = geometry.project(car), projection.offsetMeters < 2_000 else { return planned }
        var ahead = geometry.slice(from: projection.distanceAlong, to: geometry.totalLength)
        guard !ahead.isEmpty else { return planned }
        if GeoMath.distance(car, ahead[0]) > 1 { ahead.insert(car, at: 0) }
        return ahead
    }

    /// The trip beyond the next stop (beyond the one after, at a stop; all of it while heading to
    /// the start), simplified for drawing.
    private func refreshRouteAfterTarget() {
        let firstLeg = isHeadingToStart ? 0 : trip.progress.targetStopIndex + (trip.progress.phase == .atStop ? 1 : 0)
        let legs = trip.itinerary.legs
        guard trip.progress.phase != .completed, firstLeg < legs.count else {
            routeAfterTarget = []
            return
        }
        let coordinates = legs[firstLeg...].flatMap { (try? PolylineCodec.decode($0.encodedPolyline)) ?? [] }
        routeAfterTarget = GeoMath.simplify(coordinates, minimumSpacingMeters: 150)
    }

    private func persistIfDue() async {
        let now = dependencies.now()
        if let lastSave, now.timeIntervalSince(lastSave) < saveInterval { return }
        await persist()
    }

    private func persist() async {
        lastSave = dependencies.now()
        try? await dependencies.repository.saveActiveTrip(trip)
    }
}
