import SwiftUI
import TripFeatures
import TripModels

struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: HomeViewModel
    let isDemo: Bool
    let onPlanTrip: () -> Void
    let onOpenSettings: () -> Void
    let onResume: (ActiveTrip) -> Void
    let onOpenItinerary: (Itinerary) -> Void
    private let formatters: TripFormatters

    init(
        dependencies: AppDependencies,
        isDemo: Bool,
        onPlanTrip: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onResume: @escaping (ActiveTrip) -> Void,
        onOpenItinerary: @escaping (Itinerary) -> Void
    ) {
        _model = State(initialValue: HomeViewModel(dependencies: dependencies))
        formatters = dependencies.formatters
        self.isDemo = isDemo
        self.onPlanTrip = onPlanTrip
        self.onOpenSettings = onOpenSettings
        self.onResume = onResume
        self.onOpenItinerary = onOpenItinerary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                header
                if isDemo { demoBanner }
                if let trip = model.activeTrip { resumeCard(trip) }
                Button(action: onPlanTrip) {
                    Label("Plan a trip", systemImage: "map.fill")
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier(AccessibilityID.Home.planTrip)

                if !model.savedItineraries.isEmpty {
                    savedTrips
                } else if model.activeTrip == nil {
                    emptyState
                }
            }
            .padding(Theme.Spacing.m)
        }
        .background(Theme.background)
        .navigationTitle("Cadence")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier(AccessibilityID.Home.settings)
            }
        }
        .task(id: environment.drivingTrip?.id) { await model.load() }
    }

    private var header: some View {
        Text("Plan long drives with breaks, fuel and hotels built in.")
            .font(.title3)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var demoBanner: some View {
        Label {
            Text("Demo mode: add your Google Maps API key in Config/Secrets.xcconfig to plan real trips.")
                .font(.footnote)
        } icon: {
            Image(systemName: "wand.and.stars")
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .accessibilityIdentifier(AccessibilityID.Home.demoBanner)
    }

    private func resumeCard(_ trip: ActiveTrip) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label("Trip in progress", systemImage: "car.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text(model.resumeSummary(for: trip))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: trip.completionFraction)
                .tint(Theme.accent)
            HStack {
                Button("Resume") { onResume(trip) }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier(AccessibilityID.Home.resume)
                Menu {
                    Button("End trip", role: .destructive) {
                        Task { await model.discardActiveTrip() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 54, height: 54)
                        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
                .accessibilityLabel("More options")
                .accessibilityIdentifier(AccessibilityID.Home.discard)
            }
        }
        .card()
    }

    private var savedTrips: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Saved trips")
                .font(.headline)
            ForEach(model.savedItineraries) { itinerary in
                Button { onOpenItinerary(itinerary) } label: {
                    savedRow(itinerary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Home.savedTrip)
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        Task { await model.deleteItinerary(itinerary.id) }
                    }
                }
            }
        }
    }

    private func savedRow(_ itinerary: Itinerary) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            StopIcon(kind: .destination, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(itinerary.request.origin.name) → \(itinerary.request.destination.name)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text([
                    formatters.dayTitle(itinerary.request.departure, utcOffsetSeconds: itinerary.request.origin.utcOffsetSeconds),
                    formatters.duration(itinerary.totals.elapsedDuration),
                    formatters.currency(itinerary.totals.cost.total),
                ].joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .card()
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: "road.lanes")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("Your next road trip starts here")
                .font(.headline)
            Text("Tell Cadence where you're going and how far your car goes on a gallon. It plans breaks every 2–3 hours, fuel stops and places to sleep.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
    }
}
