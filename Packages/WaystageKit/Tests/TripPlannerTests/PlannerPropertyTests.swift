import Foundation
import Testing
import TripModels
@testable import TripPlanner
import TripSandbox

/// Randomized ("property-based") tests: whatever the route, stop density, vehicle, policy,
/// goal or deadline, every plan must satisfy the safety rules checked by `ScheduleValidator`.
@Suite("Planner properties")
struct PlannerPropertyTests {
    struct Scenario {
        var request: TripRequest
        var profile: RouteProfile
        var candidates: [StopCandidate]
    }

    static func scenario(seed: UInt64) -> Scenario {
        var rng = SeededGenerator(seed: seed)
        let origin = GeoCoordinate(latitude: .random(in: 32...45, using: &rng), longitude: .random(in: -122 ... -110, using: &rng))
        let destination = GeoCoordinate(latitude: .random(in: 32...45, using: &rng), longitude: .random(in: -118 ... -75, using: &rng))
        let route = SyntheticRoute.make(from: origin, to: destination, speedMPH: .random(in: 50...70, using: &rng), vertexSpacingMeters: 2_000)
        let profile = route.profile()
        let density = SyntheticPlaces.Density(
            fuelEveryMinutes: .random(in: 20...90, using: &rng),
            restEveryMinutes: .random(in: 30...200, using: &rng),
            lodgingEveryMinutes: .random(in: 20...240, using: &rng)
        )
        let places = SyntheticPlaces.all(along: profile, density: density, seed: seed)
        let vehicle = Vehicle(
            milesPerGallon: .random(in: 15...45, using: &rng),
            tankCapacityGallons: .random(in: 9...22, using: &rng),
            initialFuelFraction: .random(in: 0.3...1, using: &rng),
            fuelType: FuelType.allCases.randomElement(using: &rng)!
        )
        var policy = DrivingPolicy.standard
        policy.maxContinuousDriving = [1.5, 2, 2.5, 3].randomElement(using: &rng)! * 3_600
        policy.fuelReserveFraction = [0.1, 0.15, 0.25, 0.35].randomElement(using: &rng)!
        let departure = SampleTrips.departure.addingTimeInterval(.random(in: -6...10, using: &rng) * 3_600)
        let arriveBy: Date? = Bool.random(using: &rng)
            ? departure.addingTimeInterval(profile.totalDuration * .random(in: 0.8...2.5, using: &rng))
            : nil
        let request = TripRequest(
            origin: Place(name: "Origin", coordinate: origin),
            destination: Place(name: "Destination", coordinate: destination),
            departure: departure,
            arriveBy: arriveBy,
            vehicle: vehicle,
            policy: policy,
            goal: OptimizationGoal.allCases.randomElement(using: &rng)!
        )
        let candidates = CandidateBuilder().build(profile: profile, places: places, fuelType: vehicle.fuelType)
        return Scenario(request: request, profile: profile, candidates: candidates)
    }

    @Test("Every plan satisfies rest, fuel, daily-driving and deadline rules", arguments: 1...24)
    func plansAreAlwaysSafe(seed: Int) {
        let scenario = Self.scenario(seed: UInt64(seed))
        let feasible = FeasibilityPlanner(policy: scenario.request.policy).solve(OptimizationProblem(
            profile: scenario.profile, candidates: scenario.candidates, request: scenario.request, goal: scenario.request.goal
        ))
        let itinerary = ItineraryAssembler().assemble(
            request: scenario.request, goal: scenario.request.goal, profile: scenario.profile,
            feasible: feasible, overviewPolyline: ""
        )
        let violations = ScheduleValidator(timeTolerance: 1, fuelTolerance: 1e-6).violations(in: itinerary)
        #expect(violations.isEmpty, "seed \(seed): \(violations)")
        // The rest-break limit is never relaxed.
        #expect(itinerary.appliedPolicy.maxContinuousDriving == scenario.request.policy.maxContinuousDriving)
        // Stops are in route order and the trip ends at the destination.
        #expect(itinerary.stops.first?.kind == .origin)
        #expect(itinerary.stops.last?.kind == .destination)
        let distances = itinerary.stops.map(\.distanceFromStartMeters)
        #expect(distances == distances.sorted())
        // A met deadline is really met; a missed one is explained.
        if let deadline = scenario.request.arriveBy, let arrival = itinerary.arrival, arrival > deadline {
            #expect(itinerary.warnings.contains { $0.code == .deadlineMissed })
        }
    }
}
