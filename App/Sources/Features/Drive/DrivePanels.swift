import SwiftUI
import TripFeatures
import TripModels

// Panels and controls of drive mode (see `DriveScreen`).

// MARK: - Guidance

/// The next maneuver, large and high contrast, with the turn after it when that comes soon.
struct ManeuverBannerView: View {
    let banner: DriveViewModel.Banner
    let isRerouting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .padding(Theme.Spacing.m)
            .background(Theme.heroGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            if let then = banner.thenSymbolName, !isRerouting {
                HStack(spacing: 6) {
                    Text("Then")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: then)
                        .font(.headline.weight(.bold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Theme.brandDeep,
                    in: UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
                )
                .padding(.leading, 20)
                .accessibilityLabel("Then \(then)")
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Drive.banner)
    }
}

/// Time left, distance and arrival time to the next stop, with the exit button and the menu.
struct NextStopPanel<MenuContent: View>: View {
    let info: DriveViewModel.NextStopInfo?
    let canContinue: Bool
    /// The whole trip at a glance, with the driven part filled.
    let ribbon: [RibbonMark]
    let progress: Double
    let onExit: () -> Void
    let onContinue: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            TripRibbonView(marks: ribbon, progress: progress, height: 12)
                .padding(.horizontal, Theme.Spacing.xxs)
            HStack(spacing: Theme.Spacing.s) {
                ExitNavigationButton(action: onExit)
                VStack(spacing: 2) {
                    if let info {
                        Text(info.durationText.isEmpty ? info.etaText : info.durationText)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                            .monospacedDigit()
                        Text([info.remainingText, info.etaText].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        HStack(spacing: 6) {
                            StopDot(kind: info.kind, isPullOff: info.isPullOff, size: 10)
                            Text("\(info.kindTitle) · \(info.name)")
                                .lineLimit(1)
                        }
                        .font(.caption.weight(.medium))
                    }
                }
                .frame(maxWidth: .infinity)
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
        .driveSheet()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Drive.nextStop)
    }
}

// MARK: - Preview

/// Top of the preview: from the car to the next stop.
struct PreviewHeader: View {
    let destination: DriveViewModel.NextStopInfo

    /// The plan's start is named as such, so it isn't mistaken for where the user is.
    private var title: String {
        destination.kind == .origin ? "Trip start · \(destination.name)" : destination.name
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            VStack(spacing: 3) {
                Circle()
                    .fill(Theme.routeLine)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(.secondary).frame(width: 2.5, height: 2.5)
                }
                StopDot(kind: destination.kind, isPullOff: destination.isPullOff, size: 10)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Your location")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .driveSheet(cornerRadius: 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Route from your location to \(title)")
    }
}

/// Bottom of the preview: how long the next leg takes, what happens at the stop, and Start.
struct PreviewSheet<MenuContent: View>: View {
    let info: DriveViewModel.NextStopInfo?
    /// Shown above the time, e.g. when the leg leads to the trip's start.
    var headline: String?
    var startTitle = "Start"
    let onExit: () -> Void
    let onStart: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    if let headline {
                        Text(headline)
                            .font(.subheadline.weight(.semibold))
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(info?.durationText ?? "")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                        Text(info.map { "(\($0.remainingText))" } ?? "")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    Text("Arrive \(info?.etaText ?? "—")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                DriveMenuButton(content: menu)
            }
            if let info {
                HStack(alignment: .top, spacing: Theme.Spacing.s) {
                    StopDot(kind: info.kind, isPullOff: info.isPullOff, size: 18)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.kindTitle.uppercased())
                            .font(.caption2.weight(.bold))
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
                }
                .padding(Theme.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.mutedFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            HStack(spacing: Theme.Spacing.s) {
                ExitNavigationButton(action: onExit)
                Button(action: onStart) {
                    Label(startTitle, systemImage: "location.north.fill")
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier(AccessibilityID.Drive.startNavigation)
            }
        }
        .padding(Theme.Spacing.m)
        .driveSheet()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Drive.preview)
    }
}

// MARK: - Stops

/// Shown at a stop: what to do here, then one tap to continue.
struct ArrivalCard<MenuContent: View>: View {
    let info: DriveViewModel.NextStopInfo?
    let nextStopName: String?
    let onExit: () -> Void
    let onContinue: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                if let info { StopDot(kind: info.kind, isPullOff: info.isPullOff, size: 24) }
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
            if let nextStopName {
                Text("Next: \(nextStopName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Theme.Spacing.s) {
                ExitNavigationButton(action: onExit)
                Button(action: onContinue) {
                    Label("Continue to next stop", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier(AccessibilityID.Drive.continueToNext)
            }
        }
        .padding(Theme.Spacing.m)
        .driveSheet()
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
        .driveSheet()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Drive.completedCard)
    }
}

// MARK: - Controls

/// Leaves drive mode (the trip stays saved). Red, always bottom-left, like other navigation apps.
struct ExitNavigationButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(Theme.danger, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Exit navigation")
        .accessibilityIdentifier(AccessibilityID.Drive.exit)
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
    var systemImage = "exclamationmark.triangle.fill"
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: systemImage)
                .foregroundStyle(onDismiss == nil ? Theme.accent : Theme.warning)
            Text(message)
                .font(.footnote)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(Theme.Spacing.s)
        .background(.regularMaterial, in: Capsule())
    }
}

extension View {
    /// Solid card used for drive-mode sheets: legible over any map.
    func driveSheet(cornerRadius: CGFloat = 24) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
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
                Label(
                    "Set up your trip before you start moving. Waystage is made to be glanced at and listened to, not operated, while driving. Let a passenger use it, or pull over safely first.",
                    systemImage: "hand.raised"
                )
                Label(
                    "Directions come from Google Maps and can be wrong. Road signs, traffic laws and conditions always come first.",
                    systemImage: "exclamationmark.triangle"
                )
                Label(
                    "Hotels in your plan aren't booked, and prices and opening hours can change. Confirm them before you rely on a stop.",
                    systemImage: "tag"
                )
                Label("Rest whenever you feel tired, even if no break is planned. Stop only where it's legal and safe.", systemImage: "bed.double")
            }
            .font(.body)
            Spacer()
            Button("I understand", action: onAccept)
                .buttonStyle(.primary)
                .accessibilityIdentifier(AccessibilityID.Drive.safetyAccept)
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background.ignoresSafeArea())
    }
}
