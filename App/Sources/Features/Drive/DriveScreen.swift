import SwiftUI
import TripFeatures
import TripModels
import UIKit

/// Turn-by-turn drive mode, laid out like the navigation apps drivers already know: the next turn
/// at the very top, the map in the middle, and a bottom sheet with the time left, the next stop,
/// a red exit button and one menu.
///
/// A leg can open as a *preview* (resuming a trip, or continuing from a stop): the route from the
/// car to the next stop, framed on the map, with a Start button that glides down into guidance.
struct DriveScreen: View {
    /// What the camera does while guiding.
    enum CameraMode: Equatable {
        /// Behind the car, heading up.
        case follow
        /// The route to the next stop ("Show route").
        case overview([GeoCoordinate])
        /// Where the user panned or zoomed to; "Re-center" returns to `follow`.
        case free
    }

    @State private var model: DriveViewModel
    @State private var showsSafetyNotice: Bool
    @State private var confirmsEnd = false
    @State private var cameraMode = CameraMode.follow
    /// Drive mode opens on the next leg, then glides down to the car.
    @State private var showsIntro = true
    @State private var mapCommand: MapCommand?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    private let dependencies: AppDependencies
    let onFinish: () -> Void

    init(trip: ActiveTrip, dependencies: AppDependencies, onFinish: @escaping () -> Void) {
        _model = State(initialValue: DriveViewModel(trip: trip, dependencies: dependencies))
        _showsSafetyNotice = State(initialValue: !dependencies.preferences.load().hasAcceptedSafetyNotice)
        self.dependencies = dependencies
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
            try? await Task.sleep(nanoseconds: 800_000_000)
            showsIntro = false
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await model.stop() }
        }
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
    }

    private var isGuiding: Bool { model.mode == .driving && model.stage == .navigating }
    private var isPreviewing: Bool { model.mode == .driving && model.stage == .preview }

    private var driveContent: some View {
        ZStack(alignment: .top) {
            RouteMap(
                paths: paths,
                markers: markers,
                camera: camera,
                chrome: chrome,
                vehicle: model.currentLocation.map { TripMapView.Vehicle(coordinate: $0, course: model.currentCourse) },
                command: mapCommand,
                onUserMoved: userMovedMap
            )
            .ignoresSafeArea()

            VStack(spacing: Theme.Spacing.s) {
                topArea
                HStack(alignment: .top) {
                    Spacer()
                    sideControls
                }
                Spacer(minLength: 0)
                if isGuiding && cameraMode != .follow {
                    recenterButton
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                bottomPanel
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.xs)
            .animation(.easeInOut(duration: 0.25), value: model.mode)
            .animation(.easeInOut(duration: 0.25), value: model.stage)
            .animation(.easeInOut(duration: 0.2), value: cameraMode)
        }
    }

    // MARK: Map

    /// The leg being driven (strong) and the rest of the trip (light).
    private var paths: [[GeoCoordinate]] {
        var paths = [model.routeToTarget]
        if !model.routeAfterTarget.isEmpty { paths.append(model.routeAfterTarget) }
        return paths
    }

    private var camera: TripMapView.Camera {
        switch model.mode {
        case .completed:
            return .overview
        case .atStop:
            return .frame(model.previewFrame)
        case .driving:
            guard model.stage == .navigating else { return .frame(model.previewFrame) }
            switch cameraMode {
            case .follow:
                guard !showsIntro, let location = model.currentLocation else { return .frame(model.previewFrame) }
                return .follow(location, course: model.currentCourse)
            case let .overview(coordinates):
                return .frame(coordinates)
            case .free:
                return .free
            }
        }
    }

    /// The parts of the map covered by the header and the bottom sheet, which framed routes stay
    /// clear of. (Only used for framing, so changing it never moves the map by itself.)
    private var chrome: UIEdgeInsets {
        switch model.mode {
        case .driving where model.stage == .preview:
            return UIEdgeInsets(top: 150, left: 24, bottom: 340, right: 64)
        case .driving:
            return UIEdgeInsets(top: 220, left: 24, bottom: 210, right: 64)
        case .atStop:
            return UIEdgeInsets(top: 70, left: 24, bottom: 320, right: 64)
        case .completed:
            return UIEdgeInsets(top: 70, left: 24, bottom: 300, right: 24)
        }
    }

    private var markers: [MapStopMarker] {
        let trip = model.trip
        let remaining = trip.itinerary.stops.enumerated()
            .filter { $0.offset >= trip.progress.targetStopIndex && !trip.progress.skippedStopIDs.contains($0.element.id) }
            .map(\.element)
        return MapContent.markers(for: remaining, activeID: trip.targetStop?.id)
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

    @ViewBuilder
    private var sideControls: some View {
        if isGuiding {
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
        } else if isPreviewing || model.mode == .atStop {
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
        if model.mode == .driving {
            Button {
                Task { await model.confirmArrival() }
            } label: {
                Label(model.isHeadingToStart ? "I'm at the start" : "I've arrived", systemImage: "checkmark.circle")
            }
            .accessibilityIdentifier(AccessibilityID.Drive.arrived)
            if !model.trip.isFinalTarget && !model.isHeadingToStart {
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
        Task {
            await model.stop()
            onFinish()
        }
    }

    private func startNavigation() {
        cameraMode = .follow
        model.beginNavigation()
    }

    private func continueToNext() {
        cameraMode = .follow
        Task { await model.continueToNextStop() }
    }
}
