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
    /// "Add a stop after this one": the stop it goes after.
    @State private var addingAfter: AddingStop?
    /// "Adjust visits", while open.
    @State private var visitsEditor: AdjustVisitsViewModel?
    @Environment(\.openURL) private var openURL
    private let dependencies: AppDependencies

    struct AddingStop: Identifiable {
        let stopID: String
        var id: String { stopID }
    }
    private let formatters: TripFormatters
    private let startButtonTitle: String?
    let onStart: (ActiveTrip) -> Void

    init(
        result: PlanResult, dependencies: AppDependencies, startButtonTitle: String? = nil,
        onStart: @escaping (ActiveTrip) -> Void
    ) {
        _model = State(initialValue: PlanResultViewModel(result: result, dependencies: dependencies))
        formatters = dependencies.formatters
        self.dependencies = dependencies
        self.startButtonTitle = startButtonTitle
        self.onStart = onStart
    }

    var body: some View {
        VStack(spacing: 0) {
            if let itinerary = model.selected {
                mapArea(itinerary)
                StopLegend(entries: StopLegend.entries(for: itinerary.stops))
                    .padding(.top, Theme.Spacing.s)
                    .padding(.bottom, Theme.Spacing.xs)
            }
            if !mapExpanded {
                ScrollView { details }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.canvas.ignoresSafeArea())
        .task { await model.locateUser() }
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
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More actions")
            }
        }
        .safeAreaInset(edge: .bottom) {
            BottomActionBar {
                VStack(spacing: Theme.Spacing.xs) {
                    if let note = model.startDistanceNote {
                        // The plan's start and the user's position are different places: say so
                        // before driving (drive mode then leads to the start first).
                        Label(note, systemImage: "location.circle")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(note)
                            .accessibilityIdentifier(AccessibilityID.Results.startNote)
                    }
                    if model.canUndo {
                        Button {
                            withAnimation(.snappy) { model.undo() }
                        } label: {
                            Label("Undo last change", systemImage: "arrow.uturn.backward")
                        }
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier(AccessibilityID.Results.undo)
                    }
                    Button {
                        visitsEditor = model.visitsEditor()
                    } label: {
                        Label("Adjust visits", systemImage: "mappin.and.ellipse")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.secondary)
                    .disabled(model.selected == nil || model.isUpdating)
                    .accessibilityIdentifier(AccessibilityID.Results.adjustVisits)
                    Button {
                        Task {
                            isStarting = true
                            defer { isStarting = false }
                            if let trip = await model.startTrip() { onStart(trip) }
                        }
                    } label: {
                        Label(startTitle, systemImage: "car.fill")
                    }
                    .buttonStyle(.primary)
                    .disabled(isStarting || model.selected == nil || model.isUpdating)
                    .accessibilityIdentifier(AccessibilityID.Results.start)
                }
            }
        }
        .overlay {
            if model.isUpdating {
                ProgressView("Updating the plan…")
                    .padding(Theme.Spacing.l)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityIdentifier(AccessibilityID.Results.updating)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isUpdating)
        .alert("Can't update the plan", isPresented: Binding(
            get: { model.updateError != nil },
            set: { if !$0 { model.dismissUpdateError() } }
        )) {
            Button("OK", role: .cancel) { model.dismissUpdateError() }
        } message: {
            Text(model.updateError ?? "")
        }
        .sheet(isPresented: Binding(get: { visitsEditor != nil }, set: { if !$0 { visitsEditor = nil } })) {
            if let visitsEditor {
                AdjustVisitsSheet(
                    model: visitsEditor,
                    dependencies: dependencies,
                    onUse: {
                        withAnimation(.snappy) { model.use(visitsEditor) }
                        self.visitsEditor = nil
                    },
                    onCancel: { self.visitsEditor = nil }
                )
            }
        }
        .sheet(item: $addingAfter) { adding in
            AddStopSheet(dependencies: dependencies) { place, stay in
                addingAfter = nil
                Task { await model.apply(.addStop(after: adding.stopID, place: place, stay: stay)) }
            }
        }
        .sheet(item: $selectedStop) { stop in
            StopDetailSheet(
                stop: stop,
                presentation: StopPresentation(
                    stop: stop, formatters: formatters, tankCapacityGallons: model.selected?.request.vehicle.tankCapacityGallons
                ),
                travelers: model.selected?.request.travelers ?? 2,
                editing: editing(for: stop.id)
            )
        }
    }

    /// The bottom button's title: from another screen it says what it does there.
    private var startTitle: String { startButtonTitle ?? "Start driving" }

    /// Changes to a stop, applied at once (the plan is made again; Undo brings it back).
    private func editing(for stopID: String) -> StopEditing {
        StopEditing(
            stopID: stopID,
            state: { model.editState(for: stopID) },
            formatters: formatters,
            canAddStop: { model.canAddStop },
            apply: { edit in
                selectedStop = nil
                Task { await model.apply(edit) }
            },
            addStopAfter: {
                selectedStop = nil
                addingAfter = AddingStop(stopID: stopID)
            }
        )
    }

    // MARK: Map

    private func mapArea(_ itinerary: Itinerary) -> some View {
        ZStack(alignment: .topTrailing) {
            RouteMap(
                paths: routePaths(itinerary),
                markers: MapContent.markers(for: itinerary.stops),
                chrome: UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 64),
                userLocation: model.currentLocation,
                command: mapCommand,
                badges: routeBadges,
                onSelectBadge: chooseRoute,
                secondaryStyle: .alternatives
            )
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
                    DayTimelineView(day: day, editing: { editing(for: $0) }) { stopID in
                        selectedStop = model.selected?.stops.first { $0.id == stopID }
                    }
                }
                Text("Touch and hold a stop to remove it, keep it, pick another hotel or add a stop after it. The plan updates right away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                Capsule()
                    .fill(choice.isSelected ? Theme.routeLine : Theme.routeAlternative)
                    .frame(width: 5, height: 34)
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

/// A selectable plan: goal, total time, cost and nights. The selected plan is filled with the
/// brand colour.
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
                    .fill(isSelected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.card))
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
    /// Changes a stop can take (nil: read-only).
    var editing: ((String) -> StopEditing)?
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
                .contextMenu {
                    if let editing = editing?(stop.id) {
                        StopEditMenu(stopKind: stop.kind, editing: editing)
                    }
                }
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

/// What can change about a stop (keep, remove, another hotel, a stop after it); each change
/// updates the plan at once.
struct StopEditing {
    let stopID: String
    let state: () -> StopEditState?
    let formatters: TripFormatters
    let canAddStop: () -> Bool
    let apply: (PlanEdit) -> Void
    let addStopAfter: () -> Void
}

/// The stop's actions, for its long-press menu (the details sheet shows the same).
struct StopEditMenu: View {
    let stopKind: StopKind
    let editing: StopEditing

    var body: some View {
        if let state = editing.state() {
            if state.canKeep {
                Button(state.isKept ? "Stop keeping it" : "Keep this stop", systemImage: state.isKept ? "pin.slash" : "pin") {
                    editing.apply(.toggleKeep(stopID: stopID))
                }
            }
            if state.canRemove {
                Button("Remove", systemImage: "minus.circle", role: .destructive) { editing.apply(.remove(stopID: stopID)) }
            }
            if !state.hotelChoices.isEmpty {
                Menu("Other hotels", systemImage: "bed.double") {
                    ForEach(state.hotelChoices) { choice in
                        Button(choice.place.name) { editing.apply(.chooseHotel(stopID: stopID, choice)) }
                    }
                }
            }
        }
        if stopKind != .destination && editing.canAddStop() {
            Button("Add a stop after this one", systemImage: "plus.circle", action: editing.addStopAfter)
        }
    }

    private var stopID: String { editing.stopID }
}

/// Details and outbound links (Google Maps, Expedia) for a stop.
struct StopDetailSheet: View {
    let stop: ItineraryStop
    let presentation: StopPresentation
    let travelers: Int
    var editing: StopEditing?
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mapProvider) private var mapProvider

    /// Places data shown without a map carries its source (Google Maps attribution).
    private var attribution: String {
        mapProvider == .google ? "Place information from Google Maps." : "Sample data (demo mode)."
    }

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
                } footer: {
                    Text(attribution)
                }
                if let notice = Disclosures.notice(for: stop) {
                    Section {
                        Label(notice, systemImage: stop.kind == .lodging ? "exclamationmark.circle" : "checkmark.shield")
                            .font(.footnote)
                            .foregroundStyle(stop.kind == .lodging ? Theme.warning : .secondary)
                            .accessibilityIdentifier(AccessibilityID.Results.stopNotice)
                    }
                }
                if let editing {
                    editSections(editing, editing.state())
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
                                Label("Check availability on \(stop.lodging?.provider ?? "partner site")", systemImage: "bed.double")
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

    @ViewBuilder
    private func editSections(_ editing: StopEditing, _ state: StopEditState?) -> some View {
        Section {
            if let state, state.canKeep {
                Button {
                    editing.apply(.toggleKeep(stopID: stop.id))
                } label: {
                    Label(state.isKept ? "Stop keeping it" : "Keep this stop", systemImage: state.isKept ? "pin.slash" : "pin")
                }
                .accessibilityIdentifier(AccessibilityID.Results.keepStop)
            }
            if let state, state.canRemove {
                Button(role: .destructive) {
                    editing.apply(.remove(stopID: stop.id))
                } label: {
                    Label("Remove this stop", systemImage: "minus.circle")
                }
                .accessibilityIdentifier(AccessibilityID.Results.removeStop)
            }
            if stop.kind != .destination && editing.canAddStop() {
                Button(action: editing.addStopAfter) {
                    Label("Add a stop after this one", systemImage: "plus.circle")
                }
                .accessibilityIdentifier(AccessibilityID.Results.addStopHere)
            }
        } header: {
            Text("Change the plan")
        } footer: {
            Text(stop.kind == .visit || stop.isRequiredStop
                ? "The plan updates right away; Undo brings the previous one back."
                : "The plan updates right away; Undo brings the previous one back. Another break or fuel stop may take a removed one's place where your break rhythm or fuel needs one.")
        }
        if let state, !state.hotelChoices.isEmpty {
            Section {
                ForEach(Array(state.hotelChoices.enumerated()), id: \.element.id) { index, choice in
                    Button {
                        editing.apply(.chooseHotel(stopID: stop.id, choice))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.place.name).foregroundStyle(.primary)
                            Text(hotelDetail(choice, formatters: editing.formatters))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.Results.hotelChoice(index))
                }
            } header: {
                Text("Stay somewhere else tonight")
            } footer: {
                Text("Rates aren't booked or guaranteed. \(attribution)")
            }
        }
    }

    /// "$129/night (est.) · 12 min earlier · 4 min off the route"
    private func hotelDetail(_ choice: HotelChoice, formatters: TripFormatters) -> String {
        var parts: [String] = []
        if let rate = choice.nightlyRate {
            parts.append("\(formatters.currency(rate))/night\(choice.isRateEstimated ? " (est.)" : "")")
        }
        let minutes = Int((abs(choice.timeFromPlanned) / 60).rounded())
        if minutes >= 5 {
            parts.append("\(formatters.duration(abs(choice.timeFromPlanned))) \(choice.timeFromPlanned < 0 ? "earlier" : "later")")
        }
        if choice.detourDuration >= 60 {
            parts.append("\(formatters.duration(choice.detourDuration)) off the route")
        }
        return parts.joined(separator: " · ")
    }
}
