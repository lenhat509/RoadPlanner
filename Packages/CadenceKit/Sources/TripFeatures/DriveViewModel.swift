import Foundation
import Observation
import TripModels
import TripNavigation
import TripPlanner

/// Turn-by-turn drive mode. Follows the driver to each stop, offers "Continue to next stop"
/// when close to / at a stop, reroutes when off course and auto-saves progress.
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
public final class DriveViewModel {
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

    public enum Mode: Equatable, Sendable {
        case driving
        case atStop
        case completed
    }

    /// Whether a leg is being previewed or guided.
    public enum Stage: Equatable, Sendable {
        /// The route to the next stop with a Start button: no voice, the simulated car waits.
        case preview
        /// Turn-by-turn guidance.
        case navigating
    }

    public private(set) var trip: ActiveTrip
    public private(set) var guidance: GuidanceUpdate?
    public private(set) var currentLocation: GeoCoordinate?
    public private(set) var currentCourse: Double?
    public private(set) var legCoordinates: [GeoCoordinate] = []
    public private(set) var stage: Stage
    /// Driving to the plan's start before the trip begins (the car was far from it).
    public private(set) var isHeadingToStart: Bool
    /// The route still to drive to the target stop, starting at the car (at a stop: the next leg).
    public private(set) var routeToTarget: [GeoCoordinate] = []
    /// The rest of the trip after that, drawn lighter.
    public private(set) var routeAfterTarget: [GeoCoordinate] = []
    /// What the map frames in a preview and at a stop: the route to the next stop as it was when
    /// the leg was loaded (it doesn't follow the car, so the user can zoom and pan freely).
    public private(set) var previewFrame: [GeoCoordinate] = []
    public private(set) var isRerouting = false
    public private(set) var isLoadingDirections = false
    public private(set) var statusMessage: String?
    public var isMuted: Bool {
        didSet {
            if isMuted { dependencies.speech.stopSpeaking() }
            var preferences = dependencies.preferences.load()
            preferences.voiceGuidanceEnabled = !isMuted
            dependencies.preferences.save(preferences)
        }
    }

    private let dependencies: AppDependencies
    private var engine: GuidanceEngine?
    private var updatesTask: Task<Void, Never>?
    private var lastSave: Date?
    private var lastReroute: Date?
    private var legGeometry: PolylineGeometry?
    /// The leg's opening instruction, spoken when guidance starts.
    private var departureAnnouncement: String?
    /// Whether the car's position has been checked against the current leg's start.
    private var hasCheckedLegStart = false

    /// How often location-only progress is persisted.
    public var saveInterval: TimeInterval = 30
    /// Minimum time between reroute requests.
    public var rerouteCooldown: TimeInterval = 20
    /// Driving this far from a stop (at speed) counts as leaving it.
    public var autoDepartureDistance: Double = 400
    /// When the car is farther than this from the planned leg, directions are fetched from the car.
    public var legStartTolerance: Double = 300
    /// Farther than this from the plan's start, the car first drives to it (or the driver chooses
    /// to start from where they are). Closer, the trip simply starts from the car.
    public static let farFromStartDistance: Double = 50_000

    /// Opens on a preview of the next leg (for a trip that hasn't started and is far away, the way
    /// to its start).
    public init(trip: ActiveTrip, dependencies: AppDependencies) {
        self.trip = trip
        self.dependencies = dependencies
        self.isMuted = !dependencies.preferences.load().voiceGuidanceEnabled
        let car = dependencies.location.lastKnownLocation ?? trip.progress.lastKnownLocation
        let farFromStart = trip.progress.phase == .notStarted && car.map { Self.isFar($0, fromStartOf: trip) } == true
        self.isHeadingToStart = farFromStart
        self.stage = .preview
        self.currentLocation = car
        // Planned geometry right away, so the map opens on the right area.
        refreshRouteAfterTarget()
        updateRouteToTarget()
        previewFrame = routeToTarget
    }

    /// Whether `location` is far from where `trip` starts.
    public static func isFar(_ location: GeoCoordinate, fromStartOf trip: ActiveTrip) -> Bool {
        guard let start = trip.itinerary.stops.first else { return false }
        return GeoMath.distance(location, start.place.coordinate) > farFromStartDistance
    }

    /// The stop guidance leads to: the trip's start while heading there, otherwise the target.
    private var guidedStop: ItineraryStop? {
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

    /// The "Continue to next stop" option: shown at a stop and when approaching one.
    public var canContinueToNextStop: Bool {
        switch trip.progress.phase {
        case .atStop: return true
        case .enRoute: return !trip.isFinalTarget && (guidance?.arrival ?? .enRoute) != .enRoute
        default: return false
        }
    }

    /// Show "Then …" when the turn after the next one is at most this far after it.
    public static let thenManeuverDistance: Double = 1_000

    public var banner: Banner? {
        guard mode == .driving, stage == .navigating, let guidance else { return nil }
        var then: String?
        if let following = guidance.followingManeuver, let between = guidance.distanceBetweenManeuvers,
           between <= Self.thenManeuverDistance, guidance.upcomingManeuver != .arrive {
            then = following.symbolName
        }
        return Banner(
            symbolName: guidance.upcomingManeuver.symbolName,
            distanceText: DistanceText.short(guidance.distanceToManeuver),
            instruction: guidance.upcomingInstruction,
            thenSymbolName: then
        )
    }

    public var nextStop: NextStopInfo? {
        guard let target = guidedStop else { return nil }
        let formatters = dependencies.formatters
        let now = dependencies.now()
        let eta: Date? = isOnLeg
            ? guidance.map { now.addingTimeInterval($0.timeRemaining) } ?? target.arrival
            : trip.progress.actualArrivals[target.id] ?? target.arrival
        let presentation = StopPresentation(
            stop: target, formatters: formatters, tankCapacityGallons: trip.itinerary.request.vehicle.tankCapacityGallons
        )
        var plannedAction = presentation.detail
        if isHeadingToStart {
            let departure = target.departure.map { formatters.dateTime($0, utcOffsetSeconds: target.place.utcOffsetSeconds) }
            plannedAction = "Your trip begins here" + (departure.map { " · planned departure \($0)" } ?? "")
        }
        return NextStopInfo(
            kind: target.kind,
            isPullOff: target.isRoadsidePullOff,
            name: target.place.name,
            kindTitle: isHeadingToStart ? "Trip start" : target.isRoadsidePullOff ? "Rest break" : target.kind.displayName,
            symbolName: presentation.symbolName,
            etaText: eta.map { formatters.clockTime($0, utcOffsetSeconds: target.place.utcOffsetSeconds) } ?? "—",
            remainingText: guidance.map { formatters.distance($0.distanceRemaining) } ?? "",
            durationText: trip.progress.phase == .atStop ? "" : guidance.map { formatters.duration($0.timeRemaining) } ?? "",
            plannedAction: plannedAction,
            isDestination: target.kind == .destination
        )
    }

    /// Stops after the target, with times adjusted for the current delay.
    public var upcomingStops: [StopPresentation] {
        let projected = trip.projectedSchedule(now: dependencies.now(), remainingToTarget: guidance?.timeRemaining)
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

    /// Fraction of the trip already driven, `0...1`.
    public var tripProgress: Double { TripRibbon.progress(of: trip, legProgress: guidance?.progress) }

    /// Hand-off link to the Google Maps app for the current leg.
    public var googleMapsURL: URL? {
        guard let target = guidedStop else { return nil }
        return ExternalLinks.googleMapsDirections(from: currentLocation, to: target.place)
    }

    // MARK: Lifecycle

    /// Starts (or resumes) the drive: begins location updates and loads directions.
    public func start() async {
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

    /// Stops location updates and speech (progress is saved).
    public func stop() async {
        updatesTask?.cancel()
        updatesTask = nil
        dependencies.location.stopUpdates()
        dependencies.speech.stopSpeaking()
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
        case .notStarted:
            await guide(with: sample)
        case .atStop:
            // Driving away from the stop starts the next leg automatically.
            if let stop = trip.targetStop, sample.speed > 4,
               GeoMath.distance(sample.coordinate, stop.place.coordinate) > autoDepartureDistance {
                await continueToNextStop(startNavigating: true)
                return
            }
        case .enRoute:
            await guide(with: sample)
        }
        await persistIfDue()
    }

    /// Advances guidance along the current leg (to a stop, or to the trip's start).
    private func guide(with sample: LocationSample) async {
        guard var engine else {
            if !isLoadingDirections { await prepareLeg() }
            return
        }
        if await fetchDirectionsFromCarIfAway() { return }
        if stage == .preview {
            // Show where the car is on the leg, without advancing guidance or speaking.
            guidance = engine.update(with: sample)
            updateRouteToTarget()
            return
        }
        let update = engine.update(with: sample)
        self.engine = engine
        guidance = update
        if let announcement = update.announcement, !(isHeadingToStart && update.arrival == .arrived) {
            speak(announcement)
        }
        if update.arrival == .arrived {
            if isHeadingToStart { await reachStart() } else { await arriveAtTarget() }
            return
        }
        if update.isOffRoute { await reroute(from: sample.coordinate) }
        updateRouteToTarget()
    }

    // MARK: Driver actions

    /// Starts guidance from a preview ("Start"): starts a new trip (unless heading to its start),
    /// speaks the instruction and starts following.
    public func beginNavigation() async {
        guard stage == .preview else { return }
        stage = .navigating
        if trip.progress.phase == .notStarted, !isHeadingToStart {
            try? trip.start(at: dependencies.now())
            await persist()
        }
        guard isOnLeg, let guidance else { return }
        if guidance.progress < 0.01, let departureAnnouncement {
            speak(departureAnnouncement)
        } else if guidance.upcomingManeuver == .arrive {
            speak("\(guidance.upcomingInstruction) in \(DistanceText.spoken(guidance.distanceToManeuver)).")
        } else {
            speak("In \(DistanceText.spoken(guidance.distanceToManeuver)), \(lowercasedFirst(guidance.upcomingInstruction)).")
        }
        startFollowing()
    }

    /// "I'm here": records arrival at the target stop (or at the trip's start).
    public func confirmArrival() async {
        if isHeadingToStart { await reachStart() } else { await arriveAtTarget() }
    }

    /// Starts the trip where the car is, instead of driving to the plan's start first. Directions
    /// to the first stop are fetched from the car.
    public func startTripFromHere() async {
        guard isHeadingToStart else { return }
        isHeadingToStart = false
        engine = nil
        guidance = nil
        try? trip.start(at: dependencies.now())
        await persist()
        await prepareLeg()
    }

    /// At the plan's start: the trip begins and guidance carries on to the first stop.
    private func reachStart() async {
        guard isHeadingToStart else { return }
        isHeadingToStart = false
        engine = nil
        guidance = nil
        try? trip.start(at: dependencies.now())
        speak("You've reached the start of your trip.")
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
        engine = nil
        guidance = nil
        stage = startNavigating ? .navigating : .preview
        await persist()
        if trip.progress.phase == .completed {
            speak("You have arrived at your destination.")
        } else {
            await prepareLeg()
        }
    }

    /// Skips the stop being driven to.
    public func skipTargetStop() async {
        guard (try? trip.skipTargetStop(at: dependencies.now())) != nil else { return }
        engine = nil
        guidance = nil
        // The planned leg started at the skipped stop; fetch directions from here instead.
        await persist()
        await prepareLeg(forceFetch: true)
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

    private func arriveAtTarget() async {
        guard trip.progress.phase == .enRoute else { return }
        try? trip.markArrived(at: dependencies.now())
        guidance = guidance.map { var arrived = $0; arrived.arrival = .arrived; return arrived }
        refreshRouteAfterTarget()
        updateRouteToTarget()
        previewFrame = routeToTarget
        await persist()
    }

    private func prepareLeg(forceFetch: Bool = false) async {
        refreshRouteAfterTarget()
        if isHeadingToStart, let start = trip.itinerary.stops.first {
            // There are no planned directions to the start: fetch them from the car.
            if let car = currentLocation {
                await fetchLeg(from: car, to: start)
            } else {
                updateRouteToTarget()
                previewFrame = routeToTarget
            }
            return
        }
        guard isOnLeg, let target = trip.targetStop else {
            engine = nil
            legCoordinates = []
            legGeometry = nil
            updateRouteToTarget()
            previewFrame = routeToTarget
            return
        }
        if !forceFetch, let leg = trip.legToTarget {
            // Directions start where the car is: when it is away from the planned leg (starting
            // from home, or continuing while still approaching a stop), fetch them from the car.
            if let car = currentLocation, isAway(car, from: leg) {
                await fetchLeg(from: car, to: target)
                if engine != nil { return }
            }
            install(leg, to: target)
            return
        }
        let previousIndex = max(0, trip.progress.targetStopIndex - 1)
        let start = currentLocation ?? trip.itinerary.stops[previousIndex].place.coordinate
        await fetchLeg(from: start, to: target)
    }

    private func install(_ leg: RouteLeg, to target: ItineraryStop) {
        var engine = GuidanceEngine(leg: leg, destinationName: target.place.name)
        let initial = engine.start()
        self.engine = engine
        guidance = initial
        legCoordinates = engine.coordinates
        legGeometry = PolylineGeometry(coordinates: legCoordinates)
        departureAnnouncement = initial.announcement
        // Without a position yet, the first fix is checked against the leg instead.
        hasCheckedLegStart = currentLocation != nil
        if stage == .preview, let car = currentLocation {
            // Where the car is on the leg (e.g. resuming halfway), without touching guidance state.
            var probe = engine
            guidance = probe.update(with: LocationSample(coordinate: car, timestamp: dependencies.now()))
        }
        updateRouteToTarget()
        previewFrame = routeToTarget
        if stage == .navigating {
            if let announcement = initial.announcement { speak(announcement) }
            startFollowing()
        }
    }

    /// Hands the leg to a route-following (simulated) location source.
    private func startFollowing() {
        (dependencies.location as? any RouteFollowingLocationProvider)?.follow(legCoordinates)
    }

    private func isAway(_ car: GeoCoordinate, from leg: RouteLeg) -> Bool {
        let geometry = PolylineGeometry(coordinates: (try? PolylineCodec.decode(leg.encodedPolyline)) ?? [])
        return geometry.project(car).map { $0.offsetMeters > legStartTolerance } ?? false
    }

    /// The first fix of a leg loaded before the position was known: when the car is well away
    /// from the leg, fetches directions from the car (once per leg).
    private func fetchDirectionsFromCarIfAway() async -> Bool {
        guard !hasCheckedLegStart, isOnLeg, let car = currentLocation,
              let legGeometry, let target = guidedStop else { return false }
        hasCheckedLegStart = true
        guard let projection = legGeometry.project(car), projection.offsetMeters > legStartTolerance else { return false }
        await fetchLeg(from: car, to: target)
        hasCheckedLegStart = true
        return true
    }

    /// The route from the car (or, at a stop, from the stop) to the next stop.
    private func updateRouteToTarget() {
        if isHeadingToStart || trip.progress.phase == .enRoute || trip.progress.phase == .notStarted {
            guard let legGeometry, legGeometry.coordinates.count > 1 else {
                // No directions yet: the planned leg, or a straight line to the start.
                if isHeadingToStart {
                    routeToTarget = [currentLocation, trip.itinerary.stops.first?.place.coordinate].compactMap { $0 }
                } else {
                    routeToTarget = trip.legToTarget.flatMap { try? PolylineCodec.decode($0.encodedPolyline) } ?? []
                }
                return
            }
            let along = (guidance?.progress ?? 0) * legGeometry.totalLength
            var ahead = legGeometry.slice(from: along, to: legGeometry.totalLength)
            if ahead.isEmpty, let last = legGeometry.coordinates.last { ahead = [last] }
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

    private func fetchLeg(from start: GeoCoordinate, to target: ItineraryStop) async {
        isLoadingDirections = true
        defer { isLoadingDirections = false }
        do {
            let routes = try await dependencies.routing.computeRoutes(RouteQuery(
                origin: start, destination: target.place.coordinate, departure: nil
            ))
            guard let leg = routes.first?.legs.first else { throw PlanningError.noRoute }
            // The trip may have moved on while directions were loading.
            guard guidedStop?.id == target.id, isOnLeg else { return }
            if !isHeadingToStart { trip.rerouteLegs[trip.progress.targetStopIndex - 1] = leg }
            install(leg, to: target)
            statusMessage = nil
            await persist()
        } catch {
            statusMessage = "Directions are unavailable right now. Use “Open in Google Maps” or try again."
        }
    }

    private func reroute(from coordinate: GeoCoordinate) async {
        let now = dependencies.now()
        if let lastReroute, now.timeIntervalSince(lastReroute) < rerouteCooldown { return }
        guard let target = guidedStop, !isRerouting else { return }
        lastReroute = now
        isRerouting = true
        defer { isRerouting = false }
        speak("Rerouting.")
        await fetchLeg(from: coordinate, to: target)
    }

    private func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    private func speak(_ text: String) {
        guard !isMuted else { return }
        dependencies.speech.speak(text)
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
