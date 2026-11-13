import SwiftUI
import TripFeatures
import TripModels

/// Full-width, high-contrast call to action.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isEnabled ? Theme.accent : Color.gray.opacity(0.45))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Quiet secondary action.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(Theme.accent)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.accent.opacity(0.12))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

/// Rounded surface used for grouped content.
struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardModifier()) }
}

/// A stop marker: a plain coloured dot with a white ring (colours are explained by `StopLegend`).
struct StopDot: View {
    let kind: StopKind
    var isPullOff = false
    var size: CGFloat = 16

    var body: some View {
        Circle()
            .fill(Theme.color(for: kind, isPullOff: isPullOff))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white, lineWidth: max(2, size * 0.14)))
            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// Explains which colour marks which kind of stop.
struct StopLegend: View {
    struct Entry: Hashable, Identifiable {
        let kind: StopKind
        let isPullOff: Bool
        var id: String { "\(kind.rawValue)-\(isPullOff)" }
    }

    let entries: [Entry]

    /// Entries for the stop types present in `stops`, in trip order.
    static func entries(for stops: [ItineraryStop]) -> [Entry] {
        let order: [Entry] = [
            Entry(kind: .origin, isPullOff: false), Entry(kind: .rest, isPullOff: false),
            Entry(kind: .rest, isPullOff: true), Entry(kind: .fuel, isPullOff: false),
            Entry(kind: .lodging, isPullOff: false), Entry(kind: .destination, isPullOff: false),
        ]
        let present = Set(stops.map { Entry(kind: $0.kind, isPullOff: $0.isRoadsidePullOff) })
        return order.filter(present.contains)
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), alignment: .leading)], alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(entries) { entry in
                HStack(spacing: 6) {
                    StopDot(kind: entry.kind, isPullOff: entry.isPullOff, size: 14)
                    Text(Theme.legendTitle(for: entry.kind, isPullOff: entry.isPullOff))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Map legend: " + entries.map { Theme.legendTitle(for: $0.kind, isPullOff: $0.isPullOff) }.joined(separator: ", "))
        .accessibilityIdentifier(AccessibilityID.Results.legend)
    }
}

/// The car's position: an arrow pointing in the direction of travel.
struct VehicleArrow: View {
    /// Rotation in degrees relative to the screen's up direction.
    let rotation: Double

    var body: some View {
        Image(systemName: "location.north.fill")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Theme.accent, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .rotationEffect(.degrees(rotation))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .accessibilityLabel("Your car")
    }
}

/// A big number with a caption.
struct MetricView: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Explains relaxed preferences and estimates without alarming the user.
struct WarningList: View {
    let warnings: [PlanWarning]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(warnings) { warning in
                Label {
                    Text(warning.message)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: icon(for: warning.code))
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    private func icon(for code: PlanWarning.Code) -> String {
        switch code {
        case .estimatedPrices: "tag"
        case .deadlineMissed: "clock.badge.exclamationmark"
        case .nightDriving: "moon.stars"
        case .fuelGap: "fuelpump.exclamationmark"
        default: "info.circle"
        }
    }
}
