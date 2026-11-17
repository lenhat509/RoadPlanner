import CoreLocation
import GoogleMaps
import GoogleNavigation
import TripFeatures
import TripModels
import TripNavigation
import UIKit
import UserNotifications

/// Turn-by-turn navigation with Google's Navigation SDK (App Store build).
///
/// The SDK computes each leg's route from the phone's position, guides turn by turn with its own
/// voice, reroutes, and reports arrival. Its map draws the route, the car and the turn header
/// (`TripMapView` with a `NavigationMapState`, and the CarPlay map). There is one navigation
/// session for the app, shared by the iPhone's drive screen and the CarPlay screen.
///
/// Google's terms dialog (which also covers driver awareness) must be accepted before the session
/// exists: `requestTerms()` shows it at first launch and before a drive while it hasn't been.
@MainActor
final class GoogleNavigationEngine: NSObject, TurnByTurnGuidance {
    let drawsOwnGuidance = true
    var eventHandler: (@MainActor (GuidanceEvent) async -> Void)?
    var isMuted = false {
        didSet { applyVoice() }
    }

    /// The session the maps enable navigation with; nil until Google's terms are accepted.
    private(set) var session: GMSNavigationSession?
    /// Turn-by-turn data for the CarPlay screen (maneuvers, lanes, estimates).
    var onNavInfo: (@MainActor (GMSNavigationNavInfo) -> Void)?
    /// Called when the session is created (the CarPlay map then shows navigation).
    var onSessionReady: (@MainActor (GMSNavigationSession) -> Void)?
    /// Whether guidance is running.
    private(set) var isGuiding = false

    private let companyName: String
    /// Developer option: drive the route with the SDK's location simulator (CarPlay simulator,
    /// desk testing). Off in normal use.
    private let simulatesLocation: Bool
    private var isShowingTerms = false
    private var isRerouting = false
    /// Bumped by every new destination and by stopping, so a stale route callback is ignored.
    private var request = 0
    /// Events are delivered one after another, in the order the SDK reported them.
    private var lastDelivery: Task<Void, Never>?

    init(companyName: String, simulatesLocation: Bool = false) {
        self.companyName = companyName
        self.simulatesLocation = simulatesLocation
        super.init()
    }

    private var navigator: GMSNavigator? { session?.navigator }

    static var areTermsAccepted: Bool { GMSNavigationServices.areTermsAndConditionsAccepted() }

    /// Shows Google's navigation terms if they haven't been accepted (from a screen that can
    /// present a dialog: first launch, or before drive mode opens). Returns whether they are.
    @discardableResult
    func requestTerms() async -> Bool {
        if Self.areTermsAccepted { return true }
        guard !isShowingTerms else { return false }
        isShowingTerms = true
        defer { isShowingTerms = false }
        let options = GMSNavigationTermsAndConditionsOptions(companyName: companyName)
        let accepted = await withCheckedContinuation { continuation in
            GMSNavigationServices.showTermsAndConditionsDialogIfNeeded(with: options) { accepted in
                continuation.resume(returning: accepted)
            }
        }
        if accepted {
            // Guidance reaches the lock screen as notifications while the app is in the background.
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        }
        return accepted
    }

    // MARK: TurnByTurnGuidance

    func prepare() async throws {
        if session != nil { return }
        // Drive mode is shown full screen, over which the SDK can't present its dialog: the terms
        // are asked for before it opens (`requestTerms`).
        guard Self.areTermsAccepted else { throw GuidanceError.termsNotAccepted }
        guard let session = GMSNavigationServices.createNavigationSession() else {
            throw GuidanceError.failed("The navigation session couldn't be created.")
        }
        session.travelMode = .driving
        session.isStarted = true
        session.roadSnappedLocationProvider?.allowsBackgroundLocationUpdates = true
        if let navigator = session.navigator {
            navigator.add(self)
            navigator.stopGuidanceAtArrival = true
            navigator.sendsBackgroundNotifications = true
            navigator.timeUpdateThreshold = 5
            navigator.distanceUpdateThreshold = 25
        }
        self.session = session
        applyVoice()
        onSessionReady?(session)
    }

    func setDestination(_ destination: GuidanceDestination, from origin: GeoCoordinate?) async throws -> GuidanceRoute {
        guard let navigator else { throw GuidanceError.termsNotAccepted }
        navigator.isGuidanceActive = false
        setGuiding(false)
        request += 1
        let current = request
        var status = await route(to: destination, placeID: destination.placeID)
        if status == .waypointError, destination.placeID != nil, current == request {
            // A place ID Google no longer knows: the stop's position still works.
            status = await route(to: destination, placeID: nil)
        }
        guard current == request else { throw GuidanceError.canceled }
        if let error = Self.error(for: status) { throw error }
        return currentRoute() ?? GuidanceRoute(
            coordinates: [], distanceMeters: max(0, navigator.distanceToNextDestination),
            duration: max(0, navigator.timeToNextDestination)
        )
    }

    func startGuidance() async {
        guard let navigator, navigator.currentRouteLeg != nil else { return }
        navigator.isGuidanceActive = true
        if simulatesLocation { session?.locationSimulator?.simulateLocationsAlongExistingRoute() }
        setGuiding(true)
        deliverProgress()
    }

    func stopGuidance() {
        request += 1
        isRerouting = false
        guard let navigator else { return }
        navigator.isGuidanceActive = false
        navigator.clearDestinations()
        if simulatesLocation { session?.locationSimulator?.stopSimulation() }
        setGuiding(false)
    }

    func didUpdateLocation(_ sample: LocationSample) async {
        // The SDK follows the phone itself.
    }

    // MARK: Internals

    private func route(to destination: GuidanceDestination, placeID: String?) async -> GMSRouteStatus {
        guard let navigator else { return .internalError }
        let location = destination.coordinate.clCoordinate
        let waypoint = placeID.flatMap { GMSNavigationWaypoint(location: location, placeID: $0, title: destination.name) }
            ?? GMSNavigationWaypoint(location: location, title: destination.name)
        guard let waypoint else { return .waypointError }
        return await withCheckedContinuation { continuation in
            navigator.setDestinations([waypoint], completionHandler: { description, _ in
                continuation.resume(returning: description?.routeStatus ?? .internalError)
            })
        }
    }

    private static func error(for status: GMSRouteStatus) -> GuidanceError? {
        switch status {
        case .OK:
            return nil
        case .noRouteFound, .waypointError:
            return GuidanceError.noRoute
        case .networkError:
            return GuidanceError.network
        case .locationUnavailable:
            return GuidanceError.locationUnavailable
        case .quotaExceeded:
            return GuidanceError.notAuthorized
        case .canceled:
            return GuidanceError.canceled
        default:
            // 5: the API key isn't authorized for the Navigation SDK.
            return status.rawValue == 5 ? GuidanceError.notAuthorized : GuidanceError.failed("Route status \(status.rawValue)")
        }
    }

    /// The route the navigator has to the destination (kept in memory only).
    private func currentRoute() -> GuidanceRoute? {
        guard let navigator, let path = navigator.currentRouteLeg?.path, path.count() > 1 else { return nil }
        let coordinates = (0..<path.count()).map { GeoCoordinate(path.coordinate(at: $0)) }
        let distance = navigator.distanceToNextDestination
        return GuidanceRoute(
            coordinates: coordinates,
            distanceMeters: distance > 0 ? distance : GeoMath.length(of: coordinates),
            duration: max(0, navigator.timeToNextDestination)
        )
    }

    private func applyVoice() {
        navigator?.voiceGuidance = isMuted ? .silent : .alertsAndGuidance
    }

    private func setGuiding(_ guiding: Bool) {
        isGuiding = guiding
    }

    private func deliverProgress() {
        guard let navigator else { return }
        let distance = navigator.distanceToNextDestination, time = navigator.timeToNextDestination
        guard distance >= 0, time >= 0 else { return }
        deliver(.progress(distanceRemaining: distance, timeRemaining: time))
    }

    private func deliver(_ event: GuidanceEvent) {
        let previous = lastDelivery
        lastDelivery = Task { @MainActor [weak self] in
            await previous?.value
            await self?.eventHandler?(event)
        }
    }

    /// Runs SDK callbacks on the main actor (they arrive on the main thread).
    nonisolated private func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
    }
}

extension GoogleNavigationEngine: GMSNavigatorListener {
    nonisolated func navigator(_ navigator: GMSNavigator, didArriveAt waypoint: GMSNavigationWaypoint) {
        onMain { [weak self] in
            guard let self else { return }
            self.setGuiding(false)
            self.deliver(.arrived)
        }
    }

    nonisolated func navigatorDidChangeRoute(_ navigator: GMSNavigator) {
        onMain { [weak self] in
            guard let self, let route = self.currentRoute() else { return }
            self.deliver(.routeChanged(route))
        }
    }

    nonisolated func navigator(_ navigator: GMSNavigator, didUpdateRemainingTime time: TimeInterval) {
        onMain { [weak self] in self?.deliverProgress() }
    }

    nonisolated func navigator(_ navigator: GMSNavigator, didUpdateRemainingDistance distance: CLLocationDistance) {
        onMain { [weak self] in self?.deliverProgress() }
    }

    @objc(navigator:didUpdateNavInfo:)
    nonisolated func navigator(_ navigator: GMSNavigator, didUpdate navInfo: GMSNavigationNavInfo) {
        onMain { [weak self] in
            guard let self else { return }
            let rerouting = navInfo.navState == .rerouting
            if rerouting != self.isRerouting {
                self.isRerouting = rerouting
                self.deliver(.rerouting(rerouting))
            }
            self.onNavInfo?(navInfo)
        }
    }
}
