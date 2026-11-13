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
        driveTask = Task { [weak self] in
            var distance = 0.0
            while !Task.isCancelled {
                let point = geometry.coordinate(atDistance: distance)
                let ahead = geometry.coordinate(atDistance: distance + 10)
                self?.send(LocationSample(
                    coordinate: point, horizontalAccuracy: 5, speed: step / interval,
                    course: GeoMath.bearing(from: point, to: ahead), timestamp: Date()
                ))
                if distance >= geometry.totalLength { break }
                distance = min(geometry.totalLength, distance + step)
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
