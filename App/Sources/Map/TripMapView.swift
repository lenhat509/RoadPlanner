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
/// (preview), or following the driver (drive mode). Camera moves follow `MapCameraDirector`.
struct TripMapView: UIViewRepresentable {
    enum Camera: Equatable {
        /// Everything on the map.
        case overview
        /// These coordinates, filling about `MapCameraDirector.frameFill` of the visible map.
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
    /// The parts of the map covered by the screen's own UI.
    var chrome = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    /// Drawn from the location the app navigates with (real or simulated), not the SDK's own GPS dot.
    var vehicle: Vehicle?
    /// The user's position when it is not the car being guided.
    var userLocation: GeoCoordinate?
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
        // Framing accounts for the chrome explicitly; padding would shift the map when it changes.
        mapView.padding = .zero
        mapView.accessibilityIdentifier = "map"
        mapView.delegate = context.coordinator
        return mapView
    }

    func updateUIView(_ mapView: GMSMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onUserMoved = onUserMoved
        coordinator.chrome = chrome
        coordinator.applyStyle(colorScheme, to: mapView)
        coordinator.render(paths: paths, on: mapView)
        coordinator.render(markers: markers, on: mapView)
        coordinator.updateUserLocation(userLocation, on: mapView)
        coordinator.updateVehicle(vehicle, on: mapView)
        coordinator.updateCamera(camera, paths: paths, markers: markers, on: mapView)
        coordinator.perform(command, camera: camera, paths: paths, markers: markers, on: mapView)
    }

    @MainActor
    final class Coordinator: NSObject, GMSMapViewDelegate {
        var onUserMoved: (() -> Void)?
        var chrome = UIEdgeInsets.zero
        private var pathsSignature: Int?
        private var markersSignature: Int?
        private var styledScheme: ColorScheme?
        private var routeCasing: GMSPolyline?
        private var routeLine: GMSPolyline?
        private var restLines: [GMSPolyline] = []
        private var stopMarkers: [GMSMarker] = []
        private var userMarker: GMSMarker?
        private var vehicleMarker: GMSMarker?
        private var shownVehicle: Vehicle?
        private var lastCommandID: UUID?
        private var appliedCamera: Camera?
        private var framedOverview: Int?
        private var lastFix = Date.distantPast
        private var lastVehicleFix = Date.distantPast
        private var flyInEnds = Date.distantPast

        nonisolated func mapView(_ mapView: GMSMapView, willMove gesture: Bool) {
            guard gesture else { return }
            MainActor.assumeIsolated { onUserMoved?() }
        }

        // MARK: Camera

        func perform(_ command: MapCommand?, camera: Camera, paths: [[GeoCoordinate]], markers: [MapStopMarker], on mapView: GMSMapView) {
            guard let command, command.id != lastCommandID else { return }
            lastCommandID = command.id
            let target: GMSCameraUpdate?
            switch command.action {
            case .zoomIn:
                target = GMSCameraUpdate.zoomIn()
            case .zoomOut:
                target = GMSCameraUpdate.zoomOut()
            case .fitRoute:
                target = cameraUpdate(for: .overview, paths: paths, markers: markers, on: mapView)
            case .reapplyCamera:
                target = cameraUpdate(for: camera, paths: paths, markers: markers, on: mapView)
            }
            let duration = command.action == .zoomIn || command.action == .zoomOut
                ? MapCameraDirector.zoomDuration : MapCameraDirector.framingDuration
            if let target { move(mapView, with: target, motion: .ease(duration)) }
        }

        func updateCamera(_ camera: Camera, paths: [[GeoCoordinate]], markers: [MapStopMarker], on mapView: GMSMapView) {
            let overview = Self.signature(paths) ^ markers.hashValue
            let planChanged = camera == .overview && appliedCamera == .overview && overview != framedOverview
            // updateUIView runs on every SwiftUI update: act only on a new camera (or a new plan).
            guard camera != appliedCamera || planChanged else { return }
            guard mapView.bounds.width > 0, mapView.bounds.height > 0 else {
                // Not laid out yet: place it on the next turn of the run loop.
                DispatchQueue.main.async { [weak self, weak mapView] in
                    guard let self, let mapView, mapView.bounds.width > 0 else { return }
                    self.updateCamera(camera, paths: paths, markers: markers, on: mapView)
                }
                return
            }
            let now = Date()
            var motion = MapCameraDirector.motion(
                from: appliedCamera, to: camera, sinceLastFix: now.timeIntervalSince(lastFix), isFlyingIn: now < flyInEnds
            )
            if planChanged { motion = .ease(MapCameraDirector.framingDuration) }
            if camera.isFollow {
                if let previous = appliedCamera, !previous.isFollow { flyInEnds = now.addingTimeInterval(MapCameraDirector.flyInDuration) }
                lastFix = now
            }
            appliedCamera = camera
            if camera == .overview { framedOverview = overview }
            guard let motion, let update = cameraUpdate(for: camera, paths: paths, markers: markers, on: mapView) else { return }
            move(mapView, with: update, motion: motion)
        }

        private func cameraUpdate(
            for camera: Camera, paths: [[GeoCoordinate]], markers: [MapStopMarker], on mapView: GMSMapView
        ) -> GMSCameraUpdate? {
            switch camera {
            case .free:
                return nil
            case .overview:
                return fit(paths.flatMap { $0 } + markers.map(\.coordinate), fill: 0.9, on: mapView)
            case let .frame(coordinates):
                return fit(coordinates, fill: MapCameraDirector.frameFill, on: mapView)
            case let .follow(car, course):
                let bearing = course ?? mapView.camera.bearing
                return GMSCameraUpdate.setCamera(GMSCameraPosition(
                    target: MapCameraDirector.followCenter(car: car, heading: bearing).clCoordinate,
                    zoom: MapCameraDirector.followZoom,
                    bearing: bearing,
                    viewingAngle: MapCameraDirector.followPitch
                ))
            }
        }

        /// Fits `coordinates` (at least ~1 km across) to `fill` of the area clear of the chrome.
        private func fit(_ coordinates: [GeoCoordinate], fill: Double, on mapView: GMSMapView) -> GMSCameraUpdate? {
            guard !coordinates.isEmpty else { return nil }
            var bounds = GMSCoordinateBounds()
            for coordinate in coordinates { bounds = bounds.includingCoordinate(coordinate.clCoordinate) }
            let center = GeoCoordinate(
                latitude: (bounds.northEast.latitude + bounds.southWest.latitude) / 2,
                longitude: (bounds.northEast.longitude + bounds.southWest.longitude) / 2
            )
            for bearing in [0.0, 90, 180, 270] {
                bounds = bounds.includingCoordinate(GeoMath.destination(from: center, bearing: bearing, distance: 500).clCoordinate)
            }
            let insets = MapCameraDirector.fitInsets(in: mapView.bounds.size, chrome: chrome, fill: fill)
            return GMSCameraUpdate.fit(bounds, with: insets)
        }

        private func move(_ mapView: GMSMapView, with update: GMSCameraUpdate, motion: MapCameraDirector.Motion) {
            switch motion {
            case .immediate:
                mapView.moveCamera(update)
            case let .ease(duration):
                Self.animate(duration: duration, timing: .easeInEaseOut) { mapView.animate(with: update) }
            case let .linear(duration):
                Self.animate(duration: duration, timing: .linear) { mapView.animate(with: update) }
            }
        }

        private static func animate(duration: TimeInterval, timing: CAMediaTimingFunctionName, _ changes: () -> Void) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: timing))
            changes()
            CATransaction.commit()
        }

        // MARK: Markers

        /// The car glides between fixes at the same pace as the follow camera.
        func updateVehicle(_ vehicle: Vehicle?, on mapView: GMSMapView) {
            guard vehicle != shownVehicle else { return }
            let previous = shownVehicle
            shownVehicle = vehicle
            let now = Date()
            defer { lastVehicleFix = now }
            guard let vehicle else {
                vehicleMarker?.map = nil
                vehicleMarker = nil
                return
            }
            let marker = vehicleMarker ?? GMSMarker()
            marker.icon = MarkerIconFactory.vehicleIcon()
            marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            // Flat markers rotate with the map, so the course is an absolute bearing.
            marker.isFlat = true
            marker.zIndex = 20
            let glides = previous.map { GeoMath.distance($0.coordinate, vehicle.coordinate) < 5_000 } ?? false
            let place = {
                marker.position = vehicle.coordinate.clCoordinate
                marker.rotation = vehicle.course ?? mapView.camera.bearing
            }
            if glides, vehicleMarker != nil {
                let duration = min(MapCameraDirector.maximumGlide, max(0.05, now.timeIntervalSince(lastVehicleFix)))
                Self.animate(duration: duration, timing: .linear, place)
            } else {
                place()
            }
            marker.map = mapView
            vehicleMarker = marker
        }

        func updateUserLocation(_ location: GeoCoordinate?, on mapView: GMSMapView) {
            guard let location else {
                userMarker?.map = nil
                userMarker = nil
                return
            }
            let marker = userMarker ?? GMSMarker()
            marker.position = location.clCoordinate
            marker.icon = MarkerIconFactory.userLocationIcon()
            marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            marker.title = "You are here"
            marker.zIndex = 15
            marker.map = mapView
            userMarker = marker
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
