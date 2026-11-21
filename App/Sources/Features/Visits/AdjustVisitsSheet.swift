import SwiftUI
import TripFeatures
import TripModels

/// "Adjust visits": the places to visit, in the order they'll be visited, with their addresses and
/// arrival times. Changes are listed first (green "To be added", red "To be removed", or a new
/// order) and planned together with "Update plan"; "Use this plan" then makes the new plan the one
/// shown (plan screen) or the trip (Home).
struct AdjustVisitsSheet: View {
    let model: AdjustVisitsViewModel
    let dependencies: AppDependencies
    let onUse: () -> Void
    let onCancel: () -> Void
    @State private var addsVisit = false
    /// Moving visits (drag handles), turned on with Reorder.
    @State private var editMode = EditMode.inactive

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        addsVisit = true
                    } label: {
                        Label("Add a visit", systemImage: "plus.circle.fill")
                    }
                    .disabled(!model.canAddVisit)
                    .accessibilityIdentifier(AccessibilityID.Visits.add)
                } footer: {
                    if !model.canEdit && !model.isUpdating {
                        Text("Visits can't be changed until your location is known. Try again in a moment.")
                    }
                }
                Section {
                    if model.visits.isEmpty {
                        Text("No visits yet. Add the places you want to stop at.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.visits) { visit in
                        VisitEntryRow(visit: visit) { model.toggle(visit.id) }
                    }
                    .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    HStack {
                        Text("Your visits")
                        Spacer()
                        if model.visits.count > 1 {
                            Button(editMode.isEditing ? "Done" : "Reorder") {
                                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                            }
                            .font(.subheadline.weight(.semibold))
                            .textCase(nil)
                            .disabled(model.isUpdating)
                            .accessibilityIdentifier(AccessibilityID.Visits.reorder)
                        }
                    }
                } footer: {
                    Text(editMode.isEditing
                        ? "Drag the visits into the order you want to stop at them."
                        : "Waystage puts your visits in the order that adds the least driving; tap Reorder to change it. Tap a visit to remove it from the plan, or tap it again to keep it. Nothing changes until you tap Update plan.")
                }
            }
            .environment(\.editMode, $editMode)
            .disabled(model.isUpdating)
            .overlay {
                if model.isUpdating {
                    ProgressView("Updating the plan…")
                        .padding(Theme.Spacing.l)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .navigationTitle("Adjust visits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .safeAreaInset(edge: .bottom) {
                BottomActionBar {
                    if model.isUpdated && !model.hasPendingChanges {
                        Button(action: onUse) {
                            Label("Use this plan", systemImage: "checkmark")
                        }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier(AccessibilityID.Visits.use)
                    } else {
                        Button {
                            Task { await model.updatePlan() }
                        } label: {
                            Label("Update plan", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.primary)
                        .disabled(!model.hasPendingChanges || !model.canEdit)
                        .accessibilityIdentifier(AccessibilityID.Visits.update)
                    }
                }
            }
            .alert(
                "Can't update the plan",
                isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .sheet(isPresented: $addsVisit) {
                AddStopSheet(dependencies: dependencies, title: "Add a visit") { place, stay in
                    model.add(place, stay: stay)
                    addsVisit = false
                }
            }
        }
    }
}

/// A place to visit: tap to mark it to be removed (red) or keep it again; a place added (green)
/// has a button to take it off the list.
private struct VisitEntryRow: View {
    let visit: AdjustVisitsViewModel.Visit
    let onToggle: () -> Void

    var body: some View {
        Group {
            if visit.status == .toBeAdded {
                HStack(alignment: .top, spacing: Theme.Spacing.s) {
                    content
                    Button(action: onToggle) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(visit.name) from the list")
                    .accessibilityIdentifier(AccessibilityID.Visits.discard)
                }
            } else {
                Button(action: onToggle) {
                    content
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(visit.status == .toBeRemoved ? "Keeps it in the plan" : "Marks it to be removed")
            }
        }
        .listRowBackground(tint.map { $0.opacity(0.12) })
    }

    private var content: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint ?? Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(visit.name)
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(visit.status == .toBeRemoved)
                if let label {
                    Text(label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint ?? .secondary)
                }
                Text(visit.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let address = visit.address, address != visit.name {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var label: String? {
        switch visit.status {
        case .inPlan: nil
        case .toBeRemoved: "To be removed"
        case .toBeAdded: "To be added"
        }
    }

    private var tint: Color? {
        switch visit.status {
        case .inPlan: nil
        case .toBeRemoved: Theme.danger
        case .toBeAdded: Theme.success
        }
    }

    private var symbol: String {
        switch visit.status {
        case .inPlan: "mappin.circle.fill"
        case .toBeRemoved: "minus.circle.fill"
        case .toBeAdded: "plus.circle.fill"
        }
    }
}
