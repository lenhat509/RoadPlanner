import Foundation
import Observation
import TripModels
import TripNavigation
import TripPlanner

/// "Adjust visits", from drive mode's preview or the trip banner on Home: every stop still ahead
/// (visits, breaks, fuel stops, hotels, the destination) with its address and arrival time, and
/// the places to visit to add or remove.
///
/// Each change plans the rest of the trip again at once and the list shows the new stops and
/// times; Undo brings the previous plan back. The trip being driven changes only with "Use this
/// plan" (`DriveViewModel.use(plan:)`).
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
        /// A place to visit: it can be removed.
        public var isVisit: Bool
    }

    /// The plan shown: the trip's own until the first change.
    public private(set) var plan: Itinerary
    public private(set) var isUpdating = false
    public private(set) var errorMessage: String?

    private let dependencies: AppDependencies
    private var state: State
    private var history: [(plan: Itinerary, state: State)] = []

    private struct State {
        /// The rest of the trip as a request the changes edit; nil when it can't be planned from here.
        var request: TripRequest?
        /// Index of the first stop shown (stops behind the car aren't).
        var firstShown: Int
        var skipped: Set<String>
        /// Arrival times projected from where the car is (the trip's own plan only).
        var projectedArrivals: [String: Date]
    }

    init(
        plan: Itinerary, request: TripRequest?, firstShown: Int, skipped: Set<String> = [],
        projectedArrivals: [String: Date] = [:], dependencies: AppDependencies
    ) {
        self.plan = plan
        self.dependencies = dependencies
        state = State(request: request, firstShown: firstShown, skipped: skipped, projectedArrivals: projectedArrivals)
    }

    /// Every stop still ahead, in order, ending with the destination.
    public var rows: [Row] {
        let stops = plan.stops
        guard state.firstShown < stops.count else { return [] }
        return stops[state.firstShown...].filter { !state.skipped.contains($0.id) }.map(row)
    }

    /// Visits can be changed from here (the rest of the trip can be planned).
    public var canEdit: Bool { state.request != nil && !isUpdating }

    public var canAddVisit: Bool {
        canEdit && (state.request?.requiredStops.count { $0.purpose == .visit } ?? 0) < RequiredStop.maximumCount
    }

    public var hasChanges: Bool { !history.isEmpty }
    public var canUndo: Bool { !history.isEmpty && !isUpdating }

    /// Removes a place to visit (a row with `isVisit`).
    public func remove(_ rowID: String) async {
        guard canEdit, var request = state.request, var stops = request.stops else { return }
        let shown = rows
        guard let row = shown.first(where: { $0.id == rowID }), row.isVisit,
              let stop = plan.stops.first(where: { $0.id == rowID }) else { return }
        // The n-th visit shown is the n-th visit of the request (both in route order).
        let ordinal = shown.filter(\.isVisit).firstIndex { $0.id == rowID } ?? 0
        let visits = stops.indices.filter { stops[$0].purpose == .visit }
        let index = visits.indices.contains(ordinal) && stops[visits[ordinal]].place.id == stop.place.id
            ? visits[ordinal]
            : stops.firstIndex { $0.purpose == .visit && $0.place.id == stop.place.id }
        guard let index else { return }
        stops.remove(at: index)
        request.stops = stops.isEmpty ? nil : stops
        await update(request)
    }

    /// Adds a place to visit, for `stay`, where it adds the least driving.
    public func add(_ place: Place, stay: TimeInterval) async {
        guard canAddVisit, var request = state.request else { return }
        var stops = request.stops ?? []
        let index = Self.insertionIndex(
            of: place.coordinate, origin: request.origin.coordinate,
            stops: stops.map(\.place.coordinate), destination: request.destination.coordinate
        )
        stops.insert(.visit(place, stay: stay), at: index)
        request.stops = stops
        await update(request)
    }

    public func undo() {
        guard canUndo, let previous = history.popLast() else { return }
        plan = previous.plan
        state = previous.state
        errorMessage = nil
    }

    public func dismissError() { errorMessage = nil }

    private func update(_ request: TripRequest) async {
        isUpdating = true
        defer { isUpdating = false }
        errorMessage = nil
        do {
            let result = try await dependencies.planner.plan(request) { _ in }
            guard let next = result.itineraries[request.goal] ?? result.recommended else {
                errorMessage = "Waystage couldn't find a plan with this change."
                return
            }
            history.append((plan, state))
            plan = next
            state = State(request: request, firstShown: 1, skipped: [], projectedArrivals: [:])
        } catch let error as PlanningError {
            errorMessage = error.message
        } catch {
            errorMessage = "The plan couldn't be updated. Check your connection and try again."
        }
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
        of point: GeoCoordinate, origin: GeoCoordinate, stops: [GeoCoordinate], destination: GeoCoordinate
    ) -> Int {
        let path = [origin] + stops + [destination]
        var best = stops.count
        var bestCost = Double.infinity
        for index in 0..<(path.count - 1) {
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
