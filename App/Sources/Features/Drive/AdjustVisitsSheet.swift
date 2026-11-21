import SwiftUI
import TripFeatures
import TripModels

/// "Adjust visits": the places to visit, and every stop still ahead with its address and arrival
/// time. Changes are listed first (green "To be added", red "To be removed") and planned together
/// with "Update plan"; "Use this plan" then makes the new plan the trip.
struct AdjustVisitsSheet: View {
    let model: AdjustVisitsViewModel
    let dependencies: AppDependencies
    let onUse: (Itinerary) -> Void
    let onCancel: () -> Void
    @State private var addsVisit = false

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
                    .accessibilityIdentifier(AccessibilityID.Drive.addVisit)
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
                } header: {
                    Text("Your visits")
                } footer: {
                    Text("Tap a visit to remove it from the plan, or tap it again to keep it. Nothing changes until you tap Update plan.")
                }
                Section {
                    ForEach(model.rows) { row in
                        StopAheadRow(row: row)
                    }
                } header: {
                    Text("Stops ahead")
                } footer: {
                    if model.hasPendingChanges {
                        Text("These are the current plan's stops and times. They change when you tap Update plan.")
                    }
                }
            }
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
                        Button {
                            onUse(model.plan)
                        } label: {
                            Label("Use this plan", systemImage: "checkmark")
                        }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier(AccessibilityID.Drive.useVisits)
                    } else {
                        Button {
                            Task { await model.updatePlan() }
                        } label: {
                            Label("Update plan", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.primary)
                        .disabled(!model.hasPendingChanges || !model.canEdit)
                        .accessibilityIdentifier(AccessibilityID.Drive.updateVisits)
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
                    .accessibilityIdentifier(AccessibilityID.Drive.discardVisit)
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

/// One stop ahead: what it is, where, and when the car gets there.
private struct StopAheadRow: View {
    let row: AdjustVisitsViewModel.Row

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            StopDot(kind: row.kind, isPullOff: row.isPullOff, size: 14)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                Text(row.kindText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let address = row.address, address != row.name {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let eta = row.eta {
                    Text(eta)
                        .font(.caption.weight(.medium))
                }
            }
            Spacer(minLength: 0)
        }
    }
}
