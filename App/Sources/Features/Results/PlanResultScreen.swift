import SwiftUI
import TripFeatures
import TripModels
import TripPlanner

/// Compare plans, review the day-by-day timeline and start driving.
struct PlanResultScreen: View {
    @State private var model: PlanResultViewModel
    @State private var selectedStop: ItineraryStop?
    @State private var isStarting = false
    @Environment(\.openURL) private var openURL
    private let formatters: TripFormatters
    let onStart: (ActiveTrip) -> Void

    init(result: PlanResult, dependencies: AppDependencies, onStart: @escaping (ActiveTrip) -> Void) {
        _model = State(initialValue: PlanResultViewModel(result: result, dependencies: dependencies))
        formatters = dependencies.formatters
        self.onStart = onStart
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                if let itinerary = model.selected {
                    TripMapView(paths: MapContent.paths(for: itinerary), markers: MapContent.markers(for: itinerary.stops), showsUserLocation: false)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .accessibilityIdentifier(AccessibilityID.Results.map)
                }
                if model.options.count > 1 { optionPicker }
                if let itinerary = model.selected { summary(itinerary) }
                if !model.warnings.isEmpty {
                    WarningList(warnings: model.warnings)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(AccessibilityID.Results.warnings)
                }
                VStack(spacing: Theme.Spacing.m) {
                    ForEach(model.days) { day in
                        DayTimelineView(day: day) { stopID in
                            selectedStop = model.selected?.stops.first { $0.id == stopID }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.Results.timeline)
            }
            .padding(Theme.Spacing.m)
        }
        .background(Theme.background)
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
                Label("Start trip", systemImage: "car.fill")
            }
            .buttonStyle(.primary)
            .disabled(isStarting || model.selected == nil)
            .padding(Theme.Spacing.m)
            .background(.bar)
            .accessibilityIdentifier(AccessibilityID.Results.start)
        }
        .sheet(item: $selectedStop) { stop in
            StopDetailSheet(
                stop: stop,
                presentation: StopPresentation(stop: stop, formatters: formatters),
                travelers: model.selected?.request.travelers ?? 2
            )
        }
    }

    private var optionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(model.options) { option in
                    PlanOptionCard(option: option, isSelected: option.goal == model.selectedGoal) {
                        withAnimation(.snappy) { model.selectedGoal = option.goal }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func summary(_ itinerary: Itinerary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
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

/// A selectable plan summary card.
struct PlanOptionCard: View {
    let option: PlanOption
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(option.title)
                        .font(.headline)
                    if option.isRecommended {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                            .accessibilityLabel("Your preference")
                    }
                }
                Text(option.durationText)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("\(option.costText) · \(option.nightsText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !option.badges.isEmpty {
                    Text(option.badges.joined(separator: " · "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 168, alignment: .leading)
            .padding(Theme.Spacing.m)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
            )
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.title)
                    .font(.headline)
                Text(day.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                StopIcon(kind: stop.kind, symbolName: stop.symbolName, isPullOff: stop.symbolName == "parkingsign.circle.fill", size: 30)
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
                        StopIcon(kind: stop.kind, symbolName: presentation.symbolName, isPullOff: stop.isRoadsidePullOff, size: 40)
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
