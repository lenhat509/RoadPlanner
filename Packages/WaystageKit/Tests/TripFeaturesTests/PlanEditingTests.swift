import Foundation
import Testing
@testable import TripFeatures
import TripModels
import TripPlanner
import TripSandbox

@MainActor
@Suite("Editing a plan")
struct PlanEditingTests {
    /// San Francisco → Denver (a night on the way), planned with the harness's own planner.
    private func model() async throws -> (PlanResultViewModel, Itinerary, FeatureHarness) {
        let harness = FeatureHarness()
        let result = try await harness.dependencies.planner.plan(SampleTrips.request(from: "sf", to: "den")) { _ in }
        let model = PlanResultViewModel(result: result, dependencies: harness.dependencies)
        return (model, try #require(model.selected), harness)
    }

    private func optionalStop(_ plan: Itinerary, kinds: Set<StopKind> = [.rest, .fuel]) throws -> ItineraryStop {
        try #require(plan.stops.first { kinds.contains($0.kind) && !$0.isRoadsidePullOff && !$0.isRequiredStop })
    }

    @Test("Start and destination can't be edited; generated breaks can be removed but not kept")
    func whatCanBeEdited() async throws {
        let (model, plan, _) = try await model()
        #expect(model.editState(for: "origin") == nil && model.editState(for: "destination") == nil)
        let hotel = try optionalStop(plan, kinds: [.lodging])
        let state = try #require(model.editState(for: hotel.id))
        #expect(state.canKeep && state.canRemove && !state.isKept && !state.hotelChoices.isEmpty)
        if let pullOff = plan.stops.first(where: \.isRoadsidePullOff) {
            #expect(model.editState(for: pullOff.id)?.canKeep == false)
        }
        #expect(!model.canUndo)
    }

    @Test("Removing a stop updates the plan at once; Undo brings the previous plan back")
    func removeAndUndo() async throws {
        let (model, plan, _) = try await model()
        let removed = try optionalStop(plan)
        await model.apply(.remove(stopID: removed.id))
        let next = try #require(model.selected)
        #expect(next.id != plan.id)
        #expect(!next.stops.contains { $0.place.id == removed.place.id })
        #expect(model.canUndo)
        model.undo()
        #expect(model.selected?.id == plan.id)
        #expect(!model.canUndo)
    }

    @Test("Each change keeps the earlier ones: kept stops and a chosen hotel stay while others change")
    func changesAccumulate() async throws {
        let (model, plan, _) = try await model()
        let kept = try optionalStop(plan)
        await model.apply(.toggleKeep(stopID: kept.id))
        let afterKeep = try #require(model.selected)
        let keptNow = try #require(afterKeep.stops.first { $0.place.id == kept.place.id })
        #expect(keptNow.isRequiredStop)
        #expect(model.editState(for: keptNow.id)?.isKept == true)

        let hotel = try optionalStop(afterKeep, kinds: [.lodging])
        let other = try #require(model.editState(for: hotel.id)?.hotelChoices.first)
        await model.apply(.chooseHotel(stopID: hotel.id, other))
        let afterHotel = try #require(model.selected)
        #expect(afterHotel.stops.contains { $0.place.id == other.place.id && $0.kind == .lodging && $0.isRequiredStop })
        #expect(!afterHotel.stops.contains { $0.place.id == hotel.place.id }, "the planned hotel is replaced")
        #expect(afterHotel.stops.contains { $0.place.id == kept.place.id && $0.isRequiredStop }, "the earlier change stays")

        // Stop keeping it: it's no longer required (Waystage may still choose it).
        let keptAgain = try #require(afterHotel.stops.first { $0.place.id == kept.place.id })
        await model.apply(.toggleKeep(stopID: keptAgain.id))
        #expect(model.selected?.stops.first { $0.place.id == kept.place.id }?.isRequiredStop != true)
    }

    @Test("Adding a stop after another visits it, for its stay, in that place in the trip")
    func addStopHere() async throws {
        let (model, plan, harness) = try await model()
        let search = PlaceSearchViewModel(dependencies: harness.dependencies)
        search.queryChanged("Las")
        await search.waitForSuggestions()
        let suggestion = try #require(search.suggestions.first { $0.primaryText == "Las Vegas" })
        await search.select(suggestion)
        search.setStay(90)
        let place = try #require(search.place)
        await model.apply(.addStop(after: "origin", place: place, stay: search.stay))
        let next = try #require(model.selected)
        let visit = try #require(next.stops.first { $0.kind == .visit })
        #expect(visit.place.id == "lv" && visit.dwellDuration == 5_400.0)
        #expect(plan.request.requiredStops.isEmpty)
        #expect(model.canAddStop)
    }

    @Test("A departure that has passed moves to the next hour when the plan is made again")
    func pastDeparture() async throws {
        let (_, plan, _) = try await model()
        let stop = try optionalStop(plan)
        let later = plan.request.departure.addingTimeInterval(5 * 3_600 + 600)
        let request = try #require(PlanResultViewModel.request(for: plan, applying: .remove(stopID: stop.id), now: later))
        #expect(request.departure > later && request.departure.timeIntervalSince(later) <= 3_600)
        #expect(request.avoidedPlaceIDs == [stop.place.id])
    }
}
