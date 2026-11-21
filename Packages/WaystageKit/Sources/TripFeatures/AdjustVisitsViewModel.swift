import Foundation
import Observation
import TripModels
import TripNavigation
import TripPlanner

/// "Adjust visits", from drive mode's preview or the trip banner on Home: the places to visit,
/// and every stop still ahead (visits, breaks, fuel stops, hotels, the destination) with its
/// address and arrival time.
///
/// Changes are collected first and nothing is planned until "Update plan": a place added is listed
/// as "To be added" (and can be taken off the list again), and a visit in the plan is marked "To be
/// removed" (or kept again) with a tap. "Update plan" plans once with all of them; the trip being
/// driven changes only with "Use this plan" (`DriveViewModel.use(plan:)`).
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

    private let dependencies: AppDependencies
    private var state: State
    /// Visits in the plan marked to be removed (row IDs).
    private var removals: Set<String> = []
    /// Places added, not planned yet.
    private var additions: [Addition] = []

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
        var id: String
        var place: Place
        var stay: TimeInterval
    }

    init(
        plan: Itinerary, request: TripRequest?, firstShown: Int, skipped: Set<String> = [],
        projectedArrivals: [String: Date] = [:], dependencies: AppDependencies
    ) {
        self.plan = plan
        self.dependencies = dependencies
        state = State(request: request, firstShown: firstShown, skipped: skipped, projectedArrivals: projectedArrivals)
    }

    /// Every stop still ahead in the plan shown, in order, ending with the destination.
    public var rows: [Row] {
        let stops = plan.stops
        guard state.firstShown < stops.count else { return [] }
        return stops[state.firstShown...].filter { !state.skipped.contains($0.id) }.map(row)
    }

    /// The visits ahead in the plan, then the places added.
    public var visits: [Visit] {
        let formatters = dependencies.formatters
        let planned = rows.filter(\.isVisit).map { row in
            let stay = plan.stops.first { $0.id == row.id }?.dwellDuration.map { "\(formatters.duration($0)) there" }
            return Visit(
                id: row.id, name: row.name, address: row.address,
                detail: [stay, row.eta].compactMap { $0 }.joined(separator: " · "),
                status: removals.contains(row.id) ? .toBeRemoved : .inPlan
            )
        }
        let added = additions.map {
            Visit(id: $0.id, name: $0.place.name, address: $0.place.address, detail: "\(formatters.duration($0.stay)) there", status: .toBeAdded)
        }
        return planned + added
    }

    /// Visits can be changed from here (the rest of the trip can be planned).
    public var canEdit: Bool { state.request != nil && !isUpdating }

    /// Another place can be added (up to `RequiredStop.maximumCount` visits).
    public var canAddVisit: Bool {
        canEdit && visits.count { $0.status != .toBeRemoved } < RequiredStop.maximumCount
    }

    /// Places added or visits marked to be removed, not planned yet.
    public var hasPendingChanges: Bool { !removals.isEmpty || !additions.isEmpty }

    /// Adds a place to the list, to be planned with "Update plan".
    public func add(_ place: Place, stay: TimeInterval) {
        guard canAddVisit else { return }
        additions.append(Addition(id: "added-\(UUID().uuidString)", place: place, stay: stay))
    }

    /// Marks a visit in the plan to be removed, or keeps it again; takes a place added off the list.
    public func toggle(_ visitID: String) {
        guard !isUpdating else { return }
        if let index = additions.firstIndex(where: { $0.id == visitID }) {
            additions.remove(at: index)
        } else if removals.contains(visitID) {
            removals.remove(visitID)
        } else if rows.contains(where: { $0.id == visitID && $0.isVisit }) {
            removals.insert(visitID)
        }
    }

    /// Plans once with every change: visits marked are removed, places added go where they add the
    /// least driving.
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
            state = State(request: request, firstShown: 1, skipped: [], projectedArrivals: [:])
            removals = []
            additions = []
            isUpdated = true
        } catch let error as PlanningError {
            errorMessage = error.message
        } catch {
            errorMessage = "The plan couldn't be updated. Check your connection and try again."
        }
    }

    public func dismissError() { errorMessage = nil }

    /// The request with the changes: visits marked removed, places added inserted.
    private func changedRequest() -> TripRequest? {
        guard var request = state.request else { return nil }
        var stops = request.stops ?? []
        // The n-th visit shown is the n-th visit of the request (both in route order).
        let visitIndices = stops.indices.filter { stops[$0].purpose == .visit }
        var removed: [Int] = []
        for (ordinal, row) in rows.filter(\.isVisit).enumerated() where removals.contains(row.id) {
            let placeID = plan.stops.first { $0.id == row.id }?.place.id
            if visitIndices.indices.contains(ordinal), stops[visitIndices[ordinal]].place.id == placeID {
                removed.append(visitIndices[ordinal])
            } else if let index = visitIndices.first(where: { stops[$0].place.id == placeID && !removed.contains($0) }) {
                removed.append(index)
            }
        }
        for index in removed.sorted(by: >) { stops.remove(at: index) }
        for addition in additions {
            let index = Self.insertionIndex(
                of: addition.place.coordinate, origin: request.origin.coordinate,
                stops: stops.map(\.place.coordinate), destination: request.destination.coordinate
            )
            stops.insert(.visit(addition.place, stay: addition.stay), at: index)
        }
        request.stops = stops.isEmpty ? nil : stops
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
