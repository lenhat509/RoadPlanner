import Foundation
import Testing
@testable import TripFeatures
import TripModels
import TripNavigation
import TripPlanner
import TripSandbox

@MainActor
@Suite("Adjusting visits")
struct AdjustVisitsTests {
    final class Clock: @unchecked Sendable {
        var now = testNow
    }

    private func dependencies(_ harness: FeatureHarness, _ clock: Clock) -> AppDependencies {
        let base = harness.dependencies
        return AppDependencies(
            planner: base.planner, routing: base.routing, autocomplete: base.autocomplete, repository: base.repository,
            preferences: base.preferences, location: base.location, guidance: base.guidance, formatters: base.formatters,
            autocompleteDebounce: base.autocompleteDebounce, timeZone: base.timeZone, now: { clock.now }
        )
    }

    /// San Francisco → Denver with 1 h 30 in Las Vegas.
    private func itinerary(_ harness: FeatureHarness) async throws -> Itinerary {
        var request = SampleTrips.request(from: "sf", to: "den")
        request.stops = [.visit(SampleTrips.city("lv"), stay: 5_400)]
        return try #require(try await harness.dependencies.planner.plan(request) { _ in }.recommended)
    }

    @Test("Before Start: every stop of the trip, with its address and arrival time; visits can be removed and added, and Undo goes back")
    func beforeStart() async throws {
        let harness = FeatureHarness(), clock = Clock()
        let itinerary = try await itinerary(harness)
        clock.now = SampleTrips.departure.addingTimeInterval(-3_600)
        let drive = DriveViewModel(trip: ActiveTrip(itinerary: itinerary), dependencies: dependencies(harness, clock))
        let editor = drive.visitsEditor()
        #expect(editor.rows.map(\.id) == itinerary.stops.dropFirst().map(\.id), "every stop after the start")
        #expect(editor.rows.last?.kind == .destination)
        #expect(editor.rows.allSatisfy { $0.eta?.hasPrefix(($0.kind == .lodging) ? "Check in " : "Arrive ") == true })
        let visit = try #require(editor.rows.first { $0.isVisit })
        #expect(visit.name == "Las Vegas" && visit.address == "Las Vegas, NV, USA" && visit.kindText.hasSuffix("there"))
        #expect(editor.rows.filter(\.isVisit).count == 1, "only visits can be removed")
        #expect(editor.canEdit && editor.canAddVisit && !editor.hasChanges)

        await editor.remove(visit.id)
        #expect(editor.errorMessage == nil)
        #expect(!editor.plan.stops.contains { $0.kind == .visit })
        #expect(editor.plan.stops.first?.place.id == "sf", "the whole trip, from its start")
        #expect(editor.hasChanges && editor.canUndo)

        await editor.add(SampleTrips.city("la"), stay: 3_600)
        let added = try #require(editor.plan.stops.first { $0.kind == .visit })
        #expect(added.place.id == "la" && added.dwellDuration == 3_600.0)

        editor.undo()
        editor.undo()
        #expect(editor.plan.id == itinerary.id && !editor.hasChanges)
    }

    @Test("At a stop: only the stops ahead are shown, and the rest of the trip is planned from here")
    func atAStop() async throws {
        let harness = FeatureHarness(), clock = Clock()
        let itinerary = try await itinerary(harness)
        let visitIndex = try #require(itinerary.stops.firstIndex { $0.kind == .visit })
        let stopIndex = visitIndex - 1
        #expect(stopIndex >= 1)
        var trip = ActiveTrip(itinerary: itinerary)
        trip.progress.phase = .atStop
        trip.progress.targetStopIndex = stopIndex
        clock.now = try #require(itinerary.stops[stopIndex].arrival).addingTimeInterval(600)
        let drive = DriveViewModel(trip: trip, dependencies: dependencies(harness, clock))
        let editor = drive.visitsEditor()
        #expect(editor.rows.map(\.id) == itinerary.stops.dropFirst(stopIndex + 1).map(\.id))
        let visit = try #require(editor.rows.first { $0.isVisit })

        await editor.remove(visit.id)
        #expect(editor.errorMessage == nil)
        #expect(editor.plan.stops.first?.place.id == itinerary.stops[stopIndex].place.id, "from the stop the car is at")
        #expect(!editor.plan.stops.contains { $0.kind == .visit })
        #expect(editor.rows.first?.id == editor.plan.stops[1].id)

        let next = try #require(await drive.use(plan: editor.plan))
        #expect(try await harness.repository.loadActiveTrip()?.id == next.id, "saved as the trip being driven")
    }

    @Test("A new visit goes where it adds the least driving")
    func insertion() {
        let origin = GeoCoordinate(latitude: 0, longitude: 0)
        let stop = GeoCoordinate(latitude: 0, longitude: 10)
        let destination = GeoCoordinate(latitude: 0, longitude: 20)
        func index(_ longitude: Double) -> Int {
            AdjustVisitsViewModel.insertionIndex(
                of: GeoCoordinate(latitude: 0.1, longitude: longitude), origin: origin, stops: [stop], destination: destination
            )
        }
        #expect(index(4) == 0)
        #expect(index(16) == 1)
    }
}
