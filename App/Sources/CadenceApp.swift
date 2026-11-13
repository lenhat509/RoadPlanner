import GoogleMaps
import SwiftUI

@main
struct CadenceApp: App {
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
                .tint(Theme.accent)
        }
    }
}
