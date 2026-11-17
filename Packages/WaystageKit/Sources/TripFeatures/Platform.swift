import Foundation
import TripModels
import TripNavigation

/// Location permission state, independent of CoreLocation.
public enum LocationAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
}

/// Device location, implemented with CoreLocation in the app and simulated in tests.
@MainActor
public protocol LocationProviding: AnyObject {
    var authorization: LocationAuthorization { get }
    var lastKnownLocation: GeoCoordinate? { get }
    func requestAuthorization() async -> LocationAuthorization
    /// The device's position now: a recent fix if there is one, otherwise a fresh one. Nil when
    /// location access is off or no fix arrives in time. Doesn't ask for permission.
    func requestLocation() async -> GeoCoordinate?
    /// Starts location updates. The stream ends when `stopUpdates()` is called.
    func startUpdates() -> AsyncStream<LocationSample>
    func stopUpdates()
}

/// A location source that can drive along a path (sandbox/demo mode only).
@MainActor
public protocol RouteFollowingLocationProvider: LocationProviding {
    func follow(_ coordinates: [GeoCoordinate])
    /// Parks the car where it is.
    func stopFollowing()
}

/// Spoken prompts of the offline simulation (made-up data only: Google content is never passed
/// to a speech synthesizer; in the App Store build the Navigation SDK speaks its own guidance).
@MainActor
public protocol SpeechAnnouncing: AnyObject {
    func speak(_ text: String)
    func stopSpeaking()
}
