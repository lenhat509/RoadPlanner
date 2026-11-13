import SwiftUI
import TripFeatures
import TripModels
import TripPlanner

/// Compare plans, explore the route on the map, review the day-by-day timeline and start driving.
/// The map sits above the scrolling content (not inside it) so pinch and pan gestures go to the map.
struct PlanResultScreen: View {
    @State private var model: PlanResultViewModel
    @State private var selectedStop: ItineraryStop?
    @State private var isStarting = false
    @State private var mapExpanded = false
    @State private var mapCommand: MapCommand?
    @Environment(\.openURL) private var openURL
    private let formatters: TripFormatters
    let onStart: (ActiveTrip) -> Void

    init(result: PlanResult, dependencies: AppDependencies, onStart: @escaping (ActiveTrip) -> Void) {
        _model = State(initialValue: PlanResultViewModel(result: result, dependencies: dependencies))
        formatters = dependencies.formatters
        self.onStart = onStart
    }

    var body: some View {
        VStack(spacing: 0) {
            if let itinerary = model.selected {
                mapArea(itinerary)
                StopLegend(entries: StopLegend.entries(for: itinerary.stops))
                    .padding(.vertical, Theme.Spacing.s)
            }
            if !mapExpanded {
                ScrollView { details }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle(model.routeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await model.save() }
                    } label: {
                        Label(model.isSaved ? "Saved" : "Save for later", systemImage: model.isSaved ? "checkmark" : "bookmark")
                    }
                    .disabled(model.isSaved)
                    .accessibilityIdentifier(AccessibilityID.Results.save)
                    if let url = model.googleMapsURL {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open in Google Maps", systemImage: "map")
                        }
                        .accessibilityIdentifier(AccessibilityID.Results.openInGoogleMaps)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More actions")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task {
                    isStarting = true
                    defer { isStarting = false }
                    if let trip = await model.startTrip() { onStart(trip) }
                }
            } label: {
                Label("Start driving", systemImage: "car.fill")
            }
            .buttonStyle(.primary)
            .disabled(isStarting || model.selected == nil)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.xs)
            .background(Theme.canvas.opacity(0.94).ignoresSafeArea())
            .accessibilityIdentifier(AccessibilityID.Results.start)
        }
        .sheet(item: $selectedStop) { stop in
            StopDetailSheet(
                stop: stop,
                presentation: StopPresentation(
                    stop: stop, formatters: formatters, tankCapacityGallons: model.selected?.request.vehicle.tankCapacityGallons
                ),
                travelers: model.selected?.request.travelers ?? 2
            )
        }
    }

    // MARK: Map

    private func mapArea(_ itinerary: Itinerary) -> some View {
        ZStack(alignment: .topTrailing) {
            RouteMap(paths: MapContent.paths(for: itinerary), markers: MapContent.markers(for: itinerary.stops), command: mapCommand)
            VStack(spacing: Theme.Spacing.xs) {
                MapControlButton(
                    systemImage: mapExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    label: mapExpanded ? "Show plan details" : "Expand map",
                    action: toggleExpanded
                )
                Spacer().frame(height: Theme.Spacing.xxs)
                MapControlButton(systemImage: "plus", label: "Zoom in") { mapCommand = MapCommand(action: .zoomIn) }
                MapControlButton(systemImage: "minus", label: "Zoom out") { mapCommand = MapCommand(action: .zoomOut) }
                MapControlButton(systemImage: "scope", label: "Show the whole route") { mapCommand = MapCommand(action: .fitRoute) }
            }
            .padding(Theme.Spacing.s)
        }
        .frame(maxHeight: mapExpanded ? .infinity : 300)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 28, bottomTrailingRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Results.map)
    }

    private func toggleExpanded() {
        withAnimation(.snappy) { mapExpanded.toggle() }
        // Re-frame the route once the map has its new size.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            mapCommand = MapCommand(action: .fitRoute)
        }
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            if model.options.count > 1 {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(model.options) { option in
                        PlanOptionCard(option: option, isSelected: option.goal == model.selectedGoal) {
                            withAnimation(.snappy) { model.selectedGoal = option.goal }
                        }
                    }
                }
            }
            if let itinerary = model.selected { summary(itinerary) }
            if !model.warnings.isEmpty {
                WarningList(warnings: model.warnings)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AccessibilityID.Results.warnings)
            }
            VStack(spacing: Theme.Spacing.s) {
                SectionLabel(title: "Day by day")
                ForEach(model.days) { day in
                    DayTimelineView(day: day) { stopID in
                        selectedStop = model.selected?.stops.first { $0.id == stopID }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Results.timeline)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.top, Theme.Spacing.xxs)
        .padding(.bottom, Theme.Spacing.l)
    }

    private func summary(_ itinerary: Itinerary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            TripRibbonView(marks: TripRibbon.marks(for: itinerary))
            HStack(alignment: .top) {
                MetricView(value: formatters.duration(itinerary.totals.elapsedDuration), label: "Total time")
                Spacer()
                MetricView(value: formatters.distance(itinerary.totals.distanceMeters), label: "Distance")
                Spacer()
                MetricView(value: formatters.currency(itinerary.totals.cost.total), label: "Est. cost")
            }
            Text(model.costBreakdownText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

/// A selectable plan: goal, total time, cost and nights. The selected plan is filled with the
/// brand gradient.
struct PlanOptionCard: View {
    let option: PlanOption
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: PlanTripScreen.symbol(for: option.goal))
                    Text(option.title)
                        .textCase(.uppercase)
                    if option.isRecommended {
                        Image(systemName: "star.fill")
                            .accessibilityLabel("Your preference")
                    }
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Theme.accent)
                Text(option.durationText)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(option.costText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(option.nightsText)
                    .font(.caption)
                    .opacity(0.75)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.s)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.card))
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .strokeBorder(isSelected ? Color.clear : Theme.cardStroke, lineWidth: 1)
            )
            .shadow(color: isSelected ? Theme.accent.opacity(0.3) : .black.opacity(0.04), radius: isSelected ? 10 : 6, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(AccessibilityID.Results.option(option.goal.rawValue))
    }
}

/// One day of the itinerary as a vertical timeline.
struct DayTimelineView: View {
    let day: DaySection
    let onSelect: (String) -> Void

    /// "Day 1" from "Day 1 · Mon, May 3".
    private var dayName: String { day.title.components(separatedBy: " · ").first ?? day.title }
    private var dateText: String { day.title.components(separatedBy: " · ").dropFirst().joined(separator: " · ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(dayName)
                    .font(.title3.weight(.bold))
                Text(dateText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(day.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, Theme.Spacing.xs)
            ForEach(Array(day.stops.enumerated()), id: \.element.id) { index, stop in
                Button { onSelect(stop.id) } label: {
                    StopRowView(stop: stop, isFirst: index == 0, isLast: index == day.stops.count - 1)
                }
                .buttonStyle(.plain)
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Results.day(day.index))
    }
}

/// A timeline row: connector line, stop icon, title, times and planned action.
struct StopRowView: View {
    let stop: StopPresentation
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Color.secondary.opacity(0.3))
                    .frame(width: 2, height: 8)
                StopDot(kind: stop.kind, isPullOff: stop.isPullOff, size: 18)
                    .frame(width: 30, height: 30)
                Rectangle()
                    .fill(isLast ? Color.clear : Color.secondary.opacity(0.3))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.title)
                    .font(.subheadline.weight(.semibold))
                Text(stop.timeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail = stop.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(stop.isEstimate ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, Theme.Spacing.s)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Details and outbound links (Google Maps, Expedia) for a stop.
struct StopDetailSheet: View {
    let stop: ItineraryStop
    let presentation: StopPresentation
    let travelers: Int
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: Theme.Spacing.s) {
                        StopDot(kind: stop.kind, isPullOff: stop.isRoadsidePullOff, size: 22)
                        VStack(alignment: .leading) {
                            Text(presentation.title).font(.headline)
                            Text(presentation.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if !presentation.timeText.isEmpty { Label(presentation.timeText, systemImage: "clock") }
                    if let detail = presentation.detail { Label(detail, systemImage: "info.circle") }
                }
                Section("Open in") {
                    Button {
                        openURL(ExternalLinks.googleMapsPlace(stop.place))
                    } label: {
                        Label("Google Maps", systemImage: "map")
                    }
                    if stop.kind == .lodging {
                        if let url = stop.lodging?.bookingURL {
                            Button {
                                openURL(url)
                            } label: {
                                Label("Book on \(stop.lodging?.provider ?? "partner site")", systemImage: "bed.double")
                            }
                        }
                        if let checkIn = stop.arrival, let checkOut = stop.departure {
                            Button {
                                openURL(ExternalLinks.expediaHotelSearch(near: stop.place, checkIn: checkIn, checkOut: checkOut, adults: travelers))
                            } label: {
                                Label("Compare rates on Expedia", systemImage: "magnifyingglass")
                            }
                        }
                        Button {
                            openURL(ExternalLinks.googleHotels(near: stop.place.coordinate))
                        } label: {
                            Label("Hotels nearby on Google", systemImage: "building.2")
                        }
                    }
                }
            }
            .navigationTitle(stop.isRoadsidePullOff ? "Rest break" : stop.kind.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
