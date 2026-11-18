import SwiftUI
import TripFeatures
import TripModels
import UIKit

/// Turn-by-turn drive mode, laid out like the navigation apps drivers already know: the next turn
/// at the very top, the map in the middle, and a bottom sheet with the time left, the next stop,
/// a red exit button and one menu.
///
/// In the App Store build, Google's Navigation SDK guides on the map: it draws the route, the car,
/// the turn-by-turn header, the speed and its re-center button, and speaks the directions. While
/// it guides, Waystage's bottom panel is docked to the bottom of the screen and the map ends
/// where it starts, so the panel never covers the car, the route or any of Google's navigation
/// controls (Google's policies don't allow hiding them).
///
/// Every leg opens as a *preview* — starting a trip, resuming one, continuing from a stop: the map
/// opens on the route from the car to the next stop (north-up, no zooming in from elsewhere),
/// with a Start button. Start goes down to the car: Google's following camera in the App Store
/// build, a flight that keeps the car in view offline.
struct DriveScreen: View {
    /// What the camera does while guiding.
    typealias CameraMode = MapCameraDirector.GuidingView

    let model: DriveViewModel
    @State private var showsSafetyNotice: Bool
    @State private var confirmsEnd = false
    @State private var cameraMode = CameraMode.follow
    /// Where the floating bottom panel starts, and where the map ends (screen coordinates): routes
    /// are framed above the panel.
    @State private var panelTop: CGFloat?
    @State private var mapBottom: CGFloat?
    /// The docked panel's height while guiding: the map ends at its top.
    @State private var dockHeight: CGFloat = 0
    @State private var mapCommand: MapCommand?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    private let dependencies: AppDependencies
    /// Google's Navigation SDK (App Store build).
    private let navigation: GoogleNavigationEngine?
    /// Leaves drive mode (the environment stops the drive).
    let onFinish: () -> Void

    init(model: DriveViewModel, dependencies: AppDependencies, navigation: GoogleNavigationEngine?, onFinish: @escaping () -> Void) {
        self.model = model
        _showsSafetyNotice = State(initialValue: !dependencies.preferences.load().hasAcceptedSafetyNotice)
        self.dependencies = dependencies
        self.navigation = navigation
        self.onFinish = onFinish
    }

    var body: some View {
        Group {
            if showsSafetyNotice {
                // Shown inline rather than as a sheet: presenting a sheet while the full-screen
                // cover is still animating in can be dropped by UIKit.
                SafetyNoticeView {
                    var preferences = dependencies.preferences.load()
                    preferences.hasAcceptedSafetyNotice = true
                    dependencies.preferences.save(preferences)
                    withAnimation { showsSafetyNotice = false }
                }
            } else {
                driveContent
            }
        }
        .task(id: showsSafetyNotice) {
            guard !showsSafetyNotice else { return }
            await model.start()
        }
        // The Navigation SDK doesn't keep the screen on by itself.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: scenePhase) { _, phase in
            // Guidance keeps running in the background; nothing to pause. Progress is auto-saved.
            if phase == .active { UIApplication.shared.isIdleTimerDisabled = true }
        }
        .confirmationDialog("End this trip?", isPresented: $confirmsEnd, titleVisibility: .visible) {
            Button("End trip", role: .destructive) {
                Task {
                    await model.endTrip()
                    onFinish()
                }
            }
            Button("Keep driving", role: .cancel) {}
        } message: {
            Text("Your progress on this trip will be cleared.")
        }
        // Google's map and banner switch between their day and night looks with the time of day
        // where the car is (not the phone's appearance): drive mode's own panels, menus and
        // status bar follow the same switch. Offline, the map follows the phone, and so does
        // drive mode.
        .preferredColorScheme(navigation != nil ? (model.isNight == true ? .dark : .light) : nil)
    }

    private var isGuiding: Bool { model.mode == .driving && model.stage == .navigating }
    private var isPreviewing: Bool { model.mode == .driving && model.stage == .preview }
    /// Google's Navigation SDK is guiding on the map (App Store build).
    private var isGoogleGuiding: Bool { isGuiding && navigationMap != nil }

    /// One map for the whole drive (so it never reloads).
    ///
    /// * Preview, at a stop, at the end: the panel floats over the map, and the app's camera frames
    ///   the route above the panel's measured top (`chrome`).
    /// * While guiding: the panel itself is the bottom of the screen (full width, no margins) and
    ///   the map ends exactly where it starts, so the car, which Google's camera keeps near the
    ///   bottom of its map, the route and Google's logo, buttons and speed display are never
    ///   under it. The mute and route buttons sit at the map's trailing edge, mid-height.
    private var driveContent: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .top) {
                map
                    .ignoresSafeArea(edges: isGuiding ? .top : .all)

                VStack(spacing: Theme.Spacing.s) {
                    if isGoogleGuiding {
                        // Google's turn banner is at the top of its map.
                        Spacer(minLength: 0)
                        HStack {
                            Spacer()
                            guidingButtons
                        }
                        Spacer(minLength: 0)
                    } else {
                        topArea
                        HStack(alignment: .top) {
                            Spacer()
                            if isGuiding { guidingButtons } else { sideControls }
                        }
                        Spacer(minLength: 0)
                        if isGuiding && cameraMode != .follow && !model.engineDrawsGuidance {
                            recenterButton
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                        if !isGuiding {
                            bottomPanel
                                .onGeometryChange(for: CGFloat.self) { proxy in
                                    proxy.frame(in: .global).minY
                                } action: { top in
                                    panelTop = top
                                }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.bottom, Theme.Spacing.xs)
            }
            // The map ends exactly where the docked panel starts: nothing of Google's (the car,
            // its logo, buttons and speed display at the bottom corners) is under the panel.
            .padding(.bottom, isGuiding ? dockHeight : 0)

            if isGuiding {
                dock
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.mode)
        .animation(.easeInOut(duration: 0.25), value: model.stage)
        .animation(.easeInOut(duration: 0.2), value: cameraMode)
    }

    /// The panel while guiding: the panel itself is the bottom of the screen (full width, down to
    /// the bottom edge, no container or margins around it), in the same light or dark theme as the
    /// map, set apart from Google's map by a shadow along its top edge.
    private var dock: some View {
        VStack(spacing: 0) {
            if isGoogleGuiding, let message = model.statusMessage {
                StatusPill(message: message, onDismiss: model.dismissStatus)
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.top, Theme.Spacing.s)
            }
            bottomPanel
        }
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            dockHeight = height
        }
    }

    private var map: some View {
        RouteMap(
            paths: paths,
            markers: markers,
            camera: camera,
            chrome: chrome,
            // Google's map draws the car itself.
            vehicle: model.engineDrawsGuidance
                ? nil : model.currentLocation.map { TripMapView.Vehicle(coordinate: $0, course: model.currentCourse) },
            command: mapCommand,
            onUserMoved: userMovedMap,
            navigation: navigationMap,
            onRecenter: { cameraMode = .follow }
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).maxY
        } action: { bottom in
            mapBottom = bottom
        }
    }

    // MARK: Map

    /// Google's navigation on the map (App Store build). The session is made before drive mode
    /// opens (`AppEnvironment.beginDrive`), so the map has it from the start.
    private var navigationMap: NavigationMapState? {
        guard let session = navigation?.session else { return nil }
        let camera: NavigationMapState.Camera = switch cameraMode {
        case .follow: .following
        case .overview: .overview
        case .free: .free
        }
        return NavigationMapState(session: session, isGuiding: isGuiding, camera: camera, isNight: model.isNight == true)
    }

    /// The leg being driven (strong) and the rest of the trip (light). Google's map draws the
    /// route it guides along itself.
    private var paths: [[GeoCoordinate]] {
        var paths = [model.drawsRouteToTarget ? model.routeToTarget : []]
        if !model.routeAfterTarget.isEmpty { paths.append(model.routeAfterTarget) }
        return paths
    }

    /// The same for every way into drive mode (see `MapCameraDirector.driveCamera`).
    private var camera: TripMapView.Camera {
        MapCameraDirector.driveCamera(
            mode: model.mode, stage: model.stage, guiding: cameraMode,
            previewFrame: model.previewFrame, car: model.currentLocation, course: model.currentCourse,
            route: model.routeToTarget
        )
    }

    /// The parts of the map covered by the header and the bottom sheet, which framed routes stay
    /// clear of. (Only used for framing, so changing it never moves the map by itself.)
    private var chrome: UIEdgeInsets {
        var chrome: UIEdgeInsets
        switch model.mode {
        case .driving where model.stage == .preview:
            chrome = UIEdgeInsets(top: 150, left: 24, bottom: 340, right: 64)
        case .driving:
            // Guiding: the map ends at the docked panel.
            return UIEdgeInsets(top: 220, left: 24, bottom: 16, right: 64)
        case .atStop:
            chrome = UIEdgeInsets(top: 70, left: 24, bottom: 320, right: 64)
        case .completed:
            chrome = UIEdgeInsets(top: 70, left: 24, bottom: 300, right: 24)
        }
        // The floating panel's real height when it's taller than expected (larger text, a longer
        // stop description): routes, and the car at their start, stay above it.
        if let panelTop, let mapBottom, mapBottom > panelTop {
            chrome.bottom = max(chrome.bottom, mapBottom - panelTop + 16)
        }
        return chrome
    }

    /// The stops still ahead; while heading to the trip's start, the start too.
    private var markers: [MapStopMarker] {
        let trip = model.trip
        let first = model.isHeadingToStart ? 0 : trip.progress.targetStopIndex
        let remaining = trip.itinerary.stops.enumerated()
            .filter { $0.offset >= first && !trip.progress.skippedStopIDs.contains($0.element.id) }
            .map(\.element)
        let active = model.isHeadingToStart ? trip.itinerary.stops.first?.id : trip.targetStop?.id
        return MapContent.markers(for: remaining, activeID: active)
    }

    private func userMovedMap() {
        if isGuiding { cameraMode = .free }
    }

    // MARK: Chrome

    @ViewBuilder
    private var topArea: some View {
        if isGuiding {
            if let banner = model.banner {
                ManeuverBannerView(banner: banner, isRerouting: model.isRerouting)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                StatusPill(message: "Finding the route…", systemImage: "location.magnifyingglass")
            }
        } else if isPreviewing, let info = model.nextStop {
            PreviewHeader(destination: info)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        if let message = model.statusMessage {
            StatusPill(message: message, onDismiss: model.dismissStatus)
        }
    }

    /// Mute and route overview while guiding: at the map's trailing edge, mid-height, clear of the
    /// car, Google's turn banner, its buttons and logo (Google's guides describe adding controls
    /// to the navigation map this way).
    private var guidingButtons: some View {
        VStack(spacing: Theme.Spacing.xs) {
            MapControlButton(
                systemImage: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: model.isMuted ? "Unmute voice" : "Mute voice"
            ) {
                model.isMuted.toggle()
            }
            .accessibilityIdentifier(AccessibilityID.Drive.mute)
            MapControlButton(systemImage: "point.topleft.down.to.point.bottomright.curvepath", label: "Show route") {
                cameraMode = .overview(model.routeToTarget)
            }
            .accessibilityIdentifier(AccessibilityID.Drive.overview)
        }
    }

    /// Zoom buttons over the map in the preview and at a stop (the app's own camera).
    @ViewBuilder
    private var sideControls: some View {
        if isPreviewing || model.mode == .atStop {
            VStack(spacing: Theme.Spacing.xs) {
                MapControlButton(systemImage: "plus", label: "Zoom in") { mapCommand = MapCommand(action: .zoomIn) }
                MapControlButton(systemImage: "minus", label: "Zoom out") { mapCommand = MapCommand(action: .zoomOut) }
                MapControlButton(systemImage: "scope", label: "Show the next leg") { mapCommand = MapCommand(action: .reapplyCamera) }
            }
        }
    }

    private var recenterButton: some View {
        Button {
            cameraMode = .follow
        } label: {
            Label("Re-center", systemImage: "location.north.line.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(Theme.card, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.Drive.recenter)
    }

    @ViewBuilder
    private var bottomPanel: some View {
        switch model.mode {
        case .driving where model.stage == .preview:
            PreviewSheet(
                info: model.nextStop,
                headline: model.isHeadingToStart ? "Head to the start of your trip" : nil,
                startTitle: model.isHeadingToStart ? "Directions to start" : "Start",
                onExit: exitDrive,
                onStart: startNavigation
            ) {
                menuContent
            }
        case .driving:
            NextStopPanel(
                info: model.nextStop,
                canContinue: model.canContinueToNextStop,
                ribbon: model.ribbonMarks,
                progress: model.tripProgress,
                onExit: exitDrive,
                onContinue: continueToNext
            ) {
                menuContent
            }
        case .atStop:
            ArrivalCard(
                info: model.nextStop,
                nextStopName: model.trip.stopAfterTarget?.place.name,
                onExit: exitDrive,
                onContinue: continueToNext
            ) {
                menuContent
            }
        case .completed:
            CompletedCard(
                destination: model.trip.itinerary.request.destination.name,
                summary: completionSummary
            ) {
                Task {
                    await model.endTrip()
                    onFinish()
                }
            }
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        if model.isHeadingToStart {
            Button {
                Task { await model.startTripFromHere() }
            } label: {
                Label("Start the trip from here", systemImage: "location.fill")
            }
            .accessibilityIdentifier(AccessibilityID.Drive.startHere)
        }
        // A trip that hasn't started has nothing to arrive at or skip yet (it starts on Start).
        let isUnderway = model.trip.progress.phase == .enRoute
        if model.mode == .driving && (isUnderway || model.isHeadingToStart) {
            Button {
                Task { await model.confirmArrival() }
            } label: {
                Label(model.isHeadingToStart ? "I'm at the start" : "I've arrived", systemImage: "checkmark.circle")
            }
            .accessibilityIdentifier(AccessibilityID.Drive.arrived)
            if isUnderway && !model.trip.isFinalTarget {
                Button {
                    Task { await model.skipTargetStop() }
                } label: {
                    Label("Skip this stop", systemImage: "forward.end")
                }
                .accessibilityIdentifier(AccessibilityID.Drive.skip)
            }
        }
        if let url = model.googleMapsURL {
            Button {
                openURL(url)
            } label: {
                Label("Open in Google Maps", systemImage: "map")
            }
        }
        Button(role: .destructive) {
            confirmsEnd = true
        } label: {
            Label("End trip", systemImage: "xmark.octagon")
        }
        .accessibilityIdentifier(AccessibilityID.Drive.endTrip)
    }

    private var completionSummary: String {
        let formatters = dependencies.formatters
        let totals = model.trip.itinerary.totals
        return "\(formatters.distance(totals.distanceMeters)) · \(formatters.duration(totals.drivingDuration)) of driving"
    }

    // MARK: Actions

    /// Leaves drive mode; the trip stays saved and can be resumed from Home.
    private func exitDrive() {
        onFinish()
    }

    private func startNavigation() {
        cameraMode = .follow
        Task { await model.beginNavigation() }
    }

    private func continueToNext() {
        cameraMode = .follow
        Task { await model.continueToNextStop() }
    }
}
