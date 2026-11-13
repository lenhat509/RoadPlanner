import SwiftUI
import TripFeatures
import TripModels
import TripPlanner

/// The planning form. Required inputs first (where, when, car); everything else is optional
/// and tucked away so the common path is a few taps.
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
        Form {
            routeSection
            whenSection
            carSection
            breaksSection
            goalSection
            advancedSection
        }
        .navigationTitle("Plan a trip")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { submitBar }
        .overlay {
            if model.isPlanning {
                PlanningProgressView(
                    text: model.progressText ?? "",
                    fraction: model.progressFraction,
                    onCancel: model.cancelPlanning
                )
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

    // MARK: Sections

    private var routeSection: some View {
        Section {
            placeRow(.origin, title: "Start", systemImage: "circle.circle", identifier: AccessibilityID.Plan.origin)
            suggestionRows(.origin)
            if model.origin.place == nil {
                Button {
                    focusedField = nil
                    Task { await model.useCurrentLocation(for: .origin) }
                } label: {
                    Label("Use current location", systemImage: "location.fill")
                }
                .accessibilityIdentifier(AccessibilityID.Plan.currentLocation)
            }
            placeRow(.destination, title: "Destination", systemImage: "flag.checkered", identifier: AccessibilityID.Plan.destination)
            suggestionRows(.destination)
        } header: {
            HStack {
                Text("Route")
                Spacer()
                Button {
                    model.swapLocations()
                } label: {
                    Label("Swap", systemImage: "arrow.up.arrow.down")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Swap start and destination")
                .accessibilityIdentifier(AccessibilityID.Plan.swap)
            }
        }
    }

    private func placeRow(_ field: PlanTripViewModel.Field, title: String, systemImage: String, identifier: String) -> some View {
        let input = model.input(for: field)
        return HStack(spacing: Theme.Spacing.s) {
            Image(systemName: systemImage)
                .foregroundStyle(field == .origin ? Theme.accent : Theme.color(for: .destination))
                .frame(width: 24)
            TextField(title, text: Binding(
                get: { model.input(for: field).text },
                set: { model.queryChanged($0, for: field) }
            ))
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
            }
        }
    }

    @ViewBuilder
    private func suggestionRows(_ field: PlanTripViewModel.Field) -> some View {
        ForEach(model.input(for: field).suggestions) { suggestion in
            Button {
                focusedField = field == .origin && model.destination.place == nil ? .destination : nil
                Task { await model.select(suggestion, for: field) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.primaryText)
                        .foregroundStyle(.primary)
                    if !suggestion.secondaryText.isEmpty {
                        Text(suggestion.secondaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 32)
            }
            .accessibilityIdentifier(AccessibilityID.Plan.suggestion(suggestion.primaryText))
        }
    }

    private var whenSection: some View {
        Section("When") {
            DatePicker("Depart", selection: $model.departure, displayedComponents: [.date, .hourAndMinute])
                .accessibilityIdentifier(AccessibilityID.Plan.departure)
            Toggle("Arrive by a set time", isOn: $model.arriveByEnabled)
                .accessibilityIdentifier(AccessibilityID.Plan.arriveByToggle)
            if model.arriveByEnabled {
                DatePicker("Arrive by", selection: $model.arriveBy, in: model.departure..., displayedComponents: [.date, .hourAndMinute])
            }
        }
    }

    private var carSection: some View {
        Section("Your car") {
            HStack {
                Label("Fuel economy", systemImage: "fuelpump")
                Spacer()
                TextField("MPG", text: $model.mpgText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 72)
                    .accessibilityIdentifier(AccessibilityID.Plan.mpg)
                Text("mpg")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var breaksSection: some View {
        Section {
            Toggle("Custom break interval", isOn: $model.customRestEnabled)
                .accessibilityIdentifier(AccessibilityID.Plan.customRestToggle)
            if model.customRestEnabled {
                Stepper(value: $model.restIntervalHours, in: 0.5...5, step: 0.25) {
                    Text("Break every \(Self.hoursText(model.restIntervalHours))")
                }
                .accessibilityIdentifier(AccessibilityID.Plan.restInterval)
            }
        } header: {
            Text("Breaks")
        } footer: {
            Text(model.customRestEnabled
                ? "You'll never drive longer than this without a break."
                : "By default you'll take a 15-minute break every 2–3 hours of driving.")
        }
    }

    private var goalSection: some View {
        Section {
            Picker("Optimize for", selection: $model.goal) {
                ForEach(OptimizationGoal.allCases) { goal in
                    Text(goal.displayName).tag(goal)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(AccessibilityID.Plan.goal)
        } header: {
            Text("Optimize for")
        } footer: {
            Text(goalDescription)
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("More options", isExpanded: $showsAdvanced) {
                HStack {
                    Text("Tank size")
                    Spacer()
                    TextField("Gallons", text: $model.tankGallonsText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 72)
                    Text("gal").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text("Fuel at departure: \(Int(model.startingFuelPercent))%")
                    Slider(value: $model.startingFuelPercent, in: 10...100, step: 5)
                }
                Picker("Fuel type", selection: $model.fuelType) {
                    ForEach(FuelType.allCases) { Text($0.displayName).tag($0) }
                }
                Stepper(value: $model.maxDailyDrivingHours, in: 4...12, step: 0.5) {
                    Text("Up to \(Self.hoursText(model.maxDailyDrivingHours)) of driving a day")
                }
                Stepper(value: $model.travelers, in: 1...8) {
                    Text(model.travelers == 1 ? "1 traveler" : "\(model.travelers) travelers")
                }
            }
        }
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
                Label("Plan trip", systemImage: "sparkles")
            }
            .buttonStyle(.primary)
            .disabled(!model.canPlan)
            .accessibilityIdentifier(AccessibilityID.Plan.submit)
        }
        .padding(Theme.Spacing.m)
        .background(.bar)
    }

    // MARK: Helpers

    private var goalDescription: String {
        switch model.goal {
        case .fastest: "Arrive as early as possible."
        case .cheapest: "Lowest fuel, lodging and toll cost, with cheaper gas and hotels."
        case .balanced: "Trades time against money (about $25 per hour by default)."
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })
    }

    static func hoursText(_ hours: Double) -> String {
        let whole = Int(hours)
        let minutes = Int(((hours - Double(whole)) * 60).rounded())
        if whole == 0 { return "\(minutes) min" }
        return minutes == 0 ? "\(whole) h" : "\(whole) h \(minutes) min"
    }
}

/// Planning progress, shown over the form.
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
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .frame(maxWidth: 260)
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
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .padding(Theme.Spacing.xl)
        }
        .animation(.easeInOut, value: fraction)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Plan.progress)
    }
}
