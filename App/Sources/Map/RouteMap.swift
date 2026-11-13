import MapKit
import SwiftUI
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

/// The latest camera, updated continuously without re-rendering the view (for the zoom buttons).
@MainActor
private final class CameraTracker {
    var camera: MapCamera?
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
    @State private var flyInEnds = Date.distantPast

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
        .onMapCameraChange(frequency: .continuous) { context in tracker.camera = context.camera }
        .onMapCameraChange(frequency: .onEnd) { context in heading = context.camera.heading }
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
            if camera == .overview, appliedCamera != nil { apply(.overview, motion: .ease(MapCameraDirector.framingDuration)) }
        }
        .onChange(of: position.positionedByUser) { _, byUser in
            if byUser { onUserMoved?() }
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
            from: appliedCamera, to: newCamera, sinceLastFix: now.timeIntervalSince(lastFix), isFlyingIn: now < flyInEnds, lag: lag
        )
        if newCamera.isFollow {
            if let previous = appliedCamera, !previous.isFollow { flyInEnds = now.addingTimeInterval(MapCameraDirector.flyInDuration) }
            lastFix = now
        }
        appliedCamera = newCamera
        if let motion { apply(newCamera, motion: motion) }
    }

    private func apply(_ camera: TripMapView.Camera, motion: MapCameraDirector.Motion) {
        guard let target = target(for: camera) else { return }
        switch motion {
        case .immediate:
            position = target
        case let .ease(duration):
            withAnimation(.easeInOut(duration: duration)) { position = target }
        case let .linear(duration):
            withAnimation(.linear(duration: duration)) { position = target }
        }
    }

    private func target(for camera: TripMapView.Camera) -> MapCameraPosition? {
        switch camera {
        case .free:
            return nil
        case .overview:
            let everything = paths.flatMap { $0 } + markers.map(\.coordinate)
            return MapCameraDirector.framingRect(for: everything, in: viewSize, insets: chrome, fill: 0.9).map { .rect($0) } ?? .automatic
        case let .frame(coordinates):
            return MapCameraDirector.framingRect(for: coordinates, in: viewSize, insets: chrome).map { .rect($0) }
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
            apply(.overview, motion: .ease(MapCameraDirector.framingDuration))
        case .reapplyCamera:
            apply(camera, motion: .ease(MapCameraDirector.framingDuration))
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
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
