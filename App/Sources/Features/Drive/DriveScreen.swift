import SwiftUI
import TripFeatures
import TripModels
import UIKit

/// Turn-by-turn drive mode. Glanceable: one big instruction, one next-stop panel, one
/// primary action. Everything else is in a single menu.
struct DriveScreen: View {
    @State private var model: DriveViewModel
    @State private var showsSafetyNotice: Bool
    @State private var confirmsEnd = false
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
        ZStack(alignment: .top) {
            TripMapView(
                paths: model.legCoordinates.isEmpty ? [] : [model.legCoordinates],
                markers: markers,
                camera: camera,
                edgeInsets: UIEdgeInsets(top: 170, left: 16, bottom: 240, right: 16)
            )
            .ignoresSafeArea()

            VStack(spacing: Theme.Spacing.s) {
                topBar
                if let banner = model.banner {
                    ManeuverBannerView(banner: banner, isRerouting: model.isRerouting)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let message = model.statusMessage {
                    StatusPill(message: message, onDismiss: model.dismissStatus)
                }
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.xs)
            .animation(.easeInOut(duration: 0.25), value: model.mode)
        }
        .task(id: showsSafetyNotice) {
            if !showsSafetyNotice { await model.start() }
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
        .sheet(isPresented: $showsSafetyNotice) {
            SafetyNoticeView {
                var preferences = dependencies.preferences.load()
                preferences.hasAcceptedSafetyNotice = true
                dependencies.preferences.save(preferences)
                showsSafetyNotice = false
            }
            .interactiveDismissDisabled()
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

    // MARK: Map

    private var camera: TripMapView.Camera {
        if model.mode == .driving, let location = model.currentLocation {
            return .follow(location, course: model.currentCourse)
        }
        return .overview
    }

    private var markers: [MapStopMarker] {
        let trip = model.trip
        let remaining = trip.itinerary.stops.enumerated()
            .filter { $0.offset >= trip.progress.targetStopIndex && !trip.progress.skippedStopIDs.contains($0.element.id) }
            .map(\.element)
        return MapContent.markers(for: remaining, activeID: trip.targetStop?.id)
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            Button {
                Task {
                    await model.stop()
                    onFinish()
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Close drive mode")
            .accessibilityIdentifier(AccessibilityID.Drive.close)
            Spacer()
            if model.isMuted {
                Image(systemName: "speaker.slash.fill")
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
                    .accessibilityLabel("Voice guidance muted")
            }
        }
    }

    @ViewBuilder
    private var bottomPanel: some View {
        switch model.mode {
        case .driving:
            NextStopPanel(info: model.nextStop, canContinue: model.canContinueToNextStop, onContinue: continueToNext) {
                menuContent
            }
        case .atStop:
            ArrivalCard(info: model.nextStop, nextStopName: model.trip.stopAfterTarget?.place.name, onContinue: continueToNext) {
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
        if model.mode == .driving {
            Button {
                Task { await model.confirmArrival() }
            } label: {
                Label("I've arrived", systemImage: "checkmark.circle")
            }
            .accessibilityIdentifier(AccessibilityID.Drive.arrived)
            if !model.trip.isFinalTarget {
                Button {
                    Task { await model.skipTargetStop() }
                } label: {
                    Label("Skip this stop", systemImage: "forward.end")
                }
                .accessibilityIdentifier(AccessibilityID.Drive.skip)
            }
        }
        Button {
            model.isMuted.toggle()
        } label: {
            Label(model.isMuted ? "Unmute voice" : "Mute voice", systemImage: model.isMuted ? "speaker.wave.2" : "speaker.slash")
        }
        .accessibilityIdentifier(AccessibilityID.Drive.mute)
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

    private func continueToNext() {
        Task { await model.continueToNextStop() }
    }
}

/// The next maneuver, large and high contrast.
struct ManeuverBannerView: View {
    let banner: DriveViewModel.Banner
    let isRerouting: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: isRerouting ? "arrow.triangle.2.circlepath" : banner.symbolName)
                .font(.system(size: 40, weight: .bold))
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(isRerouting ? "Rerouting…" : banner.distanceText)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(banner.instruction)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(Theme.Spacing.m)
        .background(Theme.bannerBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Drive.banner)
    }
}

/// Next stop, ETA and — when close — the "Continue to next stop" action.
struct NextStopPanel<MenuContent: View>: View {
    let info: DriveViewModel.NextStopInfo?
    let canContinue: Bool
    let onContinue: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                if let info {
                    StopIcon(kind: info.kind, symbolName: info.symbolName, isPullOff: info.isPullOff, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.kindTitle.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(info.name)
                            .font(.headline)
                            .lineLimit(1)
                        if let action = info.plannedAction {
                            Text(action)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(info.etaText)
                            .font(.title3.bold())
                            .monospacedDigit()
                        Text(info.remainingText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Spacer()
                }
                DriveMenuButton(content: menu)
            }
            if canContinue {
                Button(action: onContinue) {
                    Label("Continue to next stop", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier(AccessibilityID.Drive.continueToNext)
            }
        }
        .padding(Theme.Spacing.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Drive.nextStop)
    }
}

/// Shown at a stop: what to do here, then one tap to continue.
struct ArrivalCard<MenuContent: View>: View {
    let info: DriveViewModel.NextStopInfo?
    let nextStopName: String?
    let onContinue: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                if let info { StopIcon(kind: info.kind, symbolName: info.symbolName, isPullOff: info.isPullOff, size: 44) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("You've arrived")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.success)
                    Text(info?.name ?? "Stop")
                        .font(.title3.bold())
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                DriveMenuButton(content: menu)
            }
            Label(info?.plannedAction ?? "Take a break: stretch, hydrate and rest your eyes.", systemImage: "checklist")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onContinue) {
                Label("Continue to next stop", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier(AccessibilityID.Drive.continueToNext)
            if let nextStopName {
                Text("Next: \(nextStopName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.l)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Drive.arrivalCard)
    }
}

/// End of the trip.
struct CompletedCard: View {
    let destination: String
    let summary: String
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: "flag.checkered.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.success)
            Text("Welcome to \(destination)")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Done", action: onDone)
                .buttonStyle(.primary)
                .accessibilityIdentifier(AccessibilityID.Drive.done)
        }
        .padding(Theme.Spacing.l)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Drive.completedCard)
    }
}

/// The single overflow menu in drive mode.
struct DriveMenuButton<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(Theme.elevated, in: Circle())
        }
        .accessibilityLabel("Trip options")
        .accessibilityIdentifier(AccessibilityID.Drive.menu)
    }
}

/// Non-blocking status message (e.g. directions unavailable).
struct StatusPill: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            Text(message)
                .font(.footnote)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(Theme.Spacing.s)
        .background(.regularMaterial, in: Capsule())
    }
}

/// One-time safety acknowledgement before the first drive.
struct SafetyNoticeView: View {
    let onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Image(systemName: "steeringwheel")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("Before you drive")
                .font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Label("Set up your trip before you start moving. Cadence is designed to be glanced at, not operated, while driving.", systemImage: "hand.raised")
                Label("Always follow traffic laws, road signs and conditions. Directions can be wrong.", systemImage: "exclamationmark.triangle")
                Label("Prices, hours and availability come from Google and partners and may change. Confirm before relying on them.", systemImage: "tag")
                Label("Rest whenever you feel tired, even if no break is planned.", systemImage: "bed.double")
            }
            .font(.body)
            Spacer()
            Button("I understand", action: onAccept)
                .buttonStyle(.primary)
                .accessibilityIdentifier(AccessibilityID.Drive.safetyAccept)
        }
        .padding(Theme.Spacing.l)
        .presentationDetents([.large])
    }
}
