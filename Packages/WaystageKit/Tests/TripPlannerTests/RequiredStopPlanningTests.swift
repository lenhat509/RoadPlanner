import Foundation
import Testing
import TripModels
@testable import TripPlanner
import TripSandbox

@Suite("Required stops")
struct RequiredStopPlanningTests {
    private func visit(_ id: String, atHours hours: Double, stayHours: Double) -> StopCandidate {
        var candidate = Fixture.candidate(id, atHours: hours, [], detourMinutes: 0)
        candidate.requirement = .visit(stay: stayHours * 3_600)
        return candidate
    }

    private func required(_ candidate: StopCandidate, _ requirement: StopRequirement) -> StopCandidate {
        var candidate = candidate
        candidate.requirement = requirement
        return candidate
    }

    // MARK: Optimizer

    @Test("A visit is kept, with its stay, and no driving goes past it")
    func visitKept() throws {
        let candidates = Fixture.restAreas(everyMinutes: 30, hours: 6) + Fixture.gasStations(everyMinutes: 90, hours: 6)
            + [visit("museum", atHours: 2.6, stayHours: 2)]
        let schedule = try #require(Fixture.optimize(Fixture.problem(hours: 6, candidates: candidates)).value)
        let stop = try #require(schedule.stops.first { $0.candidate.id == "museum" })
        #expect(stop.action == .visit(stay: 2 * 3_600))
        #expect(stop.departure.timeIntervalSince(stop.arrival) == 2 * 3_600)
        #expect(schedule.arrival.timeIntervalSince(Fixture.departure) >= 8 * 3_600, "6 h of driving plus the 2 h visit")
        #expect(Fixture.respectsBreaks(schedule, interval: DrivingPolicy.standard.maxContinuousDriving))
    }

    @Test("A visit is kept even when skipping it would be faster")
    func visitNotSkipped() throws {
        // Without the requirement, a 3 h stop at 1 h would never be chosen.
        let candidates = Fixture.restAreas(everyMinutes: 30, hours: 4) + [visit("lake", atHours: 1, stayHours: 3)]
        let schedule = try #require(Fixture.optimize(Fixture.problem(hours: 4, candidates: candidates)).value)
        #expect(schedule.stops.contains { $0.candidate.id == "lake" })
    }

    @Test("A late visit still fits: the night goes before or after it, within the day's limits")
    func visitAndNight() throws {
        let candidates = Fixture.restAreas(everyMinutes: 30, hours: 14) + Fixture.gasStations(everyMinutes: 90, hours: 14)
            + Fixture.lodging(everyMinutes: 30, from: 6, to: 13.5) + [visit("canyon", atHours: 10, stayHours: 2)]
        let schedule = try #require(Fixture.optimize(Fixture.problem(hours: 14, candidates: candidates)).value)
        let stops = schedule.stops.map(\.candidate.id)
        #expect(stops.contains("canyon"))
        #expect(schedule.stops.contains { if case .overnight = $0.action { true } else { false } })
        let canyon = try #require(schedule.stops.first { $0.candidate.id == "canyon" })
        #expect(Fixture.localSecondsOfDay(canyon.departure) <= DrivingPolicy.standard.dayEnd.secondsFromMidnight + 60,
                "the visit ends within the driving day")
    }

    @Test("A kept hotel is used even when the check-in would be early")
    func keptHotel() throws {
        let hotel = required(Fixture.candidate("inn", atHours: 1, [.lodging], nightlyRate: 90), .overnight)
        let candidates = Fixture.restAreas(everyMinutes: 30, hours: 5) + [hotel]
        let schedule = try #require(Fixture.optimize(Fixture.problem(hours: 5, candidates: candidates)).value)
        let stop = try #require(schedule.stops.first { $0.candidate.id == "inn" })
        #expect(stop.action == .overnight(nightlyRate: 90))
        #expect(schedule.finalDayIndex == 1)
    }

    @Test("Driving already done today counts toward the daily limit")
    func startState() throws {
        var problem = Fixture.problem(
            hours: 4, candidates: Fixture.restAreas(everyMinutes: 30, hours: 4) + Fixture.lodging(everyMinutes: 30, from: 0.5, to: 4)
        )
        // Planned again at 3 PM, after a morning on the road.
        problem.departure = Fixture.departure.addingTimeInterval(7 * 3_600)
        let fresh = try #require(Fixture.optimize(problem).value)
        #expect(!fresh.stops.contains { if case .overnight = $0.action { true } else { false } })
        problem.initialDrivenToday = 9 * 3_600
        let tired = try #require(Fixture.optimize(problem).value)
        let night = try #require(tired.stops.first { if case .overnight = $0.action { true } else { false } })
        #expect(night.candidate.timeAlong <= 3_600, "with 1 h of driving left today, the night comes within the hour")
    }

    @Test("When no schedule exists, the straight-through fallback still includes the required stops")
    func fallbackKeepsStops() {
        // A 60-mile tank and no gas stations: no level can plan this.
        var problem = Fixture.problem(
            hours: 6, candidates: [visit("museum", atHours: 2, stayHours: 1)],
            vehicle: Vehicle(milesPerGallon: 30, tankCapacityGallons: 2)
        )
        problem.referenceFuelPrice = 3.5
        let feasible = FeasibilityPlanner(policy: .standard).solve(problem)
        #expect(feasible.schedule.stops.map(\.candidate.id) == ["museum"])
        #expect(feasible.warnings.contains { $0.code == .fuelGap })
    }

    @Test("Lodging is searched where nights fall once visits are counted")
    func lodgingWindowsCountStays() {
        let estimator = LodgingWindowEstimator()
        let plain = estimator.windows(routeDuration: 20 * 3_600, departure: Fixture.departure, utcOffset: Fixture.utcOffset, policy: .standard)
        let withVisit = estimator.windows(
            routeDuration: 20 * 3_600, departure: Fixture.departure, utcOffset: Fixture.utcOffset, policy: .standard,
            stays: [(at: 2.0 * 3_600, duration: 4.0 * 3_600)]
        )
        let first = plain.first?.routeTimeRange.upperBound ?? 0
        let firstWithVisit = withVisit.first?.routeTimeRange.upperBound ?? 0
        #expect(firstWithVisit < first, "a 4 h visit ends the first driving day earlier along the route")
    }

    // MARK: Planning service

    final class CountingPlaces: PlaceSearchProvider, @unchecked Sendable {
        let inner = FakePlaceSearchProvider()
        private let lock = NSLock()
        private var count = 0
        var sent: Int { lock.withLock { count } }
        func searchAlongRoute(_ search: AlongRouteSearch) async throws -> [FoundPlace] {
            lock.withLock { count += 1 }
            return try await inner.searchAlongRoute(search)
        }
    }

    @Test("Stops on the way: one route through them, in order, with the stay")
    func stopsOnTheWay() async throws {
        var request = SampleTrips.request(from: "sf", to: "lv")
        request.stops = [.visit(SampleTrips.city("la"), stay: 2.0 * 3_600)]
        let result = try await SampleTrips.planningService().plan(request)
        #expect(result.routes.count == 1, "Google offers no alternative routes through stops")
        let itinerary = try #require(result.recommended)
        let visit = try #require(itinerary.stops.first { $0.kind == .visit })
        #expect(visit.place.id == "la" && visit.isRequiredStop)
        #expect(visit.dwellDuration == 7_200.0)
        let distances = itinerary.stops.map(\.distanceFromStartMeters)
        #expect(distances == distances.sorted())
    }

    @Test("A removed stop isn't planned again, and a kept hotel stays")
    func avoidAndKeep() async throws {
        let service = SampleTrips.planningService()
        let first = try #require(try await service.plan(SampleTrips.request(from: "sf", to: "den")).recommended)
        let removed = try #require(first.stops.first { ($0.kind == .rest || $0.kind == .fuel) && !$0.isRoadsidePullOff })
        let hotel = try #require(first.stops.first { $0.kind == .lodging })
        var request = first.request
        request.avoidedPlaceIDs = [removed.place.id]
        request.stops = [RequiredStop(place: hotel.place, purpose: .lodging, lodging: hotel.lodging)]
        let second = try #require(try await service.plan(request).recommended)
        #expect(!second.stops.contains { $0.place.id == removed.place.id })
        let kept = try #require(second.stops.first { $0.place.id == hotel.place.id })
        #expect(kept.kind == .lodging && kept.isRequiredStop)
    }

    @Test("Planning again in the same session reuses its searches")
    func sessionMemory() async throws {
        let places = CountingPlaces()
        let service = TripPlanningService(routing: FakeRoutingProvider(), places: places)
        _ = try await service.plan(SampleTrips.request(from: "la", to: "lv"))
        let first = places.sent
        #expect(first > 0)
        _ = try await service.plan(SampleTrips.request(from: "la", to: "lv", goal: .cheapest))
        #expect(places.sent == first, "the same road isn't searched again")

        var forgetful = TripPlanningConfiguration()
        forgetful.searchMemoryLifetime = 0
        let fresh = CountingPlaces()
        let service2 = TripPlanningService(routing: FakeRoutingProvider(), places: fresh, configuration: forgetful)
        _ = try await service2.plan(SampleTrips.request(from: "la", to: "lv"))
        _ = try await service2.plan(SampleTrips.request(from: "la", to: "lv"))
        #expect(fresh.sent == 2 * first, "with no memory, every plan searches")
    }
}
