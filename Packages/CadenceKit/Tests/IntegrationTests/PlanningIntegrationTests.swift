import Foundation
import Testing
import TripModels
import TripPlanner
import TripSandbox
import TripServices

/// End-to-end planning through the production Google/gateway adapters, served by the
/// in-process `SimulatedGoogleBackend` (no network, deterministic).
@Suite("Planning integration", .serialized)
struct PlanningIntegrationTests {
    actor PhaseLog {
        var phases: [PlanningPhase] = []
        func append(_ phase: PlanningPhase) { phases.append(phase) }
    }

    @Test("Plans a cross-country trip with valid, comparable options for every goal")
    func crossCountry() async throws {
        let services = SimulatedGoogleBackend.services()
        let log = PhaseLog()
        let result = try await services.planner.plan(SampleTrips.request(from: "sf", to: "nyc")) { phase in
            Task { await log.append(phase) }
        }
        #expect(Set(result.itineraries.keys) == Set(OptimizationGoal.allCases))
        let fastest = try #require(result.itineraries[.fastest])
        let cheapest = try #require(result.itineraries[.cheapest])
        let balanced = try #require(result.itineraries[.balanced])

        for itinerary in [fastest, cheapest, balanced] {
            let violations = ScheduleValidator().violations(in: itinerary)
            #expect(violations.isEmpty, "\(itinerary.goal): \(violations)")
            #expect(itinerary.nights >= 3, "a ~46 h drive needs several nights")
            #expect(itinerary.legs.count == itinerary.stops.count - 1, "turn-by-turn legs for every stop")
            #expect(itinerary.legs.allSatisfy { !$0.steps.isEmpty })
            #expect(itinerary.stops.contains { $0.kind == .fuel })
            #expect(itinerary.totals.cost.total > 0)
            #expect(!itinerary.overviewPolyline.isEmpty)
        }
        // Each goal wins on its own objective (small tolerance for re-timing with real legs).
        #expect(fastest.totals.elapsedDuration <= cheapest.totals.elapsedDuration + 600)
        #expect(cheapest.totals.cost.total <= fastest.totals.cost.total + 5)
        #expect(result.recommendedGoal == .balanced)

        try await Task.sleep(nanoseconds: 50_000_000)
        let phases = await log.phases
        #expect(phases.first == .findingRoute)
        #expect(phases.contains(.optimizing))
        #expect(phases.contains(.finalizing))
    }

    /// Regression: "Current Location" in Los Angeles on a phone set to UTC+9 made Fastest slower than Cheapest.
    @Test("Fastest is never slower and Cheapest never pricier than another option")
    func goalsAreConsistent() async throws {
        let services = SimulatedGoogleBackend.services()
        let departure = Date(timeIntervalSince1970: 1_794_552_300)
        var scenarios: [(String, Int, Date)] = [("nyc", 540, departure)]
        for offset in [-480, 60, 420] {
            for hours in [0.0, 8, 16] { scenarios.append(("den", offset, departure.addingTimeInterval(hours * 3_600))) }
        }
        for (destination, offsetMinutes, start) in scenarios {
            let origin = Place(
                id: "current-location", name: "Current Location",
                coordinate: SampleTrips.city("la").coordinate, utcOffsetMinutes: offsetMinutes
            )
            let request = TripRequest(origin: origin, destination: SampleTrips.city(destination), departure: start, vehicle: Vehicle(milesPerGallon: 28))
            let result = try await services.planner.plan(request) { _ in }
            let options = result.options
            let fastest = try #require(result.itineraries[.fastest])
            let cheapest = try #require(result.itineraries[.cheapest])
            let label = "\(destination) tz\(offsetMinutes / 60) \(start)"
            #expect(options.allSatisfy { fastest.totals.elapsedDuration <= $0.totals.elapsedDuration + 1 }, "\(label)")
            #expect(options.allSatisfy { cheapest.totals.cost.total <= $0.totals.cost.total + 0.01 }, "\(label)")
            for itinerary in options {
                #expect(ScheduleValidator().violations(in: itinerary).isEmpty, "\(label) \(itinerary.goal)")
                for stay in itinerary.stops where stay.kind == .lodging {
                    let wait = (stay.departure ?? .distantPast).timeIntervalSince(stay.arrival ?? .distantPast)
                    // Check-in from 2 PM, departure from 8 AM: at most 18 h (the bug produced ~23 h waits).
                    #expect(wait <= 18.5 * 3_600, "\(label) \(itinerary.goal) waits \(wait / 3_600) h at a hotel")
                }
            }
        }
    }

    @Test("Trip cost includes the gas used even without a fuel stop")
    func gasCostWithoutFuelStop() async throws {
        let result = try await SimulatedGoogleBackend.services().planner.plan(SampleTrips.request(from: "la", to: "lv", goal: .cheapest)) { _ in }
        let itinerary = try #require(result.recommended)
        #expect(itinerary.totals.cost.fuel > 20) // ~270 mi at 30 mpg ≈ 9 gal
        #expect((itinerary.totals.fuelGallonsUsed ?? 0) > 7)
    }

    @Test("A short trip is a single day with a rest stop")
    func shortTrip() async throws {
        let services = SimulatedGoogleBackend.services()
        let result = try await services.planner.plan(SampleTrips.request(from: "la", to: "lv", goal: .fastest)) { _ in }
        let itinerary = try #require(result.recommended)
        #expect(itinerary.nights == 0)
        #expect(itinerary.stops.first?.kind == .origin)
        #expect(itinerary.stops.last?.kind == .destination)
        #expect(ScheduleValidator().violations(in: itinerary).isEmpty)
        #expect(itinerary.totals.elapsedDuration < 8 * 3_600)
    }

    @Test("Respects a custom rest interval end to end")
    func customRestInterval() async throws {
        var policy = DrivingPolicy.standard
        policy.maxContinuousDriving = 2 * 3_600
        let result = try await SimulatedGoogleBackend.services().planner.plan(
            SampleTrips.request(from: "sf", to: "den", goal: .balanced, policy: policy)
        ) { _ in }
        let itinerary = try #require(result.recommended)
        #expect(ScheduleValidator().violations(in: itinerary).isEmpty)
        for index in 1..<itinerary.stops.count {
            guard let departure = itinerary.stops[index - 1].departure, let arrival = itinerary.stops[index].arrival else { continue }
            #expect(arrival.timeIntervalSince(departure) <= 2 * 3_600 + 120)
        }
    }

    @Test("An impossible deadline still yields a safe plan that explains the delay")
    func impossibleDeadline() async throws {
        let deadline = SampleTrips.departure.addingTimeInterval(20 * 3_600)
        let result = try await SimulatedGoogleBackend.services().planner.plan(
            SampleTrips.request(from: "sf", to: "chi", goal: .fastest, arriveBy: deadline)
        ) { _ in }
        let itinerary = try #require(result.recommended)
        #expect(itinerary.warnings.contains { $0.code == .deadlineMissed })
        #expect(ScheduleValidator().violations(in: itinerary).isEmpty)
    }

    @Test("Survives failing lodging searches with generic lodging areas and warnings")
    func degradedPlaces() async throws {
        let backend = SimulatedGoogleBackend(places: FakePlaceSearchProvider(failingCategories: [.lodging]))
        let result = try await SimulatedGoogleBackend.services(backend: backend).planner.plan(
            SampleTrips.request(from: "sf", to: "den", goal: .cheapest)
        ) { _ in }
        let itinerary = try #require(result.recommended)
        let codes = Set(itinerary.warnings.map(\.code))
        #expect(codes.contains(.incompleteStopData))
        #expect(ScheduleValidator().violations(in: itinerary).isEmpty)
        // Expedia offers (gateway) still provide real lodging even though Places failed.
        #expect(itinerary.stops.contains { $0.kind == .lodging })
    }

    @Test("Reports routing failures and invalid requests clearly")
    func failures() async throws {
        let failing = SampleTrips.planningService(routing: FakeRoutingProvider(failure: ServiceError.unauthorized("API key not valid")))
        await #expect(throws: PlanningError.self) {
            _ = try await failing.plan(SampleTrips.request(from: "sf", to: "lv")) { _ in }
        }
        let invalid = SampleTrips.request(from: "sf", to: "sf")
        await #expect(throws: PlanningError.invalidRequest([.originEqualsDestination])) {
            _ = try await SampleTrips.planningService().plan(invalid) { _ in }
        }
    }
}
