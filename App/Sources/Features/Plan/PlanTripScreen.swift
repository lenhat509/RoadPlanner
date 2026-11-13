import SwiftUI
import TripFeatures
import TripModels
import TripPlanner

/// The planning form, as a short stack of cards: where, when, the car, breaks and the goal.
/// Required inputs come first; everything optional is tucked into "More options".
struct PlanTripScreen: View {
    @State private var model: PlanTripViewModel
    @State private var showsAdvanced = false
    @FocusState private var focusedField: PlanTripViewModel.Field?
    let onPlanned: (PlanResult) -> Void

    init(dependencies: AppDependencies, onPlanned: @escaping (PlanResult) -> Void) {
        _model = State(initialValue: PlanTripViewModel(dependencies: dependencies))
        self.onPlanned = onPlanned
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.l) {
                routeCard
                VStack(spacing: Theme.Spacing.xs) {
                    SectionLabel(title: "When")
                    whenCard
                }
                VStack(spacing: Theme.Spacing.xs) {
                    SectionLabel(title: "Your car")
                    carCard
                }
                VStack(spacing: Theme.Spacing.xs) {
                    SectionLabel(title: "Breaks")
                    breaksCard
                }
                VStack(spacing: Theme.Spacing.xs) {
                    SectionLabel(title: "Optimize for")
                    goalCard
                }
                advancedCard
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.top, Theme.Spacing.xs)
            .padding(.bottom, Theme.Spacing.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle("New trip")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { submitBar }
        .overlay {
            if model.isPlanning {
                PlanningProgressView(text: model.progressText ?? "", fraction: model.progressFraction, onCancel: model.cancelPlanning)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isPlanning)
        .alert("Can't plan this trip", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.result != nil) { _, hasResult in
            guard hasResult, let result = model.result else { return }
            model.clearResult()
            onPlanned(result)
        }
    }

    // MARK: Route

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Spacing.s) {
                RouteRail()
                    .padding(.vertical, 20)
                VStack(spacing: 0) {
                    placeRow(.origin, placeholder: "Start", identifier: AccessibilityID.Plan.origin)
                    Divider()
                    placeRow(.destination, placeholder: "Where to?", identifier: AccessibilityID.Plan.destination)
                }
                Button {
                    withAnimation(.snappy) { model.swapLocations() }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.footnote.weight(.bold))
                        .frame(width: 36, height: 36)
                        .background(Theme.mutedFill, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Swap start and destination")
                .accessibilityIdentifier(AccessibilityID.Plan.swap)
            }
            suggestions
        }
        .card(padding: Theme.Spacing.s)
    }

    private func placeRow(_ field: PlanTripViewModel.Field, placeholder: String, identifier: String) -> some View {
        let input = model.input(for: field)
        return HStack(spacing: Theme.Spacing.xs) {
            TextField(placeholder, text: Binding(
                get: { model.input(for: field).text },
                set: { model.queryChanged($0, for: field) }
            ))
            .font(.body.weight(input.place == nil ? .regular : .semibold))
            .focused($focusedField, equals: field)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .accessibilityIdentifier(identifier)
            if input.isResolving {
                ProgressView()
            } else if input.place != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                    .accessibilityLabel("Place selected")
            } else if field == .origin {
                Button {
                    focusedField = nil
                    Task { await model.useCurrentLocation(for: .origin) }
                } label: {
                    Image(systemName: "location.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use current location")
                .accessibilityIdentifier(AccessibilityID.Plan.currentLocation)
            }
        }
        .frame(minHeight: 50)
    }

    /// Suggestions for whichever field is being typed into, inside the route card.
    @ViewBuilder
    private var suggestions: some View {
        let field: PlanTripViewModel.Field? = !model.origin.suggestions.isEmpty
            ? .origin
            : (!model.destination.suggestions.isEmpty ? .destination : nil)
        if let field {
            VStack(spacing: 0) {
                ForEach(model.input(for: field).suggestions) { suggestion in
                    Divider().padding(.leading, 34)
                    Button {
                        focusedField = field == .origin && model.destination.place == nil ? .destination : nil
                        Task { await model.select(suggestion, for: field) }
                    } label: {
                        HStack(spacing: Theme.Spacing.s) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Theme.color(for: field == .origin ? .origin : .destination).opacity(0.85))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.primaryText)
                                    .foregroundStyle(.primary)
                                if !suggestion.secondaryText.isEmpty {
                                    Text(suggestion.secondaryText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.Plan.suggestion(suggestion.primaryText))
                }
            }
            .padding(.top, Theme.Spacing.xxs)
            .transition(.opacity)
        }
    }

    // MARK: When

    private var whenCard: some View {
        VStack(spacing: Theme.Spacing.s) {
            HStack {
                Label("Depart", systemImage: "clock")
                Spacer()
                DatePicker("Depart", selection: $model.departure, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .accessibilityIdentifier(AccessibilityID.Plan.departure)
            }
            Divider()
            Toggle(isOn: $model.arriveByEnabled.animation(.snappy)) {
                Label("Arrive by a set time", systemImage: "flag.checkered")
            }
            .tint(Theme.accent)
            .accessibilityIdentifier(AccessibilityID.Plan.arriveByToggle)
            if model.arriveByEnabled {
                HStack {
                    Text("Arrive by")
                        .foregroundStyle(.secondary)
                    Spacer()
                    DatePicker("Arrive by", selection: $model.arriveBy, in: model.departure..., displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }
        }
        .card()
    }

    // MARK: Car

    private var carCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.s) {
                NumberTile(title: "Fuel economy", unit: "mpg", text: $model.mpgText, identifier: AccessibilityID.Plan.mpg)
                NumberTile(title: "Tank size", unit: "gal", text: $model.tankGallonsText, identifier: AccessibilityID.Plan.tank)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack {
                    Text("Refuel before **\(Int(model.minimumFuelPercent))% left**")
                    Spacer()
                    Stepper("Minimum fuel level", value: $model.minimumFuelPercent, in: 5...50, step: 5)
                        .labelsHidden()
                        .accessibilityIdentifier(AccessibilityID.Plan.minimumFuel)
                }
                FuelGauge(reserveFraction: model.minimumFuelPercent / 100)
            }
            if let summary = model.rangeSummary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    // MARK: Breaks

    private var breaksCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Toggle(isOn: $model.customRestEnabled.animation(.snappy)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom break interval")
                    Text(model.customRestEnabled
                        ? "You'll never drive longer than this without a break."
                        : "Default: a 15-minute break every 2–3 hours.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Theme.accent)
            .accessibilityIdentifier(AccessibilityID.Plan.customRestToggle)
            if model.customRestEnabled {
                Stepper(value: $model.restIntervalHours, in: 0.5...5, step: 0.25) {
                    Text("Every \(Self.hoursText(model.restIntervalHours))")
                        .font(.headline)
                }
                .accessibilityIdentifier(AccessibilityID.Plan.restInterval)
            }
            RhythmStrip(intervalHours: model.customRestEnabled ? model.restIntervalHours : 3)
                .padding(.top, Theme.Spacing.xxs)
        }
        .card()
    }

    // MARK: Goal

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(OptimizationGoal.allCases) { goal in
                    ChoiceTile(
                        systemImage: Self.symbol(for: goal),
                        title: goal.displayName,
                        subtitle: Self.tagline(for: goal),
                        isSelected: model.goal == goal
                    ) {
                        withAnimation(.snappy) { model.goal = goal }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Plan.goal)
            Text(goalDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.xxs)
        }
    }

    // MARK: More

    private var advancedCard: some View {
        DisclosureGroup(isExpanded: $showsAdvanced.animation(.snappy)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Fuel at departure: \(Int(model.startingFuelPercent))%")
                    Slider(value: $model.startingFuelPercent, in: 10...100, step: 5)
                        .tint(Theme.accent)
                }
                Picker("Fuel type", selection: $model.fuelType) {
                    ForEach(FuelType.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Stepper(value: $model.maxDailyDrivingHours, in: 4...12, step: 0.5) {
                    Text("Up to \(Self.hoursText(model.maxDailyDrivingHours)) of driving a day")
                }
                Stepper(value: $model.travelers, in: 1...8) {
                    Text(model.travelers == 1 ? "1 traveler" : "\(model.travelers) travelers")
                }
            }
            .padding(.top, Theme.Spacing.s)
        } label: {
            Label("More options", systemImage: "slider.horizontal.3")
                .foregroundStyle(.primary)
        }
        .tint(Theme.accent)
        .card()
    }

    private var submitBar: some View {
        VStack(spacing: Theme.Spacing.xs) {
            if let first = model.validationErrors.first, model.origin.place != nil, model.destination.place != nil {
                Text(first.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                focusedField = nil
                model.startPlanning()
            } label: {
                Label("Plan my trip", systemImage: "sparkles")
            }
            .buttonStyle(.primary)
            .disabled(!model.canPlan)
            .accessibilityIdentifier(AccessibilityID.Plan.submit)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.top, Theme.Spacing.s)
        .padding(.bottom, Theme.Spacing.xs)
        .background(Theme.canvas.opacity(0.94).ignoresSafeArea())
    }

    // MARK: Helpers

    private var goalDescription: String {
        switch model.goal {
        case .fastest: "Arrive as early as possible."
        case .cheapest: "Lowest total for gas, hotels and tolls."
        case .balanced: "Trades time against money (about $25 per hour by default)."
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })
    }

    static func symbol(for goal: OptimizationGoal) -> String {
        switch goal {
        case .fastest: "hare.fill"
        case .cheapest: "dollarsign.circle.fill"
        case .balanced: "scalemass.fill"
        }
    }

    static func tagline(for goal: OptimizationGoal) -> String {
        switch goal {
        case .fastest: "Arrive earliest"
        case .cheapest: "Lowest cost"
        case .balanced: "Time vs. money"
        }
    }

    static func hoursText(_ hours: Double) -> String {
        let whole = Int(hours)
        let minutes = Int(((hours - Double(whole)) * 60).rounded())
        if whole == 0 { return "\(minutes) min" }
        return minutes == 0 ? "\(whole) h" : "\(whole) h \(minutes) min"
    }
}

/// Planning progress: a little car travelling along the road as the plan comes together.
struct PlanningProgressView: View {
    let text: String
    let fraction: Double
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            VStack(spacing: Theme.Spacing.m) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 4)
                        Capsule()
                            .fill(Theme.brandGradient)
                            .frame(width: max(4, (geometry.size.width - 30) * fraction + 15), height: 4)
                        ForEach([0.25, 0.5, 0.75], id: \.self) { mark in
                            StopDot(kind: mark == 0.5 ? .fuel : (mark == 0.25 ? .rest : .lodging), size: 10)
                                .offset(x: (geometry.size.width - 30) * mark + 10)
                        }
                        VehicleArrow(rotation: 90)
                            .offset(x: (geometry.size.width - 30) * fraction)
                    }
                    .frame(height: geometry.size.height)
                }
                .frame(width: 240, height: 30)
                Text(text)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Comparing routes, breaks, gas prices and hotels.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier(AccessibilityID.Plan.cancel)
            }
            .padding(Theme.Spacing.xl)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 20, y: 8)
            .padding(Theme.Spacing.xl)
        }
        .animation(.easeInOut, value: fraction)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Plan.progress)
    }
}
