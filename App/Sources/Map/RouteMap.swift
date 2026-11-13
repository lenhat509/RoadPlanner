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

/// Route map that renders with the configured provider.
struct RouteMap: View {
    var paths: [[GeoCoordinate]]
    var markers: [MapStopMarker]
    var camera: TripMapView.Camera = .overview
    var edgeInsets = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    var vehicle: TripMapView.Vehicle?

    @Environment(\.mapProvider) private var provider

    var body: some View {
        switch provider {
        case .google:
            TripMapView(paths: paths, markers: markers, camera: camera, edgeInsets: edgeInsets, vehicle: vehicle)
        case .apple:
            AppleRouteMap(paths: paths, markers: markers, camera: camera, edgeInsets: edgeInsets, vehicle: vehicle)
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

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(paths.indices, id: \.self) { index in
                MapPolyline(coordinates: paths[index].map(\.clCoordinate))
                    .stroke(
                        index == 0 ? Theme.routeLine : Theme.routeLine.opacity(0.35),
                        style: StrokeStyle(lineWidth: index == 0 ? 6 : 4, lineCap: .round, lineJoin: .round)
                    )
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
        .safeAreaPadding(EdgeInsets(top: edgeInsets.top, leading: edgeInsets.left, bottom: edgeInsets.bottom, trailing: edgeInsets.right))
        .onAppear { apply(camera, animated: false) }
        .onChange(of: camera) { _, newValue in apply(newValue, animated: true) }
        .onChange(of: paths.first?.count) { _, _ in
            if camera == .overview { position = .automatic }
        }
        .accessibilityIdentifier("map")
    }

    /// In follow mode the map is rotated to the direction of travel, so the arrow points up.
    private func vehicleRotation(_ vehicle: TripMapView.Vehicle) -> Double {
        if case .follow = camera { return 0 }
        return vehicle.course ?? 0
    }

    private func apply(_ camera: TripMapView.Camera, animated: Bool) {
        let target: MapCameraPosition = switch camera {
        case .overview:
            .automatic
        case let .follow(coordinate, course):
            .camera(MapCamera(centerCoordinate: coordinate.clCoordinate, distance: 1_500, heading: course ?? 0, pitch: 45))
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.8)) { position = target }
        } else {
            position = target
        }
    }
}

extension GeoCoordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
