import Foundation
import TripModels
import TripPersistence
import TripPlanner

/// What Waystage may keep on the phone from Google Maps Platform (docs/COMPLIANCE.md, "What is
/// stored"):
///
/// * Place IDs: indefinitely.
/// * Coordinates and route lines (latitude/longitude from the Places and Routes APIs): up to 30
///   days, then deleted.
/// * Place names, addresses, time-zone offsets, turn instructions, route descriptions, station
///   prices: not at all. They're fetched again by place ID when a trip is opened, and kept in
///   memory only.
/// * The driver's own plan (dates, stop order, times, the vehicle, progress) is theirs.
public enum GoogleContentRetention {
    /// How long Google coordinates may be kept.
    public static let coordinateLifetime: TimeInterval = 30 * 86_400

    /// Whether the plan's Google coordinates are past their 30 days.
    public static func isExpired(_ itinerary: Itinerary, now: Date) -> Bool {
        now.timeIntervalSince(itinerary.createdAt) > coordinateLifetime
    }

    /// The itinerary as written to disk.
    public static func storageForm(of itinerary: Itinerary, pricing: PricingDefaults = .standard) -> Itinerary {
        var stored = itinerary
        stored.request.origin = stripped(stored.request.origin)
        stored.request.destination = stripped(stored.request.destination)
        stored.request.stops = stored.request.stops?.map { stop in
            var stop = stop
            stop.place = stripped(stop.place)
            // May be a station's own (Google) price; planning again finds the current one.
            stop.fuelPricePerGallon = nil
            return stop
        }
        let fuelType = itinerary.request.vehicle.fuelType
        stored.stops = stored.stops.map { stop in
            var stop = stop
            stop.place = stripped(stop.place)
            if var fuel = stop.fuelPurchase, !fuel.isPriceEstimated {
                // A station's own price is Google content: the saved plan uses the estimate.
                fuel.pricePerGallon = pricing.fuelPrice(for: fuel.grade ?? fuelType)
                fuel.isPriceEstimated = true
                stop.fuelPurchase = fuel
            }
            return stop
        }
        stored.legs = stored.legs.map { leg in
            var leg = leg
            leg.steps = []
            return leg
        }
        stored.routeSummary = ""
        return stored
    }

    /// Past 30 days: the coordinates and route lines go too. What's left is the trip's outline
    /// (where it starts and ends as place IDs, dates, vehicle, preferences) to plan it again.
    public static func expiredForm(of itinerary: Itinerary) -> Itinerary {
        var expired = storageForm(of: itinerary)
        let none = GeoCoordinate(latitude: 0, longitude: 0)
        if expired.request.origin.googlePlaceID != nil { expired.request.origin.coordinate = none }
        if expired.request.destination.googlePlaceID != nil { expired.request.destination.coordinate = none }
        expired.request.stops = expired.request.stops?.map { stop in
            var stop = stop
            if stop.place.googlePlaceID != nil { stop.place.coordinate = none }
            return stop
        }
        expired.stops = expired.stops.map { stop in
            var stop = stop
            stop.place.coordinate = none
            return stop
        }
        expired.legs = expired.legs.map { leg in
            var leg = leg
            leg.encodedPolyline = ""
            return leg
        }
        expired.overviewPolyline = ""
        return expired
    }

    /// Whether the plan has been reduced to its outline (`expiredForm`).
    public static func isOutline(_ itinerary: Itinerary) -> Bool {
        itinerary.overviewPolyline.isEmpty && itinerary.legs.allSatisfy(\.encodedPolyline.isEmpty)
    }

    /// A Google place without the details that can't be kept.
    static func stripped(_ place: Place) -> Place {
        guard place.googlePlaceID != nil else { return place }
        var place = place
        place.name = ""
        place.address = nil
        place.utcOffsetMinutes = nil
        return place
    }

    /// Shown for a place whose name couldn't be fetched (offline).
    static func placeholderName(for kind: StopKind?) -> String {
        switch kind {
        case .origin: "Start"
        case .destination: "Destination"
        case .fuel: "Gas station"
        case .rest: "Rest stop"
        case .lodging: "Hotel"
        case .visit: "Stop on the way"
        case nil: "Saved place"
        }
    }
}

/// A repository that applies `GoogleContentRetention`: it writes the storage form, deletes
/// coordinates past 30 days, and fills names and addresses back in by place ID when trips are
/// read (Place Details, kept in memory for the session). The App Store build wraps the file
/// repository with it.
public actor RetainingTripRepository: TripRepository {
    private let base: any TripRepository
    private let places: any PlaceAutocompleteProvider
    private let now: @Sendable () -> Date
    /// Details fetched (or seen while planning) this session: memory only.
    private var known: [String: Place] = [:]
    /// Simultaneous Place Details requests.
    private let concurrency = 6

    public init(base: any TripRepository, places: any PlaceAutocompleteProvider, now: @escaping @Sendable () -> Date = Date.init) {
        self.base = base
        self.places = places
        self.now = now
    }

    // MARK: Writing

    public func saveActiveTrip(_ trip: ActiveTrip) async throws {
        remember(trip.itinerary)
        var stored = trip
        stored.itinerary = GoogleContentRetention.storageForm(of: trip.itinerary)
        try await base.saveActiveTrip(stored)
    }

    public func saveItinerary(_ itinerary: Itinerary) async throws {
        remember(itinerary)
        let stored = GoogleContentRetention.isOutline(itinerary)
            ? GoogleContentRetention.expiredForm(of: itinerary)
            : GoogleContentRetention.storageForm(of: itinerary)
        try await base.saveItinerary(stored)
    }

    public func clearActiveTrip() async throws {
        try await base.clearActiveTrip()
    }

    public func deleteItinerary(id: UUID) async throws {
        try await base.deleteItinerary(id: id)
    }

    // MARK: Reading

    /// The trip in progress, with all its places' details. A trip whose coordinates have
    /// expired can't be driven any more: it moves to the saved plans (as an outline to plan again).
    public func loadActiveTrip() async throws -> ActiveTrip? {
        guard var trip = try await base.loadActiveTrip() else { return nil }
        if GoogleContentRetention.isExpired(trip.itinerary, now: now()) {
            try await base.saveItinerary(GoogleContentRetention.expiredForm(of: trip.itinerary))
            try await base.clearActiveTrip()
            return nil
        }
        trip.itinerary = await filled(trip.itinerary, everyStop: true)
        return trip
    }

    /// Saved plans with their start and end named (opening one fills in the rest, `withDetails`).
    /// Plans past 30 days are reduced to their outline, on disk too.
    public func savedItineraries() async throws -> [Itinerary] {
        var result: [Itinerary] = []
        for itinerary in try await base.savedItineraries() {
            var itinerary = itinerary
            if GoogleContentRetention.isExpired(itinerary, now: now()), !GoogleContentRetention.isOutline(itinerary) {
                itinerary = GoogleContentRetention.expiredForm(of: itinerary)
                try await base.saveItinerary(itinerary)
            }
            result.append(await filled(itinerary, everyStop: false))
        }
        return result
    }

    public func withDetails(_ itinerary: Itinerary) async -> Itinerary {
        await filled(itinerary, everyStop: true)
    }

    // MARK: Details

    private func remember(_ itinerary: Itinerary) {
        for place in Self.places(in: itinerary, everyStop: true) where place.googlePlaceID != nil && !place.name.isEmpty {
            known[place.id] = place
        }
    }

    private static func places(in itinerary: Itinerary, everyStop: Bool) -> [Place] {
        var places = [itinerary.request.origin, itinerary.request.destination]
        if everyStop { places += itinerary.stops.map(\.place) + itinerary.request.requiredStops.map(\.place) }
        return places
    }

    /// Fills in names, addresses and time-zone offsets (and, for an outline, positions).
    private func filled(_ itinerary: Itinerary, everyStop: Bool) async -> Itinerary {
        let missing = Set(Self.places(in: itinerary, everyStop: everyStop)
            .filter { $0.googlePlaceID != nil && $0.name.isEmpty && known[$0.id] == nil }
            .map(\.id))
        await fetch(Array(missing))
        var result = itinerary
        let outline = GoogleContentRetention.isOutline(itinerary)
        result.request.origin = fill(result.request.origin, kind: .origin, refreshPosition: outline)
        result.request.destination = fill(result.request.destination, kind: .destination, refreshPosition: outline)
        if everyStop {
            // Stops on the way are planned again from their place IDs too.
            result.request.stops = result.request.stops?.map { stop in
                var stop = stop
                stop.place = fill(stop.place, kind: Self.kind(of: stop.purpose), refreshPosition: outline)
                return stop
            }
            result.stops = result.stops.map { stop in
                var stop = stop
                stop.place = fill(stop.place, kind: stop.kind, refreshPosition: false)
                return stop
            }
        }
        return result
    }

    private static func kind(of purpose: RequiredStop.Purpose) -> StopKind {
        switch purpose {
        case .visit: .visit
        case .rest: .rest
        case .fuel: .fuel
        case .lodging: .lodging
        }
    }

    private func fill(_ place: Place, kind: StopKind, refreshPosition: Bool) -> Place {
        guard place.googlePlaceID != nil, place.name.isEmpty else { return place }
        var place = place
        if let details = known[place.id] {
            place.name = details.name
            place.address = details.address
            place.utcOffsetMinutes = details.utcOffsetMinutes
            if refreshPosition { place.coordinate = details.coordinate }
        } else {
            place.name = GoogleContentRetention.placeholderName(for: kind)
        }
        return place
    }

    private func fetch(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        let places = self.places
        var fetched: [(String, Place)] = []
        await withTaskGroup(of: (String, Place?).self) { group in
            var pending = ids[...]
            for _ in 0..<concurrency {
                guard let id = pending.popFirst() else { break }
                group.addTask { (id, try? await places.details(for: id)) }
            }
            while let (id, place) = await group.next() {
                if let place { fetched.append((id, place)) }
                if let next = pending.popFirst() {
                    group.addTask { (next, try? await places.details(for: next)) }
                }
            }
        }
        // Keyed by the ID asked for (Google can answer with a newer ID for the same place).
        for (id, place) in fetched { known[id] = place }
    }
}
