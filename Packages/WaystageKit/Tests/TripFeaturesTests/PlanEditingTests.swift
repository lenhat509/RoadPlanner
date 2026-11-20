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
    private func model() async throws -> (PlanResultViewModel, Itinerary) {
        let harness = FeatureHarness()
        let result = try await harness.dependencies.planner.plan(SampleTrips.request(from: "sf", to: "den")) { _ in }
        let model = PlanResultViewModel(result: result, dependencies: harness.dependencies)
        return (model, try #require(model.selected))
    }

    private func firstStop(_ plan: Itinerary, _ kind: StopKind) throws -> ItineraryStop {
        try #require(plan.stops.first { $0.kind == kind && !$0.isRoadsidePullOff })
    }

    @Test("Start and destination can't be edited; generated breaks can be removed but not kept")
    func whatCanBeEdited() async throws {
        let (model, plan) = try await model()
        #expect(model.editState(for: "origin") == nil && model.editState(for: "destination") == nil)
        let hotel = try firstStop(plan, .lodging)
        let state = try #require(model.editState(for: hotel.id))
        #expect(state.canKeep && state.canRemove && !state.isKept && !state.hotelChoices.isEmpty)
        if let pullOff = plan.stops.first(where: \.isRoadsidePullOff) {
            #expect(model.editState(for: pullOff.id)?.canKeep == false)
        }
        #expect(!model.hasChanges)
    }

    @Test("Kept stops and a chosen hotel become stops the next plan must include; removed ones are avoided")
    func changedRequest() async throws {
        let (model, plan) = try await model()
        let hotel = try firstStop(plan, .lodging)
        let removed = try #require(plan.stops.first { ($0.kind == .rest || $0.kind == .fuel) && !$0.isRoadsidePullOff })
        let kept = try #require(plan.stops.first {
            ($0.kind == .rest || $0.kind == .fuel) && !$0.isRoadsidePullOff && $0.id != removed.id
        })
        let other = try #require(model.editState(for: hotel.id)?.hotelChoices.first)
        model.toggleKeep(kept.id)
        model.toggleRemove(removed.id)
        model.chooseHotel(other, for: hotel.id)
        #expect(model.hasChanges)
        let request = try #require(model.changedRequest())
        #expect(request.requiredStops.map(\.place.id).contains(kept.place.id))
        #expect(request.requiredStops.contains { $0.place.id == other.place.id && $0.purpose == .lodging })
        #expect(!request.requiredStops.contains { $0.place.id == hotel.place.id }, "the planned hotel is replaced")
        #expect(request.avoidedPlaceIDs == [removed.place.id])
        // In route order, as the plan drives them.
        let order = plan.stops.map(\.id)
        let keptIndex = try #require(order.firstIndex(of: kept.id)), hotelIndex = try #require(order.firstIndex(of: hotel.id))
        let ids = request.requiredStops.map(\.place.id)
        #expect((ids.firstIndex(of: kept.place.id)! < ids.firstIndex(of: other.place.id)!) == (keptIndex < hotelIndex))
    }

    @Test("Planning again with the changes replaces the plan; the chosen hotel is kept, the removed stop is gone")
    func planAgain() async throws {
        let (model, plan) = try await model()
        let hotel = try firstStop(plan, .lodging)
        let removed = try #require(plan.stops.first { ($0.kind == .rest || $0.kind == .fuel) && !$0.isRoadsidePullOff })
        let other = try #require(model.editState(for: hotel.id)?.hotelChoices.first)
        model.chooseHotel(other, for: hotel.id)
        model.toggleRemove(removed.id)
        await model.planAgainWithChanges()
        #expect(model.planAgainError == nil)
        let next = try #require(model.selected)
        #expect(next.id != plan.id)
        let night = try #require(next.stops.first { $0.place.id == other.place.id })
        #expect(night.kind == .lodging && night.isRequiredStop)
        #expect(!next.stops.contains { $0.place.id == removed.place.id })
        #expect(!model.hasChanges, "the new plan starts with no pending changes")
        #expect(model.editState(for: night.id)?.isKept == true)
    }

    @Test("Choosing another plan style or route drops unapplied changes")
    func changesReset() async throws {
        let (model, plan) = try await model()
        let removed = try #require(plan.stops.first { ($0.kind == .rest || $0.kind == .fuel) && !$0.isRoadsidePullOff })
        model.toggleRemove(removed.id)
        #expect(model.hasChanges)
        model.selectedGoal = model.selectedGoal == .cheapest ? .fastest : .cheapest
        #expect(!model.hasChanges)
    }
}
