import Foundation
import Testing
@testable import TripFeatures
import TripModels
import TripPersistence
import TripPlanner
import TripSandbox

@MainActor
@Suite("PlanResultViewModel")
struct PlanResultViewModelTests {
    @Test("Offers three comparable options with the recommended one selected")
    func options() async throws {
        let harness = FeatureHarness()
        let result = try await Plans.laToVegas(goal: .balanced)
        let model = PlanResultViewModel(result: result, dependencies: harness.dependencies)
        #expect(model.options.map(\.goal) == [.fastest, .cheapest, .balanced])
        #expect(model.selectedGoal == .balanced)
        #expect(model.options.first { $0.goal == .balanced }?.isRecommended == true)
        #expect(model.options.contains { $0.badges.contains("Fastest") })
        #expect(model.options.contains { $0.badges.contains("Lowest cost") })
        #expect(model.options.allSatisfy { $0.costText.hasPrefix("$") })
        #expect(model.routeTitle == "Los Angeles → Las Vegas")
    }

    @Test("Builds a day-by-day timeline for the selected plan")
    func timeline() async throws {
        let model = PlanResultViewModel(result: try await Plans.laToVegas(), dependencies: FeatureHarness().dependencies)
        let days = model.days
        #expect(days.count == 1)
        let day = try #require(days.first)
        #expect(day.title.hasPrefix("Day 1 · "))
        #expect(day.summary.contains("driving"))
        #expect(day.stops.first?.kind == .origin)
        #expect(day.stops.last?.kind == .destination)
        #expect(day.stops.dropFirst().dropLast().allSatisfy { [.rest, .fuel].contains($0.kind) })
        #expect(model.costBreakdownText.hasPrefix("Fuel $"))
        #expect(model.costBreakdownText.contains(" gal)"))
    }

    @Test("Starting a trip saves it as the active trip and in history")
    func startTrip() async throws {
        let harness = FeatureHarness()
        let model = PlanResultViewModel(result: try await Plans.laToVegas(), dependencies: harness.dependencies)
        let trip = try #require(await model.startTrip())
        #expect(trip.progress.phase == .notStarted)
        #expect(try await harness.repository.loadActiveTrip()?.id == trip.id)
        #expect(try await harness.repository.savedItineraries().map(\.id) == [trip.id])
    }

    @Test("Saving keeps the plan for later")
    func save() async throws {
        let harness = FeatureHarness()
        let model = PlanResultViewModel(result: try await Plans.laToVegas(), dependencies: harness.dependencies)
        model.selectedGoal = .cheapest
        await model.save()
        #expect(model.isSaved)
        #expect(try await harness.repository.savedItineraries().first?.goal == .cheapest)
    }

    @Test("Links the route to Google Maps")
    func googleMaps() async throws {
        let model = PlanResultViewModel(result: try await Plans.laToVegas(), dependencies: FeatureHarness().dependencies)
        let url = try #require(model.googleMapsURL)
        #expect(url.absoluteString.hasPrefix("https://www.google.com/maps/dir/?api=1"))
        #expect(url.absoluteString.contains("travelmode=driving"))
    }
}

@MainActor
@Suite("HomeViewModel")
struct HomeViewModelTests {
    @Test("Shows nothing to resume on first launch")
    func empty() async {
        let model = HomeViewModel(dependencies: FeatureHarness().dependencies)
        await model.load()
        #expect(model.activeTrip == nil)
        #expect(model.savedItineraries.isEmpty)
    }

    @Test("Offers to resume a saved trip and can discard it")
    func resume() async throws {
        let harness = FeatureHarness()
        let itinerary = try #require(try await Plans.laToVegas().recommended)
        var trip = ActiveTrip(itinerary: itinerary)
        try trip.start(at: testNow)
        try await harness.repository.saveActiveTrip(trip)
        let model = HomeViewModel(dependencies: harness.dependencies)
        await model.load()
        let active = try #require(model.activeTrip)
        let summary = model.resumeSummary(for: active)
        #expect(summary.hasPrefix("Los Angeles → Las Vegas"))
        #expect(summary.contains("Day 1 of 1 · Next: "))
        await model.discardActiveTrip()
        #expect(model.activeTrip == nil)
        #expect(try await harness.repository.loadActiveTrip() == nil)
    }

    @Test("A plan starting far from the user says so; one starting nearby doesn't")
    func farStartNote() async throws {
        let harness = FeatureHarness() // the user is in Los Angeles
        let far = PlanResultViewModel(result: try await Plans.sfToVegas(), dependencies: harness.dependencies)
        let note = try #require(far.startDistanceNote)
        #expect(note.hasPrefix("Starts in San Francisco · "))
        #expect(note.hasSuffix(" mi from you"))
        #expect(far.currentLocation != nil)
        let near = PlanResultViewModel(result: try await Plans.laToVegas(), dependencies: harness.dependencies)
        #expect(near.startDistanceNote == nil)
        let unknown = PlanResultViewModel(result: try await Plans.sfToVegas(), dependencies: FeatureHarness(startLocation: nil).dependencies)
        #expect(unknown.startDistanceNote == nil)
    }

    @Test("A trip waiting to be driven to its start is described as such on Home")
    func resumeNotStarted() async throws {
        let harness = FeatureHarness()
        let itinerary = try #require(try await Plans.sfToVegas().recommended)
        try await harness.repository.saveActiveTrip(ActiveTrip(itinerary: itinerary))
        let model = HomeViewModel(dependencies: harness.dependencies)
        await model.load()
        let summary = model.resumeSummary(for: try #require(model.activeTrip))
        #expect(summary == "San Francisco → Las Vegas\nNot started · Begins in San Francisco")
    }

    @Test("Starts a saved plan")
    func startSaved() async throws {
        let harness = FeatureHarness()
        let itinerary = try #require(try await Plans.laToVegas().recommended)
        try await harness.repository.saveItinerary(itinerary)
        let model = HomeViewModel(dependencies: harness.dependencies)
        await model.load()
        _ = await model.start(model.savedItineraries[0])
        #expect(try await harness.repository.loadActiveTrip()?.itinerary.id == itinerary.id)
        await model.deleteItinerary(itinerary.id)
        #expect(model.savedItineraries.isEmpty)
    }
}

@MainActor
@Suite("SettingsViewModel")
struct SettingsViewModelTests {
    @Test("Minimum fuel level is clamped to 5–50 % and saved")
    func minimumFuel() {
        let harness = FeatureHarness()
        let model = SettingsViewModel(dependencies: harness.dependencies)
        model.minimumFuelPercent = 80
        #expect(model.minimumFuelPercent == 50)
        model.minimumFuelPercent = 20
        #expect(harness.preferences.load().policy.fuelReserveFraction == 0.2)
    }

    @Test("Edits are clamped and saved immediately")
    func edits() {
        let harness = FeatureHarness()
        let model = SettingsViewModel(dependencies: harness.dependencies)
        model.restIntervalHours = 9
        #expect(harness.preferences.load().policy.maxContinuousDriving == 5 * 3_600)
        model.restIntervalHours = 2
        #expect(model.restSummary == "Break every 2 h or sooner, 15 min each")
        model.restBreakMinutes = 2
        #expect(harness.preferences.load().policy.restStopDuration == 600)
        model.maxDailyDrivingHours = 1
        #expect(model.maxDailyDrivingHours == 2)
        model.dayStartHour = 23
        #expect(model.dayStartHour < model.dayEndHour)
    }

    @Test("Reset keeps the accepted safety notice")
    func reset() {
        let model = SettingsViewModel(dependencies: FeatureHarness().dependencies)
        model.acceptSafetyNotice()
        model.preferences.goal = .fastest
        model.resetToDefaults()
        #expect(model.preferences.goal == UserPreferences.default.goal)
        #expect(model.preferences.hasAcceptedSafetyNotice)
    }
}
