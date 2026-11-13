import Foundation
import Observation
import TripFeatures
import TripModels
import TripPersistence
import TripPlanner
import TripSandbox
import TripServices

/// Composition root: builds the dependency graph for the current mode and holds app-wide
/// navigation state (the trip being driven).
@MainActor
@Observable
final class AppEnvironment {
    enum Mode: Equatable {
        /// Real Google Maps Platform + gateway services.
        case production
        /// No API key configured: offline demo data so the app still runs.
        case demo
        /// UI tests: offline, deterministic, simulated driving.
        case uiTest
    }

    let mode: Mode
    let dependencies: AppDependencies
    let configuration: AppConfiguration
    /// The trip shown full-screen in drive mode.
    var drivingTrip: ActiveTrip?

    init(mode: Mode, dependencies: AppDependencies, configuration: AppConfiguration) {
        self.mode = mode
        self.dependencies = dependencies
        self.configuration = configuration
    }

    static func make(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        configuration: AppConfiguration = .load()
    ) -> AppEnvironment {
        if arguments.contains(LaunchArgument.uiTestSandbox) {
            return makeUITest(
                reset: arguments.contains(LaunchArgument.resetState),
                skipSafetyNotice: arguments.contains(LaunchArgument.skipSafetyNotice),
                screenshotPace: arguments.contains(LaunchArgument.screenshotPace),
                configuration: configuration
            )
        }
        guard configuration.isGoogleConfigured else { return makeDemo(configuration: configuration) }
        return makeProduction(configuration: configuration)
    }

    func beginDrive(_ trip: ActiveTrip) {
        drivingTrip = trip
    }

    func endDrive() {
        drivingTrip = nil
    }

    // MARK: Factories

    private static func makeProduction(configuration: AppConfiguration) -> AppEnvironment {
        let gateway: CadenceGatewayClient.Configuration? = {
            guard let url = configuration.gatewayBaseURL, let token = configuration.gatewayAppToken else { return nil }
            return CadenceGatewayClient.Configuration(baseURL: url, appToken: token)
        }()
        let services = ServiceFactory.make(settings: ServiceFactory.Settings(
            google: GoogleMapsConfiguration(
                apiKey: configuration.googleMapsAPIKey ?? "",
                iosBundleIdentifier: configuration.bundleIdentifier,
                languageCode: Locale.preferredLanguages.first ?? "en-US",
                regionCode: Locale.current.region?.identifier ?? "US"
            ),
            gateway: gateway
        ))
        let dependencies = AppDependencies(
            planner: services.planner,
            routing: services.routing,
            autocomplete: services.autocomplete,
            repository: FileTripRepository(directory: FileTripRepository.defaultDirectory()),
            preferences: UserDefaultsPreferencesStore(),
            location: CoreLocationProvider(),
            speech: SpeechAnnouncer()
        )
        return AppEnvironment(mode: .production, dependencies: dependencies, configuration: configuration)
    }

    private static func makeDemo(configuration: AppConfiguration) -> AppEnvironment {
        // A fast-forward car (~800 m/s) in small steps, which waits for the camera to settle on it
        // after Start before it drives off.
        let location = SimulatedLocationProvider(
            start: FakeAutocompleteProvider.cities[1].coordinate, autoDrive: true, metersPerTick: 200, tickInterval: 0.25
        )
        location.departureDelay = 2.5
        let dependencies = SandboxEnvironment.makeDependencies(
            backend: SimulatedGoogleBackend(latency: 0.05),
            repository: FileTripRepository(directory: FileTripRepository.defaultDirectory().appendingPathComponent("Demo")),
            preferences: UserDefaultsPreferencesStore(key: "cadence.demo.preferences.v1"),
            location: location,
            speech: SpeechAnnouncer(),
            formatters: TripFormatters(),
            autocompleteDebounce: 0.2
        )
        return AppEnvironment(mode: .demo, dependencies: dependencies, configuration: configuration)
    }

    private static func makeUITest(
        reset: Bool,
        skipSafetyNotice: Bool,
        screenshotPace: Bool,
        configuration: AppConfiguration
    ) -> AppEnvironment {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CadenceUITests", isDirectory: true)
        let defaults = UserDefaults(suiteName: "cadence.uitests") ?? .standard
        if reset {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: "cadence.uitests")
        }
        let preferences = UserDefaultsPreferencesStore(defaults: defaults)
        if skipSafetyNotice {
            var stored = preferences.load()
            stored.hasAcceptedSafetyNotice = true
            preferences.save(stored)
        }
        let location = SimulatedLocationProvider(
            start: FakeAutocompleteProvider.cities[1].coordinate, autoDrive: true, metersPerTick: 4_000, tickInterval: 0.05
        )
        if screenshotPace {
            // Drive a little way into each leg, then park: UI tests read the screen only once the
            // app is idle, which a moving map never is.
            location.metersPerTick = 2_000
            location.tickInterval = 0.25
            location.parksAfterMeters = 40_000
            location.departureDelay = 2.5
        }
        let dependencies = SandboxEnvironment.makeDependencies(
            backend: SimulatedGoogleBackend(latency: 0.01),
            repository: FileTripRepository(directory: directory),
            preferences: preferences,
            location: location,
            speech: RecordingSpeechAnnouncer(),
            formatters: TripFormatters(locale: Locale(identifier: "en_US")),
            autocompleteDebounce: 0.05
        )
        return AppEnvironment(mode: .uiTest, dependencies: dependencies, configuration: configuration)
    }
}
