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
    let location = SimulatedLocationProvider(start: SampleTrips.city("la").coordinate)
    let speech = RecordingSpeechAnnouncer()
    let dependencies: AppDependencies

    init(backend: SimulatedGoogleBackend = SimulatedGoogleBackend()) {
        dependencies = SandboxEnvironment.makeDependencies(
            backend: backend,
            repository: repository,
            preferences: preferences,
            location: location,
            speech: speech,
            formatters: TripFormatters(locale: Locale(identifier: "en_US_POSIX")),
            now: { testNow }
        )
    }
}

enum Plans {
    /// LA → Las Vegas (one day, a couple of stops), planned offline.
    static func laToVegas(goal: OptimizationGoal = .fastest) async throws -> PlanResult {
        try await SimulatedGoogleBackend.services().planner.plan(SampleTrips.request(from: "la", to: "lv", goal: goal)) { _ in }
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
