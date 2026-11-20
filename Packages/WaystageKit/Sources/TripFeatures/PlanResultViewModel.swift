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

/// One of the routes found, as offered on the map and in the list.
public struct RouteChoice: Equatable, Identifiable, Sendable {
    public var id: String
    /// "via Salt Lake City"; "Best route" when it's the only one.
    public var title: String
    /// Total travel time with the selected plan style ("1 d 4 h").
    public var durationText: String
    public var distanceText: String
    public var isBest: Bool
    public var isSelected: Bool
    /// Where to put the route's travel-time tag on the map.
    public var labelCoordinate: GeoCoordinate

    public init(
        id: String, title: String, durationText: String, distanceText: String,
        isBest: Bool, isSelected: Bool, labelCoordinate: GeoCoordinate
    ) {
        self.id = id
        self.title = title
        self.durationText = durationText
        self.distanceText = distanceText
        self.isBest = isBest
        self.isSelected = isSelected
        self.labelCoordinate = labelCoordinate
    }
}

/// What the traveler can change about one stop of the selected plan.
public struct StopEditState: Equatable, Sendable {
    /// The plan must include it (a visit, a kept stop, a chosen hotel).
    public var isKept: Bool
    /// Real places can be kept; generated breaks and lodging search areas can't.
    public var canKeep: Bool
    public var canRemove: Bool
    /// Other hotels nearby (an overnight stop of a plan just made).
    public var hotelChoices: [HotelChoice]
}

/// A change to the selected plan; the plan is made again with it at once.
public enum PlanEdit: Sendable {
    /// Leave the stop out (a visit or kept stop is dropped; another place isn't planned again).
    case remove(stopID: String)
    /// Keep the stop in the plan, or stop keeping it.
    case toggleKeep(stopID: String)
    /// Stay at another hotel that night.
    case chooseHotel(stopID: String, HotelChoice)
    /// Visit a place after this stop, for `stay`.
    case addStop(after: String, place: Place, stay: TimeInterval)
}

/// Compare routes and plans, inspect the timeline, save or start the trip.
///
/// A search can find a few different routes; the best is selected first. The user picks one
/// route and one plan style, and only that plan is ever saved.
@MainActor
@Observable
public final class PlanResultViewModel {
    /// The plans shown; replaced when the traveler plans again with changes.
    public private(set) var result: PlanResult
    public var selectedGoal: OptimizationGoal
    public private(set) var selectedRouteID: String
    public private(set) var isSaved = false

    /// The plan is being made again after a change.
    public private(set) var isUpdating = false
    public private(set) var updateError: String?
    /// Plans before each change, for Undo.
    private var history: [(result: PlanResult, routeID: String, goal: OptimizationGoal)] = []

    private let dependencies: AppDependencies

    public init(result: PlanResult, dependencies: AppDependencies) {
        self.result = result
        self.dependencies = dependencies
        currentLocation = dependencies.location.lastKnownLocation
        selectedRouteID = result.routes.first?.id ?? ""
        selectedGoal = result.itineraries[result.recommendedGoal] != nil
            ? result.recommendedGoal
            : (result.options.first?.goal ?? .balanced)
    }

    public var selectedRoute: RoutePlan? { result.routes.first { $0.id == selectedRouteID } ?? result.routes.first }

    public var selected: Itinerary? {
        guard let route = selectedRoute else { return nil }
        return route.itineraries[selectedGoal] ?? route.options.first
    }

    /// Whether there is more than one route to choose from.
    public var hasRouteChoice: Bool { result.routes.count > 1 }

    /// Chooses a route; the plan style stays.
    public func selectRoute(_ id: String) {
        guard result.routes.contains(where: { $0.id == id }) else { return }
        selectedRouteID = id
        isSaved = false
    }

    // MARK: Editing the plan

    public func editState(for stopID: String) -> StopEditState? {
        guard let plan = selected, let stop = plan.stops.first(where: { $0.id == stopID }),
              stop.kind != .origin, stop.kind != .destination else { return nil }
        let isReal = !stop.isRoadsidePullOff && !stop.place.id.hasPrefix("lodging-area-")
        return StopEditState(
            isKept: stop.isRequiredStop,
            canKeep: isReal && stop.kind != .visit,
            canRemove: isReal || stop.kind == .visit,
            hotelChoices: stop.kind == .lodging ? (selectedRoute?.hotelChoices[stop.place.id] ?? []) : []
        )
    }

    public var canUndo: Bool { !history.isEmpty && !isUpdating }

    /// Another place to visit can be added (up to `RequiredStop.maximumCount`).
    public var canAddStop: Bool {
        (selected?.stops.count { $0.kind == .visit } ?? 0) < RequiredStop.maximumCount
    }

    /// Makes the plan again with the change. Your own stops, kept stops and chosen hotels stay;
    /// Waystage re-chooses the rest. The previous plan can be brought back with `undo()`.
    public func apply(_ edit: PlanEdit) async {
        guard let plan = selected, !isUpdating, let request = Self.request(for: plan, applying: edit, now: dependencies.now()) else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            let planned = try await dependencies.planner.plan(request) { _ in }
            history.append((result, selectedRouteID, selectedGoal))
            show(planned, goal: selectedGoal)
        } catch let error as PlanningError {
            updateError = error.message
        } catch {
            updateError = "The plan couldn't be updated. Check your connection and try again."
        }
    }

    /// Brings back the plan before the last change.
    public func undo() {
        guard let previous = history.popLast(), !isUpdating else { return }
        result = previous.result
        selectedRouteID = previous.routeID
        selectedGoal = previous.goal
        isSaved = false
    }

    public func dismissUpdateError() { updateError = nil }

    private func show(_ planned: PlanResult, goal: OptimizationGoal) {
        result = planned
        selectedRouteID = planned.routes.first?.id ?? ""
        selectedGoal = planned.itineraries[goal] != nil ? goal : planned.recommendedGoal
        isSaved = false
    }

    /// The plan's request with the change: the stops the plan must include (visits, kept stops,
    /// chosen hotels, in route order) and the places left out. A departure that has passed moves to
    /// the next hour (with the deadline, as when a saved trip is planned again).
    static func request(for plan: Itinerary, applying edit: PlanEdit, now: Date) -> TripRequest? {
        var request = plan.request
        let body = Array(plan.stops.dropFirst().dropLast())
        // (position in the plan, stop) for each stop the next plan must include.
        var required: [(Double, RequiredStop)] = body.enumerated()
            .filter { $0.element.isRequiredStop }
            .map { (Double($0.offset), requiredStop(keeping: $0.element)) }
        var avoided = request.avoidedPlaceIDs ?? []
        func position(of stopID: String) -> Double? { body.firstIndex { $0.id == stopID }.map(Double.init) }
        switch edit {
        case let .remove(stopID):
            guard let index = position(of: stopID) else { return nil }
            let stop = body[Int(index)]
            required.removeAll { $0.0 == index }
            if stop.kind != .visit, !avoided.contains(stop.place.id) { avoided.append(stop.place.id) }
        case let .toggleKeep(stopID):
            guard let index = position(of: stopID) else { return nil }
            let stop = body[Int(index)]
            if stop.isRequiredStop {
                required.removeAll { $0.0 == index }
            } else {
                required.append((index, requiredStop(keeping: stop)))
            }
        case let .chooseHotel(stopID, hotel):
            guard let index = position(of: stopID) else { return nil }
            required.removeAll { $0.0 == index }
            required.append((index, hotel.requiredStop))
        case let .addStop(after, place, stay):
            let index = after == "origin" ? -1 : position(of: after)
            guard let index else { return nil }
            required.append((index + 0.5, .visit(place, stay: stay)))
        }
        request.stops = required.sorted { $0.0 < $1.0 }.map(\.1)
        if request.stops?.isEmpty == true { request.stops = nil }
        request.avoidedPlaceIDs = avoided.isEmpty ? nil : avoided
        if request.departure < now {
            let nextHour = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 3_600).rounded(.up) * 3_600)
            let shift = nextHour.timeIntervalSince(request.departure)
            request.departure = nextHour
            request.arriveBy = request.arriveBy.map { $0.addingTimeInterval(shift) }
        }
        return request
    }

    /// A stop of a plan as a stop the next plan must include.
    static func requiredStop(keeping stop: ItineraryStop) -> RequiredStop {
        switch stop.kind {
        case .visit:
            return .visit(stop.place, stay: stop.dwellDuration ?? 3_600)
        case .lodging:
            return RequiredStop(place: stop.place, purpose: .lodging, lodging: stop.lodging)
        case .fuel:
            return RequiredStop(
                place: stop.place, purpose: .fuel,
                fuelPricePerGallon: stop.fuelPurchase.flatMap { $0.isPriceEstimated ? nil : $0.pricePerGallon }
            )
        case .rest, .origin, .destination:
            return RequiredStop(place: stop.place, purpose: .rest)
        }
    }

    /// The plan with the selected style on a route (for drawing every route on the map).
    public func itinerary(onRoute id: String) -> Itinerary? {
        guard let route = result.routes.first(where: { $0.id == id }) else { return nil }
        return route.itineraries[selectedGoal] ?? route.options.first
    }

    /// Every route found, best first, with its travel time for the selected plan style.
    public var routeChoices: [RouteChoice] {
        let formatters = dependencies.formatters
        let selectedID = selectedRoute?.id
        return result.routes.enumerated().compactMap { index, route in
            guard let itinerary = route.itineraries[selectedGoal] ?? route.options.first else { return nil }
            return RouteChoice(
                id: route.id,
                title: route.name ?? (index == 0 ? "Best route" : "Route \(index + 1)"),
                durationText: formatters.duration(itinerary.totals.elapsedDuration),
                distanceText: formatters.distance(itinerary.totals.distanceMeters),
                isBest: index == 0,
                isSelected: route.id == selectedID,
                labelCoordinate: route.labelCoordinate
            )
        }
    }

    public var options: [PlanOption] {
        let formatters = dependencies.formatters
        let itineraries = selectedRoute?.options ?? []
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
    public private(set) var currentLocation: GeoCoordinate?

    /// Finds where the user is, if location access is already allowed (this screen never asks).
    public func locateUser() async {
        let location = dependencies.location
        guard location.authorization == .authorized else { return }
        if let here = await location.requestLocation() { currentLocation = here }
    }

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
