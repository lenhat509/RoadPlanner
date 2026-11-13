import Foundation
import Testing
import TripModels
import TripPersistence
import TripPlanner
import TripSandbox
@testable import TripFeatures

@MainActor
@Suite("PlanTripViewModel")
struct PlanTripViewModelTests {
    private func select(_ model: PlanTripViewModel, _ query: String, _ field: PlanTripViewModel.Field) async throws {
        model.queryChanged(query, for: field)
        await model.waitForSuggestions()
        let suggestion = try #require(model.input(for: field).suggestions.first)
        await model.select(suggestion, for: field)
    }

    @Test("Starts from saved preferences with a departure on the next quarter hour")
    func initialState() {
        let harness = FeatureHarness()
        var preferences = UserPreferences.default
        preferences.vehicle.milesPerGallon = 33.5
        preferences.goal = .cheapest
        harness.preferences.save(preferences)
        let model = PlanTripViewModel(dependencies: harness.dependencies)
        #expect(model.mpgText == "33.5")
        #expect(model.goal == .cheapest)
        #expect(model.departure >= testNow)
        #expect(model.departure.timeIntervalSince1970.truncatingRemainder(dividingBy: 900) == 0)
        #expect(!model.customRestEnabled)
        #expect(!model.canPlan)
    }

    @Test("Requires both places before planning")
    func requiresPlaces() {
        let model = PlanTripViewModel(dependencies: FeatureHarness().dependencies)
        #expect(model.validationErrors.contains(.invalidOrigin))
        #expect(model.validationErrors.contains(.invalidDestination))
    }

    @Test("Autocomplete suggests places and selecting one resolves it")
    func autocomplete() async throws {
        let model = PlanTripViewModel(dependencies: FeatureHarness().dependencies)
        model.queryChanged("Den", for: .destination)
        await model.waitForSuggestions()
        #expect(model.destination.suggestions.map(\.primaryText) == ["Denver"])
        await model.select(model.destination.suggestions[0], for: .destination)
        #expect(model.destination.place?.name == "Denver")
        #expect(model.destination.suggestions.isEmpty)
        #expect(model.destination.text == "Denver")

        // Editing the text again un-resolves the place.
        model.queryChanged("Denv", for: .destination)
        #expect(model.destination.place == nil)
        model.queryChanged("D", for: .destination)
        await model.waitForSuggestions()
        #expect(model.destination.suggestions.isEmpty)
    }

    @Test("Validates MPG, deadline and rest interval")
    func validation() async throws {
        let model = PlanTripViewModel(dependencies: FeatureHarness().dependencies)
        try await select(model, "Los", .origin)
        try await select(model, "Vegas", .destination)
        #expect(model.canPlan)

        model.mpgText = "abc"
        #expect(model.validationErrors == [.invalidFuelEconomy])
        model.mpgText = "31,5"
        #expect(model.validationErrors.isEmpty)

        model.arriveByEnabled = true
        model.arriveBy = model.departure.addingTimeInterval(-60)
        #expect(model.validationErrors == [.deadlineBeforeDeparture])
        model.arriveByEnabled = false

        model.customRestEnabled = true
        model.restIntervalHours = 2
        guard case let .valid(request) = model.makeRequest() else {
            Issue.record("Expected a valid request")
            return
        }
        #expect(request.policy.maxContinuousDriving == 7_200)
        #expect(request.vehicle.milesPerGallon == 31.5)
        model.customRestEnabled = false
        guard case let .valid(defaultRequest) = model.makeRequest() else { return }
        #expect(defaultRequest.policy.maxContinuousDriving == DrivingPolicy.standard.maxContinuousDriving)
    }

    @Test("Plans a trip, reports progress and remembers the car")
    func planning() async throws {
        let harness = FeatureHarness()
        let model = PlanTripViewModel(dependencies: harness.dependencies)
        try await select(model, "Los", .origin)
        try await select(model, "Vegas", .destination)
        model.mpgText = "41"
        await model.plan()
        #expect(model.errorMessage == nil)
        #expect(!model.isPlanning)
        let result = try #require(model.result)
        #expect(result.options.count == 3)
        #expect(harness.preferences.load().vehicle.milesPerGallon == 41)
    }

    @Test("Shows a friendly error when routing fails")
    func planningFailure() async throws {
        let backend = SimulatedGoogleBackend(routing: FakeRoutingProvider(failure: FakePlaceSearchProvider.SearchFailed()))
        let model = PlanTripViewModel(dependencies: FeatureHarness(backend: backend).dependencies)
        try await select(model, "Los", .origin)
        try await select(model, "Vegas", .destination)
        await model.plan()
        #expect(model.result == nil)
        #expect(model.errorMessage?.hasPrefix("Couldn't get directions") == true)
        model.dismissError()
        #expect(model.errorMessage == nil)
    }

    @Test("Swaps origin and destination")
    func swap() async throws {
        let model = PlanTripViewModel(dependencies: FeatureHarness().dependencies)
        try await select(model, "Los", .origin)
        try await select(model, "Vegas", .destination)
        model.swapLocations()
        #expect(model.origin.place?.name == "Las Vegas")
        #expect(model.destination.place?.name == "Los Angeles")
    }

    @Test("Uses the current location as the start")
    func currentLocation() async {
        let model = PlanTripViewModel(dependencies: FeatureHarness().dependencies)
        await model.useCurrentLocation(for: .origin)
        #expect(model.origin.place?.name == "Current Location")
        #expect(model.origin.place?.coordinate == SampleTrips.city("la").coordinate)
    }

    @Test("Explains when location permission is denied")
    func locationDenied() async {
        let harness = FeatureHarness()
        let location = SimulatedLocationProvider(start: nil, authorization: .denied)
        let dependencies = SandboxEnvironment.makeDependencies(location: location)
        let model = PlanTripViewModel(dependencies: dependencies)
        await model.useCurrentLocation(for: .origin)
        #expect(model.origin.place == nil)
        #expect(model.errorMessage?.contains("Allow location access") == true)
        _ = harness
    }

    @Test("Planning phases map to readable progress")
    func phaseText() {
        #expect(PlanningPhase.findingRoute.displayText == "Finding the best route…")
        #expect(PlanningPhase.findingStops(completed: 5, total: 10).fraction > PlanningPhase.findingRoute.fraction)
        #expect(PlanningPhase.finalizing.fraction > PlanningPhase.optimizing.fraction)
    }
}
