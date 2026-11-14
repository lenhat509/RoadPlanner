import GoogleMaps
import SwiftUI

@main
struct WaystageApp: App {
    @State private var environment: AppEnvironment

    init() {
        let configuration = AppConfiguration.load()
        // The Maps SDK must be initialised before any map view is created.
        _ = GMSServices.provideAPIKey(configuration.googleMapsAPIKey ?? "MISSING_API_KEY")
        _environment = State(initialValue: AppEnvironment.make(configuration: configuration))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                // Google Maps needs an API key; demo mode and UI tests use Apple Maps instead.
                .environment(\.mapProvider, environment.mode == .production ? .google : .apple)
                .fontDesign(.rounded)
                .tint(Theme.accent)
                // Screenshot runs can force dark mode to review the dark theme.
                .preferredColorScheme(ProcessInfo.processInfo.arguments.contains(LaunchArgument.darkMode) ? .dark : nil)
        }
    }
}
