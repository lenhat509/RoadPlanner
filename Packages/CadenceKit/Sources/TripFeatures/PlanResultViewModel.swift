import Foundation
import Observation
import TripModels
import TripPlanner

/// One selectable plan (fastest / cheapest / balanced).
public struct PlanOption: Hashable, Sendable, Identifiable {
    public var goal: OptimizationGoal
    public var title: String
    public var durationText: String
    public var costText: String
    public var nightsText: String
    public var arrivalText: String
    public var isRecommended: Bool
    /// "Fastest" / "Lowest cost" when this option wins on that metric.
    public var badges: [String]
    public var id: OptimizationGoal { goal }

    public init(
        goal: OptimizationGoal,
        title: String,
        durationText: String,
        costText: String,
        nightsText: String,
        arrivalText: String,
        isRecommended: Bool,
        badges: [String]
    ) {
        self.goal = goal
        self.title = title
        self.durationText = durationText
        self.costText = costText
        self.nightsText = nightsText
        self.arrivalText = arrivalText
        self.isRecommended = isRecommended
        self.badges = badges
    }
}

/// A day of the itinerary for the timeline.
public struct DaySection: Hashable, Sendable, Identifiable {
    public var index: Int
    public var title: String
    public var summary: String
    public var stops: [StopPresentation]
    public var id: Int { index }

    public init(index: Int, title: String, summary: String, stops: [StopPresentation]) {
        self.index = index
        self.title = title
        self.summary = summary
        self.stops = stops
    }
}

/// Compare plans, inspect the timeline, save or start the trip.
@MainActor
@Observable
public final class PlanResultViewModel {
    public let result: PlanResult
    public var selectedGoal: OptimizationGoal
    public private(set) var isSaved = false

    private let dependencies: AppDependencies

    public init(result: PlanResult, dependencies: AppDependencies) {
        self.result = result
        self.dependencies = dependencies
        selectedGoal = result.itineraries[result.recommendedGoal] != nil
            ? result.recommendedGoal
            : (result.options.first?.goal ?? .balanced)
    }

    public var selected: Itinerary? { result.itineraries[selectedGoal] ?? result.options.first }

    public var options: [PlanOption] {
        let formatters = dependencies.formatters
        let itineraries = result.options
        let fastest = itineraries.map(\.totals.elapsedDuration).min() ?? 0
        let cheapest = itineraries.map(\.totals.cost.total).min() ?? 0
        return itineraries.map { itinerary in
            var badges: [String] = []
            if itinerary.totals.elapsedDuration <= fastest + 60 { badges.append("Fastest") }
            if itinerary.totals.cost.total <= cheapest + 0.5 { badges.append("Lowest cost") }
            let destination = itinerary.stops.last?.place.utcOffsetSeconds ?? 0
            return PlanOption(
                goal: itinerary.goal,
                title: itinerary.goal.displayName,
                durationText: formatters.duration(itinerary.totals.elapsedDuration),
                costText: formatters.currency(itinerary.totals.cost.total),
                nightsText: itinerary.nights == 1 ? "1 night" : "\(itinerary.nights) nights",
                arrivalText: itinerary.arrival.map { "Arrive \(formatters.dateTime($0, utcOffsetSeconds: destination))" } ?? "",
                isRecommended: itinerary.goal == result.recommendedGoal,
                badges: badges
            )
        }
    }

    public var days: [DaySection] {
        guard let itinerary = selected else { return [] }
        let formatters = dependencies.formatters
        return itinerary.days.map { day in
            let first = day.stops.first
            let date = first?.departure ?? first?.arrival ?? itinerary.request.departure
            let offset = first?.place.utcOffsetSeconds ?? 0
            let driving = drivingTime(in: day, itinerary: itinerary)
            let distance = (day.stops.last?.distanceFromStartMeters ?? 0) - (precedingDistance(of: day, in: itinerary))
            return DaySection(
                index: day.index,
                title: "Day \(day.index + 1) · \(formatters.dayTitle(date, utcOffsetSeconds: offset))",
                summary: "\(formatters.duration(driving)) driving · \(formatters.distance(max(0, distance)))",
                stops: day.stops.map {
                    StopPresentation(stop: $0, formatters: formatters, tankCapacityGallons: itinerary.request.vehicle.tankCapacityGallons)
                }
            )
        }
    }

    public var warnings: [PlanWarning] { selected?.warnings ?? [] }

    /// Where the user is, when known: drawn on the map, distinct from the plan's start.
    public var currentLocation: GeoCoordinate? { dependencies.location.lastKnownLocation }

    /// "Starts in San Francisco · 348 mi from you" when the plan starts far from the user (who may
    /// just be looking at it, or will drive to the start first).
    public var startDistanceNote: String? {
        guard let origin = selected?.request.origin, let here = currentLocation else { return nil }
        let distance = GeoMath.distance(here, origin.coordinate)
        guard distance > DriveViewModel.farFromStartDistance else { return nil }
        return "Starts in \(origin.name) · \(dependencies.formatters.distance(distance)) from you"
    }

    public var costBreakdownText: String {
        guard let totals = selected?.totals else { return "" }
        let cost = totals.cost
        let formatters = dependencies.formatters
        let gallons = totals.fuelGallonsUsed.map { " (\(formatters.gallons($0)))" } ?? ""
        var parts = ["Fuel \(formatters.currency(cost.fuel))\(gallons)", "Lodging \(formatters.currency(cost.lodging))"]
        if cost.tolls > 0 { parts.append("Tolls \(formatters.currency(cost.tolls))") }
        return parts.joined(separator: " · ")
    }

    public var routeTitle: String {
        guard let request = selected?.request else { return "" }
        return "\(request.origin.name) → \(request.destination.name)"
    }

    /// Opens the whole route in Google Maps (first few stops as waypoints).
    public var googleMapsURL: URL? {
        guard let itinerary = selected, let destination = itinerary.stops.last?.place else { return nil }
        let waypoints = itinerary.stops.dropFirst().dropLast().map(\.place.coordinate)
        return ExternalLinks.googleMapsDirections(from: itinerary.request.origin.coordinate, to: destination, waypoints: waypoints)
    }

    public func save() async {
        guard let selected else { return }
        try? await dependencies.repository.saveItinerary(selected)
        isSaved = true
    }

    /// Saves the selected plan as the active trip (auto-saved from here on).
    public func startTrip() async -> ActiveTrip? {
        guard let selected else { return nil }
        let trip = ActiveTrip(itinerary: selected)
        do {
            try await dependencies.repository.saveActiveTrip(trip)
            try await dependencies.repository.saveItinerary(selected)
        } catch {
            return nil
        }
        return trip
    }

    private func drivingTime(in day: ItineraryDay, itinerary: Itinerary) -> TimeInterval {
        var total: TimeInterval = 0
        for stop in day.stops {
            guard let index = itinerary.stops.firstIndex(where: { $0.id == stop.id }), index > 0,
                  let arrival = stop.arrival, let departure = itinerary.stops[index - 1].departure else { continue }
            total += max(0, arrival.timeIntervalSince(departure))
        }
        return total
    }

    private func precedingDistance(of day: ItineraryDay, in itinerary: Itinerary) -> Double {
        guard let first = day.stops.first, let index = itinerary.stops.firstIndex(where: { $0.id == first.id }), index > 0 else {
            return 0
        }
        return itinerary.stops[index - 1].distanceFromStartMeters
    }
}
