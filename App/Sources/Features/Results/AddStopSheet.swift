import SwiftUI
import TripFeatures
import TripModels

/// Finds a place to stop at, with how long to stay, to add it to a plan.
struct AddStopSheet: View {
    @State private var model: PlaceSearchViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearching: Bool
    let onAdd: (Place, TimeInterval) -> Void

    init(dependencies: AppDependencies, onAdd: @escaping (Place, TimeInterval) -> Void) {
        _model = State(initialValue: PlaceSearchViewModel(dependencies: dependencies))
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search for a place", text: Binding(get: { model.text }, set: { model.queryChanged($0) }))
                        .focused($isSearching)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier(AccessibilityID.Results.addStopSearch)
                    ForEach(model.suggestions) { suggestion in
                        Button {
                            isSearching = false
                            Task { await model.select(suggestion) }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.primaryText).foregroundStyle(.primary)
                                if !suggestion.secondaryText.isEmpty {
                                    Text(suggestion.secondaryText).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier(AccessibilityID.Plan.suggestion(suggestion.primaryText))
                    }
                    if model.isResolving {
                        ProgressView()
                    } else if let place = model.place {
                        Label(place.name, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                    }
                }
                Section {
                    Stepper(
                        value: Binding(get: { model.stayMinutes }, set: { model.setStay($0) }),
                        in: PlanTripViewModel.stayRange, step: PlanTripViewModel.stayStep
                    ) {
                        Text("Stay \(model.stayText)")
                    }
                } footer: {
                    Text("The plan keeps your other stops and fits breaks, fuel and nights around this one.")
                }
                if let error = model.errorMessage {
                    Section { Text(error).foregroundStyle(Theme.warning) }
                }
            }
            .navigationTitle("Add a stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let place = model.place { onAdd(place, model.stay) }
                    }
                    .disabled(model.place == nil)
                    .accessibilityIdentifier(AccessibilityID.Results.addStopConfirm)
                }
            }
            .onAppear { isSearching = true }
        }
    }
}
