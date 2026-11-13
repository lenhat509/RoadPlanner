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

/// Google Maps SDK map showing the route and stops: everything (overview), a framed leg
/// (preview), or following the driver (drive mode). Redraws only what changed.
struct TripMapView: UIViewRepresentable {
    enum Camera: Equatable {
        /// Everything on the map.
        case overview
        /// These coordinates, filling about `MapMotion.frameFill` of the visible map.
        case frame([GeoCoordinate])
        /// Behind the car, heading up and tilted.
        case follow(GeoCoordinate, course: Double?)
        /// Leave the camera where the user put it.
        case free
    }

    /// The car's position, drawn as a heading arrow (drive mode).
    struct Vehicle: Equatable {
        let coordinate: GeoCoordinate
        let course: Double?
    }

    var paths: [[GeoCoordinate]]
    var markers: [MapStopMarker]
    var camera: Camera = .overview
    var showsUserLocation = false
    var edgeInsets = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    /// Drawn from the location the app navigates with (real or simulated), not the SDK's own GPS dot.
    var vehicle: Vehicle?
    /// Zoom / fit requests from the map buttons.
    var command: MapCommand?
    /// Called when the user moves the map by hand.
    var onUserMoved: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> GMSMapView {
        let mapView = GMSMapView()
        mapView.settings.compassButton = false
        mapView.settings.myLocationButton = false
        mapView.settings.tiltGestures = false
        mapView.isMyLocationEnabled = showsUserLocation
        mapView.accessibilityIdentifier = "map"
        mapView.delegate = context.coordinator
        return mapView
    }

    func updateUIView(_ mapView: GMSMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onUserMoved = onUserMoved
        mapView.padding = edgeInsets
        coordinator.applyStyle(colorScheme, to: mapView)
        coordinator.render(paths: paths, on: mapView)
        coordinator.render(markers: markers, on: mapView)
        coordinator.updateVehicle(vehicle, on: mapView)
        coordinator.updateCamera(camera, paths: paths, markers: markers, on: mapView)
        coordinator.perform(command, camera: camera, paths: paths, markers: markers, on: mapView)
    }

    @MainActor
    final class Coordinator: NSObject, GMSMapViewDelegate {
        var onUserMoved: (() -> Void)?
        private var pathsSignature: Int?
        private var markersSignature: Int?
        private var framedSignature: Int?
        private var styledScheme: ColorScheme?
        private var routeCasing: GMSPolyline?
        private var routeLine: GMSPolyline?
        private var restLines: [GMSPolyline] = []
        private var stopMarkers: [GMSMarker] = []
        private var vehicleMarker: GMSMarker?
        private var lastCommandID: UUID?
        private var lastCamera: Camera?
        private var lastFollowUpdate = Date.distantPast
        private var flyInEnds = Date.distantPast

        nonisolated func mapView(_ mapView: GMSMapView, willMove gesture: Bool) {
            guard gesture else { return }
            MainActor.assumeIsolated { onUserMoved?() }
        }

        func perform(_ command: MapCommand?, camera: Camera, paths: [[GeoCoordinate]], markers: [MapStopMarker], on mapView: GMSMapView) {
            guard let command, command.id != lastCommandID else { return }
            lastCommandID = command.id
            switch command.action {
            case .zoomIn:
                mapView.animate(with: GMSCameraUpdate.zoomIn())
            case .zoomOut:
                mapView.animate(with: GMSCameraUpdate.zoomOut())
            case .fitRoute:
                framedSignature = nil
                updateCamera(.overview, paths: paths, markers: markers, on: mapView, force: true)
            case .reapplyCamera:
                framedSignature = nil
                updateCamera(camera, paths: paths, markers: markers, on: mapView, force: true)
            }
        }

        func updateVehicle(_ vehicle: TripMapView.Vehicle?, on mapView: GMSMapView) {
            guard let vehicle else {
                vehicleMarker?.map = nil
                vehicleMarker = nil
                return
            }
            let marker = vehicleMarker ?? GMSMarker()
            marker.position = vehicle.coordinate.clCoordinate
            marker.icon = MarkerIconFactory.vehicleIcon()
            marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            // Flat markers rotate with the map, so the course is an absolute bearing.
            marker.isFlat = true
            marker.rotation = vehicle.course ?? mapView.camera.bearing
            marker.zIndex = 20
            marker.map = mapView
            vehicleMarker = marker
        }

        func applyStyle(_ scheme: ColorScheme, to mapView: GMSMapView) {
            guard styledScheme != scheme else { return }
            styledScheme = scheme
            mapView.mapStyle = scheme == .dark ? MapStyles.night : nil
            pathsSignature = nil // colours are resolved per appearance
        }

        /// The route being driven (strong, with a darker edge) over the rest of the trip (light).
        func render(paths: [[GeoCoordinate]], on mapView: GMSMapView) {
            let signature = Self.signature(paths)
            guard signature != pathsSignature else { return }
            pathsSignature = signature
            let traits = UITraitCollection(userInterfaceStyle: styledScheme == .dark ? .dark : .light)
            let line = UIColor(Theme.routeLine).resolvedColor(with: traits)
            let casing = UIColor(Theme.routeCasing).resolvedColor(with: traits)

            if let route = paths.first, route.count > 1 {
                let path = Self.path(route)
                routeCasing = Self.polyline(routeCasing, path: path, color: casing, width: 9, zIndex: 3, on: mapView)
                routeLine = Self.polyline(routeLine, path: path, color: line, width: 6, zIndex: 4, on: mapView)
            } else {
                routeCasing?.map = nil
                routeLine?.map = nil
                routeCasing = nil
                routeLine = nil
            }
            let rest = Array(paths.dropFirst())
            restLines.dropFirst(rest.count).forEach { $0.map = nil }
            restLines = rest.enumerated().map { index, coordinates in
                Self.polyline(
                    restLines.indices.contains(index) ? restLines[index] : nil, path: Self.path(coordinates),
                    color: line.withAlphaComponent(0.38), width: 5, zIndex: 1, on: mapView
                )
            }
        }

        func render(markers: [MapStopMarker], on mapView: GMSMapView) {
            let signature = markers.hashValue
            guard signature != markersSignature else { return }
            markersSignature = signature
            stopMarkers.forEach { $0.map = nil }
            stopMarkers = markers.map { stop in
                let marker = GMSMarker(position: stop.coordinate.clCoordinate)
                marker.icon = MarkerIconFactory.icon(for: stop.kind, isPullOff: stop.isPullOff, isActive: stop.isActive)
                marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
                marker.title = stop.title
                marker.zIndex = stop.isActive ? 10 : 5
                marker.map = mapView
                return marker
            }
        }

        func updateCamera(
            _ camera: Camera, paths: [[GeoCoordinate]], markers: [MapStopMarker], on mapView: GMSMapView, force: Bool = false
        ) {
            let previous = lastCamera
            lastCamera = camera
            switch camera {
            case .free:
                return
            case .overview:
                let coordinates = paths.flatMap { $0 } + markers.map(\.coordinate)
                frame(
                    coordinates, signature: Self.signature(paths) ^ markers.hashValue, insetFraction: 0,
                    animated: previous != nil, force: force, on: mapView
                )
            case let .frame(coordinates):
                frame(
                    coordinates, signature: Self.signature([coordinates]), insetFraction: (1 - MapMotion.frameFill) / 2,
                    animated: previous != nil, force: force, on: mapView
                )
            case let .follow(coordinate, course):
                framedSignature = nil
                let now = Date()
                let position = GMSCameraPosition(
                    target: coordinate.clCoordinate,
                    zoom: MapMotion.followZoom,
                    bearing: course ?? mapView.camera.bearing,
                    viewingAngle: MapMotion.followPitch
                )
                if !(previous?.isFollow ?? false) || force {
                    // From a preview or overview: glide down to the car.
                    flyInEnds = now.addingTimeInterval(MapMotion.flyInDuration)
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(MapMotion.flyInDuration)
                    mapView.animate(to: position)
                    CATransaction.commit()
                } else if now >= flyInEnds {
                    if now.timeIntervalSince(lastFollowUpdate) > MapMotion.minimumGlideInterval {
                        CATransaction.begin()
                        CATransaction.setAnimationDuration(MapMotion.followGlideDuration)
                        mapView.animate(to: position)
                        CATransaction.commit()
                    } else {
                        mapView.moveCamera(GMSCameraUpdate.setCamera(position))
                    }
                }
                lastFollowUpdate = now
            }
        }

        /// Fits `coordinates` inside the padded map, leaving `insetFraction` of each side empty.
        private func frame(
            _ coordinates: [GeoCoordinate], signature: Int, insetFraction: CGFloat, animated: Bool, force: Bool, on mapView: GMSMapView
        ) {
            guard !coordinates.isEmpty, force || signature != framedSignature else { return }
            framedSignature = signature
            var bounds = GMSCoordinateBounds()
            for coordinate in coordinates {
                bounds = bounds.includingCoordinate(coordinate.clCoordinate)
            }
            // Wait for layout so the map has a size to fit into.
            DispatchQueue.main.async {
                let size = mapView.bounds.inset(by: mapView.padding).size
                let insets = UIEdgeInsets(
                    top: max(24, size.height * insetFraction), left: max(24, size.width * insetFraction),
                    bottom: max(24, size.height * insetFraction), right: max(24, size.width * insetFraction)
                )
                let update = GMSCameraUpdate.fit(bounds, with: insets)
                guard animated else {
                    mapView.moveCamera(update)
                    return
                }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.8)
                mapView.animate(with: update)
                CATransaction.commit()
            }
        }

        private static func path(_ coordinates: [GeoCoordinate]) -> GMSMutablePath {
            let path = GMSMutablePath()
            for coordinate in coordinates { path.add(coordinate.clCoordinate) }
            return path
        }

        private static func polyline(
            _ existing: GMSPolyline?, path: GMSPath, color: UIColor, width: CGFloat, zIndex: Int32, on mapView: GMSMapView
        ) -> GMSPolyline {
            let line = existing ?? GMSPolyline()
            line.path = path
            line.strokeColor = color
            line.strokeWidth = width
            line.zIndex = zIndex
            line.map = mapView
            return line
        }

        private static func signature(_ paths: [[GeoCoordinate]]) -> Int {
            var hasher = Hasher()
            for path in paths {
                hasher.combine(path.count)
                hasher.combine(path.first)
                hasher.combine(path.last)
            }
            return hasher.finalize()
        }
    }
}
