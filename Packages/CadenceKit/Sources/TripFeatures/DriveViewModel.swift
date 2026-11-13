import Foundation
import Observation
import TripModels
import TripNavigation
import TripPlanner

/// Turn-by-turn drive mode. Follows the driver to each stop, offers "Continue to next stop"
/// when close to / at a stop, reroutes when off course and auto-saves progress.
@MainActor
@Observable
public final class DriveViewModel {
    public struct Banner: Equatable, Sendable {
        public var symbolName: String
        public var distanceText: String
        public var instruction: String

        public init(symbolName: String, distanceText: String, instruction: String) {
            self.symbolName = symbolName
            self.distanceText = distanceText
            self.instruction = instruction
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
            self.plannedAction = plannedAction
            self.isDestination = isDestination
        }
    }

    public enum Mode: Equatable, Sendable {
        case driving
        case atStop
        case completed
    }

    public private(set) var trip: ActiveTrip
    public private(set) var guidance: GuidanceUpdate?
    public private(set) var currentLocation: GeoCoordinate?
    public private(set) var currentCourse: Double?
    public private(set) var legCoordinates: [GeoCoordinate] = []
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

    /// How often location-only progress is persisted.
    public var saveInterval: TimeInterval = 30
    /// Minimum time between reroute requests.
    public var rerouteCooldown: TimeInterval = 20
    /// Driving this far from a stop (at speed) counts as leaving it.
    public var autoDepartureDistance: Double = 400

    public init(trip: ActiveTrip, dependencies: AppDependencies) {
        self.trip = trip
        self.dependencies = dependencies
        self.isMuted = !dependencies.preferences.load().voiceGuidanceEnabled
    }

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

    public var banner: Banner? {
        guard mode == .driving, let guidance else { return nil }
        return Banner(
            symbolName: guidance.upcomingManeuver.symbolName,
            distanceText: DistanceText.short(guidance.distanceToManeuver),
            instruction: guidance.upcomingInstruction
        )
    }

    public var nextStop: NextStopInfo? {
        guard let target = trip.targetStop else { return nil }
        let formatters = dependencies.formatters
        let now = dependencies.now()
        let eta: Date? = switch trip.progress.phase {
        case .enRoute: guidance.map { now.addingTimeInterval($0.timeRemaining) } ?? target.arrival
        default: trip.progress.actualArrivals[target.id] ?? target.arrival
        }
        let presentation = StopPresentation(stop: target, formatters: formatters)
        return NextStopInfo(
            kind: target.kind,
            isPullOff: target.isRoadsidePullOff,
            name: target.place.name,
            kindTitle: target.isRoadsidePullOff ? "Rest break" : target.kind.displayName,
            symbolName: presentation.symbolName,
            etaText: eta.map { formatters.clockTime($0, utcOffsetSeconds: target.place.utcOffsetSeconds) } ?? "—",
            remainingText: guidance.map { formatters.distance($0.distanceRemaining) } ?? "",
            plannedAction: presentation.detail,
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
                return StopPresentation(stop: adjusted, formatters: dependencies.formatters)
            }
    }

    /// Hand-off link to the Google Maps app for the current leg.
    public var googleMapsURL: URL? {
        guard let target = trip.targetStop else { return nil }
        return ExternalLinks.googleMapsDirections(from: currentLocation, to: target.place)
    }

    // MARK: Lifecycle

    /// Starts (or resumes) the drive: begins location updates and loads directions.
    public func start() async {
        if trip.progress.phase == .notStarted {
            try? trip.start(at: dependencies.now())
            await persist()
        }
        if dependencies.location.authorization != .authorized {
            let authorization = await dependencies.location.requestAuthorization()
            if authorization == .denied {
                statusMessage = "Location access is off. Turn it on in Settings for turn-by-turn guidance."
            }
        }
        currentLocation = dependencies.location.lastKnownLocation ?? trip.progress.lastKnownLocation
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
        case .notStarted, .completed:
            break
        case .atStop:
            // Driving away from the stop starts the next leg automatically.
            if let stop = trip.targetStop, sample.speed > 4,
               GeoMath.distance(sample.coordinate, stop.place.coordinate) > autoDepartureDistance {
                await continueToNextStop()
                return
            }
        case .enRoute:
            guard var engine else {
                if !isLoadingDirections { await prepareLeg() }
                return
            }
            let update = engine.update(with: sample)
            self.engine = engine
            guidance = update
            if let announcement = update.announcement { speak(announcement) }
            if update.arrival == .arrived {
                await arriveAtTarget()
                return
            }
            if update.isOffRoute { await reroute(from: sample.coordinate) }
        }
        await persistIfDue()
    }

    // MARK: Driver actions

    /// "I'm here": records arrival at the target stop.
    public func confirmArrival() async {
        await arriveAtTarget()
    }

    /// Leaves the current stop (or the one being approached) for the next one.
    public func continueToNextStop() async {
        do {
            try trip.continueToNextStop(at: dependencies.now())
        } catch {
            return
        }
        engine = nil
        guidance = nil
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
        await persist()
    }

    private func prepareLeg(forceFetch: Bool = false) async {
        guard trip.progress.phase == .enRoute, let target = trip.targetStop else {
            engine = nil
            legCoordinates = []
            return
        }
        if !forceFetch, let leg = trip.legToTarget {
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
        if let announcement = initial.announcement { speak(announcement) }
        (dependencies.location as? any RouteFollowingLocationProvider)?.follow(legCoordinates)
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
            guard trip.targetStop?.id == target.id, trip.progress.phase == .enRoute else { return }
            trip.rerouteLegs[trip.progress.targetStopIndex - 1] = leg
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
        guard let target = trip.targetStop, !isRerouting else { return }
        lastReroute = now
        isRerouting = true
        defer { isRerouting = false }
        speak("Rerouting.")
        await fetchLeg(from: coordinate, to: target)
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
