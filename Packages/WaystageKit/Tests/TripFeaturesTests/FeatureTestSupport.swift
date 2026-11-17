import Foundation
import TripFeatures
import TripModels
import TripNavigation
import TripPersistence
import TripPlanner
import TripSandbox

/// Fixed "now": the sample departure day.
let testNow = SampleTrips.departure.addingTimeInterval(-3_600)

@MainActor
struct FeatureHarness {
    let repository = InMemoryTripRepository()
    let preferences = InMemoryPreferencesStore()
    let location: SimulatedLocationProvider
    let speech = RecordingSpeechAnnouncer()
    let dependencies: AppDependencies
    /// The offline navigation engine (unless the harness was given another).
    var guidance: SimulatedGuidance { dependencies.guidance as! SimulatedGuidance }

    init(
        backend: SimulatedGoogleBackend = SimulatedGoogleBackend(),
        timeZone: TimeZone = TimeZone(identifier: "America/Los_Angeles")!,
        autocompleteDebounce: TimeInterval = 0,
        startLocation: GeoCoordinate? = SampleTrips.city("la").coordinate,
        guidance: (any TurnByTurnGuidance)? = nil
    ) {
        let location = SimulatedLocationProvider(start: startLocation)
        self.location = location
        let sandbox = SandboxEnvironment.makeDependencies(
            backend: backend,
            repository: repository,
            preferences: preferences,
            location: location,
            speech: speech,
            formatters: TripFormatters(locale: Locale(identifier: "en_US_POSIX")),
            autocompleteDebounce: autocompleteDebounce,
            timeZone: timeZone,
            now: { testNow }
        )
        dependencies = guidance.map { guidance in
            AppDependencies(
                planner: sandbox.planner, routing: sandbox.routing, autocomplete: sandbox.autocomplete,
                repository: sandbox.repository, preferences: sandbox.preferences, location: sandbox.location,
                guidance: guidance, formatters: sandbox.formatters, autocompleteDebounce: sandbox.autocompleteDebounce,
                timeZone: sandbox.timeZone, now: sandbox.now
            )
        } ?? sandbox
    }
}

enum Plans {
    /// LA → Las Vegas (one day, a couple of stops), planned offline.
    static func laToVegas(goal: OptimizationGoal = .fastest) async throws -> PlanResult {
        try await SimulatedGoogleBackend.services().planner.plan(SampleTrips.request(from: "la", to: "lv", goal: goal)) { _ in }
    }

    /// San Francisco → Denver: long enough for a few different routes.
    static func sfToDenver() async throws -> PlanResult {
        try await SimulatedGoogleBackend.services().planner.plan(SampleTrips.request(from: "sf", to: "den")) { _ in }
    }

    /// San Francisco → Las Vegas: starts ~550 km from the harness car (in LA).
    static func sfToVegas() async throws -> PlanResult {
        try await SimulatedGoogleBackend.services().planner.plan(SampleTrips.request(from: "sf", to: "lv")) { _ in }
    }
}

/// Fixes every `spacing` meters along an encoded leg.
func samples(along leg: RouteLeg, spacing: Double = 250, start: Date = testNow) -> [LocationSample] {
    let geometry = PolylineGeometry(coordinates: (try? PolylineCodec.decode(leg.encodedPolyline)) ?? [])
    var result: [LocationSample] = []
    var distance = 0.0
    var index = 0
    while true {
        result.append(LocationSample(
            coordinate: geometry.coordinate(atDistance: distance), speed: 30,
            timestamp: start.addingTimeInterval(Double(index) * 8)
        ))
        if distance >= geometry.totalLength { break }
        distance = min(geometry.totalLength, distance + spacing)
        index += 1
    }
    return result
}
