import Foundation
import Testing
import TripModels
@testable import TripPersistence
import TripSandbox

@Suite("FileTripRepository")
struct FileTripRepositoryTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cadence-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func sampleItinerary(createdAt: Date = Date()) -> Itinerary {
        let request = SampleTrips.request(from: "la", to: "lv")
        return Itinerary(
            goal: .fastest, request: request,
            stops: [
                ItineraryStop(
                    id: "o", kind: .origin, place: request.origin, arrival: nil, departure: request.departure,
                    distanceFromStartMeters: 0, dayIndex: 0
                ),
                ItineraryStop(
                    id: "d", kind: .destination, place: request.destination,
                    arrival: request.departure.addingTimeInterval(14_400), departure: nil,
                    distanceFromStartMeters: 400_000, dayIndex: 0
                ),
            ],
            legs: [],
            totals: TripTotals(distanceMeters: 400_000, drivingDuration: 14_400, elapsedDuration: 14_400, cost: CostBreakdown(fuel: 40, lodging: 0, tolls: 0)),
            createdAt: createdAt
        )
    }

    @Test("Saves and restores the active trip, including progress")
    func activeTripRoundTrip() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileTripRepository(directory: directory)
        #expect(try await repository.loadActiveTrip() == nil)

        var trip = ActiveTrip(itinerary: sampleItinerary())
        trip.progress = TripProgress(
            phase: .atStop,
            targetStopIndex: 1,
            actualArrivals: ["d": Date(timeIntervalSince1970: 1_800_000_123.5)],
            skippedStopIDs: ["x"]
        )
        try await repository.saveActiveTrip(trip)

        // A fresh instance (e.g. after the app relaunches) sees the same trip.
        let restored = try await FileTripRepository(directory: directory).loadActiveTrip()
        #expect(restored == trip)

        try await repository.clearActiveTrip()
        #expect(try await repository.loadActiveTrip() == nil)
        try await repository.clearActiveTrip() // idempotent
    }

    @Test("Lists saved itineraries newest first and deletes them")
    func savedItineraries() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileTripRepository(directory: directory)
        let older = sampleItinerary(createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = sampleItinerary(createdAt: Date(timeIntervalSince1970: 2_000))
        try await repository.saveItinerary(older)
        try await repository.saveItinerary(newer)
        #expect(try await repository.savedItineraries().map(\.id) == [newer.id, older.id])
        try await repository.deleteItinerary(id: older.id)
        #expect(try await repository.savedItineraries().map(\.id) == [newer.id])
    }

    @Test("Ignores corrupt itinerary files instead of failing the list")
    func corruptFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileTripRepository(directory: directory)
        try await repository.saveItinerary(sampleItinerary())
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("itineraries/broken.json"))
        #expect(try await repository.savedItineraries().count == 1)
    }

    @Test("Rejects files written by a newer app version")
    func futureSchema() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileTripRepository(directory: directory)
        try await repository.saveActiveTrip(ActiveTrip(itinerary: sampleItinerary()))
        let url = directory.appendingPathComponent("active-trip.json")
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":99")
        try Data(text.utf8).write(to: url)
        await #expect(throws: RepositoryError.unsupportedSchemaVersion(99)) { _ = try await repository.loadActiveTrip() }
    }
}

@Suite("Preferences")
struct PreferencesTests {
    @Test("UserDefaults store round-trips and falls back to defaults")
    func userDefaults() throws {
        let suite = "cadence-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPreferencesStore(defaults: defaults)
        #expect(store.load() == .default)
        var preferences = UserPreferences.default
        preferences.vehicle.milesPerGallon = 41
        preferences.policy.maxContinuousDriving = 2 * 3_600
        preferences.voiceGuidanceEnabled = false
        store.save(preferences)
        #expect(UserDefaultsPreferencesStore(defaults: defaults).load() == preferences)
    }

    @Test("In-memory store")
    func inMemory() {
        let store = InMemoryPreferencesStore()
        var preferences = store.load()
        preferences.goal = .cheapest
        store.save(preferences)
        #expect(store.load().goal == .cheapest)
    }
}
