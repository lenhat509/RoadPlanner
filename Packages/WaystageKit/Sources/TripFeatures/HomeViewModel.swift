import Foundation
import Observation
import TripModels
import TripPlanner

/// Start screen: resume the active trip or open a saved plan.
@MainActor
@Observable
public final class HomeViewModel {
    public private(set) var activeTrip: ActiveTrip?
    public private(set) var savedItineraries: [Itinerary] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// The saved plan being planned again (`planAgain`).
    public private(set) var replanningID: UUID?

    private let dependencies: AppDependencies

    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    /// "Good morning" / "Good afternoon" / "Good evening" in the phone's time zone.
    public var greeting: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = dependencies.timeZone
        let hour = calendar.component(.hour, from: dependencies.now())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            activeTrip = try await dependencies.repository.loadActiveTrip()
            savedItineraries = try await dependencies.repository.savedItineraries()
            errorMessage = nil
        } catch {
            errorMessage = "Your saved trips couldn't be loaded."
        }
    }

    /// Ends the active trip without completing it.
    public func discardActiveTrip() async {
        try? await dependencies.repository.clearActiveTrip()
        activeTrip = nil
    }

    public func deleteItinerary(_ id: UUID) async {
        try? await dependencies.repository.deleteItinerary(id: id)
        savedItineraries.removeAll { $0.id == id }
    }

    /// Whether a saved plan is only an outline: it was saved over 30 days ago, and Google's
    /// coordinates and route lines can't be kept that long, so it's planned again to be used.
    public func needsPlanningAgain(_ itinerary: Itinerary) -> Bool {
        GoogleContentRetention.isOutline(itinerary)
    }

    /// A saved plan with everything it shows (place names are fetched again by place ID).
    public func details(of itinerary: Itinerary) async -> Itinerary {
        await dependencies.repository.withDetails(itinerary)
    }

    /// Plans an outlined trip again with today's information: same places, vehicle and
    /// preferences; a departure that has passed moves to the next hour.
    public func planAgain(_ itinerary: Itinerary) async -> PlanResult? {
        replanningID = itinerary.id
        defer { replanningID = nil }
        var request = await dependencies.repository.withDetails(itinerary).request
        let unknown = GeoCoordinate(latitude: 0, longitude: 0)
        guard request.origin.coordinate != unknown, request.destination.coordinate != unknown else {
            errorMessage = "This trip's places couldn't be found. Check your connection and try again."
            return nil
        }
        let now = dependencies.now()
        if request.departure < now {
            let nextHour = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 3_600).rounded(.up) * 3_600)
            let shift = nextHour.timeIntervalSince(request.departure)
            request.departure = nextHour
            request.arriveBy = request.arriveBy.map { $0.addingTimeInterval(shift) }
        }
        do {
            let result = try await dependencies.planner.plan(request) { _ in }
            errorMessage = nil
            return result
        } catch {
            errorMessage = "This trip couldn't be planned again. Check your connection and try again."
            return nil
        }
    }

    /// Starts driving a saved plan, replacing any active trip.
    public func start(_ itinerary: Itinerary) async -> ActiveTrip {
        let trip = ActiveTrip(itinerary: itinerary)
        try? await dependencies.repository.saveActiveTrip(trip)
        activeTrip = trip
        return trip
    }

    /// "Day 2 of 5 · next: Shell, Rawlins" style summary for the resume card.
    public func resumeSummary(for trip: ActiveTrip) -> String {
        let formatters = dependencies.formatters
        let route = "\(trip.itinerary.request.origin.name) → \(trip.itinerary.request.destination.name)"
        guard let target = trip.targetStop, trip.progress.phase != .completed else { return "\(route) · Completed" }
        if trip.progress.phase == .notStarted {
            return "\(route)\nNot started · Begins in \(trip.itinerary.request.origin.name)"
        }
        let days = (trip.itinerary.stops.last?.dayIndex ?? 0) + 1
        let verb = trip.progress.phase == .atStop ? "At" : "Next"
        let day = "Day \(target.dayIndex + 1) of \(days)"
        let eta = target.arrival.map { " · \(formatters.clockTime($0, utcOffsetSeconds: target.place.utcOffsetSeconds))" } ?? ""
        return "\(route)\n\(day) · \(verb): \(target.place.name)\(eta)"
    }
}
