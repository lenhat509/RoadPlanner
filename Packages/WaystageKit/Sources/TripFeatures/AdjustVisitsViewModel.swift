import Foundation
import Observation
import TripModels
import TripNavigation
import TripPlanner

/// "Adjust visits", from the plan screen (before Start) or the trip banner on Home: the places to
/// visit, with their addresses and arrival times.
///
/// Changes are collected first and nothing is planned until "Update plan": a place added is listed
/// as "To be added" (and can be taken off the list again), a visit in the plan is marked "To be
/// removed" (or kept again) with a tap, and visits can be moved into another order. "Update plan"
/// plans once with all of them; the plan shown or the trip being driven changes only with "Use this
/// plan" (`PlanResultViewModel.use(_:)`, `DriveViewModel.use(plan:)`).
@MainActor
@Observable
public final class AdjustVisitsViewModel {
    /// A stop ahead, ready to show.
    public struct Row: Identifiable, Hashable, Sendable {
        public var id: String
        public var kind: StopKind
        public var isPullOff: Bool
        public var name: String
        /// "Stop on the way · 1 h 30 min there", "Fuel stop", "Overnight stay · Kept", …
        public var kindText: String
        public var address: String?
        /// "Arrive Thu, Nov 20, 3:10 PM"; for hotels, "Check in …".
        public var eta: String?
        /// A place to visit.
        public var isVisit: Bool
    }

    /// A place to visit: in the plan (kept, or marked to be removed), or added and not planned yet.
    public struct Visit: Identifiable, Hashable, Sendable {
        public enum Status: Hashable, Sendable {
            case inPlan
            case toBeRemoved
            case toBeAdded
        }

        public var id: String
        public var name: String
        public var address: String?
        /// Where it is (numbered on the map in the list's order).
        public var coordinate: GeoCoordinate
        /// "1 h 30 min there · Arrive Thu, Nov 20, 3:10 PM"; for a place to add, "1 h there".
        public var detail: String
        public var status: Status
    }

    /// The plan shown: the trip's own until "Update plan".
    public private(set) var plan: Itinerary
    public private(set) var isUpdating = false
    public private(set) var errorMessage: String?
    /// The plan was made again ("Use this plan" makes it the trip).
    public private(set) var isUpdated = false
    /// Every plan made by "Update plan" (both goals, every route), for the plan screen.
    public private(set) var updatedResult: PlanResult?

    private let dependencies: AppDependencies
    private var state: State
    /// Visits in the plan marked to be removed (row IDs).
    private var removals: Set<String> = []
    /// Places added, not planned yet, by ID.
    private var additions: [String: Addition] = [:]
    /// The visits in the order they'll be planned: Waystage's (the plan's own, and where each place
    /// added adds the least driving) until the traveler moves them.
    private var order: [Entry] = []
    /// The plan's own order of its visits (row IDs), to tell whether they were moved.
    private var plannedOrder: [String] = []

    private struct State {
        /// The rest of the trip as a request the changes edit; nil when it can't be planned from here.
        var request: TripRequest?
        /// Index of the first stop shown (stops behind the car aren't).
        var firstShown: Int
        var skipped: Set<String>
        /// Arrival times projected from where the car is (the trip's own plan only).
        var projectedArrivals: [String: Date]
    }

    private struct Addition {
        var place: Place
        var stay: TimeInterval
    }

    private enum Entry: Hashable {
        case planned(String)
        case added(String)
    }

    init(
        plan: Itinerary, request: TripRequest?, firstShown: Int, skipped: Set<String> = [],
        projectedArrivals: [String: Date] = [:], dependencies: AppDependencies
    ) {
        self.plan = plan
        self.dependencies = dependencies
        state = State(request: request, firstShown: firstShown, skipped: skipped, projectedArrivals: projectedArrivals)
        resetOrder()
    }

    /// Every stop still ahead in the plan shown, in order, ending with the destination.
    public var rows: [Row] {
        let stops = plan.stops
        guard state.firstShown < stops.count else { return [] }
        return stops[state.firstShown...].filter { !state.skipped.contains($0.id) }.map(row)
    }

    /// The visits, in the order they'll be planned: the plan's, with places added where they add the
    /// least driving, until the traveler moves them.
    public var visits: [Visit] {
        let formatters = dependencies.formatters
        let planned = Dictionary(rows.filter(\.isVisit).map { ($0.id, $0) }) { first, _ in first }
        return order.compactMap { entry in
            switch entry {
            case let .planned(id):
                guard let row = planned[id], let stop = plan.stops.first(where: { $0.id == id }) else { return nil }
                let stay = stop.dwellDuration.map { "\(formatters.duration($0)) there" }
                return Visit(
                    id: id, name: row.name, address: row.address, coordinate: stop.place.coordinate,
                    detail: [stay, row.eta].compactMap { $0 }.joined(separator: " · "),
                    status: removals.contains(id) ? .toBeRemoved : .inPlan
                )
            case let .added(id):
                guard let addition = additions[id] else { return nil }
                return Visit(
                    id: id, name: addition.place.name, address: addition.place.address, coordinate: addition.place.coordinate,
                    detail: "\(formatters.duration(addition.stay)) there", status: .toBeAdded
                )
            }
        }
    }

    /// Visits can be changed from here (the rest of the trip can be planned).
    public var canEdit: Bool { state.request != nil && !isUpdating }

    /// Another place can be added (up to `RequiredStop.maximumCount` visits).
    public var canAddVisit: Bool {
        canEdit && visits.count { $0.status != .toBeRemoved } < RequiredStop.maximumCount
    }

    /// Places added, visits marked to be removed or visits moved, not planned yet.
    public var hasPendingChanges: Bool { !removals.isEmpty || !additions.isEmpty || isReordered }

    /// The visits in the plan are no longer in its order.
    private var isReordered: Bool {
        order.compactMap { if case let .planned(id) = $0 { id } else { nil } } != plannedOrder
    }

    /// Adds a place to the list where it adds the least driving, to be planned with "Update plan".
    public func add(_ place: Place, stay: TimeInterval) {
        guard canAddVisit, let request = state.request else { return }
        let id = "added-\(UUID().uuidString)"
        additions[id] = Addition(place: place, stay: stay)
        let index = Self.insertionIndex(
            of: place.coordinate, origin: request.origin.coordinate,
            stops: order.map { coordinate(of: $0) ?? request.origin.coordinate }, destination: request.destination.coordinate
        )
        order.insert(.added(id), at: index)
    }

    /// Moves visits in the list (the order they'll be planned in).
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !isUpdating else { return }
        let moving = source.sorted().filter { order.indices.contains($0) }.map { order[$0] }
        var rest = order.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let index = destination - source.count { $0 < destination }
        rest.insert(contentsOf: moving, at: max(0, min(index, rest.count)))
        order = rest
    }

    /// Marks a visit in the plan to be removed, or keeps it again; takes a place added off the list.
    public func toggle(_ visitID: String) {
        guard !isUpdating else { return }
        if additions.removeValue(forKey: visitID) != nil {
            order.removeAll { $0 == .added(visitID) }
        } else if removals.contains(visitID) {
            removals.remove(visitID)
        } else if plannedOrder.contains(visitID) {
            removals.insert(visitID)
        }
    }

    /// Plans once with every change: the visits in the list's order, without those marked removed.
    public func updatePlan() async {
        guard canEdit, hasPendingChanges, let request = changedRequest() else { return }
        isUpdating = true
        defer { isUpdating = false }
        errorMessage = nil
        do {
            let result = try await dependencies.planner.plan(request) { _ in }
            guard let next = result.itineraries[request.goal] ?? result.recommended else {
                errorMessage = "Waystage couldn't find a plan with these visits."
                return
            }
            plan = next
            updatedResult = result
            state = State(request: request, firstShown: 1, skipped: [], projectedArrivals: [:])
            removals = []
            additions = [:]
            resetOrder()
            isUpdated = true
        } catch let error as PlanningError {
            errorMessage = error.message
        } catch {
            errorMessage = "The plan couldn't be updated. Check your connection and try again."
        }
    }

    public func dismissError() { errorMessage = nil }

    private func resetOrder() {
        plannedOrder = rows.filter(\.isVisit).map(\.id)
        order = plannedOrder.map(Entry.planned)
    }

    private func coordinate(of entry: Entry) -> GeoCoordinate? {
        switch entry {
        case let .planned(id): plan.stops.first { $0.id == id }?.place.coordinate
        case let .added(id): additions[id]?.place.coordinate
        }
    }

    /// The request with the changes: the visits in the list's order (without those marked removed),
    /// and the other stops the plan keeps (hotels ahead, kept stops) where they add the least
    /// driving, in their own order.
    private func changedRequest() -> TripRequest? {
        guard var request = state.request else { return nil }
        let stops = request.stops ?? []
        // The n-th visit of the plan is the n-th visit of the request (both in route order).
        let requestVisits = stops.filter { $0.purpose == .visit }
        let visits: [RequiredStop] = order.enumerated().compactMap { _, entry in
            switch entry {
            case let .planned(id):
                guard !removals.contains(id), let stop = plan.stops.first(where: { $0.id == id }) else { return nil }
                let ordinal = plannedOrder.firstIndex(of: id) ?? -1
                if requestVisits.indices.contains(ordinal), requestVisits[ordinal].place.id == stop.place.id {
                    return requestVisits[ordinal]
                }
                return requestVisits.first { $0.place.id == stop.place.id } ?? .visit(stop.place, stay: stop.dwellDuration ?? 3_600)
            case let .added(id):
                return additions[id].map { .visit($0.place, stay: $0.stay) }
            }
        }
        var merged = visits
        var earliest = 0
        for stop in stops where stop.purpose != .visit {
            let index = Self.insertionIndex(
                of: stop.place.coordinate, origin: request.origin.coordinate,
                stops: merged.map(\.place.coordinate), destination: request.destination.coordinate, from: earliest
            )
            merged.insert(stop, at: index)
            earliest = index + 1
        }
        request.stops = merged.isEmpty ? nil : merged
        return request
    }

    private func row(_ stop: ItineraryStop) -> Row {
        let formatters = dependencies.formatters
        var kindText = stop.isRoadsidePullOff ? "Rest break" : stop.kind.displayName
        if stop.kind == .visit, let stay = stop.dwellDuration {
            kindText += " · \(formatters.duration(stay)) there"
        } else if stop.isRequiredStop {
            kindText += " · Kept"
        }
        let arrival = state.projectedArrivals[stop.id] ?? stop.arrival
        let eta = arrival.map {
            (stop.kind == .lodging ? "Check in " : "Arrive ") + formatters.dateTime($0, utcOffsetSeconds: stop.place.utcOffsetSeconds)
        }
        return Row(
            id: stop.id, kind: stop.kind, isPullOff: stop.isRoadsidePullOff, name: stop.place.name,
            kindText: kindText, address: stop.place.address, eta: eta, isVisit: stop.kind == .visit
        )
    }

    /// Where a new place goes among the stops a plan keeps: between the two it adds the least
    /// distance to (straight lines).
    static func insertionIndex(
        of point: GeoCoordinate, origin: GeoCoordinate, stops: [GeoCoordinate], destination: GeoCoordinate, from minimum: Int = 0
    ) -> Int {
        let path = [origin] + stops + [destination]
        var best = stops.count
        var bestCost = Double.infinity
        for index in max(0, min(minimum, stops.count))..<(path.count - 1) {
            let cost = GeoMath.distance(path[index], point) + GeoMath.distance(point, path[index + 1])
                - GeoMath.distance(path[index], path[index + 1])
            if cost < bestCost {
                bestCost = cost
                best = index
            }
        }
        return best
    }
}

extension DriveViewModel {
    /// The trip's places to visit, to add or remove. Before the trip starts, the whole plan is
    /// made again (leaving now if its departure has passed); once it has, the rest of the trip from
    /// here, as "Adjust the rest" plans it.
    public func visitsEditor() -> AdjustVisitsViewModel {
        let itinerary = trip.itinerary
        let now = dependencies.now()
        guard trip.progress.phase != .notStarted else {
            var request = itinerary.request
            if request.departure < now { request.departure = now }
            if let deadline = request.arriveBy, deadline <= request.departure { request.arriveBy = nil }
            return AdjustVisitsViewModel(plan: itinerary, request: request, firstShown: 1, dependencies: dependencies)
        }
        let target = trip.progress.targetStopIndex
        let projected = trip.projectedSchedule(now: now, remainingToTarget: mode == .atStop ? nil : legProgress?.timeRemaining)
        return AdjustVisitsViewModel(
            plan: itinerary,
            request: restOfTripRequest(),
            firstShown: mode == .atStop ? target + 1 : target,
            skipped: trip.progress.skippedStopIDs,
            projectedArrivals: Dictionary(projected.compactMap { stop in stop.arrival.map { (stop.stopID, $0) } }) { first, _ in first },
            dependencies: dependencies
        )
    }
}
