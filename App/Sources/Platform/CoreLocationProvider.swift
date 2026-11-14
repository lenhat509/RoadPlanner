import CoreLocation
import Foundation
import TripFeatures
import TripModels
import TripNavigation

/// CoreLocation adapter tuned for in-car navigation.
@MainActor
final class CoreLocationProvider: NSObject, LocationProviding {
    private let manager = CLLocationManager()
    private var continuation: AsyncStream<LocationSample>.Continuation?
    private var authorizationWaiters: [CheckedContinuation<LocationAuthorization, Never>] = []
    /// One-shot requests waiting for a fix (see `requestLocation()`).
    private var locationWaiters: [UUID: CheckedContinuation<GeoCoordinate?, Never>] = [:]
    private(set) var lastKnownLocation: GeoCoordinate?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
        lastKnownLocation = manager.location.map { GeoCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
    }

    var authorization: LocationAuthorization { Self.map(manager.authorizationStatus) }

    func requestAuthorization() async -> LocationAuthorization {
        guard manager.authorizationStatus == .notDetermined else { return authorization }
        return await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    /// How long a one-shot request waits for a fix.
    static let locationRequestTimeout: TimeInterval = 15
    /// A cached fix this recent and accurate is good enough for a trip's start.
    static let recentFixAge: TimeInterval = 120
    static let usableAccuracy: Double = 1_000

    func requestLocation() async -> GeoCoordinate? {
        guard authorization == .authorized else { return nil }
        if let location = manager.location, Self.isUsable(location, now: Date()) {
            let coordinate = GeoCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            lastKnownLocation = coordinate
            return coordinate
        }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            locationWaiters[id] = continuation
            manager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.locationRequestTimeout * 1_000_000_000))
                self?.locationWaiters.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    static func isUsable(_ location: CLLocation, now: Date) -> Bool {
        now.timeIntervalSince(location.timestamp) < recentFixAge
            && location.horizontalAccuracy >= 0 && location.horizontalAccuracy < usableAccuracy
    }

    func startUpdates() -> AsyncStream<LocationSample> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: LocationSample.self, bufferingPolicy: .bufferingNewest(10))
        self.continuation = continuation
        if authorization == .authorized {
            // Requires the "location" background mode (Info.plist) — guidance continues when locked.
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
        return stream
    }

    func stopUpdates() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        continuation?.finish()
        continuation = nil
    }

    // MARK: Mapping (internal for unit tests)

    static func map(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: .authorized
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    static func sample(from location: CLLocation) -> LocationSample {
        LocationSample(
            coordinate: GeoCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
            horizontalAccuracy: location.horizontalAccuracy,
            speed: location.speed,
            course: location.course,
            timestamp: location.timestamp
        )
    }

    fileprivate func deliver(_ samples: [LocationSample]) {
        for sample in samples where sample.horizontalAccuracy >= 0 && sample.horizontalAccuracy < 200 {
            lastKnownLocation = sample.coordinate
            continuation?.yield(sample)
        }
        // One-shot requests take any usable fix (a rough one is fine for a trip's start).
        if let fix = samples.last(where: { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy < Self.usableAccuracy }) {
            if lastKnownLocation == nil { lastKnownLocation = fix.coordinate }
            resolveLocationWaiters(with: fix.coordinate)
        }
    }

    fileprivate func resolveLocationWaiters(with coordinate: GeoCoordinate?) {
        let waiters = locationWaiters
        locationWaiters.removeAll()
        waiters.values.forEach { $0.resume(returning: coordinate) }
    }

    fileprivate func authorizationDidChange(_ status: CLAuthorizationStatus) {
        guard status != .notDetermined else { return }
        let result = Self.map(status)
        let waiters = authorizationWaiters
        authorizationWaiters.removeAll()
        waiters.forEach { $0.resume(returning: result) }
    }
}

extension CoreLocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let samples = locations.map(CoreLocationProvider.sample(from:))
        Task { @MainActor in self.deliver(samples) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationDidChange(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Continuous updates carry on after transient failures (e.g. kCLErrorLocationUnknown), but
        // a one-shot request has ended: answer it now rather than at its timeout.
        Task { @MainActor in self.resolveLocationWaiters(with: nil) }
    }
}
