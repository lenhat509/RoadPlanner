import Foundation
import GoogleMaps
import Observation
import TripFeatures
import TripModels
import TripPersistence
import TripPlanner
import TripSandbox
import TripServices

/// Composition root: builds the dependency graph for the current mode and holds app-wide
/// navigation state (the drive in progress, shared by the iPhone and CarPlay).
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
    /// Google's Navigation SDK (App Store build); nil offline, where navigation is simulated.
    let navigation: GoogleNavigationEngine?
    /// The drive in progress, shown full screen on the iPhone and on the CarPlay screen.
    private(set) var drive: DriveViewModel?

    init(mode: Mode, dependencies: AppDependencies, configuration: AppConfiguration, navigation: GoogleNavigationEngine? = nil) {
        self.mode = mode
        self.dependencies = dependencies
        self.configuration = configuration
        self.navigation = navigation
    }

    /// The app's environment, shared by the iPhone and CarPlay scenes (the app can be launched on
    /// the CarPlay screen alone).
    static let shared: AppEnvironment = {
        let configuration = AppConfiguration.load()
        // The Maps SDK must be initialised before any map view is created.
        _ = GMSServices.provideAPIKey(configuration.googleMapsAPIKey ?? "MISSING_API_KEY")
        return make(configuration: configuration)
    }()

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
        return makeProduction(configuration: configuration, arguments: arguments)
    }

    /// Opens drive mode for `trip` (on the iPhone, and on CarPlay when connected). In the App
    /// Store build, Google's navigation terms are asked for first if they haven't been accepted
    /// (`asksForTerms`: not from CarPlay, whose driver can't answer on the phone).
    func beginDrive(_ trip: ActiveTrip, asksForTerms: Bool = true) async {
        if let drive {
            if drive.id == trip.id { return }
            await drive.stop()
            self.drive = nil
        }
        if let navigation {
            if asksForTerms { await navigation.requestTerms() }
            // Ready Google's navigation before drive mode's map exists, so the map has it from the
            // start: attaching it to a map already on screen can move the camera.
            try? await navigation.prepare()
        }
        drive = DriveViewModel(trip: trip, dependencies: dependencies)
    }

    /// Leaves drive mode (the trip stays saved unless it was ended).
    func endDrive() async {
        guard let drive else { return }
        self.drive = nil
        await drive.stop()
    }

    /// Whether a drive can be started without the iPhone (from CarPlay): the terms, the driving
    /// safety notice and, in the App Store build, Google's navigation terms have been accepted.
    var isReadyToDriveWithoutPhone: Bool {
        let preferences = dependencies.preferences.load()
        guard preferences.hasAcceptedSafetyNotice, !TermsAgreement.isNeeded(preferences) || mode == .uiTest else { return false }
        return navigation == nil || GoogleNavigationEngine.areTermsAccepted
    }

    // MARK: Factories

    private static func makeProduction(configuration: AppConfiguration, arguments: [String]) -> AppEnvironment {
        let navigation = GoogleNavigationEngine(
            companyName: configuration.navigationCompanyName,
            simulatesLocation: arguments.contains(LaunchArgument.simulateNavigation)
        )
        let gateway: WaystageGatewayClient.Configuration? = {
            guard let url = configuration.gatewayBaseURL, let token = configuration.gatewayAppToken else { return nil }
            return WaystageGatewayClient.Configuration(baseURL: url, appToken: token)
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
            // Keeps only what Google allows on the phone (place IDs; coordinates for 30 days) and
            // fetches names and addresses again by place ID (see GoogleContentRetention).
            repository: RetainingTripRepository(
                base: FileTripRepository(directory: FileTripRepository.defaultDirectory()),
                places: services.autocomplete
            ),
            preferences: UserDefaultsPreferencesStore(),
            location: CoreLocationProvider(),
            // Google's Navigation SDK guides, with its own voice (no speech synthesizer: Google's
            // terms don't allow speaking Google content with one).
            guidance: navigation
        )
        return AppEnvironment(mode: .production, dependencies: dependencies, configuration: configuration, navigation: navigation)
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
            preferences: UserDefaultsPreferencesStore(key: "waystage.demo.preferences.v1"),
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WaystageUITests", isDirectory: true)
        let defaults = UserDefaults(suiteName: "waystage.uitests") ?? .standard
        if reset {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: "waystage.uitests")
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
