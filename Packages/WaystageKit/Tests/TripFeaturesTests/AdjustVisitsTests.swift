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

    /// The harness's planner, counting the plans made.
    final class CountingPlanner: TripPlanning, @unchecked Sendable {
        let inner: any TripPlanning
        private let lock = NSLock()
        private var count = 0
        var plans: Int { lock.withLock { count } }
        init(_ inner: any TripPlanning) { self.inner = inner }
        func plan(_ request: TripRequest, progress: @escaping @Sendable (PlanningPhase) -> Void) async throws -> PlanResult {
            lock.withLock { count += 1 }
            return try await inner.plan(request, progress: progress)
        }
    }

    private func dependencies(_ harness: FeatureHarness, _ clock: Clock, planner: any TripPlanning) -> AppDependencies {
        let base = harness.dependencies
        return AppDependencies(
            planner: planner, routing: base.routing, autocomplete: base.autocomplete, repository: base.repository,
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

    @Test("Before Start: changes are listed, not planned, until Update plan; then the whole trip is planned once")
    func beforeStart() async throws {
        let harness = FeatureHarness(), clock = Clock()
        let planner = CountingPlanner(harness.dependencies.planner)
        let itinerary = try await itinerary(harness)
        clock.now = SampleTrips.departure.addingTimeInterval(-3_600)
        let drive = DriveViewModel(trip: ActiveTrip(itinerary: itinerary), dependencies: dependencies(harness, clock, planner: planner))
        let editor = drive.visitsEditor()
        #expect(editor.rows.map(\.id) == itinerary.stops.dropFirst().map(\.id), "every stop after the start")
        #expect(editor.rows.last?.kind == .destination)
        #expect(editor.rows.allSatisfy { $0.eta?.hasPrefix(($0.kind == .lodging) ? "Check in " : "Arrive ") == true })
        let lasVegas = try #require(editor.visits.first)
        #expect(editor.visits.count == 1)
        #expect(lasVegas.name == "Las Vegas" && lasVegas.address == "Las Vegas, NV, USA" && lasVegas.status == .inPlan)
        #expect(lasVegas.detail.hasPrefix("1 h 30 min there · Arrive "))
        #expect(editor.canEdit && editor.canAddVisit && !editor.hasPendingChanges && !editor.isUpdated)

        // Tapping marks it to be removed, and again keeps it.
        editor.toggle(lasVegas.id)
        #expect(editor.visits.first?.status == .toBeRemoved && editor.hasPendingChanges)
        editor.toggle(lasVegas.id)
        #expect(editor.visits.first?.status == .inPlan && !editor.hasPendingChanges)

        // A place added is listed to be added; taking it off the list removes it at once.
        editor.add(SampleTrips.city("chi"), stay: 1_800)
        let chicago = try #require(editor.visits.last)
        #expect(chicago.status == .toBeAdded && chicago.name == "Chicago" && chicago.detail == "30 min there")
        editor.toggle(chicago.id)
        #expect(editor.visits.map(\.name) == ["Las Vegas"])

        editor.add(SampleTrips.city("la"), stay: 3_600)
        editor.toggle(lasVegas.id)
        #expect(editor.visits.map(\.name) == ["Los Angeles", "Las Vegas"], "Los Angeles goes first: the least driving")
        #expect(editor.visits.map(\.status) == [.toBeAdded, .toBeRemoved])
        #expect(editor.plan.id == itinerary.id && planner.plans == 0, "nothing is planned before Update plan")

        await editor.updatePlan()
        #expect(editor.errorMessage == nil)
        #expect(planner.plans == 1, "one plan for every change")
        #expect(editor.isUpdated && !editor.hasPendingChanges)
        #expect(editor.plan.stops.first?.place.id == "sf", "the whole trip, from its start")
        let visits = editor.plan.stops.filter { $0.kind == .visit }
        #expect(visits.map(\.place.id) == ["la"] && visits.first?.dwellDuration == 3_600.0)
        #expect(editor.visits.map(\.name) == ["Los Angeles"] && editor.visits.first?.status == .inPlan)
    }

    @Test("On the plan screen: visits changed together become the plan shown, both goals, and Undo goes back")
    func planScreen() async throws {
        let harness = FeatureHarness(), clock = Clock()
        let planner = CountingPlanner(harness.dependencies.planner)
        let dependencies = dependencies(harness, clock, planner: planner)
        var request = SampleTrips.request(from: "sf", to: "den")
        request.stops = [.visit(SampleTrips.city("lv"), stay: 5_400)]
        let result = try await harness.dependencies.planner.plan(request) { _ in }
        let model = PlanResultViewModel(result: result, dependencies: dependencies)
        let shown = try #require(model.selected)
        let editor = try #require(model.visitsEditor())
        #expect(editor.visits.map(\.name) == ["Las Vegas"])
        editor.toggle(try #require(editor.visits.first).id)
        editor.add(SampleTrips.city("la"), stay: 3_600)
        #expect(planner.plans == 0)
        await editor.updatePlan()
        #expect(planner.plans == 1)
        #expect(model.selected?.id == shown.id, "the plan screen changes only with Use this plan")

        model.use(editor)
        let next = try #require(model.selected)
        #expect(next.stops.filter { $0.kind == .visit }.map(\.place.id) == ["la"])
        #expect(model.options.map(\.goal) == [.fastest, .cheapest])
        #expect(model.canUndo)
        model.undo()
        #expect(model.selected?.id == shown.id)
    }

    @Test("At a stop: only what's ahead is listed, and the rest of the trip is planned from here")
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
        let drive = DriveViewModel(trip: trip, dependencies: dependencies(harness, clock, planner: harness.dependencies.planner))
        let editor = drive.visitsEditor()
        #expect(editor.rows.map(\.id) == itinerary.stops.dropFirst(stopIndex + 1).map(\.id))
        let visit = try #require(editor.visits.first)

        editor.toggle(visit.id)
        await editor.updatePlan()
        #expect(editor.errorMessage == nil)
        #expect(editor.plan.stops.first?.place.id == itinerary.stops[stopIndex].place.id, "from the stop the car is at")
        #expect(!editor.plan.stops.contains { $0.kind == .visit } && editor.visits.isEmpty)
        #expect(editor.rows.first?.id == editor.plan.stops[1].id)

        let next = try #require(await drive.use(plan: editor.plan))
        #expect(try await harness.repository.loadActiveTrip()?.id == next.id, "saved as the trip being driven")
    }

    @Test("At most 10 visits, counting the places added and not those to be removed")
    func visitLimit() async throws {
        let harness = FeatureHarness(), clock = Clock()
        let itinerary = try await itinerary(harness)
        let drive = DriveViewModel(trip: ActiveTrip(itinerary: itinerary), dependencies: dependencies(harness, clock, planner: harness.dependencies.planner))
        let editor = drive.visitsEditor()
        for _ in 0..<9 { editor.add(SampleTrips.city("la"), stay: 600) }
        #expect(editor.visits.count == 10 && !editor.canAddVisit)
        editor.add(SampleTrips.city("chi"), stay: 600)
        #expect(editor.visits.count == 10)
        editor.toggle(try #require(editor.visits.first).id)
        #expect(editor.canAddVisit, "Las Vegas is to be removed")
    }

    @Test("Visits can be moved: the plan follows the list's order, and moving alone is a change to plan")
    func reorder() async throws {
        let harness = FeatureHarness(), clock = Clock()
        let planner = CountingPlanner(harness.dependencies.planner)
        let itinerary = try await itinerary(harness)
        let drive = DriveViewModel(trip: ActiveTrip(itinerary: itinerary), dependencies: dependencies(harness, clock, planner: planner))
        let editor = drive.visitsEditor()
        editor.add(SampleTrips.city("la"), stay: 3_600)
        #expect(editor.visits.map(\.name) == ["Los Angeles", "Las Vegas"])
        editor.move(fromOffsets: [0], toOffset: 2)
        #expect(editor.visits.map(\.name) == ["Las Vegas", "Los Angeles"])
        #expect(planner.plans == 0)
        await editor.updatePlan()
        #expect(editor.errorMessage == nil)
        #expect(editor.plan.stops.filter { $0.kind == .visit }.map(\.place.id) == ["lv", "la"], "the traveler's order")
        #expect(!editor.hasPendingChanges)

        editor.move(fromOffsets: [1], toOffset: 0)
        #expect(editor.visits.map(\.name) == ["Los Angeles", "Las Vegas"] && editor.hasPendingChanges, "moving alone is a change")
        editor.move(fromOffsets: [0], toOffset: 2)
        #expect(!editor.hasPendingChanges, "back in the plan's order")
    }

    @Test("From the plan screen, a departure that has passed moves to the next hour")
    func pastDeparture() {
        var request = SampleTrips.request(from: "sf", to: "den")
        let later = request.departure.addingTimeInterval(5 * 3_600 + 600)
        PlanResultViewModel.movePastDeparture(of: &request, now: later)
        #expect(request.departure > later && request.departure.timeIntervalSince(later) <= 3_600)
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
