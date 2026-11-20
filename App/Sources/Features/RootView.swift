import SwiftUI
import TripFeatures
import TripModels
import TripPlanner

/// Navigation destinations.
enum AppRoute: Hashable {
    case plan
    case results(PlanResultRoute)
    case settings
}

/// Wraps a plan result so it can travel through a `NavigationPath`.
struct PlanResultRoute: Hashable {
    let id = UUID()
    let result: PlanResult

    static func == (lhs: PlanResultRoute, rhs: PlanResultRoute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Home → Plan → Results, with drive mode presented full screen on top.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var path: [AppRoute] = []
    /// The phone's light or dark setting (drive mode's map follows Google's day and night instead,
    /// but the plans it shows follow the phone, like the rest of the app).
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(
                dependencies: environment.dependencies,
                isDemo: environment.mode == .demo,
                onPlanTrip: { path.append(.plan) },
                onOpenSettings: { path.append(.settings) },
                onResume: { trip in Task { await environment.beginDrive(trip) } },
                onOpenItinerary: { itinerary in
                    let result = PlanResult(itineraries: [itinerary.goal: itinerary], recommendedGoal: itinerary.goal)
                    path.append(.results(PlanResultRoute(result: result)))
                },
                onOpenPlan: { result in path.append(.results(PlanResultRoute(result: result))) }
            )
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .plan:
                    PlanTripScreen(dependencies: environment.dependencies) { result in
                        path.append(.results(PlanResultRoute(result: result)))
                    }
                case let .results(route):
                    PlanResultScreen(result: route.result, dependencies: environment.dependencies) { trip in
                        Task { await environment.beginDrive(trip) }
                    }
                case .settings:
                    SettingsScreen(dependencies: environment.dependencies)
                }
            }
        }
        // The drive in progress, started here or on CarPlay.
        .fullScreenCover(item: driveBinding) { drive in
            DriveScreen(
                model: drive, dependencies: environment.dependencies, navigation: environment.navigation,
                appColorScheme: colorScheme,
                onReplaceTrip: { trip in Task { await environment.beginDrive(trip) } }
            ) {
                Task { await environment.endDrive() }
                path.removeAll()
            }
        }
    }

    private var driveBinding: Binding<DriveViewModel?> {
        Binding(
            get: { environment.drive },
            set: { drive in
                if drive == nil { Task { await environment.endDrive() } }
            }
        )
    }
}
