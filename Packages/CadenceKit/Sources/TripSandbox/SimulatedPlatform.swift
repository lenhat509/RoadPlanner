import Foundation
import TripFeatures
import TripModels
import TripNavigation

/// Simulated GPS. Tests push fixes with `send(_:)`; in demo / UI-test mode it can drive
/// along each leg automatically (`autoDrive`).
@MainActor
public final class SimulatedLocationProvider: RouteFollowingLocationProvider {
    public var authorization: LocationAuthorization
    public private(set) var lastKnownLocation: GeoCoordinate?
    /// Drive automatically along legs handed to `follow(_:)`.
    public var autoDrive: Bool
    public var metersPerTick: Double
    public var tickInterval: TimeInterval
    /// When set, the simulated car parks after driving this far on each leg (screenshots need a
    /// still screen).
    public var parksAfterMeters: Double?
    /// Seconds the car waits before driving off on a new leg (lets the app's camera settle on it,
    /// as a real driver pressing Start is still standing).
    public var departureDelay: TimeInterval = 0
    public private(set) var isUpdating = false

    private var continuation: AsyncStream<LocationSample>.Continuation?
    private var driveTask: Task<Void, Never>?

    public init(
        start: GeoCoordinate? = nil,
        authorization: LocationAuthorization = .authorized,
        autoDrive: Bool = false,
        metersPerTick: Double = 2_000,
        tickInterval: TimeInterval = 0.1
    ) {
        self.lastKnownLocation = start
        self.authorization = authorization
        self.autoDrive = autoDrive
        self.metersPerTick = metersPerTick
        self.tickInterval = tickInterval
    }

    public func requestAuthorization() async -> LocationAuthorization {
        if authorization == .notDetermined { authorization = .authorized }
        return authorization
    }

    /// What a one-shot request finds when no position is known yet (nil: the device finds none).
    public var fixOnRequest: GeoCoordinate?

    public func requestLocation() async -> GeoCoordinate? {
        guard authorization == .authorized else { return nil }
        if lastKnownLocation == nil { lastKnownLocation = fixOnRequest }
        return lastKnownLocation
    }

    public func startUpdates() -> AsyncStream<LocationSample> {
        isUpdating = true
        let (stream, continuation) = AsyncStream.makeStream(of: LocationSample.self)
        self.continuation = continuation
        return stream
    }

    public func stopUpdates() {
        isUpdating = false
        driveTask?.cancel()
        driveTask = nil
        continuation?.finish()
        continuation = nil
    }

    /// Emits a fix.
    public func send(_ sample: LocationSample) {
        lastKnownLocation = sample.coordinate
        continuation?.yield(sample)
    }

    public func follow(_ coordinates: [GeoCoordinate]) {
        guard autoDrive, coordinates.count > 1 else { return }
        driveTask?.cancel()
        let geometry = PolylineGeometry(coordinates: coordinates)
        let step = metersPerTick, interval = tickInterval
        // Carry on from where the car is when it is on the leg (resuming mid-leg); otherwise
        // start at the beginning.
        var startDistance = 0.0
        if let here = lastKnownLocation, let projection = geometry.project(here), projection.offsetMeters < 500 {
            startDistance = projection.distanceAlong
        }
        let end = min(geometry.totalLength, startDistance + (parksAfterMeters ?? .infinity))
        let delay = departureDelay
        driveTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            var distance = startDistance
            while !Task.isCancelled {
                let point = geometry.coordinate(atDistance: distance)
                let ahead = geometry.coordinate(atDistance: distance + 10)
                self?.send(LocationSample(
                    coordinate: point, horizontalAccuracy: 5, speed: step / interval,
                    course: GeoMath.bearing(from: point, to: ahead), timestamp: Date()
                ))
                if distance >= end { break }
                distance = min(end, distance + step)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
            }
        }
    }
}

/// Collects spoken prompts instead of speaking them.
@MainActor
public final class RecordingSpeechAnnouncer: SpeechAnnouncing {
    public private(set) var spoken: [String] = []
    public private(set) var stopCount = 0

    public init() {}

    public func speak(_ text: String) { spoken.append(text) }

    public func stopSpeaking() { stopCount += 1 }
}
