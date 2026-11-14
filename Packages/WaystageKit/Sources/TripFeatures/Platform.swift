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
}

/// Spoken guidance, implemented with AVSpeechSynthesizer in the app.
@MainActor
public protocol SpeechAnnouncing: AnyObject {
    func speak(_ text: String)
    func stopSpeaking()
}
