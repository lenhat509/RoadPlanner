import Foundation
import Testing
@testable import TripFeatures
import TripModels
import TripNavigation
import TripPlanner
import TripSandbox

@MainActor
@Suite("Adjusting the rest of a trip")
struct AdjustRestTests {
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

    @Test("At a stop: the rest starts there, now, keeps your stops and the hotels ahead, and counts today's driving")
    func restOfTripFromAStop() async throws {
        let harness = FeatureHarness(), clock = Clock()
        var request = SampleTrips.request(from: "sf", to: "den")
        request.stops = [.visit(SampleTrips.city("lv"), stay: 5_400)]
        let itinerary = try await plan(request, harness)
        let stopIndex = 1
        clock.now = try #require(itinerary.stops[stopIndex].arrival).addingTimeInterval(600)
        let model = DriveViewModel(trip: trip(itinerary, at: stopIndex, phase: .atStop), dependencies: dependencies(harness, clock))
        let rest = try #require(model.restOfTripRequest())
        #expect(rest.origin.id == itinerary.stops[stopIndex].place.id)
        #expect(rest.departure == clock.now)
        #expect(rest.destination.id == "den")
        let ahead = itinerary.stops.dropFirst(stopIndex + 1).dropLast()
        let expected = ahead.filter { $0.isRequiredStop || $0.kind == .visit || ($0.kind == .lodging && !$0.place.id.hasPrefix("lodging-area-")) }
        #expect(rest.requiredStops.map(\.place.id) == expected.map(\.place.id), "your stops and hotels are kept, in order")
        #expect(!rest.requiredStops.contains { $0.purpose == .fuel || $0.purpose == .rest }, "Waystage chooses its fuel stops and breaks again")
        #expect(rest.requiredStops.contains { $0.purpose == .visit && $0.stay == 5_400 })
        let planned = try #require(itinerary.stops[stopIndex].arrival).timeIntervalSince(try #require(itinerary.stops[0].departure))
        #expect(abs((rest.startState?.drivenToday ?? 0) - planned) < 1)
        #expect((0.05...1).contains(rest.vehicle.initialFuelFraction))
    }

    @Test("Adjusting keeps the plan: your stops and hotels ahead stay, re-timed from now, and what changed is listed")
    func adjustKeepsThePlan() async throws {
        let harness = FeatureHarness(), clock = Clock()
        let itinerary = try await plan(SampleTrips.request(from: "sf", to: "den"), harness)
        clock.now = try #require(itinerary.stops[1].arrival).addingTimeInterval(1_800)
        let model = DriveViewModel(trip: trip(itinerary, at: 1, phase: .atStop), dependencies: dependencies(harness, clock))
        let adjustment = try #require(await model.adjustRest())
        let kept = itinerary.stops.dropFirst(2).dropLast().filter { $0.kind == .lodging && !$0.place.id.hasPrefix("lodging-area-") }
        #expect(!kept.isEmpty)
        for stop in kept {
            #expect(adjustment.plan.stops.contains { $0.place.id == stop.place.id && $0.isRequiredStop }, "\(stop.place.name) is kept")
        }
        #expect(adjustment.plan.stops.first?.place.id == itinerary.stops[1].place.id)
        #expect(adjustment.changes.first?.hasPrefix("Arrive Denver") == true)
        #expect(adjustment.changes.contains { $0.hasPrefix("Tonight: ") })
        #expect(!adjustment.stopsEarlierTonight)
        #expect(!adjustment.changes.contains { $0.hasPrefix("No longer in the plan") }, "nothing of yours is dropped")

        let next = try #require(await model.use(adjustment))
        #expect(next.id == adjustment.plan.id && next.id != itinerary.id)
        #expect(try await harness.repository.loadActiveTrip()?.id == next.id, "saved as the trip being driven")
    }

    @Test("Running late: stopping earlier tonight lets Waystage choose tonight's hotel, with others to pick from")
    func stopEarlierTonight() async throws {
        let harness = FeatureHarness(), clock = Clock()
        let itinerary = try await plan(SampleTrips.request(from: "sf", to: "den"), harness)
        let hotelIndex = try #require(itinerary.stops.firstIndex { $0.kind == .lodging })
        let hotel = itinerary.stops[hotelIndex]
        // At the stop before the hotel, 3 hours late.
        let previous = hotelIndex - 1
        clock.now = try #require(itinerary.stops[previous].departure).addingTimeInterval(3 * 3_600)
        let model = DriveViewModel(trip: trip(itinerary, at: previous, phase: .atStop), dependencies: dependencies(harness, clock))
        let kept = try #require(await model.adjustRest())
        #expect(kept.plan.stops.contains { $0.place.id == hotel.place.id }, "keeping the plan keeps tonight's hotel")
        let earlier = try #require(await model.stopEarlierTonight())
        #expect(earlier.stopsEarlierTonight)
        let tonight = try #require(earlier.plan.stops.first { $0.kind == .lodging })
        #expect(!earlier.hotelChoices.isEmpty)
        #expect(!earlier.hotelChoices.contains { $0.place.id == tonight.place.id })
        #expect(earlier.hotelChoices.allSatisfy { $0.timeFromPlanned <= 15 * 60 }, "only hotels within today's reach")
        let other = try #require(earlier.hotelChoices.first)
        let chosen = try #require(await model.adjust(earlier, stayingAt: other))
        #expect(chosen.plan.stops.first { $0.kind == .lodging }?.place.id == other.place.id)
    }

    @Test("A long trip with many fuel stops and nights ahead can be adjusted")
    func longTrip() async throws {
        let harness = FeatureHarness(), clock = Clock()
        var request = SampleTrips.request(from: "sf", to: "nyc")
        request.stops = [.visit(SampleTrips.city("lv"), stay: 3_600), .visit(SampleTrips.city("den"), stay: 3_600)]
        let itinerary = try await plan(request, harness)
        // Fuel stops, hotels and visits ahead: more than 10 (1.2.0 build 13 refused to adjust these).
        let ahead = itinerary.stops.dropFirst(2).dropLast()
            .filter { $0.kind != .rest && !$0.isRoadsidePullOff && !$0.place.id.hasPrefix("lodging-area-") }
        #expect(ahead.count > RequiredStop.maximumCount)
        clock.now = try #require(itinerary.stops[1].arrival).addingTimeInterval(600)
        let model = DriveViewModel(trip: trip(itinerary, at: 1, phase: .atStop), dependencies: dependencies(harness, clock))
        let adjustment = try #require(await model.adjustRest(), "\(model.statusMessage ?? "")")
        #expect(model.statusMessage == nil)
        #expect(adjustment.plan.stops.contains { $0.place.id == "den" && $0.kind == .visit })
        #expect(adjustment.plan.stops.last?.place.id == "nyc")
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
