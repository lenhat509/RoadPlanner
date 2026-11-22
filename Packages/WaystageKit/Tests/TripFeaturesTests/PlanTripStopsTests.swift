import Foundation
import Testing
@testable import TripFeatures
import TripModels
import TripPlanner
import TripSandbox

@MainActor
@Suite("Plan form: stops on the way")
struct PlanTripStopsTests {
    private func choose(_ model: PlanTripViewModel, _ id: String, _ field: PlanTripViewModel.Field) async {
        let city = SampleTrips.city(id)
        await model.select(PlaceSuggestion(placeID: city.id, primaryText: city.name, secondaryText: ""), for: field)
    }

    private func filledModel() async -> PlanTripViewModel {
        let model = PlanTripViewModel(dependencies: FeatureHarness().dependencies)
        await choose(model, "sf", .origin)
        await choose(model, "lv", .destination)
        return model
    }

    @Test("A stop with a place and a stay goes into the request, in order")
    func stopInRequest() async throws {
        let model = await filledModel()
        let field = try #require(model.addStop())
        guard case let .stop(id) = field else { Issue.record("not a stop field"); return }
        await choose(model, "la", field)
        model.setStay(120, for: id)
        guard case let .valid(request) = model.makeRequest() else { Issue.record("\(model.validationErrors)"); return }
        #expect(request.requiredStops.map(\.place.id) == ["la"])
        #expect(request.requiredStops.first?.purpose == .visit)
        #expect(request.requiredStops.first?.stay == 7_200)
    }

    @Test("A stop without a place stops the plan; removing it fixes that")
    func emptyStop() async throws {
        let model = await filledModel()
        let field = try #require(model.addStop())
        #expect(model.validationErrors == [.invalidStop])
        #expect(!model.canPlan)
        guard case let .stop(id) = field else { Issue.record("not a stop field"); return }
        model.removeStop(id)
        #expect(model.canPlan)
    }

    @Test("Stops can be reordered, the stay is nights and hours (whole hours), and at most 10 can be added")
    func editing() async throws {
        let model = await filledModel()
        for city in ["la", "den"] {
            let field = try #require(model.addStop())
            await choose(model, city, field)
        }
        model.moveStop(model.stops[1].id, by: -1)
        #expect(model.stops.map { $0.location.place?.id } == ["den", "la"])
        // Dragged onto another stop: it takes that stop's place.
        model.moveStop(model.stops[0].id, to: model.stops[1].id)
        #expect(model.stops.map { $0.location.place?.id } == ["la", "den"])
        #expect(model.stopOrder == .shortest, "new trips: the shortest drive")
        guard case let .valid(request) = model.makeRequest() else { Issue.record("\(model.validationErrors)"); return }
        #expect(request.stopOrder == .shortest)
        model.stopOrder = .asListed
        guard case let .valid(listed) = model.makeRequest() else { Issue.record("\(model.validationErrors)"); return }
        #expect(listed.stopOrder == .asListed && listed.requiredStops.map(\.place.id) == ["la", "den"])
        let first = model.stops[0].id
        model.setStay(1, for: first)
        #expect(model.stops[0].stayMinutes == 60, "at least an hour without nights")
        model.setStay(5_000, for: first)
        #expect(model.stops[0].stayMinutes == 23 * 60)
        #expect(PlanTripViewModel.stayStep == 60)
        // 2 nights, leaving the morning after plus 3 hours, in a hotel nearby.
        model.setNights(2, for: first)
        model.setStay(0, for: first)
        #expect(model.stops[0].stayMinutes == 0, "no extra hours is fine with nights")
        model.setStay(180, for: first)
        model.setOvernight(.nearbyHotel, for: first)
        model.setNights(30, for: first)
        #expect(model.stops[0].nights == 14)
        model.setNights(2, for: first)
        guard case let .valid(withNights) = model.makeRequest() else { Issue.record("\(model.validationErrors)"); return }
        let nightsStop = try #require(withNights.requiredStops.first)
        #expect(nightsStop.visitNights == 2 && nightsStop.stay == 3 * 3_600 && nightsStop.overnight == .nearbyHotel)
        while model.canAddStop { model.addStop() }
        #expect(model.stops.count == RequiredStop.maximumCount)
        #expect(model.addStop() == nil)
    }

    @Test("Swapping start and destination drives the stops the other way")
    func swapReversesStops() async throws {
        let model = await filledModel()
        for city in ["la", "den"] {
            let field = try #require(model.addStop())
            await choose(model, city, field)
        }
        model.swapLocations()
        #expect(model.origin.place?.id == "lv")
        #expect(model.stops.map { $0.location.place?.id } == ["den", "la"])
    }
}
