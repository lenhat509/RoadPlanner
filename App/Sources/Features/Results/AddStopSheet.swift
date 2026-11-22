import SwiftUI
import TripFeatures
import TripModels

/// A place to visit and how long: hours, or nights (and where to sleep).
struct NewVisit {
    var place: Place
    var stay: TimeInterval
    var nights: Int
    var overnight: RequiredStop.Overnight?
}

/// Finds a place to stop at, with how long to stay, to add it to a plan.
struct AddStopSheet: View {
    @State private var model: PlaceSearchViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearching: Bool
    let title: String
    let onAdd: (NewVisit) -> Void

    init(dependencies: AppDependencies, title: String = "Add a stop", onAdd: @escaping (NewVisit) -> Void) {
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
                BoxSection("Stay") {
                    BoxRow(isLast: true) {
                        StayEditor(
                            nights: model.nights, minutes: model.stayMinutes, overnight: model.overnight,
                            onNights: { model.setNights($0) },
                            onMinutes: { model.setStay($0) },
                            onOvernight: { model.overnight = $0 }
                        )
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
                        if let place = model.place {
                            onAdd(NewVisit(
                                place: place, stay: model.stay, nights: model.nights,
                                overnight: model.nights > 0 ? model.overnight : nil
                            ))
                        }
                    }
                    .disabled(model.place == nil)
                    .accessibilityIdentifier(AccessibilityID.Results.addStopConfirm)
                }
            }
            .onAppear { isSearching = true }
        }
    }
}
