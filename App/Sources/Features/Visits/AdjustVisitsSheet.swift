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
    @State private var mapExpanded = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    routeMap(collapsedHeight: WholeRouteMap.collapsedHeight(in: proxy.size))
                    if !mapExpanded {
                        visitList
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Adjust visits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
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

    /// The whole route of the plan shown (as on the plan screen), with the visits numbered in the
    /// list's order (green: to be added, red: to be removed) and the route's driving time: for the
    /// trip in progress, from where you are to the destination.
    private func routeMap(collapsedHeight: CGFloat) -> some View {
        let paths = MapContent.paths(for: model.plan)
        let badges = MapContent.labelCoordinate(for: paths).map { coordinate in
            [MapRouteBadge(
                id: "route", coordinate: coordinate, text: model.routeTimeText,
                accessibilityLabel: "Route, \(model.routeTimeText)", isSelected: true, isBest: false
            )]
        } ?? []
        return WholeRouteMap(paths: paths, markers: mapMarkers, badges: badges, isExpanded: $mapExpanded, collapsedHeight: collapsedHeight)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.xs)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Visits.map)
    }

    private var mapMarkers: [MapStopMarker] {
        let listed = Set(model.visits.map(\.id))
        // Other stops (and visits already behind the car) as plain dots: the numbers are the list's.
        let others = MapContent.markers(for: model.plan.stops.filter { !listed.contains($0.id) }).map { marker in
            var marker = marker
            marker.number = nil
            return marker
        }
        let visits = model.visits.enumerated().map { index, visit in
            MapStopMarker(
                id: "visit-\(visit.id)", coordinate: visit.coordinate, title: "\(index + 1). \(visit.name)", kind: .visit,
                isPullOff: false, isActive: false, number: index + 1,
                change: visit.status == .toBeAdded ? .toBeAdded : (visit.status == .toBeRemoved ? .toBeRemoved : nil)
            )
        }
        return others + visits
    }

    private var visitList: some View {
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
                ForEach(Array(model.visits.enumerated()), id: \.element.id) { index, visit in
                    VisitEntryRow(visit: visit, number: index + 1) { model.toggle(visit.id) }
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
    }

    /// Update plan (while there are changes to plan), then Use this plan.
    private var bottomBar: some View {
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
}

/// A place to visit: tap to mark it to be removed (red) or keep it again; a place added (green)
/// has a button to take it off the list.
private struct VisitEntryRow: View {
    let visit: AdjustVisitsViewModel.Visit
    /// Its place in the list, as numbered on the map.
    let number: Int
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
            NumberedPin(number: number, color: tint ?? Theme.color(for: .visit), size: 26)
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
}
