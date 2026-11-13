import Foundation
import Testing
import TripModels
@testable import TripPlanner

@Suite("FeasibilityPlanner")
struct FeasibilityPlannerTests {
    private let planner = FeasibilityPlanner(policy: .standard)

    private func richCandidates(hours: Double) -> [StopCandidate] {
        Fixture.restAreas(everyMinutes: 30, hours: hours)
            + Fixture.gasStations(everyMinutes: 45, hours: hours)
            + Fixture.lodging(everyMinutes: 30, from: 1, to: hours)
    }

    @Test("Uses the user's policy when it is feasible")
    func standardLevel() {
        let result = planner.solve(Fixture.problem(hours: 15, candidates: richCandidates(hours: 15)))
        #expect(result.level == .standard)
        #expect(result.deadlineMet)
        #expect(result.warnings.isEmpty)
        #expect(result.appliedPolicy == .standard)
    }

    @Test("Extends the driving day to meet a deadline, and says so")
    func extendsDayForDeadline() {
        // 10.5 h of road (+ detours): impossible in one standard day (10 h max), possible in an
        // extended one (11 h, ending by 23:00).
        let deadline = Fixture.departure.addingTimeInterval(14 * 3_600)
        let result = planner.solve(Fixture.problem(hours: 10.5, candidates: richCandidates(hours: 10.5), arriveBy: deadline))
        #expect(result.deadlineMet)
        #expect(result.level == .extendedDay)
        #expect(result.schedule.arrival <= deadline)
        #expect(result.warnings.map(\.code).contains(.extendedDrivingDay))
        #expect(Fixture.drivingSegments(result.schedule).allSatisfy { $0 <= 3 * 3_600 + 1 })
    }

    @Test("Drops an impossible deadline but still returns a safe plan")
    func impossibleDeadline() {
        let deadline = Fixture.departure.addingTimeInterval(5 * 3_600)
        let result = planner.solve(Fixture.problem(hours: 11, candidates: richCandidates(hours: 11), arriveBy: deadline))
        #expect(!result.deadlineMet)
        #expect(result.level == .standard)
        #expect(result.warnings.map(\.code).contains(.deadlineMissed))
        #expect(Fixture.drivingSegments(result.schedule).allSatisfy { $0 <= 3 * 3_600 + 1 })
    }

    @Test("Falls back to lodging search areas when no lodging is known")
    func lodgingAreas() {
        let profile = RouteProfile(
            coordinates: (0...1_600).map { GeoCoordinate(latitude: 40, longitude: -110 + Double($0) * 0.01) },
            totalDuration: 16 * 3_600
        )
        let places = (1..<32).map { index in
            FoundPlace(
                place: Place(id: "ra\(index)", name: "Rest Area", coordinate: GeoCoordinate(latitude: 40.002, longitude: -110 + Double(index) * 0.5)),
                categories: [.rest]
            )
        } + (1..<10).map { index in
            FoundPlace(
                place: Place(id: "gas\(index)", name: "Gas", coordinate: GeoCoordinate(latitude: 40.002, longitude: -110.2 + Double(index) * 1.6)),
                categories: [.fuel],
                fuelPrices: [.regular: 3.4]
            )
        }
        let candidates = CandidateBuilder().build(profile: profile, places: places, fuelType: .regular)
        let problem = OptimizationProblem(
            routeDistance: profile.totalDistance, routeDuration: profile.totalDuration, candidates: candidates,
            vehicle: Vehicle(milesPerGallon: 30), departure: Fixture.departure,
            originUTCOffset: Fixture.utcOffset, destinationUTCOffset: Fixture.utcOffset, goal: .balanced
        )
        let result = planner.solve(problem)
        #expect(result.level == .lastResort)
        #expect(result.warnings.map(\.code).contains(.lodgingAreaOnly))
        #expect(result.schedule.stops.contains { $0.candidate.isLodgingSearchArea })
        #expect(Fixture.drivingSegments(result.schedule).allSatisfy { $0 <= 3 * 3_600 + 1 })
    }

    @Test("Relaxation levels are cumulative and never touch the rest-break limit")
    func relaxationSettings() {
        var base = OptimizerSettings(policy: .standard)
        base.policy.maxContinuousDriving = 2 * 3_600
        let extended = FeasibilityPlanner.settings(for: .extendedDay, base: base)
        #expect(extended.policy.dayEnd == LocalTime(hour: 23))
        #expect(extended.policy.dayStart == LocalTime(hour: 7))
        #expect(extended.policy.maxDailyDriving == 11 * 3_600)
        #expect(!extended.allowNightDriving)

        let night = FeasibilityPlanner.settings(for: .nightDriving, base: base)
        #expect(night.allowNightDriving)
        #expect(night.policy.restStopDuration == 10 * 60)

        let last = FeasibilityPlanner.settings(for: .lastResort, base: base)
        #expect(last.allowLodgingSearchAreas && last.allowFuelAtPullOffs)
        #expect(last.policy.fuelReserveFraction == 0.05)

        for level in RelaxationLevel.allCases {
            #expect(FeasibilityPlanner.settings(for: level, base: base).policy.maxContinuousDriving == 2 * 3_600)
        }
    }

    @Test("Late day ends are clamped before midnight")
    func lateDayEndClamp() {
        var base = OptimizerSettings(policy: .standard)
        base.policy.dayEnd = LocalTime(hour: 22, minute: 45)
        #expect(FeasibilityPlanner.settings(for: .extendedDay, base: base).policy.dayEnd == LocalTime(hour: 23, minute: 30))
    }
}
