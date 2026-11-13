import Foundation
import Observation
import TripModels

/// Start screen: resume the active trip or open a saved plan.
@MainActor
@Observable
public final class HomeViewModel {
    public private(set) var activeTrip: ActiveTrip?
    public private(set) var savedItineraries: [Itinerary] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let dependencies: AppDependencies

    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
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
        let days = (trip.itinerary.stops.last?.dayIndex ?? 0) + 1
        let verb = trip.progress.phase == .atStop ? "At" : "Next"
        let day = "Day \(target.dayIndex + 1) of \(days)"
        let eta = target.arrival.map { " · \(formatters.clockTime($0, utcOffsetSeconds: target.place.utcOffsetSeconds))" } ?? ""
        return "\(route)\n\(day) · \(verb): \(target.place.name)\(eta)"
    }
}
