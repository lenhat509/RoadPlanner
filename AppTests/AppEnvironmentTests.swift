@testable import Cadence
import Foundation
import Testing
import TripFeatures
import TripModels
import TripSandbox

@MainActor
@Suite("AppEnvironment")
struct AppEnvironmentTests {
    private let unconfigured = AppConfiguration(info: [:], bundleIdentifier: "com.example.cadence")
    private let configured = AppConfiguration(info: ["CADGoogleMapsAPIKey": "AIzaTest"], bundleIdentifier: "com.example.cadence")

    @Test("UI-test launch argument selects the offline sandbox")
    func uiTestMode() {
        let environment = AppEnvironment.make(arguments: [LaunchArgument.uiTestSandbox, LaunchArgument.resetState], configuration: configured)
        #expect(environment.mode == .uiTest)
    }

    @Test("Screenshot pace parks the simulated car so drive mode can be captured")
    func screenshotPace() throws {
        let fast = AppEnvironment.make(arguments: [LaunchArgument.uiTestSandbox], configuration: unconfigured)
        let paced = AppEnvironment.make(arguments: [LaunchArgument.uiTestSandbox, LaunchArgument.screenshotPace], configuration: unconfigured)
        let fastCar = try #require(fast.dependencies.location as? SimulatedLocationProvider)
        let pacedCar = try #require(paced.dependencies.location as? SimulatedLocationProvider)
        #expect(paced.mode == .uiTest)
        #expect(fastCar.parksAfterMeters == nil)
        #expect(pacedCar.parksAfterMeters != nil)
        #expect(fastCar.departureDelay == 0, "functional tests don't wait")
        #expect(pacedCar.departureDelay > MapCameraDirector.flyInDuration, "the camera reaches the car before it drives off")
        #expect(pacedCar.metersPerTick / pacedCar.tickInterval < fastCar.metersPerTick / fastCar.tickInterval)
    }

    @Test("Without an API key the app runs in demo mode instead of failing")
    func demoMode() throws {
        let demo = AppEnvironment.make(arguments: [], configuration: unconfigured)
        #expect(demo.mode == .demo)
        let car = try #require(demo.dependencies.location as? SimulatedLocationProvider)
        #expect(car.departureDelay > MapCameraDirector.flyInDuration, "the demo car waits for the camera after Start")
    }

    @Test("With an API key the app uses production services")
    func productionMode() {
        let environment = AppEnvironment.make(arguments: [], configuration: configured)
        #expect(environment.mode == .production)
        #expect(environment.dependencies.location is CoreLocationProvider)
        #expect(environment.dependencies.speech is SpeechAnnouncer)
    }

    @Test("Drive mode presentation state")
    func driveState() async throws {
        let environment = AppEnvironment.make(arguments: [LaunchArgument.uiTestSandbox, LaunchArgument.resetState], configuration: unconfigured)
        #expect(environment.drivingTrip == nil)
        let plan = try await environment.dependencies.planner.plan(
            TripSandboxSamples.request()
        ) { _ in }
        let trip = ActiveTrip(itinerary: try #require(plan.recommended))
        environment.beginDrive(trip)
        #expect(environment.drivingTrip?.id == trip.id)
        environment.endDrive()
        #expect(environment.drivingTrip == nil)
    }
}
