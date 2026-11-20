import Foundation
import Testing
@testable import TripFeatures
import TripModels
import TripNavigation
import TripPlanner
import TripSandbox

@MainActor
@Suite("Planning the rest of a trip again")
struct PlanRestAgainTests {
    final class Clock: @unchecked Sendable {
        var now = testNow
    }

    /// The harness's dependencies with a clock the test moves.
    private func dependencies(_ harness: FeatureHarness, _ clock: Clock) -> AppDependencies {
        let base = harness.dependencies
        return AppDependencies(
            planner: base.planner, routing: base.routing, autocomplete: base.autocomplete, repository: base.repository,
            preferences: base.preferences, location: base.location, guidance: base.guidance, formatters: base.formatters,
            autocompleteDebounce: base.autocompleteDebounce, timeZone: base.timeZone, now: { clock.now }
        )
    }

    private func plan(_ request: TripRequest, _ harness: FeatureHarness) async throws -> Itinerary {
        try #require(try await harness.dependencies.planner.plan(request) { _ in }.recommended)
    }

    /// The trip on its way to stop `index` (or stopped there).
    private func trip(_ itinerary: Itinerary, at index: Int, phase: TripProgress.Phase = .enRoute) -> ActiveTrip {
        var trip = ActiveTrip(itinerary: itinerary)
        trip.progress.phase = phase
        trip.progress.targetStopIndex = index
        return trip
    }

    @Test("On time: nothing is suggested, but the rest can always be planned again")
    func onTime() async throws {
        let harness = FeatureHarness(), clock = Clock()
        let itinerary = try await plan(SampleTrips.request(from: "sf", to: "den"), harness)
        clock.now = try #require(itinerary.stops[0].departure)
        let model = DriveViewModel(trip: trip(itinerary, at: 1), dependencies: dependencies(harness, clock))
        #expect(model.replanSuggestion == nil)
        #expect(model.canPlanRestAgain)
    }

    @Test("Running hours late: tonight's hotel would be reached well after the driving day ends")
    func lateForHotel() async throws {
        let harness = FeatureHarness(), clock = Clock()
        let itinerary = try await plan(SampleTrips.request(from: "sf", to: "den"), harness)
        let hotelIndex = try #require(itinerary.stops.firstIndex { $0.kind == .lodging })
        let previous = itinerary.stops[hotelIndex - 1]
        clock.now = try #require(previous.departure).addingTimeInterval(4 * 3_600)
        let model = DriveViewModel(trip: trip(itinerary, at: hotelIndex), dependencies: dependencies(harness, clock))
        let suggestion = try #require(model.replanSuggestion)
        #expect(suggestion.reason == .lateForHotel(stopID: itinerary.stops[hotelIndex].id))
        #expect(suggestion.text.hasPrefix("Tonight's hotel: now around"))
        #expect(suggestion.text.contains("day end"))
    }

    @Test("Running late for a deadline the plan met")
    func deadlineAtRisk() async throws {
        let harness = FeatureHarness(), clock = Clock()
        let request = SampleTrips.request(from: "la", to: "lv", arriveBy: SampleTrips.departure.addingTimeInterval(7 * 3_600))
        let itinerary = try await plan(request, harness)
        #expect(!itinerary.warnings.contains { $0.code == .deadlineMissed })
        clock.now = SampleTrips.departure.addingTimeInterval(6 * 3_600)
        let model = DriveViewModel(trip: trip(itinerary, at: 1), dependencies: dependencies(harness, clock))
        #expect(model.replanSuggestion?.reason == .deadlineAtRisk)
    }

    @Test("At a stop: the rest starts there, now, keeps the visits ahead, and counts today's driving")
    func restOfTripFromAStop() async throws {
        let harness = FeatureHarness(), clock = Clock()
        var request = SampleTrips.request(from: "sf", to: "lv")
        request.stops = [.visit(SampleTrips.city("la"), stay: 5_400)]
        let itinerary = try await plan(request, harness)
        let visitIndex = try #require(itinerary.stops.firstIndex { $0.kind == .visit })
        #expect(visitIndex > 1, "a break before Los Angeles")
        let stopIndex = 1
        clock.now = try #require(itinerary.stops[stopIndex].arrival).addingTimeInterval(600)
        let model = DriveViewModel(trip: trip(itinerary, at: stopIndex, phase: .atStop), dependencies: dependencies(harness, clock))
        let rest = try #require(model.restOfTripRequest())
        #expect(rest.origin.id == itinerary.stops[stopIndex].place.id)
        #expect(rest.departure == clock.now)
        #expect(rest.destination.id == "lv")
        #expect(rest.requiredStops.map(\.place.id) == ["la"])
        #expect(rest.requiredStops.first?.stay == 5_400)
        let planned = try #require(itinerary.stops[stopIndex].arrival).timeIntervalSince(try #require(itinerary.stops[0].departure))
        #expect(abs((rest.startState?.drivenToday ?? 0) - planned) < 1)
        #expect((0.05...1).contains(rest.vehicle.initialFuelFraction))

        let result = try #require(await model.planRestAgain())
        let next = try #require(result.recommended)
        #expect(next.stops.first?.place.id == itinerary.stops[stopIndex].place.id)
        #expect(next.stops.contains { $0.kind == .visit && $0.place.id == "la" })
    }

    @Test("On the way: the rest starts where the car is")
    func restOfTripFromTheRoad() async throws {
        let harness = FeatureHarness(), clock = Clock()
        let itinerary = try await plan(SampleTrips.request(from: "la", to: "lv"), harness)
        clock.now = SampleTrips.departure.addingTimeInterval(1_800)
        let model = DriveViewModel(trip: trip(itinerary, at: 1), dependencies: dependencies(harness, clock))
        let rest = try #require(model.restOfTripRequest())
        #expect(rest.origin.id == "current-location")
        #expect(rest.origin.coordinate == harness.location.lastKnownLocation)
        #expect(rest.requiredStops.isEmpty)
    }
}
