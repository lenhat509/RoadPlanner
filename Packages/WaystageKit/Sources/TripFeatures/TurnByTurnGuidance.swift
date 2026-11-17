import Foundation
import TripModels
import TripNavigation

/// The navigation engine drive mode hands each leg to.
///
/// In the App Store build this is Google's Navigation SDK: it computes the route from the phone's
/// position, draws it with the car and the turn-by-turn header on its own map, speaks the
/// directions, reroutes and detects arrival. Google's terms don't allow rebuilding that from the
/// Routes API and the Maps SDK, or speaking Google content with a speech synthesizer (see
/// docs/COMPLIANCE.md), so the app does none of it itself.
///
/// Offline (demo mode without a key, unit and UI tests) a simulation stands in, on made-up data
/// (`TripSandbox.SimulatedGuidance`).
@MainActor
public protocol TurnByTurnGuidance: AnyObject {
    /// The engine draws the route, the car and the turn instructions on its own map (Google's
    /// Navigation SDK); drive mode then doesn't draw them.
    var drawsOwnGuidance: Bool { get }
    /// Receives every event, in order. Drive mode sets it when it opens.
    var eventHandler: (@MainActor (GuidanceEvent) async -> Void)? { get set }
    /// Voice guidance off.
    var isMuted: Bool { get set }
    /// Readies the engine. The first time, Google's Navigation SDK shows its terms, which the
    /// driver must accept before it can guide (`GuidanceError.termsNotAccepted`).
    func prepare() async throws
    /// Loads the route to `destination` from where the car is, without guiding (the leg's
    /// preview). `origin` is the car's last known position (the simulation starts there; Google
    /// uses the phone's own).
    func setDestination(_ destination: GuidanceDestination, from origin: GeoCoordinate?) async throws -> GuidanceRoute
    /// Starts turn-by-turn guidance along the loaded route.
    func startGuidance() async
    /// Stops guidance and clears the route.
    func stopGuidance()
    /// A location fix from the app's location provider (the simulation advances on it; Google
    /// follows the phone itself and ignores it).
    func didUpdateLocation(_ sample: LocationSample) async
}

/// Where guidance leads.
public struct GuidanceDestination: Equatable, Sendable {
    public var name: String
    public var coordinate: GeoCoordinate
    /// The Google Place ID, when the stop came from Google (better arrival points).
    public var placeID: String?

    public init(name: String, coordinate: GeoCoordinate, placeID: String? = nil) {
        self.name = name
        self.coordinate = coordinate
        self.placeID = placeID
    }

    public init(_ place: Place) {
        self.init(name: place.name, coordinate: place.coordinate, placeID: place.googlePlaceID)
    }
}

/// The route guidance follows, from the car to the destination. Kept in memory only.
public struct GuidanceRoute: Equatable, Sendable {
    public var coordinates: [GeoCoordinate]
    public var distanceMeters: Double
    public var duration: TimeInterval

    public init(coordinates: [GeoCoordinate], distanceMeters: Double, duration: TimeInterval) {
        self.coordinates = coordinates
        self.distanceMeters = distanceMeters
        self.duration = duration
    }
}

/// The next maneuver, for engines that don't draw their own (the simulation).
public struct GuidanceInstruction: Equatable, Sendable {
    public var maneuver: Maneuver
    public var text: String
    public var distanceToManeuver: Double
    /// The maneuver right after this one, and how far after it.
    public var followingManeuver: Maneuver?
    public var distanceBetweenManeuvers: Double?

    public init(
        maneuver: Maneuver, text: String, distanceToManeuver: Double,
        followingManeuver: Maneuver? = nil, distanceBetweenManeuvers: Double? = nil
    ) {
        self.maneuver = maneuver
        self.text = text
        self.distanceToManeuver = distanceToManeuver
        self.followingManeuver = followingManeuver
        self.distanceBetweenManeuvers = distanceBetweenManeuvers
    }
}

public enum GuidanceEvent: Equatable, Sendable {
    /// Distance and driving time left to the destination.
    case progress(distanceRemaining: Double, timeRemaining: TimeInterval)
    /// A new route to the same destination (after a reroute, or a faster one).
    case routeChanged(GuidanceRoute)
    /// Looking for a new route after leaving the current one.
    case rerouting(Bool)
    /// The next maneuver (only from engines that don't draw their own).
    case instruction(GuidanceInstruction?)
    /// At the destination.
    case arrived
}

public enum GuidanceError: Error, Equatable, Sendable {
    /// Google's Navigation SDK terms were declined.
    case termsNotAccepted
    /// No route to the destination.
    case noRoute
    /// The phone's position isn't known yet.
    case locationUnavailable
    /// No connection.
    case network
    /// The API key isn't allowed to use the Navigation SDK, or the quota is used up.
    case notAuthorized
    /// A newer request replaced this one.
    case canceled
    case failed(String)

    /// What drive mode tells the driver.
    public var message: String {
        switch self {
        case .termsNotAccepted:
            "Turn-by-turn directions need Google's navigation terms. They're shown again the next time you open a trip."
        case .noRoute:
            "No driving route was found to this stop. Use “Open in Google Maps” or skip the stop."
        case .locationUnavailable:
            "Waiting for your location. Directions start once it's found."
        case .network:
            "Directions need a connection. They'll load when you're back online."
        case .notAuthorized:
            "Directions are unavailable right now. Use “Open in Google Maps”."
        case .canceled:
            ""
        case .failed:
            "Directions are unavailable right now. Use “Open in Google Maps” or try again."
        }
    }
}
