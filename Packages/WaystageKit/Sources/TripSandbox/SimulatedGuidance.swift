import Foundation
import TripFeatures
import TripModels
import TripNavigation
import TripPlanner

/// Turn-by-turn navigation for the offline sandbox (demo mode without a key, unit and UI tests):
/// routes from the simulated backend, followed by `GuidanceEngine`, with the simulated car
/// driving each leg and prompts spoken through `SpeechAnnouncing`.
///
/// Only ever used with made-up data. The App Store build navigates with Google's Navigation SDK.
@MainActor
public final class SimulatedGuidance: TurnByTurnGuidance {
    public let drawsOwnGuidance = false
    public var eventHandler: (@MainActor (GuidanceEvent) async -> Void)?
    public var isMuted = false {
        didSet { if isMuted { speech.stopSpeaking() } }
    }

    /// Simulates the driver declining the navigation terms.
    public var declinesTerms = false
    /// Minimum time between reroutes.
    public var rerouteCooldown: TimeInterval = 20
    /// The first fix of a leg farther than this from its start reroutes from the car at once.
    public var startTolerance: Double = 300
    public private(set) var isGuiding = false
    public private(set) var prepareCount = 0
    public private(set) var destination: GuidanceDestination?

    private let routing: any RoutingProvider
    private let location: any LocationProviding
    private let speech: any SpeechAnnouncing
    private let now: @Sendable () -> Date
    private var engine: GuidanceEngine?
    private var route: GuidanceRoute?
    private var departureAnnouncement: String?
    private var lastUpdate: GuidanceUpdate?
    private var hasCheckedStart = false
    private var lastReroute: Date?
    private var isRerouting = false
    /// Bumped by every new destination, so a slow request for an old one is dropped.
    private var generation = 0

    public init(
        routing: any RoutingProvider,
        location: any LocationProviding,
        speech: any SpeechAnnouncing,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.routing = routing
        self.location = location
        self.speech = speech
        self.now = now
    }

    public func prepare() async throws {
        prepareCount += 1
        if declinesTerms { throw GuidanceError.termsNotAccepted }
    }

    public func setDestination(_ destination: GuidanceDestination, from origin: GeoCoordinate?) async throws -> GuidanceRoute {
        stopGuidance()
        generation += 1
        let request = generation
        self.destination = destination
        guard let origin else { throw GuidanceError.locationUnavailable }
        let leg = try await fetchLeg(from: origin, to: destination)
        guard request == generation else { throw GuidanceError.canceled }
        install(leg, to: destination)
        hasCheckedStart = false
        return route!
    }

    public func startGuidance() async {
        guard let engine, !isGuiding else { return }
        isGuiding = true
        let update = lastUpdate
        if let update, update.progress >= 0.01 {
            if update.upcomingManeuver == .arrive {
                speak("\(update.upcomingInstruction) in \(DistanceText.spoken(update.distanceToManeuver)).")
            } else {
                speak("In \(DistanceText.spoken(update.distanceToManeuver)), \(Self.lowercasedFirst(update.upcomingInstruction)).")
            }
        } else if let departureAnnouncement {
            speak(departureAnnouncement)
        }
        (location as? any RouteFollowingLocationProvider)?.follow(engine.coordinates)
        if let update { await emit(.instruction(Self.instruction(from: update))) }
    }

    public func stopGuidance() {
        let wasActive = isGuiding || engine != nil
        isGuiding = false
        engine = nil
        route = nil
        lastUpdate = nil
        destination = nil
        departureAnnouncement = nil
        generation += 1
        if wasActive {
            speech.stopSpeaking()
            (location as? any RouteFollowingLocationProvider)?.stopFollowing()
        }
    }

    public func didUpdateLocation(_ sample: LocationSample) async {
        guard var engine else { return }
        if !hasCheckedStart {
            hasCheckedStart = true
            // The leg was loaded from somewhere else (no position yet): route from the car.
            if let projection = PolylineGeometry(coordinates: engine.coordinates).project(sample.coordinate),
               projection.offsetMeters > startTolerance {
                await reroute(from: sample.coordinate, force: true)
                return
            }
        }
        guard isGuiding else {
            // Preview: where the car is on the leg, without advancing guidance or speaking.
            var probe = engine
            let update = probe.update(with: sample)
            await emit(.progress(distanceRemaining: update.distanceRemaining, timeRemaining: update.timeRemaining))
            return
        }
        let update = engine.update(with: sample)
        self.engine = engine
        lastUpdate = update
        if let announcement = update.announcement { speak(announcement) }
        await emit(.progress(distanceRemaining: update.distanceRemaining, timeRemaining: update.timeRemaining))
        await emit(.instruction(Self.instruction(from: update)))
        if update.arrival == .arrived {
            isGuiding = false
            await emit(.arrived)
            return
        }
        if update.isOffRoute { await reroute(from: sample.coordinate) }
    }

    // MARK: Internals

    private func install(_ leg: RouteLeg, to destination: GuidanceDestination) {
        var engine = GuidanceEngine(leg: leg, destinationName: destination.name)
        let initial = engine.start()
        self.engine = engine
        lastUpdate = initial
        departureAnnouncement = initial.announcement
        route = GuidanceRoute(coordinates: engine.coordinates, distanceMeters: engine.totalDistance, duration: leg.duration)
    }

    private func reroute(from coordinate: GeoCoordinate, force: Bool = false) async {
        let time = now()
        if !force, let lastReroute, time.timeIntervalSince(lastReroute) < rerouteCooldown { return }
        guard let destination, !isRerouting else { return }
        lastReroute = time
        isRerouting = true
        defer { isRerouting = false }
        let request = generation
        await emit(.rerouting(true))
        if isGuiding { speak("Rerouting.") }
        if let leg = try? await fetchLeg(from: coordinate, to: destination), request == generation {
            let wasGuiding = isGuiding
            install(leg, to: destination)
            if let route { await emit(.routeChanged(route)) }
            if let lastUpdate {
                await emit(.progress(distanceRemaining: lastUpdate.distanceRemaining, timeRemaining: lastUpdate.timeRemaining))
                if wasGuiding { await emit(.instruction(Self.instruction(from: lastUpdate))) }
            }
            if wasGuiding, let engine {
                (location as? any RouteFollowingLocationProvider)?.follow(engine.coordinates)
            }
        }
        await emit(.rerouting(false))
    }

    private func fetchLeg(from origin: GeoCoordinate, to destination: GuidanceDestination) async throws -> RouteLeg {
        let routes: [ComputedRoute]
        do {
            routes = try await routing.computeRoutes(RouteQuery(origin: origin, destination: destination.coordinate, departure: nil))
        } catch {
            throw GuidanceError.network
        }
        guard let leg = routes.first?.legs.first else { throw GuidanceError.noRoute }
        return leg
    }

    private func emit(_ event: GuidanceEvent) async {
        await eventHandler?(event)
    }

    private func speak(_ text: String) {
        guard isGuiding, !isMuted else { return }
        speech.speak(text)
    }

    private static func instruction(from update: GuidanceUpdate) -> GuidanceInstruction {
        GuidanceInstruction(
            maneuver: update.upcomingManeuver,
            text: update.upcomingInstruction,
            distanceToManeuver: update.distanceToManeuver,
            followingManeuver: update.followingManeuver,
            distanceBetweenManeuvers: update.distanceBetweenManeuvers
        )
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
