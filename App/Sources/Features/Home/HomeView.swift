import SwiftUI
import TripFeatures
import TripModels
import TripPlanner

/// Start screen: a calm hero with one action, the trip in progress, and saved trips.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: HomeViewModel
    /// "Adjust visits" for the trip in progress.
    @State private var visits: VisitsEditing?
    let isDemo: Bool
    let onPlanTrip: () -> Void
    let onOpenSettings: () -> Void
    let onResume: (ActiveTrip) -> Void
    /// Opens the trip in progress: its whole plan, like a plan just made.
    let onOpenTrip: (ActiveTrip) -> Void
    let onOpenItinerary: (Itinerary) -> Void
    /// A plan made again from an outlined saved trip.
    let onOpenPlan: (PlanResult) -> Void
    private let formatters: TripFormatters

    init(
        dependencies: AppDependencies,
        isDemo: Bool,
        onPlanTrip: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onResume: @escaping (ActiveTrip) -> Void,
        onOpenTrip: @escaping (ActiveTrip) -> Void,
        onOpenItinerary: @escaping (Itinerary) -> Void,
        onOpenPlan: @escaping (PlanResult) -> Void
    ) {
        _model = State(initialValue: HomeViewModel(dependencies: dependencies))
        formatters = dependencies.formatters
        self.isDemo = isDemo
        self.onPlanTrip = onPlanTrip
        self.onOpenSettings = onOpenSettings
        self.onResume = onResume
        self.onOpenTrip = onOpenTrip
        self.onOpenItinerary = onOpenItinerary
        self.onOpenPlan = onOpenPlan
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
        .task(id: environment.drive?.id) { await model.load() }
        // Back from the trip's plan, where its visits may have changed.
        .onAppear { Task { await model.load() } }
        .sheet(item: $visits) { visits in
            AdjustVisitsSheet(
                model: visits.editor,
                dependencies: environment.dependencies,
                onUse: {
                    Task {
                        guard await visits.drive.use(plan: visits.editor.plan) != nil else { return }
                        self.visits = nil
                        await model.load()
                    }
                },
                onCancel: { self.visits = nil }
            )
        }
    }

    // MARK: Sections

    /// The app's name, a greeting and the one action: plain type on the page, no banner.
    private var hero: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.greeting)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Where to next?")
                    .font(.largeTitle.weight(.bold))
            }
            Button(action: onPlanTrip) {
                Label("Plan a road trip", systemImage: "magnifyingglass")
            }
            .buttonStyle(.primary)
            .accessibilityLabel("Plan a road trip")
            .accessibilityIdentifier(AccessibilityID.Home.planTrip)
        }
        .padding(.top, Theme.Spacing.m)
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
                SectionLabel(title: "On the road")
                Spacer()
                Menu {
                    Button("End trip", role: .destructive) {
                        Task { await model.discardActiveTrip() }
                    }
                } label: {
                    IconButtonLabel(systemImage: "ellipsis")
                }
                .accessibilityLabel("More options")
                .accessibilityIdentifier(AccessibilityID.Home.discard)
            }
            Button { onOpenTrip(trip) } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.resumeSummary(for: trip))
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Theme.Spacing.xs)
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    TripRibbonView(
                        marks: TripRibbon.marks(for: trip.itinerary),
                        progress: TripRibbon.progress(of: trip, legProgress: nil)
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the whole trip")
            .accessibilityIdentifier(AccessibilityID.Home.tripOverview)
            HStack(spacing: Theme.Spacing.xs) {
                Button {
                    let drive = DriveViewModel(trip: trip, dependencies: environment.dependencies)
                    visits = VisitsEditing(drive: drive, editor: drive.visitsEditor())
                } label: {
                    Label("Adjust visits", systemImage: "mappin.and.ellipse")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .buttonStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.Home.adjustVisits)
                Button { onResume(trip) } label: {
                    Label("Resume", systemImage: "play.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier(AccessibilityID.Home.resume)
            }
        }
        .card()
    }

    private var savedTrips: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel(title: "Saved trips")
            ForEach(model.savedItineraries) { itinerary in
                Button { open(itinerary) } label: {
                    savedRow(itinerary)
                }
                .disabled(model.replanningID != nil)
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

    /// Opens a saved plan with its place names fetched again, or plans an outlined one again.
    private func open(_ itinerary: Itinerary) {
        Task {
            if model.needsPlanningAgain(itinerary) {
                if let result = await model.planAgain(itinerary) { onOpenPlan(result) }
            } else {
                onOpenItinerary(await model.details(of: itinerary))
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
            if model.needsPlanningAgain(itinerary) {
                // Saved over 30 days ago: Google's map data for it can't be kept that long.
                Label(
                    model.replanningID == itinerary.id ? "Planning again…" : "Saved over 30 days ago · tap to plan again",
                    systemImage: "arrow.clockwise"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                TripRibbonView(marks: TripRibbon.marks(for: itinerary), height: 14)
            }
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

/// "Adjust visits" for the trip in progress, opened from Home (no drive running).
private struct VisitsEditing: Identifiable {
    let id = UUID()
    let drive: DriveViewModel
    let editor: AdjustVisitsViewModel
}
