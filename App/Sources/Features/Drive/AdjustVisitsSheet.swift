import SwiftUI
import TripFeatures
import TripModels

/// "Adjust visits": every stop still ahead with its address and arrival time, and the places to
/// visit to add or remove. Each change updates the list at once; the trip changes only with
/// "Use this plan".
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
                    Text(model.canEdit || model.isUpdating
                        ? "A new visit goes where it adds the least driving. Breaks, fuel and nights are planned around your visits."
                        : "Visits can't be changed until your location is known. Try again in a moment.")
                }
                Section("Stops ahead") {
                    ForEach(model.rows) { row in
                        VisitStopRow(row: row, onRemove: row.isVisit && model.canEdit ? { remove(row) } : nil)
                    }
                }
            }
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
                ToolbarItem(placement: .primaryAction) {
                    Button("Undo") { model.undo() }
                        .disabled(!model.canUndo)
                        .accessibilityIdentifier(AccessibilityID.Drive.undoVisits)
                }
            }
            .safeAreaInset(edge: .bottom) {
                BottomActionBar {
                    Button {
                        onUse(model.plan)
                    } label: {
                        Label("Use this plan", systemImage: "checkmark")
                    }
                    .buttonStyle(.primary)
                    .disabled(!model.hasChanges || model.isUpdating)
                    .accessibilityIdentifier(AccessibilityID.Drive.useVisits)
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
                    addsVisit = false
                    Task { await model.add(place, stay: stay) }
                }
            }
        }
    }

    private func remove(_ row: AdjustVisitsViewModel.Row) {
        Task { await model.remove(row.id) }
    }
}

/// One stop ahead: what it is, where, and when the car gets there.
private struct VisitStopRow: View {
    let row: AdjustVisitsViewModel.Row
    let onRemove: (() -> Void)?

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
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(row.name)")
                .accessibilityIdentifier(AccessibilityID.Drive.removeVisit)
            }
        }
        .swipeActions {
            if let onRemove {
                Button("Remove", role: .destructive, action: onRemove)
            }
        }
    }
}
