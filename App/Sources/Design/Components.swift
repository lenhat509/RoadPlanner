import SwiftUI
import TripFeatures
import TripModels

// MARK: - Buttons

/// The one primary action on a screen: a full-width gradient capsule.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(.white)
            .background {
                Capsule(style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.gray.opacity(0.4)))
            }
            .shadow(color: isEnabled ? Theme.accent.opacity(0.3) : .clear, radius: 12, y: 6)
            .opacity(configuration.isPressed ? 0.88 : 1)
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
            .background(Theme.accent.opacity(0.12), in: Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

// MARK: - Bars

/// The bar holding a screen's primary action: opaque, with a soft fade so scrolled content
/// slides under it cleanly.
struct BottomActionBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.top, Theme.Spacing.xs)
            .padding(.bottom, Theme.Spacing.xs)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) {
                VStack(spacing: 0) {
                    LinearGradient(colors: [Theme.canvas.opacity(0), Theme.canvas], startPoint: .top, endPoint: .bottom)
                        .frame(height: 28)
                        .offset(y: -28)
                        .padding(.bottom, -28)
                    Theme.canvas
                }
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }
    }
}

/// Wraps its children onto new lines (used for the map legend).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Surfaces

/// A soft white card on the warm canvas.
struct CardModifier: ViewModifier {
    var padding: CGFloat = Theme.Spacing.m

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }
}

extension View {
    func card(padding: CGFloat = Theme.Spacing.m) -> some View { modifier(CardModifier(padding: padding)) }
}

/// Small uppercase label above a card.
struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.horizontal, Theme.Spacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Stops

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
        FlowLayout(spacing: 14, lineSpacing: 6) {
            ForEach(entries) { entry in
                HStack(spacing: 6) {
                    StopDot(kind: entry.kind, isPullOff: entry.isPullOff, size: 12)
                    Text(Theme.legendTitle(for: entry.kind, isPullOff: entry.isPullOff))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Map legend: " + entries.map { Theme.legendTitle(for: $0.kind, isPullOff: $0.isPullOff) }.joined(separator: ", "))
        .accessibilityIdentifier(AccessibilityID.Results.legend)
    }
}

/// A one-line overview of a trip: every stop as a dot along a line, positioned by distance.
/// With `progress`, the driven part of the line is filled with the brand gradient.
struct TripRibbonView: View {
    let marks: [RibbonMark]
    var progress: Double?
    var height: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let inset = height / 2
            let width = max(0, geometry.size.width - height)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 3)
                    .padding(.horizontal, inset)
                if let progress {
                    Capsule()
                        .fill(Theme.brandGradient)
                        .frame(width: width * min(1, max(0, progress)), height: 3)
                        .padding(.leading, inset)
                }
                ForEach(marks) { mark in
                    let isEnd = mark.kind == .origin || mark.kind == .destination
                    let size = isEnd ? height * 0.75 : height * 0.56
                    StopDot(kind: mark.kind, isPullOff: mark.isPullOff, size: size)
                        .offset(x: inset + width * mark.fraction - size / 2)
                }
            }
            .frame(height: geometry.size.height)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The vertical "dot, dashed line, pin" rail joining the start and destination fields.
struct RouteRail: View {
    var body: some View {
        VStack(spacing: 4) {
            StopDot(kind: .origin, size: 12)
            DashedLine()
                .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))
                .frame(width: 2)
            StopDot(kind: .destination, size: 12)
        }
        .accessibilityHidden(true)
    }
}

/// A vertical line shape (used dashed).
struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
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
            .background(Theme.brandGradient, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .rotationEffect(.degrees(rotation))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .accessibilityLabel("Your car")
    }
}

// MARK: - Inputs

/// A large numeric input on a muted tile (MPG, tank size).
struct NumberTile: View {
    let title: String
    let unit: String
    @Binding var text: String
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                TextField("0", text: $text)
                    .keyboardType(.decimalPad)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(identifier)
                Text(unit)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.mutedFill, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}

/// A selectable tile with an icon, title and short explanation (optimization goal).
struct ChoiceTile: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 2)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(Theme.Spacing.s)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.mutedFill))
            }
            .shadow(color: isSelected ? Theme.accent.opacity(0.25) : .clear, radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A fuel gauge from E to F with the reserve the driver never wants to go below shaded.
struct FuelGauge: View {
    let reserveFraction: Double

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.mutedFill)
                    Capsule()
                        .fill(Theme.color(for: .fuel).opacity(0.85))
                        .frame(width: max(10, geometry.size.width * min(1, max(0, reserveFraction))))
                    ForEach(1..<4, id: \.self) { quarter in
                        Rectangle()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 1, height: 6)
                            .offset(x: geometry.size.width * Double(quarter) / 4)
                    }
                }
            }
            .frame(height: 10)
            HStack {
                Text("E")
                Spacer()
                Text("½")
                Spacer()
                Text("F")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .animation(.snappy, value: reserveFraction)
        .accessibilityHidden(true)
    }
}

/// The driving rhythm over a 10-hour day: driving blocks separated by break dots.
struct RhythmStrip: View {
    let intervalHours: Double
    private let dayHours = 10.0

    var body: some View {
        GeometryReader { geometry in
            let blocks = max(1, Int((dayHours / max(0.5, intervalHours)).rounded(.up)))
            let gap: CGFloat = 12
            let blockWidth = (geometry.size.width - gap * CGFloat(blocks - 1)) / CGFloat(blocks)
            HStack(spacing: 0) {
                ForEach(0..<blocks, id: \.self) { index in
                    Capsule()
                        .fill(Theme.brandGradient)
                        .frame(width: max(4, blockWidth), height: 6)
                    if index < blocks - 1 {
                        StopDot(kind: .rest, size: 10)
                            .frame(width: gap)
                    }
                }
            }
            .frame(height: geometry.size.height)
        }
        .frame(height: 12)
        .animation(.snappy, value: intervalHours)
        .accessibilityHidden(true)
    }
}

// MARK: - Map controls

/// Round floating buttons for the map (zoom, fit, expand).
struct MapControlButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundStyle(.primary)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Content

/// A big rounded number with a caption.
struct MetricView: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
        default: "info.circle"
        }
    }
}

/// The hero illustration: a winding dashed road with three stops (echoes the app icon).
struct DecorativeRoute: View {
    private static let stops: [(pointIndex: Int, kind: StopKind)] = [(12, .rest), (22, .fuel), (32, .lodging)]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let points = (0...40).map { index -> CGPoint in
                let t = Double(index) / 40
                return CGPoint(
                    x: size.width * (0.05 + 0.9 * t),
                    y: size.height * (0.85 - 0.7 * t + 0.12 * sin(t * .pi * 2))
                )
            }
            ZStack {
                Path { path in path.addLines(points) }
                    .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                Path { path in path.addLines(points) }
                    .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 7]))
                ForEach(0..<Self.stops.count, id: \.self) { index in
                    StopDot(kind: Self.stops[index].kind, size: 14)
                        .position(points[Self.stops[index].pointIndex])
                }
            }
        }
        .accessibilityHidden(true)
    }
}
