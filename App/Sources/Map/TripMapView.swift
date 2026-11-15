import GoogleMaps
import SwiftUI
import TripFeatures
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
    /// Travel-time tags of the routes found; tapping one calls `onSelectBadge` with its route ID.
    var badges: [MapRouteBadge] = []
    var onSelectBadge: ((String) -> Void)?
    var secondaryStyle = SecondaryPathStyle.restOfTrip

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> GMSMapView {
        let mapView = LayoutReportingMapView()
        // Places the first camera as soon as the map has its real size.
        mapView.onLayout = { [weak coordinator = context.coordinator, weak mapView] in
            guard let coordinator, let mapView else { return }
            coordinator.placePendingCamera(on: mapView)
        }
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
        coordinator.onSelectBadge = onSelectBadge
        coordinator.chrome = chrome
        coordinator.applyStyle(colorScheme, to: mapView)
        coordinator.render(paths: paths, style: secondaryStyle, on: mapView)
        coordinator.render(markers: markers, on: mapView)
        coordinator.render(badges: badges, on: mapView)
        coordinator.updateUserLocation(userLocation, on: mapView)
        coordinator.updateVehicle(vehicle, on: mapView)
        coordinator.updateCamera(camera, paths: paths, markers: markers, on: mapView)
        coordinator.perform(command, camera: camera, paths: paths, markers: markers, on: mapView)
    }

    @MainActor
    final class Coordinator: NSObject, GMSMapViewDelegate {
        var onUserMoved: (() -> Void)?
        var onSelectBadge: ((String) -> Void)?
        var chrome = UIEdgeInsets.zero
        private var badgeMarkers: [GMSMarker] = []
        private var renderedBadges: [MapRouteBadge]?
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
        private var flightEnds = Date.distantPast
        /// The flight in progress, stepped every frame by `flightLink`.
        private var flight: (plan: CameraFlight, began: CFTimeInterval, duration: TimeInterval)?
        private var flightLink: CADisplayLink?
        private weak var flightMap: GMSMapView?
        /// The user has panned or zoomed since the current camera was applied.
        private var userMovedSinceCamera = false
        /// A camera asked for before the map had its size, placed on the next layout.
        private var pendingCamera: (camera: Camera, paths: [[GeoCoordinate]], markers: [MapStopMarker])?

        /// A route's travel-time tag chooses that route; other markers behave as usual.
        nonisolated func mapView(_ mapView: GMSMapView, didTap marker: GMSMarker) -> Bool {
            MainActor.assumeIsolated {
                guard let id = marker.userData as? String, let onSelectBadge else { return false }
                onSelectBadge(id)
                return true
            }
        }

        nonisolated func mapView(_ mapView: GMSMapView, willMove gesture: Bool) {
            guard gesture else { return }
            MainActor.assumeIsolated {
                endFlight()
                userMovedSinceCamera = true
                onUserMoved?()
            }
        }

        // MARK: Camera

        func perform(_ command: MapCommand?, camera: Camera, paths: [[GeoCoordinate]], markers: [MapStopMarker], on mapView: GMSMapView) {
            guard let command, command.id != lastCommandID else { return }
            lastCommandID = command.id
            switch command.action {
            case .zoomIn:
                move(mapView, with: GMSCameraUpdate.zoomIn(), motion: .ease(MapCameraDirector.zoomDuration))
            case .zoomOut:
                move(mapView, with: GMSCameraUpdate.zoomOut(), motion: .ease(MapCameraDirector.zoomDuration))
            case .fitRoute:
                fly(mapView, to: .overview, kind: .frame, paths: paths, markers: markers)
            case .reapplyCamera:
                if case let .follow(car, _) = camera {
                    fly(mapView, to: camera, kind: .anchored(car), paths: paths, markers: markers)
                } else {
                    fly(mapView, to: camera, kind: .frame, paths: paths, markers: markers)
                }
            }
        }

        func updateCamera(_ camera: Camera, paths: [[GeoCoordinate]], markers: [MapStopMarker], on mapView: GMSMapView) {
            let overview = Self.signature(paths) ^ markers.hashValue
            let planChanged = camera == .overview && appliedCamera == .overview && overview != framedOverview
            // updateUIView runs on every SwiftUI update: act only on a new camera (or a new plan).
            guard camera != appliedCamera || planChanged else { return }
            guard MapCameraDirector.canFrame(in: mapView.bounds.size, chrome: chrome) else {
                // Not laid out yet: placed once it is (see `placePendingCamera`).
                pendingCamera = (camera, paths, markers)
                return
            }
            pendingCamera = nil
            let now = Date()
            var lag: Double?
            if case let .follow(car, course) = camera {
                let target = MapCameraDirector.followCenter(car: car, heading: course ?? mapView.camera.bearing)
                let shown = mapView.camera.target
                lag = GeoMath.distance(GeoCoordinate(latitude: shown.latitude, longitude: shown.longitude), target)
            }
            var motion = MapCameraDirector.motion(
                from: appliedCamera, to: camera, sinceLastFix: now.timeIntervalSince(lastFix), isFlyingIn: now < flightEnds, lag: lag
            )
            if planChanged { motion = .flight(.frame) }
            if camera.isFollow { lastFix = now }
            let fromOverview = MapCameraDirector.flightStartsFromOverview(
                previous: appliedCamera, next: camera, userMoved: userMovedSinceCamera
            )
            if camera != appliedCamera { userMovedSinceCamera = false }
            appliedCamera = camera
            if camera == .overview { framedOverview = overview }
            guard let motion else { return }
            if case let .flight(kind) = motion {
                fly(mapView, to: camera, kind: kind, paths: paths, markers: markers, fromOverview: fromOverview)
                return
            }
            guard let update = cameraUpdate(for: camera, paths: paths, markers: markers, on: mapView) else { return }
            move(mapView, with: update, motion: motion)
        }

        /// Places a camera that was asked for before the map had its size.
        func placePendingCamera(on mapView: GMSMapView) {
            guard let pending = pendingCamera, MapCameraDirector.canFrame(in: mapView.bounds.size, chrome: chrome) else { return }
            updateCamera(pending.camera, paths: pending.paths, markers: pending.markers, on: mapView)
        }

        // MARK: Flights

        /// Flies from the camera on screen (or, see `MapCameraDirector.flightStartsFromOverview`,
        /// from the whole-trip overview) to `camera` (see `CameraFlight`), one step per frame.
        private func fly(
            _ mapView: GMSMapView, to camera: Camera, kind: CameraFlight.Kind, paths: [[GeoCoordinate]], markers: [MapStopMarker],
            fromOverview: Bool = false
        ) {
            guard let end = flightTarget(for: camera, paths: paths, markers: markers, on: mapView) else { return }
            let current = mapView.camera
            var start = CameraFlight.Camera(
                center: GeoCoordinate(current.target), scale: Self.scale(zoom: current.zoom),
                heading: current.bearing, pitch: current.viewingAngle
            )
            if fromOverview, let overview = flightTarget(for: .overview, paths: paths, markers: markers, on: mapView) {
                start = overview
            }
            let plan = CameraFlight(from: start, to: end, kind: kind)
            flight = (plan, CACurrentMediaTime(), plan.duration)
            flightEnds = Date().addingTimeInterval(plan.duration)
            flightMap = mapView
            if flightLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(stepFlight))
                link.add(to: .main, forMode: .common)
                flightLink = link
            }
        }

        @objc private func stepFlight() {
            guard let flight, let mapView = flightMap else {
                endFlight()
                return
            }
            let progress = (CACurrentMediaTime() - flight.began) / max(0.01, flight.duration)
            let camera = flight.plan.camera(at: progress)
            let heading = camera.heading.truncatingRemainder(dividingBy: 360)
            mapView.camera = GMSCameraPosition(
                target: camera.center.clCoordinate, zoom: Self.zoom(scale: camera.scale),
                bearing: heading < 0 ? heading + 360 : heading, viewingAngle: camera.pitch
            )
            if progress >= 1 { endFlight() }
        }

        private func endFlight() {
            flightLink?.invalidate()
            flightLink = nil
            flight = nil
            flightEnds = .distantPast
        }

        /// Where a flight to `camera` ends, as an engine-independent camera.
        private func flightTarget(
            for camera: Camera, paths: [[GeoCoordinate]], markers: [MapStopMarker], on mapView: GMSMapView
        ) -> CameraFlight.Camera? {
            switch camera {
            case .free:
                return nil
            case .overview, .frame:
                let (coordinates, fill) = camera == .overview
                    ? (paths.flatMap { $0 } + markers.map(\.coordinate), 0.9)
                    : (Self.framed(camera), MapCameraDirector.frameFill)
                guard let bounds = fitBounds(coordinates),
                      let position = mapView.camera(for: bounds, insets: MapCameraDirector.fitInsets(
                          in: mapView.bounds.size, chrome: chrome, fill: fill
                      )) else { return nil }
                return CameraFlight.Camera(center: GeoCoordinate(position.target), scale: Self.scale(zoom: position.zoom))
            case let .follow(car, course):
                let bearing = course ?? mapView.camera.bearing
                return CameraFlight.Camera(
                    center: MapCameraDirector.followCenter(car: car, heading: bearing),
                    scale: Self.scale(zoom: MapCameraDirector.followZoom), heading: bearing, pitch: MapCameraDirector.followPitch
                )
            }
        }

        private static func framed(_ camera: Camera) -> [GeoCoordinate] {
            if case let .frame(coordinates) = camera { return coordinates }
            return []
        }

        /// Flights measure zoom as 2^-zoom (proportional to the ground a screen point covers).
        private static func scale(zoom: Float) -> Double { pow(2, -Double(zoom)) }
        private static func zoom(scale: Double) -> Float { Float(-log2(max(scale, 1e-12))) }

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
            guard let bounds = fitBounds(coordinates) else { return nil }
            let insets = MapCameraDirector.fitInsets(in: mapView.bounds.size, chrome: chrome, fill: fill)
            return GMSCameraUpdate.fit(bounds, with: insets)
        }

        /// The bounds of `coordinates`, at least ~1 km across.
        private func fitBounds(_ coordinates: [GeoCoordinate]) -> GMSCoordinateBounds? {
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
            return bounds
        }

        private func move(_ mapView: GMSMapView, with update: GMSCameraUpdate, motion: MapCameraDirector.Motion) {
            switch motion {
            case .immediate:
                endFlight()
                mapView.moveCamera(update)
            case let .ease(duration):
                endFlight()
                Self.animate(duration: duration, timing: .easeInEaseOut) { mapView.animate(with: update) }
            case let .linear(duration):
                Self.animate(duration: duration, timing: .linear) { mapView.animate(with: update) }
            case .flight:
                break
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
                Self.animate(duration: duration * MapCameraDirector.glideShare, timing: .linear, place)
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
            renderedBadges = nil
        }

        /// The route being driven (strong, with a darker edge) over the rest of the trip (light).
        func render(paths: [[GeoCoordinate]], style: SecondaryPathStyle, on mapView: GMSMapView) {
            var hasher = Hasher()
            hasher.combine(Self.signature(paths))
            hasher.combine(style == .alternatives)
            let signature = hasher.finalize()
            guard signature != pathsSignature else { return }
            pathsSignature = signature
            let traits = UITraitCollection(userInterfaceStyle: styledScheme == .dark ? .dark : .light)
            let line = UIColor(Theme.routeLine).resolvedColor(with: traits)
            let casing = UIColor(Theme.routeCasing).resolvedColor(with: traits)
            let secondary = style == .alternatives
                ? UIColor(Theme.routeAlternative).resolvedColor(with: traits)
                : line.withAlphaComponent(0.38)

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
                    color: secondary, width: 5, zIndex: 1, on: mapView
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

        func render(badges: [MapRouteBadge], on mapView: GMSMapView) {
            guard badges != renderedBadges else { return }
            renderedBadges = badges
            badgeMarkers.forEach { $0.map = nil }
            let scheme = styledScheme ?? .light
            badgeMarkers = MapRouteBadge.drawingOrder(badges).enumerated().map { index, badge in
                let marker = GMSMarker(position: badge.coordinate.clCoordinate)
                let icon = Self.image(for: badge, scheme: scheme)
                marker.icon = icon
                // The pointer's tip on the route; the tag stands above it.
                marker.groundAnchor = RouteBadgeLabel.tipAnchor(in: icon?.size ?? .zero)
                marker.zIndex = Int32(30 + index)
                marker.userData = badge.id
                marker.accessibilityLabel = badge.accessibilityLabel
                marker.map = mapView
                return marker
            }
        }

        private static func image(for badge: MapRouteBadge, scheme: ColorScheme) -> UIImage? {
            let renderer = ImageRenderer(content: RouteBadgeLabel(text: badge.text, isSelected: badge.isSelected, isBest: badge.isBest)
                .environment(\.colorScheme, scheme))
            renderer.scale = UITraitCollection.current.displayScale
            return renderer.uiImage
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

/// A Google map view that reports its layout passes, so the first camera can be placed as soon as
/// the map has its real size (not a guess made before SwiftUI sized it).
final class LayoutReportingMapView: GMSMapView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
