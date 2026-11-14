import MapKit
import SwiftUI
import TripFeatures
import TripModels

/// Which map engine draws routes. Google Maps needs an API key; without one (demo mode, UI tests)
/// Apple Maps is used so the route preview always shows a real map.
enum MapProvider {
    case google
    case apple
}

private struct MapProviderKey: EnvironmentKey {
    static let defaultValue = MapProvider.apple
}

extension EnvironmentValues {
    var mapProvider: MapProvider {
        get { self[MapProviderKey.self] }
        set { self[MapProviderKey.self] = newValue }
    }
}

/// A one-off request to move the map (from the map buttons). A new value is a new request.
struct MapCommand: Equatable {
    enum Action: Equatable {
        case zoomIn
        case zoomOut
        /// Fit everything on the map.
        case fitRoute
        /// Go back to what the current camera asks for (e.g. the previewed leg) after the user
        /// zoomed or panned.
        case reapplyCamera
    }

    let action: Action
    let id = UUID()
}

/// Route map that renders with the configured provider.
///
/// `paths[0]` is the route being driven (drawn strong, with a darker edge); any further paths are
/// the rest of the trip (drawn lighter, underneath).
struct RouteMap: View {
    var paths: [[GeoCoordinate]]
    var markers: [MapStopMarker]
    var camera: TripMapView.Camera = .overview
    /// The parts of the map covered by the screen's own UI; framed routes stay clear of them.
    var chrome = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    var vehicle: TripMapView.Vehicle?
    /// The user's position when it is not the car being guided (e.g. on the plan screen).
    var userLocation: GeoCoordinate?
    var command: MapCommand?
    /// Called when the user pans, zooms or rotates the map by hand.
    var onUserMoved: (() -> Void)?

    @Environment(\.mapProvider) private var provider

    var body: some View {
        switch provider {
        case .google:
            TripMapView(
                paths: paths, markers: markers, camera: camera, chrome: chrome, vehicle: vehicle,
                userLocation: userLocation, command: command, onUserMoved: onUserMoved
            )
        case .apple:
            AppleRouteMap(
                paths: paths, markers: markers, camera: camera, chrome: chrome, vehicle: vehicle,
                userLocation: userLocation, command: command, onUserMoved: onUserMoved
            )
        }
    }
}

/// The latest camera, updated continuously without re-rendering the view (zoom buttons and flights
/// start from it).
@MainActor
private final class CameraTracker {
    var camera: MapCamera?
    /// Visible height in meters per meter of camera distance, measured from the map (flights need
    /// it to turn a framed rect into a camera).
    var heightPerDistance: Double?

    func update(_ context: MapCameraUpdateContext) {
        camera = context.camera
        guard context.camera.pitch < 1, context.camera.distance > 0, context.rect.height > 0 else { return }
        let latitude = context.camera.centerCoordinate.latitude
        heightPerDistance = context.rect.height / MKMapPointsPerMeterAtLatitude(latitude) / context.camera.distance
    }
}

/// A flight in progress: the trigger of the map's keyframe animation.
private struct AppleFlight: Equatable {
    let id = UUID()
    let target: CameraFlight.Camera
    let kind: CameraFlight.Kind
    let duration: TimeInterval

    /// Keyframes per second (between them the camera moves in straight lines, which keeps a
    /// flight's promise: see `CameraFlight`).
    static let samplesPerSecond = 30.0

    /// The flight's cameras after `initial` (the camera on screen when it starts).
    func samples(from initial: MapCamera) -> [CameraFlight.Camera] {
        let start = CameraFlight.Camera(
            center: GeoCoordinate(initial.centerCoordinate), scale: initial.distance,
            heading: initial.heading, pitch: initial.pitch
        )
        let count = max(2, Int((duration * Self.samplesPerSecond).rounded()) + 1)
        return Array(CameraFlight(from: start, to: target, kind: kind).samples(count: count).dropFirst())
    }

    var finalCamera: MapCamera {
        MapCamera(centerCoordinate: target.center.clCoordinate, distance: target.scale, heading: target.heading, pitch: target.pitch)
    }
}

/// Apple Maps (MapKit for SwiftUI) rendering of the same route, markers and camera.
struct AppleRouteMap: View {
    var paths: [[GeoCoordinate]]
    var markers: [MapStopMarker]
    var camera: TripMapView.Camera
    var chrome: UIEdgeInsets
    var vehicle: TripMapView.Vehicle?
    var userLocation: GeoCoordinate?
    var command: MapCommand?
    var onUserMoved: (() -> Void)?

    @State private var position: MapCameraPosition
    @State private var shownVehicle: TripMapView.Vehicle?
    @State private var viewSize = CGSize.zero
    /// The map's heading after the last move (to point the car arrow along its course).
    @State private var heading = 0.0
    @State private var tracker = CameraTracker()
    /// The camera last applied; nil until the map has a size and has been placed.
    @State private var appliedCamera: TripMapView.Camera?
    @State private var lastFix = Date.distantPast
    @State private var lastVehicleFix = Date.distantPast
    @State private var flight: AppleFlight?
    @State private var flightEnds = Date.distantPast
    /// A flight the user interrupted by moving the map (it isn't finished off).
    @State private var interruptedFlight: UUID?

    init(
        paths: [[GeoCoordinate]], markers: [MapStopMarker], camera: TripMapView.Camera, chrome: UIEdgeInsets,
        vehicle: TripMapView.Vehicle?, userLocation: GeoCoordinate?, command: MapCommand?, onUserMoved: (() -> Void)?
    ) {
        self.paths = paths
        self.markers = markers
        self.camera = camera
        self.chrome = chrome
        self.vehicle = vehicle
        self.userLocation = userLocation
        self.command = command
        self.onUserMoved = onUserMoved
        // Start close to the right place before the map knows its size (no flash of the world).
        _position = State(initialValue: Self.approximatePosition(for: camera))
        _shownVehicle = State(initialValue: vehicle)
    }

    var body: some View {
        Map(position: $position) {
            ForEach(paths.indices.dropFirst(), id: \.self) { index in
                MapPolyline(coordinates: paths[index].map(\.clCoordinate))
                    .stroke(Theme.routeLineMuted, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let route = paths.first, route.count > 1 {
                let coordinates = route.map(\.clCoordinate)
                MapPolyline(coordinates: coordinates)
                    .stroke(Theme.routeCasing, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: coordinates)
                    .stroke(Theme.routeLine, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            ForEach(markers, id: \.id) { marker in
                Annotation(marker.title, coordinate: marker.coordinate.clCoordinate, anchor: .center) {
                    StopDot(kind: marker.kind, isPullOff: marker.isPullOff, size: marker.isActive ? 22 : 16)
                }
                .annotationTitles(.hidden)
            }
            if let userLocation {
                Annotation("You are here", coordinate: userLocation.clCoordinate, anchor: .center) {
                    UserLocationDot()
                }
                .annotationTitles(.hidden)
            }
            if let shownVehicle {
                Annotation("Your car", coordinate: shownVehicle.coordinate.clCoordinate, anchor: .center) {
                    VehicleArrow(rotation: vehicleRotation(shownVehicle))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass().mapControlVisibility(.hidden) }
        .onMapCameraChange(frequency: .continuous) { context in tracker.update(context) }
        .onMapCameraChange(frequency: .onEnd) { context in heading = context.camera.heading }
        .mapCameraKeyframeAnimator(trigger: flight) { initial in
            let samples = flight?.samples(from: initial) ?? []
            let step = (flight?.duration ?? 0) / Double(max(1, samples.count))
            KeyframeTrack(\MapCamera.centerCoordinate) {
                for sample in samples { LinearKeyframe(sample.center.clCoordinate, duration: step) }
            }
            KeyframeTrack(\MapCamera.distance) {
                for sample in samples { LinearKeyframe(sample.scale, duration: step) }
            }
            KeyframeTrack(\MapCamera.heading) {
                for sample in samples { LinearKeyframe(sample.heading, duration: step) }
            }
            KeyframeTrack(\MapCamera.pitch) {
                for sample in samples { LinearKeyframe(sample.pitch, duration: step) }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { resized(to: proxy.size) }
                    .onChange(of: proxy.size) { _, size in resized(to: size) }
            }
        }
        .onChange(of: camera) { _, newValue in update(to: newValue) }
        .onChange(of: vehicle) { _, newValue in moveVehicle(to: newValue) }
        .onChange(of: pathsSignature) { _, _ in
            // A different plan selected: frame it.
            if camera == .overview, appliedCamera != nil { apply(.overview, motion: .flight(.frame)) }
        }
        .onChange(of: position.positionedByUser) { _, byUser in
            guard byUser else { return }
            interruptedFlight = flight?.id
            onUserMoved?()
        }
        .onChange(of: command) { _, newValue in
            if let newValue { perform(newValue.action) }
        }
        .accessibilityIdentifier("map")
    }

    // MARK: Camera

    private func resized(to size: CGSize) {
        viewSize = size
        // First placement once the map has a size; later size changes are handled by the screen.
        if appliedCamera == nil, size.width > 0, size.height > 0 { update(to: camera) }
    }

    private func update(to newCamera: TripMapView.Camera) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let now = Date()
        var lag: Double?
        if case let .follow(car, course) = newCamera, let shown = tracker.camera {
            let target = MapCameraDirector.followCenter(car: car, heading: course ?? shown.heading)
            lag = GeoMath.distance(GeoCoordinate(latitude: shown.centerCoordinate.latitude, longitude: shown.centerCoordinate.longitude), target)
        }
        let motion = MapCameraDirector.motion(
            from: appliedCamera, to: newCamera, sinceLastFix: now.timeIntervalSince(lastFix), isFlyingIn: now < flightEnds, lag: lag
        )
        if newCamera.isFollow { lastFix = now }
        appliedCamera = newCamera
        if let motion { apply(newCamera, motion: motion) }
    }

    private func apply(_ camera: TripMapView.Camera, motion: MapCameraDirector.Motion) {
        if case let .flight(kind) = motion {
            fly(to: camera, kind: kind)
            return
        }
        guard let target = target(for: camera) else { return }
        switch motion {
        case .immediate:
            position = target
        case let .ease(duration):
            withAnimation(.easeInOut(duration: duration)) { position = target }
        case let .linear(duration):
            withAnimation(.linear(duration: duration)) { position = target }
        case .flight:
            break
        }
    }

    /// Flies from the camera on screen to `camera` (see `CameraFlight`), then pins the map there.
    private func fly(to camera: TripMapView.Camera, kind: CameraFlight.Kind) {
        guard let end = flightTarget(for: camera), let current = tracker.camera else {
            // The map hasn't reported a camera yet: let MapKit animate.
            if let target = target(for: camera) {
                withAnimation(.easeInOut(duration: CameraFlight.minimumDuration)) { position = target }
            }
            return
        }
        let newFlight = AppleFlight(
            target: end, kind: kind, duration: CameraFlight.duration(fromScale: current.distance, toScale: end.scale)
        )
        flight = newFlight
        flightEnds = Date().addingTimeInterval(newFlight.duration)
        // Keyframes don't move `position`; set it to where the flight ended, so the map stays there.
        DispatchQueue.main.asyncAfter(deadline: .now() + newFlight.duration + 0.05) {
            guard flight?.id == newFlight.id, interruptedFlight != newFlight.id else { return }
            position = .camera(newFlight.finalCamera)
        }
    }

    /// Where a flight to `camera` ends, as an engine-independent camera.
    private func flightTarget(for camera: TripMapView.Camera) -> CameraFlight.Camera? {
        switch camera {
        case .free:
            return nil
        case .overview, .frame:
            guard let rect = framedRect(for: camera), let heightPerDistance = tracker.heightPerDistance else { return nil }
            let center = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
            let height = rect.height / MKMapPointsPerMeterAtLatitude(center.latitude)
            return CameraFlight.Camera(center: GeoCoordinate(center), scale: height / heightPerDistance)
        case let .follow(car, course):
            let direction = course ?? tracker.camera?.heading ?? heading
            return CameraFlight.Camera(
                center: MapCameraDirector.followCenter(car: car, heading: direction),
                scale: MapCameraDirector.followDistance, heading: direction, pitch: MapCameraDirector.followPitch
            )
        }
    }

    /// The north-up rect an overview or a frame shows.
    private func framedRect(for camera: TripMapView.Camera) -> MKMapRect? {
        switch camera {
        case .overview:
            let everything = paths.flatMap { $0 } + markers.map(\.coordinate)
            return MapCameraDirector.framingRect(for: everything, in: viewSize, insets: chrome, fill: 0.9)
        case let .frame(coordinates):
            return MapCameraDirector.framingRect(for: coordinates, in: viewSize, insets: chrome)
        case .follow, .free:
            return nil
        }
    }

    private func target(for camera: TripMapView.Camera) -> MapCameraPosition? {
        switch camera {
        case .free:
            return nil
        case .overview:
            return framedRect(for: camera).map { .rect($0) } ?? .automatic
        case .frame:
            return framedRect(for: camera).map { .rect($0) }
        case let .follow(car, course):
            let direction = course ?? tracker.camera?.heading ?? self.heading
            return .camera(MapCamera(
                centerCoordinate: MapCameraDirector.followCenter(car: car, heading: direction).clCoordinate,
                distance: MapCameraDirector.followDistance,
                heading: direction,
                pitch: MapCameraDirector.followPitch
            ))
        }
    }

    /// Zoom from the view on screen, keeping its centre, heading and tilt.
    private func perform(_ action: MapCommand.Action) {
        switch action {
        case .fitRoute:
            apply(.overview, motion: .flight(.frame))
        case .reapplyCamera:
            if case let .follow(car, _) = camera {
                apply(camera, motion: .flight(.anchored(car)))
            } else {
                apply(camera, motion: .flight(.frame))
            }
        case .zoomIn, .zoomOut:
            guard let current = tracker.camera else { return }
            let factor = action == .zoomIn ? 0.5 : 2
            let zoomed = MapCamera(
                centerCoordinate: current.centerCoordinate,
                distance: min(40_000_000, max(300, current.distance * factor)),
                heading: current.heading,
                pitch: current.pitch
            )
            withAnimation(.easeInOut(duration: MapCameraDirector.zoomDuration)) { position = .camera(zoomed) }
        }
    }

    // MARK: Car

    /// The car glides between fixes at the same pace as the follow camera.
    private func moveVehicle(to newVehicle: TripMapView.Vehicle?) {
        let now = Date()
        defer { lastVehicleFix = now }
        guard let newVehicle, let old = shownVehicle,
              GeoMath.distance(old.coordinate, newVehicle.coordinate) < 5_000 else {
            shownVehicle = newVehicle
            return
        }
        let duration = min(MapCameraDirector.maximumGlide, max(0.05, now.timeIntervalSince(lastVehicleFix))) * MapCameraDirector.glideShare
        withAnimation(.linear(duration: duration)) { shownVehicle = newVehicle }
    }

    /// The arrow points along the course, relative to the map's own rotation.
    private func vehicleRotation(_ vehicle: TripMapView.Vehicle) -> Double {
        if case .follow = camera { return 0 }
        return (vehicle.course ?? 0) - heading
    }

    private var pathsSignature: Int {
        var hasher = Hasher()
        for path in paths {
            hasher.combine(path.count)
            hasher.combine(path.first)
            hasher.combine(path.last)
        }
        return hasher.finalize()
    }

    /// A rough starting position (for a phone-sized map) until the real size is known.
    static func approximatePosition(for camera: TripMapView.Camera) -> MapCameraPosition {
        switch camera {
        case .overview, .free:
            return .automatic
        case let .frame(coordinates):
            let phone = CGSize(width: 393, height: 852)
            return MapCameraDirector.framingRect(for: coordinates, in: phone, insets: .zero).map { .rect($0) } ?? .automatic
        case let .follow(car, course):
            return .camera(MapCamera(
                centerCoordinate: MapCameraDirector.followCenter(car: car, heading: course ?? 0).clCoordinate,
                distance: MapCameraDirector.followDistance, heading: course ?? 0, pitch: MapCameraDirector.followPitch
            ))
        }
    }
}

extension GeoCoordinate {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
