import Foundation
import Testing
@testable import TripFeatures
import TripModels
import TripPersistence
import TripPlanner
import TripSandbox

/// Place details "from Google", by ID, counting requests (and able to go offline).
final class FakePlaceDetails: PlaceAutocompleteProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var places: [String: Place]
    private var _requests = 0
    var isOffline = false

    init(_ places: [Place]) {
        self.places = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var requests: Int { lock.withLock { _requests } }

    func suggestions(for query: String, near bias: GeoCoordinate?, sessionToken: String) async throws -> [PlaceSuggestion] { [] }

    func place(for placeID: String, sessionToken: String) async throws -> Place { try await details(for: placeID) }

    func details(for placeID: String) async throws -> Place {
        try lock.withLock {
            _requests += 1
            guard !isOffline, let place = places[placeID] else { throw URLError(.notConnectedToInternet) }
            return place
        }
    }
}

@MainActor
@Suite("Google content retention")
struct GoogleContentRetentionTests {
    /// LA → Las Vegas with Google-style place IDs, and the details Google would return for them.
    private func googlePlan(createdAt: Date = testNow) async throws -> (Itinerary, [Place]) {
        var itinerary = try #require(try await Plans.laToVegas().recommended)
        itinerary.createdAt = createdAt
        func googleID(_ index: Int) -> String { "ChIJ\(String(repeating: "x", count: 20))\(index)" }
        itinerary.request.origin.id = googleID(0)
        itinerary.request.destination.id = googleID(999)
        for index in itinerary.stops.indices where !itinerary.stops[index].isRoadsidePullOff {
            let id = index == 0 ? googleID(0) : index == itinerary.stops.count - 1 ? googleID(999) : googleID(index)
            itinerary.stops[index].place.id = id
        }
        var details = [itinerary.request.origin, itinerary.request.destination]
        details += itinerary.stops.map(\.place).filter { $0.googlePlaceID != nil }
        return (itinerary, details)
    }

    @Test("Saved plans keep place IDs, coordinates and the plan; not Google's names, addresses, instructions or prices")
    func storageForm() async throws {
        var (itinerary, _) = try await googlePlan()
        if let index = itinerary.stops.firstIndex(where: { $0.fuelPurchase != nil }) {
            itinerary.stops[index].fuelPurchase?.isPriceEstimated = false
            itinerary.stops[index].fuelPurchase?.pricePerGallon = 4.99
        }
        let stored = GoogleContentRetention.storageForm(of: itinerary)
        for (stop, original) in zip(stored.stops, itinerary.stops) {
            #expect(stop.place.id == original.place.id, "place IDs are kept")
            #expect(stop.place.coordinate == original.place.coordinate, "coordinates are kept (30 days)")
            #expect(stop.arrival == original.arrival, "the schedule is the driver's plan")
            if original.place.googlePlaceID != nil {
                #expect(stop.place.name.isEmpty)
                #expect(stop.place.address == nil)
                #expect(stop.place.utcOffsetMinutes == nil)
            } else {
                #expect(stop.place.name == original.place.name, "made-up pull-offs keep their own names")
            }
            if let fuel = stop.fuelPurchase {
                #expect(fuel.isPriceEstimated, "a station's own price isn't kept")
                #expect(fuel.pricePerGallon != 4.99)
            }
        }
        #expect(stored.request.origin.name.isEmpty)
        #expect(stored.legs.allSatisfy { $0.steps.isEmpty }, "no turn instructions")
        #expect(stored.legs.map(\.encodedPolyline) == itinerary.legs.map(\.encodedPolyline), "route lines are kept (30 days)")
        #expect(stored.routeSummary.isEmpty)
        #expect(!GoogleContentRetention.isOutline(stored))
    }

    @Test("Opening a saved trip fetches its places' names by place ID, once per session")
    func detailsFetchedAgain() async throws {
        let (itinerary, details) = try await googlePlan()
        let places = FakePlaceDetails(details)
        let base = InMemoryTripRepository()
        try await base.saveActiveTrip(ActiveTrip(itinerary: GoogleContentRetention.storageForm(of: itinerary)))
        let repository = RetainingTripRepository(base: base, places: places, now: { testNow })

        let trip = try #require(try await repository.loadActiveTrip())
        #expect(trip.itinerary.stops.map(\.place.name) == itinerary.stops.map(\.place.name))
        #expect(trip.itinerary.request.destination.address == itinerary.request.destination.address)
        let fetched = places.requests
        #expect(fetched == Set(details.map(\.id)).count, "one request per place")
        _ = try await repository.loadActiveTrip()
        #expect(places.requests == fetched, "kept in memory for the session")
    }

    @Test("What's written to disk has no Google names, even when saved with them")
    func savesStorageForm() async throws {
        let (itinerary, details) = try await googlePlan()
        let base = InMemoryTripRepository()
        let places = FakePlaceDetails(details)
        let repository = RetainingTripRepository(base: base, places: places, now: { testNow })
        try await repository.saveItinerary(itinerary)
        try await repository.saveActiveTrip(ActiveTrip(itinerary: itinerary))
        let disk = try #require(try await base.savedItineraries().first)
        #expect(disk.request.origin.name.isEmpty)
        #expect(try await base.loadActiveTrip()?.itinerary.stops.first?.place.name.isEmpty == true)
        // Seen while planning: no request needed to show it again this session.
        let opened = await repository.withDetails(disk)
        #expect(opened.stops.map(\.place.name) == itinerary.stops.map(\.place.name))
        #expect(places.requests == 0)
    }

    @Test("Offline, places show what they are until their names can be fetched")
    func offline() async throws {
        let (itinerary, details) = try await googlePlan()
        let places = FakePlaceDetails(details)
        places.isOffline = true
        let base = InMemoryTripRepository()
        try await base.saveItinerary(GoogleContentRetention.storageForm(of: itinerary))
        let repository = RetainingTripRepository(base: base, places: places, now: { testNow })
        let saved = try #require(try await repository.savedItineraries().first)
        #expect(saved.request.origin.name == "Start")
        #expect(saved.request.destination.name == "Destination")
        let opened = await repository.withDetails(saved)
        #expect(opened.stops.contains { $0.place.name == "Gas station" || $0.place.name == "Rest stop" })
    }

    @Test("Stops on the way are stored like the start and end: place IDs, coordinates for 30 days, no names or prices")
    func stopsOnTheWay() async throws {
        var (itinerary, details) = try await googlePlan()
        let museum = Place(
            id: "ChIJ\(String(repeating: "m", count: 20))", name: "Museum", address: "1 Main St",
            coordinate: GeoCoordinate(latitude: 35.5, longitude: -116.5), utcOffsetMinutes: -480
        )
        itinerary.request.stops = [
            .visit(museum, stay: 3_600),
            RequiredStop(place: museum, purpose: .fuel, fuelPricePerGallon: 4.99),
        ]
        let stored = GoogleContentRetention.storageForm(of: itinerary)
        for stop in stored.request.requiredStops {
            #expect(stop.place.id == museum.id && stop.place.coordinate == museum.coordinate)
            #expect(stop.place.name.isEmpty && stop.place.address == nil)
            #expect(stop.fuelPricePerGallon == nil, "a station's own price isn't kept")
        }
        #expect(stored.request.requiredStops.first?.stay == 3_600, "the stay is the traveler's plan")
        let expired = GoogleContentRetention.expiredForm(of: itinerary)
        #expect(expired.request.requiredStops.allSatisfy { $0.place.coordinate == GeoCoordinate(latitude: 0, longitude: 0) })

        // Opening it fills the names back in; an outline also gets the positions back.
        let repository = RetainingTripRepository(base: InMemoryTripRepository(), places: FakePlaceDetails(details + [museum]), now: { testNow })
        let opened = await repository.withDetails(expired)
        #expect(opened.request.requiredStops.allSatisfy { $0.place.name == "Museum" && $0.place.coordinate == museum.coordinate })
    }

    @Test("After 30 days a plan's coordinates and route lines are deleted, on disk too")
    func expiry() async throws {
        let (itinerary, details) = try await googlePlan(createdAt: testNow.addingTimeInterval(-31 * 86_400))
        let base = InMemoryTripRepository()
        try await base.saveItinerary(GoogleContentRetention.storageForm(of: itinerary))
        try await base.saveActiveTrip(ActiveTrip(itinerary: GoogleContentRetention.storageForm(of: itinerary)))
        let repository = RetainingTripRepository(base: base, places: FakePlaceDetails(details), now: { testNow })

        #expect(try await repository.loadActiveTrip() == nil, "an expired trip can't be driven")
        #expect(try await base.loadActiveTrip() == nil)
        let saved = try await repository.savedItineraries()
        #expect(saved.allSatisfy { GoogleContentRetention.isOutline($0) })
        let disk = try await base.savedItineraries()
        #expect(!disk.isEmpty)
        for plan in disk {
            #expect(GoogleContentRetention.isOutline(plan))
            #expect(plan.stops.allSatisfy { $0.place.coordinate == GeoCoordinate(latitude: 0, longitude: 0) })
            #expect(plan.request.origin.coordinate == GeoCoordinate(latitude: 0, longitude: 0))
            #expect(plan.request.origin.id == itinerary.request.origin.id, "the place ID stays")
        }
    }

    @Test("An outlined plan is planned again from fresh place details, leaving later than now")
    func planAgain() async throws {
        let (itinerary, details) = try await googlePlan(createdAt: testNow.addingTimeInterval(-40 * 86_400))
        let base = InMemoryTripRepository()
        try await base.saveItinerary(GoogleContentRetention.expiredForm(of: itinerary))
        let harness = FeatureHarness()
        let repository = RetainingTripRepository(base: base, places: FakePlaceDetails(details), now: { testNow })
        let dependencies = AppDependencies(
            planner: harness.dependencies.planner, routing: harness.dependencies.routing,
            autocomplete: harness.dependencies.autocomplete, repository: repository,
            preferences: harness.preferences, location: harness.location, guidance: harness.dependencies.guidance,
            formatters: harness.dependencies.formatters, timeZone: harness.dependencies.timeZone, now: { testNow }
        )
        let home = HomeViewModel(dependencies: dependencies)
        await home.load()
        let outline = try #require(home.savedItineraries.first)
        #expect(home.needsPlanningAgain(outline))
        let result = try #require(await home.planAgain(outline))
        let plan = try #require(result.recommended)
        #expect(plan.request.origin.coordinate == itinerary.request.origin.coordinate, "positions fetched by place ID")
        #expect(plan.request.departure >= testNow)
        #expect(!GoogleContentRetention.isOutline(plan))
    }
}
