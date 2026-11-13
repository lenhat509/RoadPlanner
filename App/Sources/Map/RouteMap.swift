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

/// Camera timing shared by both map engines.
enum MapMotion {
    /// A framed route fills about this much of the visible map.
    static let frameFill = 0.8
    /// Preview → following the car: a slow glide down to the car.
    static let flyInDuration: TimeInterval = 1.6
    /// Glide between GPS fixes (about one a second); faster fixes (simulators) snap instead, so
    /// the camera never trails the car.
    static let followGlideDuration: TimeInterval = 0.8
    static let minimumGlideInterval: TimeInterval = 0.6
    /// Follow camera: distance (Apple) / zoom (Google) and tilt.
    static let followDistance: Double = 1_500
    static let followZoom: Float = 16.5
    static let followPitch: Double = 45
}

/// Route map that renders with the configured provider.
///
/// `paths[0]` is the route being driven (drawn strong, with a darker edge); any further paths are
/// the rest of the trip (drawn lighter, underneath).
struct RouteMap: View {
    var paths: [[GeoCoordinate]]
    var markers: [MapStopMarker]
    var camera: TripMapView.Camera = .overview
    var edgeInsets = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    var vehicle: TripMapView.Vehicle?
    var command: MapCommand?
    /// Called when the user pans, zooms or rotates the map by hand.
    var onUserMoved: (() -> Void)?

    @Environment(\.mapProvider) private var provider

    var body: some View {
        switch provider {
        case .google:
            TripMapView(
                paths: paths, markers: markers, camera: camera, edgeInsets: edgeInsets,
                vehicle: vehicle, command: command, onUserMoved: onUserMoved
            )
        case .apple:
            AppleRouteMap(
                paths: paths, markers: markers, camera: camera, edgeInsets: edgeInsets,
                vehicle: vehicle, command: command, onUserMoved: onUserMoved
            )
        }
    }
}

/// Apple Maps (MapKit for SwiftUI) rendering of the same route, markers and camera.
struct AppleRouteMap: View {
    var paths: [[GeoCoordinate]]
    var markers: [MapStopMarker]
    var camera: TripMapView.Camera
    var edgeInsets: UIEdgeInsets
    var vehicle: TripMapView.Vehicle?
    var command: MapCommand?
    var onUserMoved: (() -> Void)?

    @State private var position: MapCameraPosition = .automatic
    @State private var visibleCamera: MapCamera?
    @State private var lastFollowUpdate = Date.distantPast
    /// Follow updates wait until the fly-in from a preview has finished.
    @State private var flyInEnds = Date.distantPast

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
            if let vehicle {
                Annotation("Your car", coordinate: vehicle.coordinate.clCoordinate, anchor: .center) {
                    VehicleArrow(rotation: vehicleRotation(vehicle))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass().mapControlVisibility(.hidden) }
        .safeAreaPadding(EdgeInsets(top: edgeInsets.top, leading: edgeInsets.left, bottom: edgeInsets.bottom, trailing: edgeInsets.right))
        .onMapCameraChange(frequency: .onEnd) { context in visibleCamera = context.camera }
        .onChange(of: position.positionedByUser) { _, byUser in
            if byUser { onUserMoved?() }
        }
        .onChange(of: command) { _, newValue in
            if let newValue { perform(newValue.action) }
        }
        .onAppear { apply(camera, duration: nil) }
        .onChange(of: camera) { oldValue, newValue in move(from: oldValue, to: newValue) }
        .onChange(of: paths.first?.count) { _, _ in
            if camera == .overview { position = .automatic }
        }
        .accessibilityIdentifier("map")
    }

    /// The arrow points along the course, relative to the map's own rotation.
    private func vehicleRotation(_ vehicle: TripMapView.Vehicle) -> Double {
        if case .follow = camera { return 0 }
        return (vehicle.course ?? 0) - (visibleCamera?.heading ?? 0)
    }

    private func move(from oldCamera: TripMapView.Camera, to newCamera: TripMapView.Camera) {
        let now = Date()
        switch newCamera {
        case .free:
            return
        case .follow:
            if !oldCamera.isFollow {
                // From a preview or overview: glide down to the car.
                flyInEnds = now.addingTimeInterval(MapMotion.flyInDuration)
                apply(newCamera, duration: MapMotion.flyInDuration)
            } else if now >= flyInEnds {
                let glides = now.timeIntervalSince(lastFollowUpdate) > MapMotion.minimumGlideInterval
                apply(newCamera, duration: glides ? MapMotion.followGlideDuration : nil)
            }
            lastFollowUpdate = now
        case .overview, .frame:
            apply(newCamera, duration: 0.8)
        }
    }

    private func perform(_ action: MapCommand.Action) {
        switch action {
        case .fitRoute:
            withAnimation(.easeInOut(duration: 0.5)) { position = .automatic }
        case .reapplyCamera:
            apply(camera, duration: 0.5)
        case .zoomIn, .zoomOut:
            guard let current = visibleCamera else {
                withAnimation(.easeInOut(duration: 0.5)) { position = .automatic }
                return
            }
            let factor = action == .zoomIn ? 0.5 : 2
            let zoomed = MapCamera(
                centerCoordinate: current.centerCoordinate,
                distance: min(40_000_000, max(300, current.distance * factor)),
                heading: current.heading,
                pitch: current.pitch
            )
            withAnimation(.easeInOut(duration: 0.35)) { position = .camera(zoomed) }
        }
    }

    /// Moves the camera; `duration` nil means without animation.
    private func apply(_ camera: TripMapView.Camera, duration: TimeInterval?) {
        let target: MapCameraPosition
        switch camera {
        case .free:
            return
        case .overview:
            target = .automatic
        case let .frame(coordinates):
            guard let rect = Self.framingRect(for: coordinates) else { return }
            target = .rect(rect)
        case let .follow(coordinate, course):
            target = .camera(MapCamera(
                centerCoordinate: coordinate.clCoordinate,
                distance: MapMotion.followDistance,
                heading: course ?? visibleCamera?.heading ?? 0,
                pitch: MapMotion.followPitch
            ))
        }
        if let duration {
            withAnimation(.easeInOut(duration: duration)) { position = target }
        } else {
            position = target
        }
    }

    /// A map rect in which `coordinates` fill about `MapMotion.frameFill` of each dimension.
    static func framingRect(for coordinates: [GeoCoordinate]) -> MKMapRect? {
        guard !coordinates.isEmpty else { return nil }
        let points = coordinates.map { MKMapPoint($0.clCoordinate) }
        let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 0
        // At least ~1 km across, so a very short leg isn't zoomed in to street level.
        let minimumSide = 1_000 * MKMapPointsPerMeterAtLatitude(coordinates[0].latitude)
        let width = max(maxX - minX, minimumSide), height = max(maxY - minY, minimumSide)
        let margin = (1 / MapMotion.frameFill - 1) / 2
        return MKMapRect(
            x: (minX + maxX) / 2 - width * (0.5 + margin),
            y: (minY + maxY) / 2 - height * (0.5 + margin),
            width: width * (1 + 2 * margin),
            height: height * (1 + 2 * margin)
        )
    }
}

extension TripMapView.Camera {
    var isFollow: Bool {
        if case .follow = self { return true }
        return false
    }
}

extension GeoCoordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
