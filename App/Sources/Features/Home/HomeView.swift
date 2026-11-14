import SwiftUI
import TripFeatures
import TripModels

/// Start screen: a calm hero with one action, the trip in progress, and saved trips.
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
                hero
                if isDemo { demoBanner }
                if let trip = model.activeTrip { resumeCard(trip) }
                if !model.savedItineraries.isEmpty {
                    savedTrips
                } else if model.activeTrip == nil {
                    howItWorks
                }
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenSettings) {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier(AccessibilityID.Home.settings)
            }
        }
        .task(id: environment.drivingTrip?.id) { await model.load() }
    }

    // MARK: Sections

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.heroGradient)
            DecorativeRoute()
                .frame(width: 170, height: 110)
                .padding(.top, 14)
                .padding(.trailing, 6)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("WAYSTAGE")
                    .font(.caption.weight(.heavy))
                    .tracking(2.5)
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityHidden(true)
                Spacer(minLength: 44)
                Text(model.greeting)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                Text("Where to next?")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                Button(action: onPlanTrip) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                        Text("Plan a road trip")
                        Spacer()
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                    }
                    .font(.headline)
                    .foregroundStyle(Theme.brandDeep)
                    .padding(.leading, 18)
                    .padding(.trailing, 10)
                    .frame(height: 54)
                    .background(.white, in: Capsule(style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .padding(.top, Theme.Spacing.xs)
                .accessibilityLabel("Plan a road trip")
                .accessibilityIdentifier(AccessibilityID.Home.planTrip)
            }
            .padding(Theme.Spacing.l)
        }
        .frame(minHeight: 236)
        .padding(.top, Theme.Spacing.xs)
    }

    private var demoBanner: some View {
        Label {
            Text("Demo mode: sample cities and a simulated drive. Add a Google Maps key to plan real trips.")
                .font(.footnote)
        } icon: {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Theme.accent)
        }
        .card(padding: Theme.Spacing.s)
        .accessibilityIdentifier(AccessibilityID.Home.demoBanner)
    }

    private func resumeCard(_ trip: ActiveTrip) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Label("On the road", systemImage: "car.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .textCase(.uppercase)
                Spacer()
                Menu {
                    Button("End trip", role: .destructive) {
                        Task { await model.discardActiveTrip() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 32)
                        .background(Theme.mutedFill, in: Circle())
                }
                .accessibilityLabel("More options")
                .accessibilityIdentifier(AccessibilityID.Home.discard)
            }
            Text(model.resumeSummary(for: trip))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            TripRibbonView(
                marks: TripRibbon.marks(for: trip.itinerary),
                progress: TripRibbon.progress(of: trip, legProgress: nil)
            )
            Button { onResume(trip) } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier(AccessibilityID.Home.resume)
        }
        .card()
    }

    private var savedTrips: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel(title: "Saved trips")
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
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(itinerary.request.origin.name) → \(itinerary.request.destination.name)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            TripRibbonView(marks: TripRibbon.marks(for: itinerary), height: 14)
            Text([
                formatters.dayTitle(itinerary.request.departure, utcOffsetSeconds: itinerary.request.origin.utcOffsetSeconds),
                formatters.duration(itinerary.totals.elapsedDuration),
                formatters.currency(itinerary.totals.cost.total),
            ].joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .card()
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel(title: "How Waystage plans")
            VStack(alignment: .leading, spacing: 14) {
                feature(.rest, "A break every 2–3 hours", "Rest areas when there are some, a safe exit when there aren't.")
                feature(.fuel, "Gas before you run low", "At stations selling your fuel grade, never below your minimum level.")
                feature(.lodging, "A bed at the end of each day", "Hotels near where your driving day ends. You book them.")
            }
            .card()
            Text("Plans use Google Maps data and are suggestions: prices are estimates and nothing is booked for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.xxs)
        }
    }

    private func feature(_ kind: StopKind, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            StopDot(kind: kind, size: 14)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
