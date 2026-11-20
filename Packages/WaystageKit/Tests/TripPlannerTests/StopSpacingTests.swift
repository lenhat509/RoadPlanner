import Foundation
import Testing
import TripModels
@testable import TripPlanner
import TripSandbox

@Suite("Stops never pile up")
struct StopSpacingTests {
    @Test("Your own stop is the break: no extra break just before it")
    func noBreakJustBeforeYourStop() throws {
        // 3 h 10 min to the visit: within the stretch to reach your own stop.
        var visit = Fixture.candidate("grand-junction", atHours: 3 + 10.0 / 60, [], detourMinutes: 0)
        visit.requirement = .visit(stay: 3 * 3_600)
        let candidates = Fixture.restAreas(everyMinutes: 20, hours: 6) + Fixture.gasStations(everyMinutes: 60, hours: 6) + [visit]
        let schedule = try #require(Fixture.optimize(Fixture.problem(hours: 6, candidates: candidates)).value)
        let visitIndex = try #require(schedule.stops.firstIndex { $0.candidate.id == "grand-junction" })
        let breaksBefore = schedule.stops[..<visitIndex].filter { if case .rest = $0.action { true } else { false } }
        #expect(breaksBefore.isEmpty, "no break on the way to your own stop: \(breaksBefore.map(\.candidate.id))")
    }

    @Test("Breaks Waystage adds are at least 45 minutes apart, even with stops everywhere")
    func spacing() throws {
        let candidates = Fixture.restAreas(everyMinutes: 5, hours: 9) + Fixture.gasStations(everyMinutes: 10, hours: 9)
        let schedule = try #require(Fixture.optimize(Fixture.problem(hours: 9, candidates: candidates)).value)
        var last = Fixture.departure
        for stop in schedule.stops {
            if case .rest = stop.action { #expect(stop.arrival.timeIntervalSince(last) >= 45 * 60 - 1) }
            last = stop.departure
        }
    }

    @Test("A place on two passes of the route (out to a stop and back) is a stop on each pass")
    func samePlaceTwice() {
        let place = Place(id: "loves", name: "Love's", coordinate: GeoCoordinate(latitude: 35.2, longitude: -114.0))
        let outbound = FoundPlace(place: place, categories: [.fuel], searchRange: 100_000...200_000)
        let alsoOutbound = FoundPlace(place: place, categories: [.rest], searchRange: 180_000...280_000)
        let back = FoundPlace(place: place, categories: [.fuel], searchRange: 900_000...1_000_000)
        let merged = CandidateBuilder().mergeDuplicates([outbound, alsoOutbound, back])
        #expect(merged.count == 2, "merged on one pass, kept apart across passes")
        #expect(merged.first?.categories == [.fuel, .rest])
        #expect(merged.first?.searchRange == 100_000...280_000)
    }

    private func plan() async throws -> Itinerary {
        try #require(try await SampleTrips.planningService().plan(SampleTrips.request(from: "sf", to: "den")).recommended)
    }

    @Test("Once real driving times are known, a break minutes from the next stop is dropped")
    func crowdedBreakDropped() async throws {
        var itinerary = try await plan()
        let index = try #require(itinerary.stops.indices.first {
            itinerary.stops[$0].kind == .rest && $0 + 1 < itinerary.stops.count
        })
        // Make the break 10 minutes before the next stop.
        let drive = itinerary.legs[index].duration
        itinerary.legs[index].duration = 600
        itinerary.legs[index - 1].duration = min(itinerary.legs[index - 1].duration, itinerary.appliedPolicy.maxContinuousDriving - 900)
        let removed = itinerary.stops[index].id
        let cleaned = TripPlanningService.droppingCrowdedBreaks(itinerary)
        #expect(!cleaned.stops.contains { $0.id == removed })
        #expect(cleaned.legs.count == cleaned.stops.count - 1)
        #expect(drive > 0)
    }

    @Test("A stop the real directions show isn't where the plan put it is found")
    func misplacedStop() async throws {
        let itinerary = try await plan()
        let index = try #require(itinerary.stops.indices.first { $0 > 0 && $0 < itinerary.stops.count - 1 })
        #expect(TripPlanningService.misplacedStops(in: itinerary, legs: itinerary.legs).isEmpty, "a sound plan has none")
        var wrong = itinerary
        wrong.stops[index].distanceFromStartMeters += 300_000
        let found = TripPlanningService.misplacedStops(in: wrong, legs: wrong.legs)
        #expect(found == [TripPlanningService.candidateID(of: wrong.stops[index])])
    }
}
