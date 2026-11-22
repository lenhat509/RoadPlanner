import SwiftUI
import TripFeatures
import TripModels

/// Finds a place to stop at, with how long to stay, to add it to a plan.
struct AddStopSheet: View {
    @State private var model: PlaceSearchViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearching: Bool
    let title: String
    let onAdd: (Place, TimeInterval) -> Void

    init(dependencies: AppDependencies, title: String = "Add a stop", onAdd: @escaping (Place, TimeInterval) -> Void) {
        _model = State(initialValue: PlaceSearchViewModel(dependencies: dependencies))
        self.title = title
        self.onAdd = onAdd
    }

    /// A row under the search: the place being loaded, or the place chosen.
    private var hasStatus: Bool { model.isResolving || model.place != nil }

    var body: some View {
        NavigationStack {
            BoxPage {
                BoxSection("Place") {
                    BoxRow(isLast: model.suggestions.isEmpty && !hasStatus) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search for a place", text: Binding(get: { model.text }, set: { model.queryChanged($0) }))
                                .focused($isSearching)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier(AccessibilityID.Results.addStopSearch)
                        }
                    }
                    ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        BoxRow(isLast: index == model.suggestions.count - 1 && !hasStatus) {
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
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(AccessibilityID.Plan.suggestion(suggestion.primaryText))
                        }
                    }
                    if hasStatus {
                        BoxRow(isLast: true) {
                            if model.isResolving {
                                ProgressView()
                            } else if let place = model.place {
                                Label(place.name, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.success)
                            }
                        }
                    }
                }
                BoxSection("Stay", footer: "The plan keeps your other stops and fits breaks, fuel and nights around this one.") {
                    BoxRow(isLast: true) {
                        Stepper(
                            value: Binding(get: { model.stayMinutes }, set: { model.setStay($0) }),
                            in: PlanTripViewModel.stayRange, step: PlanTripViewModel.stayStep
                        ) {
                            Text("Stay \(model.stayText)")
                        }
                    }
                }
                if let error = model.errorMessage {
                    BoxSection {
                        BoxRow(isLast: true) {
                            Text(error).foregroundStyle(Theme.warning)
                        }
                    }
                }
            }
            .navigationTitle(title)
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
