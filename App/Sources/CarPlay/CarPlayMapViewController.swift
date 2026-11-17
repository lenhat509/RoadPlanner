import CarPlay
import GoogleMaps
import GoogleNavigation
import MapKit
import UIKit

/// The CarPlay base view: only a map (Apple's CarPlay rules). In the App Store build it is a
/// Google map showing the Navigation SDK's route and car; CarPlay's own templates draw the
/// maneuver card and the buttons, so the map's header, footer and buttons are off (no part of the
/// map is tappable on CarPlay). Offline (demo mode) it is an Apple map with no Google content.
@MainActor
final class CarPlayMapViewController: UIViewController {
    private let screen: UIScreen
    private let usesGoogle: Bool
    private(set) var googleMap: GMSMapView?
    private(set) var appleMap: MKMapView?
    private weak var session: GMSNavigationSession?

    init(screen: UIScreen, usesGoogle: Bool) {
        self.screen = screen
        self.usesGoogle = usesGoogle
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        if usesGoogle {
            let options = GMSMapViewOptions()
            options.screen = screen
            options.frame = view.bounds
            let map = GMSMapView(options: options)
            map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            map.isMyLocationEnabled = true
            configure(map)
            view.addSubview(map)
            googleMap = map
            if let session { enableNavigation(with: session) }
        } else {
            let map = MKMapView(frame: view.bounds)
            map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            map.showsUserLocation = true
            map.userTrackingMode = .followWithHeading
            view.addSubview(map)
            appleMap = map
        }
    }

    /// Shows the navigation session (route, car, camera) on the map.
    func enableNavigation(with session: GMSNavigationSession) {
        self.session = session
        guard let googleMap else { return }
        _ = googleMap.enableNavigation(with: session)
        configure(googleMap)
    }

    private func configure(_ map: GMSMapView) {
        map.settings.isNavigationHeaderEnabled = false
        map.settings.isNavigationFooterEnabled = false
        map.settings.compassButton = false
        map.settings.isRecenterButtonEnabled = false
        map.settings.showsDestinationMarkers = true
        map.shouldDisplaySpeedometer = false
    }

    // MARK: Camera (from CarPlay's map buttons)

    /// Follows the car while guiding; otherwise shows where the car is.
    func recenter(guiding: Bool) {
        if let googleMap {
            if guiding {
                googleMap.cameraMode = .following
            } else {
                googleMap.cameraMode = .free
                if let location = googleMap.myLocation {
                    googleMap.animate(to: GMSCameraPosition(target: location.coordinate, zoom: 14))
                }
            }
        }
        appleMap?.setUserTrackingMode(.followWithHeading, animated: true)
    }

    func showRouteOverview() {
        googleMap?.cameraMode = .overview
    }

    func zoom(in zoomsIn: Bool) {
        if let googleMap {
            googleMap.animate(with: zoomsIn ? GMSCameraUpdate.zoomIn() : GMSCameraUpdate.zoomOut())
        }
        if let appleMap {
            var region = appleMap.region
            let factor = zoomsIn ? 0.5 : 2.0
            region.span.latitudeDelta = min(90, region.span.latitudeDelta * factor)
            region.span.longitudeDelta = min(180, region.span.longitudeDelta * factor)
            appleMap.setRegion(region, animated: true)
        }
    }

    func pan(_ direction: CPMapTemplate.PanDirection) {
        let distance: CGFloat = 80
        var offset = CGPoint.zero
        if direction.contains(.left) { offset.x -= distance }
        if direction.contains(.right) { offset.x += distance }
        if direction.contains(.up) { offset.y -= distance }
        if direction.contains(.down) { offset.y += distance }
        if offset.x != 0 && offset.y != 0 {
            offset = CGPoint(x: offset.x * CGFloat(0.5.squareRoot()), y: offset.y * CGFloat(0.5.squareRoot()))
        }
        if let googleMap {
            googleMap.animate(with: GMSCameraUpdate.scrollBy(x: offset.x, y: offset.y))
        }
        if let appleMap {
            appleMap.userTrackingMode = .none
            let target = CGPoint(x: appleMap.bounds.midX + offset.x, y: appleMap.bounds.midY + offset.y)
            appleMap.setCenter(appleMap.convert(target, toCoordinateFrom: appleMap), animated: true)
        }
    }
}
