import GoogleMaps
import SwiftUI
import TripModels

/// A stop drawn on the map.
struct MapStopMarker: Hashable {
    let id: String
    let coordinate: GeoCoordinate
    let title: String
    let kind: StopKind
    let isPullOff: Bool
    let isActive: Bool
}

/// Google Maps SDK map showing the route and stops, either framed (overview) or following the
/// driver (drive mode). Redraws only when the inputs change.
struct TripMapView: UIViewRepresentable {
    enum Camera: Equatable {
        case overview
        case follow(GeoCoordinate, course: Double?)
    }

    var paths: [[GeoCoordinate]]
    var markers: [MapStopMarker]
    var camera: Camera = .overview
    var showsUserLocation = true
    var edgeInsets = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> GMSMapView {
        let mapView = GMSMapView()
        mapView.settings.compassButton = true
        mapView.settings.myLocationButton = false
        mapView.settings.tiltGestures = false
        mapView.isMyLocationEnabled = showsUserLocation
        mapView.accessibilityIdentifier = "map"
        return mapView
    }

    func updateUIView(_ mapView: GMSMapView, context: Context) {
        mapView.padding = edgeInsets
        context.coordinator.applyStyle(colorScheme, to: mapView)
        context.coordinator.render(paths: paths, markers: markers, on: mapView)
        context.coordinator.updateCamera(camera, paths: paths, markers: markers, on: mapView)
    }

    @MainActor
    final class Coordinator {
        private var renderedSignature: Int?
        private var framedSignature: Int?
        private var styledScheme: ColorScheme?
        private var polylines: [GMSPolyline] = []
        private var stopMarkers: [GMSMarker] = []

        func applyStyle(_ scheme: ColorScheme, to mapView: GMSMapView) {
            guard styledScheme != scheme else { return }
            styledScheme = scheme
            mapView.mapStyle = scheme == .dark ? MapStyles.night : nil
        }

        func render(paths: [[GeoCoordinate]], markers: [MapStopMarker], on mapView: GMSMapView) {
            let signature = Self.signature(paths: paths, markers: markers)
            guard signature != renderedSignature else { return }
            renderedSignature = signature

            polylines.forEach { $0.map = nil }
            stopMarkers.forEach { $0.map = nil }
            let routeColor = UIColor(Theme.routeLine)
            polylines = paths.enumerated().map { index, coordinates in
                let path = GMSMutablePath()
                for coordinate in coordinates {
                    path.add(CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
                }
                let line = GMSPolyline(path: path)
                line.strokeWidth = index == 0 ? 6 : 4
                line.strokeColor = index == 0 ? routeColor : routeColor.withAlphaComponent(0.35)
                line.zIndex = index == 0 ? 2 : 1
                line.map = mapView
                return line
            }
            stopMarkers = markers.map { stop in
                let marker = GMSMarker(position: CLLocationCoordinate2D(latitude: stop.coordinate.latitude, longitude: stop.coordinate.longitude))
                marker.icon = MarkerIconFactory.icon(for: stop.kind, isPullOff: stop.isPullOff, isActive: stop.isActive)
                marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
                marker.title = stop.title
                marker.zIndex = stop.isActive ? 10 : 5
                marker.map = mapView
                return marker
            }
        }

        func updateCamera(_ camera: TripMapView.Camera, paths: [[GeoCoordinate]], markers: [MapStopMarker], on mapView: GMSMapView) {
            switch camera {
            case .overview:
                let signature = Self.signature(paths: paths, markers: markers)
                guard signature != framedSignature else { return }
                let coordinates = paths.flatMap { $0 } + markers.map(\.coordinate)
                guard !coordinates.isEmpty else { return }
                framedSignature = signature
                var bounds = GMSCoordinateBounds()
                for coordinate in coordinates {
                    bounds = bounds.includingCoordinate(CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
                }
                // Wait for layout so the map has a size to fit into.
                DispatchQueue.main.async {
                    mapView.moveCamera(GMSCameraUpdate.fit(bounds, withPadding: 40))
                }
            case let .follow(coordinate, course):
                framedSignature = nil
                let position = GMSCameraPosition(
                    target: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                    zoom: 16.5,
                    bearing: course ?? mapView.camera.bearing,
                    viewingAngle: 45
                )
                mapView.animate(to: position)
            }
        }

        private static func signature(paths: [[GeoCoordinate]], markers: [MapStopMarker]) -> Int {
            var hasher = Hasher()
            for path in paths {
                hasher.combine(path.count)
                hasher.combine(path.first)
                hasher.combine(path.last)
            }
            hasher.combine(markers)
            return hasher.finalize()
        }
    }
}
