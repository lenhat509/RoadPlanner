import Foundation
import TripFeatures
import TripModels
import TripPersistence
import TripPlanner
import TripServices

/// A complete offline app environment: production adapters over the simulated Google
/// backend, in-memory storage, simulated GPS and silent speech. Used by unit tests,
/// SwiftUI previews and the app's UI-test sandbox mode (`-UITestSandbox`).
@MainActor
public enum SandboxEnvironment {
    public static func makeDependencies(
        backend: SimulatedGoogleBackend = SimulatedGoogleBackend(),
        repository: any TripRepository = InMemoryTripRepository(),
        preferences: any PreferencesStore = InMemoryPreferencesStore(),
        location: SimulatedLocationProvider = SimulatedLocationProvider(start: FakeAutocompleteProvider.cities[0].coordinate),
        speech: any SpeechAnnouncing = RecordingSpeechAnnouncer(),
        formatters: TripFormatters = TripFormatters(locale: Locale(identifier: "en_US")),
        autocompleteDebounce: TimeInterval = 0,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> AppDependencies {
        let services = SimulatedGoogleBackend.services(backend: backend)
        return AppDependencies(
            planner: services.planner,
            routing: services.routing,
            autocomplete: services.autocomplete,
            repository: repository,
            preferences: preferences,
            location: location,
            speech: speech,
            formatters: formatters,
            autocompleteDebounce: autocompleteDebounce,
            now: now
        )
    }

    /// A ready-made plan for previews (computed offline, deterministic).
    public static func samplePlan(from origin: String = "la", to destination: String = "lv") async throws -> PlanResult {
        try await SimulatedGoogleBackend.services().planner.plan(SampleTrips.request(from: origin, to: destination)) { _ in }
    }
}
