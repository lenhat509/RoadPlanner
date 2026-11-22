import SwiftUI
import TripFeatures
import TripModels
import TripPlanner

/// Compare plans, explore the route on the map, review the day-by-day timeline and start driving.
/// The map sits above the scrolling content (not inside it) so pinch and pan gestures go to the map.
///
/// With `trip`, it shows the trip in progress (from Home): its whole plan, Adjust visits (the rest of
/// the trip from where you are, saved as the trip with Use this plan) and Resume.
struct PlanResultScreen: View {
    @State private var model: PlanResultViewModel
    @State private var selectedStop: ItineraryStop?
    @State private var isStarting = false
    @State private var mapExpanded = false
    /// "Adjust visits", while open.
    @State private var visitsEditor: AdjustVisitsViewModel?
    /// The trip in progress shown (from Home), and the drive model its visits are adjusted with.
    @State private var trip: ActiveTrip?
    @State private var tripDrive: DriveViewModel?
    @Environment(\.openURL) private var openURL
    private let dependencies: AppDependencies
    private let formatters: TripFormatters
    private let startButtonTitle: String?
    let onStart: (ActiveTrip) -> Void

    init(
        result: PlanResult, dependencies: AppDependencies, startButtonTitle: String? = nil, trip: ActiveTrip? = nil,
        onStart: @escaping (ActiveTrip) -> Void
    ) {
        _model = State(initialValue: PlanResultViewModel(result: result, dependencies: dependencies, trip: trip))
        _trip = State(initialValue: trip)
        formatters = dependencies.formatters
        self.dependencies = dependencies
        self.startButtonTitle = startButtonTitle
        self.onStart = onStart
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if let itinerary = model.selected {
                    mapArea(itinerary, collapsedHeight: WholeRouteMap.collapsedHeight(in: proxy.size))
                    StopLegend(entries: StopLegend.entries(for: itinerary.stops))
                        .padding(.top, Theme.Spacing.s)
                        .padding(.bottom, Theme.Spacing.xs)
                }
                if !mapExpanded {
                    ScrollView { details }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(Theme.canvas.ignoresSafeArea())
        .task { await model.locateUser() }
        .navigationTitle(model.routeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if trip == nil {
                        Button {
                            Task { await model.save() }
                        } label: {
                            Label(model.isSaved ? "Saved" : "Save for later", systemImage: model.isSaved ? "checkmark" : "bookmark")
                        }
                        .disabled(model.isSaved)
                        .accessibilityIdentifier(AccessibilityID.Results.save)
                    }
                    if let url = model.googleMapsURL {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open in Google Maps", systemImage: "map")
                        }
                        .accessibilityIdentifier(AccessibilityID.Results.openInGoogleMaps)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More actions")
            }
        }
        .sheet(isPresented: Binding(get: { visitsEditor != nil }, set: { if !$0 { visitsEditor = nil } })) {
            if let visitsEditor {
                AdjustVisitsSheet(
                    model: visitsEditor,
                    dependencies: dependencies,
                    onUse: { use(visitsEditor) },
                    onCancel: { self.visitsEditor = nil }
                )
            }
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

    /// The bottom button's title: from another screen it says what it does there.
    private var startTitle: String { trip != nil ? "Resume" : (startButtonTitle ?? "Start driving") }

    /// Opens Adjust visits: the plan's, or the rest of the trip in progress.
    private func adjustVisits() {
        if let trip {
            let drive = DriveViewModel(trip: trip, dependencies: dependencies)
            tripDrive = drive
            visitsEditor = drive.visitsEditor()
        } else {
            visitsEditor = model.visitsEditor()
        }
    }

    /// Use this plan: shown here (Undo goes back) or, for the trip in progress, saved as the trip.
    private func use(_ editor: AdjustVisitsViewModel) {
        guard trip != nil, let tripDrive else {
            withAnimation(.snappy) { model.use(editor) }
            visitsEditor = nil
            return
        }
        Task {
            guard let next = await tripDrive.use(plan: editor.plan) else { return }
            trip = next
            let plan = next.itinerary
            withAnimation(.snappy) {
                model = PlanResultViewModel(
                    result: PlanResult(itineraries: [plan.goal: plan], recommendedGoal: plan.goal), dependencies: dependencies, trip: next
                )
            }
            visitsEditor = nil
        }
    }

    // MARK: Map

    private func mapArea(_ itinerary: Itinerary, collapsedHeight: CGFloat) -> some View {
        WholeRouteMap(
            paths: routePaths(itinerary),
            markers: MapContent.markers(for: itinerary.stops),
            badges: routeBadges,
            onSelectBadge: chooseRoute,
            userLocation: model.currentLocation,
            isExpanded: $mapExpanded,
            collapsedHeight: collapsedHeight
        )
        .clipped()
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Results.map)
    }

    /// The chosen route (drawn strong) over the other routes found (drawn light).
    private func routePaths(_ itinerary: Itinerary) -> [[GeoCoordinate]] {
        let others = model.routeChoices.filter { !$0.isSelected }.compactMap { model.itinerary(onRoute: $0.id) }
        return MapContent.paths(for: itinerary) + others.flatMap { MapContent.paths(for: $0) }
    }

    /// Every route's travel time, on the route where it differs most from the others.
    private var routeBadges: [MapRouteBadge] {
        model.routeChoices.map { choice in
            MapRouteBadge(
                id: choice.id,
                coordinate: choice.labelCoordinate,
                text: choice.durationText,
                accessibilityLabel: "\(choice.title), \(choice.durationText)",
                isSelected: choice.isSelected,
                isBest: choice.isBest && model.hasRouteChoice
            )
        }
    }

    private func chooseRoute(_ id: String) {
        withAnimation(.snappy) { model.selectRoute(id) }
    }


    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            if model.hasRouteChoice {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    SectionLabel(title: "Routes")
                    ForEach(Array(model.routeChoices.enumerated()), id: \.element.id) { index, choice in
                        RouteChoiceRow(choice: choice) { chooseRoute(choice.id) }
                            .accessibilityIdentifier(AccessibilityID.Results.route(index))
                    }
                }
            }
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
            actions
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.top, Theme.Spacing.xxs)
        .padding(.bottom, Theme.Spacing.l)
    }

    /// The page ends with its buttons, on one line: Undo (after Adjust visits), Adjust visits, Start.
    private var actions: some View {
        VStack(spacing: Theme.Spacing.xs) {
            if trip == nil, let note = model.startDistanceNote {
                // The plan's start and the user's position are different places: say so before
                // driving (drive mode then leads to the start first).
                Label(note, systemImage: "location.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(note)
                    .accessibilityIdentifier(AccessibilityID.Results.startNote)
            }
            HStack(spacing: Theme.Spacing.xs) {
                if model.canUndo {
                    Button {
                        withAnimation(.snappy) { model.undo() }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.secondary)
                    .frame(width: 56)
                    .accessibilityLabel("Undo last change")
                    .accessibilityIdentifier(AccessibilityID.Results.undo)
                }
                Button {
                    adjustVisits()
                } label: {
                    Label("Adjust visits", systemImage: "mappin.and.ellipse")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .buttonStyle(.secondary)
                .disabled(model.selected == nil)
                .accessibilityIdentifier(AccessibilityID.Results.adjustVisits)
                Button {
                    Task {
                        isStarting = true
                        defer { isStarting = false }
                        if let trip {
                            onStart(trip)
                        } else if let trip = await model.startTrip() {
                            onStart(trip)
                        }
                    }
                } label: {
                    Label(startTitle, systemImage: trip != nil ? "play.fill" : "car.fill")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .buttonStyle(.primary)
                .disabled(isStarting || model.selected == nil)
                .accessibilityIdentifier(AccessibilityID.Results.start)
            }
        }
        .padding(.top, Theme.Spacing.xs)
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
            Label {
                Text(Disclosures.costEstimate + (itinerary.nights > 0 ? " Hotels in this plan aren't booked." : ""))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.Results.estimateNote)
        }
        .card()
    }
}

/// One of the routes found: its name, distance and travel time; the chosen one is outlined.
struct RouteChoiceRow: View {
    let choice: RouteChoice
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Theme.Spacing.s) {
                Rectangle()
                    .fill(choice.isSelected ? Theme.routeLine : Theme.routeAlternative)
                    .frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(choice.distanceText)
                        if choice.isBest {
                            Label("Best", systemImage: "star.fill")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Spacing.xs)
                Text(choice.durationText)
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(choice.isSelected ? Theme.routeLine : .primary)
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .strokeBorder(choice.isSelected ? Theme.routeLine : Theme.cardStroke, lineWidth: choice.isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(choice.title), \(choice.durationText), \(choice.distanceText)\(choice.isBest ? ", best route" : "")")
        .accessibilityAddTraits(choice.isSelected ? [.isSelected, .isButton] : [.isButton])
    }
}

/// A selectable plan: goal, total time, cost and nights. The selected plan has a green border.
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    if option.isRecommended {
                        Image(systemName: "star.fill")
                            .accessibilityLabel("Your preference")
                    }
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(isSelected ? Theme.brand : Color.secondary)
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
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.s)
            .selectableBox(isSelected: isSelected)
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
                    StopRowView(stop: stop, isFirst: index == 0, isLast: index == day.stops.count - 1, isKept: stop.isRequired)
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
    var isKept = false

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
                HStack(spacing: 4) {
                    Text(stop.title)
                        .font(.subheadline.weight(.semibold))
                    if isKept && stop.kind != .origin && stop.kind != .destination && stop.kind != .visit {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                            .accessibilityLabel("Kept")
                    }
                }
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
    @Environment(\.mapProvider) private var mapProvider

    /// Places data shown without a map carries its source (Google Maps attribution).
    private var attribution: String {
        mapProvider == .google ? "Place information from Google Maps." : "Sample data (demo mode)."
    }

    /// A website about the stop (Google Maps; for hotels, booking and rate searches).
    private struct OutboundLink: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let url: URL
    }

    private var links: [OutboundLink] {
        var links = [OutboundLink(id: "maps", title: "Google Maps", systemImage: "map", url: ExternalLinks.googleMapsPlace(stop.place))]
        guard stop.kind == .lodging else { return links }
        if let url = stop.lodging?.bookingURL {
            links.append(OutboundLink(
                id: "booking", title: "Check availability on \(stop.lodging?.provider ?? "partner site")", systemImage: "bed.double", url: url
            ))
        }
        if let checkIn = stop.arrival, let checkOut = stop.departure {
            links.append(OutboundLink(
                id: "expedia", title: "Compare rates on Expedia", systemImage: "magnifyingglass",
                url: ExternalLinks.expediaHotelSearch(near: stop.place, checkIn: checkIn, checkOut: checkOut, adults: travelers)
            ))
        }
        links.append(OutboundLink(
            id: "hotels", title: "Hotels nearby on Google", systemImage: "building.2", url: ExternalLinks.googleHotels(near: stop.place.coordinate)
        ))
        return links
    }

    var body: some View {
        NavigationStack {
            BoxPage {
                BoxSection(footer: attribution) {
                    BoxRow(isLast: presentation.timeText.isEmpty && presentation.detail == nil) {
                        HStack(spacing: Theme.Spacing.s) {
                            StopDot(kind: stop.kind, isPullOff: stop.isRoadsidePullOff, size: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(presentation.title).font(.headline)
                                Text(presentation.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !presentation.timeText.isEmpty {
                        BoxRow(isLast: presentation.detail == nil) {
                            Label(presentation.timeText, systemImage: "clock")
                        }
                    }
                    if let detail = presentation.detail {
                        BoxRow(isLast: true) {
                            Label(detail, systemImage: "info.circle")
                        }
                    }
                }
                if let notice = Disclosures.notice(for: stop) {
                    BoxSection {
                        BoxRow(isLast: true) {
                            Label(notice, systemImage: stop.kind == .lodging ? "exclamationmark.circle" : "checkmark.shield")
                                .font(.footnote)
                                .foregroundStyle(stop.kind == .lodging ? Theme.warning : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier(AccessibilityID.Results.stopNotice)
                        }
                    }
                }
                BoxSection("Open in") {
                    ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                        BoxRow(isLast: index == links.count - 1) {
                            Button { openURL(link.url) } label: {
                                BoxRowLabel(title: link.title, systemImage: link.systemImage, trailingSymbol: "arrow.up.right")
                            }
                            .buttonStyle(.plain)
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
