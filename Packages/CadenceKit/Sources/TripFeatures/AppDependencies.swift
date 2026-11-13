import Foundation
import TripModels
import TripPersistence
import TripPlanner

/// Everything view models need, injected once at app start (composition root).
@MainActor
public final class AppDependencies {
    public let planner: any TripPlanning
    public let routing: any RoutingProvider
    public let autocomplete: any PlaceAutocompleteProvider
    public let repository: any TripRepository
    public let preferences: any PreferencesStore
    public let location: any LocationProviding
    public let speech: any SpeechAnnouncing
    public let formatters: TripFormatters
    /// Delay before an autocomplete request is sent while typing.
    public let autocompleteDebounce: TimeInterval
    public let now: @Sendable () -> Date

    public init(
        planner: any TripPlanning,
        routing: any RoutingProvider,
        autocomplete: any PlaceAutocompleteProvider,
        repository: any TripRepository,
        preferences: any PreferencesStore,
        location: any LocationProviding,
        speech: any SpeechAnnouncing,
        formatters: TripFormatters = TripFormatters(),
        autocompleteDebounce: TimeInterval = 0.25,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.planner = planner
        self.routing = routing
        self.autocomplete = autocomplete
        self.repository = repository
        self.preferences = preferences
        self.location = location
        self.speech = speech
        self.formatters = formatters
        self.autocompleteDebounce = autocompleteDebounce
        self.now = now
    }
}
