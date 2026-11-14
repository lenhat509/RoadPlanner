import Foundation
import Testing
@testable import TripFeatures
import TripModels
import TripPersistence
import TripPlanner
import TripSandbox

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

    @Test("Late at night, the default departure is the next morning")
    func defaultDepartureAtNight() {
        // 06:00 UTC = 23:00 PDT the evening before.
        let night = Date(timeIntervalSince1970: 1_809_324_000)
        let dependencies = SandboxEnvironment.makeDependencies(timeZone: TimeZone(identifier: "America/Los_Angeles")!, now: { night })
        let model = PlanTripViewModel(dependencies: dependencies)
        #expect(model.departure == Date(timeIntervalSince1970: 1_809_356_400)) // 08:00 PDT = 15:00 UTC
    }

    @Test("Choosing a start re-evaluates the default departure in that place's time zone")
    func defaultDepartureFollowsOrigin() async {
        // 08:40 UTC: daytime for a phone on UTC, but 00:40 in San Francisco (UTC−8 in the sandbox).
        let early = Date(timeIntervalSince1970: 1_809_333_600)
        let dependencies = SandboxEnvironment.makeDependencies(timeZone: TimeZone(identifier: "UTC")!, now: { early })
        let model = PlanTripViewModel(dependencies: dependencies)
        #expect(model.departure == Date(timeIntervalSince1970: 1_809_333_900)) // next quarter hour (08:45 UTC)
        await model.select(PlaceSuggestion(placeID: "sf", primaryText: "San Francisco", secondaryText: ""), for: .origin)
        #expect(model.departure == Date(timeIntervalSince1970: 1_809_360_000)) // 08:00 in San Francisco
    }

    @Test("A departure the user picked is never changed")
    func editedDepartureIsKept() async {
        let early = Date(timeIntervalSince1970: 1_809_333_600)
        let dependencies = SandboxEnvironment.makeDependencies(timeZone: TimeZone(identifier: "UTC")!, now: { early })
        let model = PlanTripViewModel(dependencies: dependencies)
        let chosen = Date(timeIntervalSince1970: 1_809_400_000)
        model.departure = chosen
        await model.select(PlaceSuggestion(placeID: "sf", primaryText: "San Francisco", secondaryText: ""), for: .origin)
        #expect(model.departure == chosen)
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

    /// Regression: picking a suggestion while a search was still in flight made the list
    /// reappear, so every place needed two taps.
    @Test("Choosing a suggestion closes the list even if a search is still in flight")
    func selectionCancelsPendingSearch() async {
        let model = PlanTripViewModel(dependencies: FeatureHarness(autocompleteDebounce: 0.05).dependencies)
        model.queryChanged("Den", for: .destination)
        await model.select(PlaceSuggestion(placeID: "den", primaryText: "Denver", secondaryText: "CO, USA"), for: .destination)
        await model.waitForSuggestions()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(model.destination.suggestions.isEmpty)
        #expect(model.destination.place?.name == "Denver")
    }

    @Test("Re-sending the selected text (e.g. on focus change) does not search again")
    func noOpTextWrite() async {
        let model = PlanTripViewModel(dependencies: FeatureHarness().dependencies)
        await model.select(PlaceSuggestion(placeID: "den", primaryText: "Denver", secondaryText: "CO, USA"), for: .destination)
        model.queryChanged("Denver", for: .destination)
        await model.waitForSuggestions()
        #expect(model.destination.suggestions.isEmpty)
        #expect(model.destination.place?.name == "Denver")
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

    @Test("With no position known yet (a fresh launch), it asks the device for one")
    func currentLocationFreshFix() async {
        let harness = FeatureHarness(startLocation: nil)
        harness.location.fixOnRequest = SampleTrips.city("la").coordinate
        let model = PlanTripViewModel(dependencies: harness.dependencies)
        await model.useCurrentLocation(for: .origin)
        #expect(model.errorMessage == nil)
        #expect(model.origin.place?.coordinate == SampleTrips.city("la").coordinate)
        #expect(!model.origin.isResolving)
    }

    @Test("Asks for permission first; explains how to turn location on if it is refused")
    func currentLocationPermission() async {
        let harness = FeatureHarness(startLocation: nil)
        harness.location.fixOnRequest = SampleTrips.city("la").coordinate
        harness.location.authorization = .notDetermined
        let model = PlanTripViewModel(dependencies: harness.dependencies)
        await model.useCurrentLocation(for: .origin)
        #expect(model.origin.place != nil, "granted on the prompt")

        let denied = FeatureHarness(startLocation: nil)
        denied.location.authorization = .denied
        let refused = PlanTripViewModel(dependencies: denied.dependencies)
        await refused.useCurrentLocation(for: .origin)
        #expect(refused.origin.place == nil)
        #expect(refused.errorMessage?.contains("Settings") == true)
    }

    @Test("Says so when the device can't find a position")
    func currentLocationNoFix() async {
        let model = PlanTripViewModel(dependencies: FeatureHarness(startLocation: nil).dependencies)
        await model.useCurrentLocation(for: .origin)
        #expect(model.origin.place == nil)
        #expect(model.errorMessage?.hasPrefix("Couldn't find your location") == true)
        #expect(!model.origin.isResolving)
    }

    @Test("Current location uses the phone's time zone when it matches the location")
    func currentLocationTimeZone() async {
        let model = PlanTripViewModel(dependencies: FeatureHarness().dependencies)
        await model.useCurrentLocation(for: .origin)
        // May 2027 in Los Angeles is PDT (UTC−7).
        #expect(model.origin.place?.utcOffsetMinutes == -420)
    }

    @Test("Current location ignores a phone time zone far from the location (e.g. a simulator set to Tokyo)")
    func currentLocationForeignTimeZone() async {
        let model = PlanTripViewModel(dependencies: FeatureHarness(timeZone: TimeZone(identifier: "Asia/Tokyo")!).dependencies)
        await model.useCurrentLocation(for: .origin)
        #expect(model.origin.place?.utcOffsetMinutes == -480) // estimated from Los Angeles' longitude
    }

    @Test("Fuel grade: any gasoline by default; the chosen grade is planned and remembered")
    func fuelGrade() async throws {
        let harness = FeatureHarness()
        let model = PlanTripViewModel(dependencies: harness.dependencies)
        #expect(model.fuelType == .any)
        try await select(model, "Los", .origin)
        try await select(model, "Vegas", .destination)
        model.mpgText = "30"
        model.tankGallonsText = "15"
        model.fuelType = .e85
        guard case let .valid(request) = model.makeRequest() else {
            Issue.record("Expected a valid request")
            return
        }
        #expect(request.vehicle.fuelType == .e85)
        // 30 mpg on gasoline is about 22.5 on E85: 15 gal go ~338 mi.
        #expect(model.rangeSummary?.hasPrefix("A full tank of E85 goes about 338 mi.") == true, "\(model.rangeSummary ?? "")")
        await model.plan()
        #expect(harness.preferences.load().vehicle.fuelType == .e85)
        #expect(PlanTripViewModel(dependencies: harness.dependencies).fuelType == .e85)
    }

    @Test("Tank size and minimum fuel level flow into the request and are remembered")
    func fuelSettings() async throws {
        let harness = FeatureHarness()
        let model = PlanTripViewModel(dependencies: harness.dependencies)
        #expect(model.minimumFuelPercent == 15)
        try await select(model, "Los", .origin)
        try await select(model, "Vegas", .destination)
        model.tankGallonsText = "18.5"
        model.minimumFuelPercent = 25
        guard case let .valid(request) = model.makeRequest() else {
            Issue.record("Expected a valid request")
            return
        }
        #expect(request.vehicle.tankCapacityGallons == 18.5)
        #expect(model.rangeSummary == "A full tank goes about 518 mi. Fuel stops keep at least 25% (4.6 gal) in the tank.")
        #expect(request.policy.fuelReserveFraction == 0.25)
        await model.plan()
        #expect(harness.preferences.load().policy.fuelReserveFraction == 0.25)
        #expect(harness.preferences.load().vehicle.tankCapacityGallons == 18.5)
        #expect(PlanTripViewModel(dependencies: harness.dependencies).minimumFuelPercent == 25)
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
