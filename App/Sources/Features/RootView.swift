import SwiftUI
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

    var body: some View {
        @Bindable var bindable = environment
        NavigationStack(path: $path) {
            HomeView(
                dependencies: environment.dependencies,
                isDemo: environment.mode == .demo,
                onPlanTrip: { path.append(.plan) },
                onOpenSettings: { path.append(.settings) },
                onResume: { trip in environment.beginDrive(trip) },
                onOpenItinerary: { itinerary in
                    let result = PlanResult(itineraries: [itinerary.goal: itinerary], recommendedGoal: itinerary.goal)
                    path.append(.results(PlanResultRoute(result: result)))
                }
            )
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .plan:
                    PlanTripScreen(dependencies: environment.dependencies) { result in
                        path.append(.results(PlanResultRoute(result: result)))
                    }
                case let .results(route):
                    PlanResultScreen(result: route.result, dependencies: environment.dependencies) { trip in
                        environment.beginDrive(trip)
                    }
                case .settings:
                    SettingsScreen(dependencies: environment.dependencies)
                }
            }
        }
        .fullScreenCover(item: $bindable.drivingTrip) { trip in
            DriveScreen(trip: trip, dependencies: environment.dependencies) {
                environment.endDrive()
                path.removeAll()
            }
        }
    }
}
