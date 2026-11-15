import MapKit
import TripFeatures
import TripModels
import UIKit

/// Camera choreography shared by the Apple and Google maps: where to look, and how to get there
/// without jumps.
///
/// * Framing is computed explicitly from the map's size and the chrome covering it (no safe-area
///   padding), so changing the chrome never shifts the map, and zooming always starts from the
///   view on screen.
/// * Big moves are *flights* that start from the view on screen and keep their subject in sight
///   the whole way: zooming from the whole trip into a leg keeps the leg on screen (north-up), and
///   going from a leg down to the car keeps the car on screen while the map turns and tilts.
/// * While following, each GPS fix glides linearly over the time since the previous fix, so the
///   camera moves continuously instead of stepping.
enum MapCameraDirector {
    /// How to move the camera to a new target.
    enum Motion: Equatable {
        /// Jump (first placement).
        case immediate
        /// A flight from the view on screen (see `CameraFlight`).
        case flight(CameraFlight.Kind)
        /// Ease in and out over the duration (the zoom buttons).
        case ease(TimeInterval)
        /// Constant speed over the duration (following the car between fixes).
        case linear(TimeInterval)
    }

    /// A framed route fills about this much of the visible map.
    static let frameFill = 0.8
    static let zoomDuration: TimeInterval = 0.4
    /// Longest glide between two fixes (a longer gap just catches up within this time).
    static let maximumGlide: TimeInterval = 1.0
    /// A glide takes this share of the time since the previous fix, so it ends before the next
    /// fix arrives instead of being interrupted by it.
    static let glideShare = 0.8
    /// If the camera is this far behind the car anyway, it jumps to it.
    static let catchUpDistance: Double = 1_000
    /// Follow camera: distance (Apple) / zoom (Google) and tilt.
    static let followDistance: Double = 1_500
    static let followZoom: Float = 16.5
    static let followPitch: Double = 45
    /// The follow camera looks this far ahead of the car, so the car sits in the lower part of the
    /// screen with more road ahead visible.
    static let followLookAhead: Double = 230

    /// How to move from `old` to `new`, or nil to leave the camera alone.
    /// - Parameters:
    ///   - sinceLastFix: seconds since the previous follow update.
    ///   - isFlyingIn: a flight to the car is still running.
    ///   - lag: how far the camera on screen is from where it should be, in meters, if known.
    static func motion(
        from old: TripMapView.Camera?, to new: TripMapView.Camera, sinceLastFix: TimeInterval, isFlyingIn: Bool,
        lag: Double? = nil
    ) -> Motion? {
        guard let old else { return new == .free ? nil : .immediate }
        switch new {
        case .free:
            return nil
        case .overview, .frame:
            return .flight(.frame)
        case let .follow(car, _):
            if !old.isFollow { return .flight(.anchored(car)) }
            if isFlyingIn { return nil }
            if let lag, lag > catchUpDistance { return .immediate }
            return .linear(min(maximumGlide, max(0.05, sinceLastFix)) * glideShare)
        }
    }

    /// Whether a flight to `new` starts from the whole-trip overview instead of from the camera the
    /// map reports: when the overview is what the map was last asked to show (drive mode opening
    /// on the whole trip, then zooming into the leg) and nobody has moved the map since. Right
    /// after a map appears, the camera it reports can still be its default one (far from the
    /// route) even though the overview is being drawn; starting there would sweep across
    /// unrelated places.
    static func flightStartsFromOverview(previous: TripMapView.Camera?, next: TripMapView.Camera, userMoved: Bool) -> Bool {
        guard previous == .overview, !userMoved, case .frame = next else { return false }
        return true
    }

    /// Whether a map of `size` is laid out enough to frame routes clear of `chrome` (it can first
    /// get a placeholder size while a screen slides in, which would frame them wrongly).
    static func canFrame(in size: CGSize, chrome: UIEdgeInsets) -> Bool {
        size.width > chrome.left + chrome.right + 40 && size.height > chrome.top + chrome.bottom + 40
    }

    // MARK: Drive mode

    /// What the camera does while guiding.
    enum GuidingView: Equatable {
        /// Behind the car, heading up.
        case follow
        /// The route to the next stop ("Show route").
        case overview([GeoCoordinate])
        /// Where the user panned or zoomed to; "Re-center" returns to `follow`.
        case free
    }

    /// How long drive mode shows the whole trip (once its directions are loaded) before zooming
    /// into the leg.
    static let wholeTripHold: TimeInterval = 0.7

    /// Drive mode's camera. Every way into drive mode (Start driving, Resume, continuing from a
    /// stop) goes through here and through the same flights, so they all move alike: the whole
    /// trip first, then the leg to the next stop (flying from the whole trip and keeping the leg in
    /// view, see `flightStartsFromOverview`), then, on Start, down to the car (keeping the car in
    /// view). Change the choreography here, in one place.
    /// - Parameters:
    ///   - showsWholeTrip: drive mode has just opened (see `wholeTripHold`).
    ///   - route: the route from the car to the next stop (to face along before the car moves).
    static func driveCamera(
        showsWholeTrip: Bool, mode: DriveViewModel.Mode, stage: DriveViewModel.Stage, guiding: GuidingView,
        previewFrame: [GeoCoordinate], car: GeoCoordinate?, course: Double?, route: [GeoCoordinate]
    ) -> TripMapView.Camera {
        if showsWholeTrip { return .overview }
        switch mode {
        case .completed:
            return .overview
        case .atStop:
            return .frame(previewFrame)
        case .driving:
            guard stage == .navigating else { return .frame(previewFrame) }
            switch guiding {
            case .follow:
                guard let car else { return .frame(previewFrame) }
                // Before the car has a course (standing still), face along the route.
                return .follow(car, course: course ?? heading(along: route))
            case let .overview(coordinates):
                return .frame(coordinates)
            case .free:
                return .free
            }
        }
    }

    /// The direction a route leaves its first point in (ignoring points within 30 m).
    static func heading(along route: [GeoCoordinate]) -> Double? {
        guard let start = route.first, let ahead = route.dropFirst().first(where: { GeoMath.distance(start, $0) > 30 }) else {
            return nil
        }
        return GeoMath.bearing(from: start, to: ahead)
    }

    /// Where the follow camera points: ahead of the car along its course (or the map's heading).
    static func followCenter(car: GeoCoordinate, heading: Double) -> GeoCoordinate {
        GeoMath.destination(from: car, bearing: heading, distance: followLookAhead)
    }

    /// A north-up map rect for a view of `size` in which `coordinates` fill about `fill` of the
    /// area left uncovered by `insets`, centred in that area. At least ~1 km across.
    static func framingRect(
        for coordinates: [GeoCoordinate], in size: CGSize, insets: UIEdgeInsets, fill: Double = frameFill
    ) -> MKMapRect? {
        guard !coordinates.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let points = coordinates.map { MKMapPoint($0.clCoordinate) }
        let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 0
        let minimumSide = 1_000 * MKMapPointsPerMeterAtLatitude(coordinates[0].latitude)
        let width = max(maxX - minX, minimumSide), height = max(maxY - minY, minimumSide)
        let visibleWidth = max(1, size.width - insets.left - insets.right)
        let visibleHeight = max(1, size.height - insets.top - insets.bottom)
        // Map points per screen point, so the box fits the visible area at `fill`.
        let scale = max(width / (fill * visibleWidth), height / (fill * visibleHeight))
        let centerX = (minX + maxX) / 2, centerY = (minY + maxY) / 2
        let visibleCenterX = insets.left + visibleWidth / 2, visibleCenterY = insets.top + visibleHeight / 2
        return MKMapRect(
            x: centerX - visibleCenterX * scale,
            y: centerY - visibleCenterY * scale,
            width: size.width * scale,
            height: size.height * scale
        )
    }

    /// Insets for Google's `fit(_:with:)`: the chrome plus the margin that makes the route fill
    /// `fill` of the visible area.
    static func fitInsets(in size: CGSize, chrome: UIEdgeInsets, fill: Double = frameFill) -> UIEdgeInsets {
        let visibleWidth = max(1, size.width - chrome.left - chrome.right)
        let visibleHeight = max(1, size.height - chrome.top - chrome.bottom)
        let marginX = visibleWidth * (1 - fill) / 2, marginY = visibleHeight * (1 - fill) / 2
        return UIEdgeInsets(
            top: chrome.top + marginY, left: chrome.left + marginX,
            bottom: chrome.bottom + marginY, right: chrome.right + marginX
        )
    }
}

extension TripMapView.Camera {
    var isFollow: Bool {
        if case .follow = self { return true }
        return false
    }
}
