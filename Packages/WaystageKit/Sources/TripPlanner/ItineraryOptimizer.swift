import Foundation
import TripModels

/// What the driver does at a chosen stop.
public enum StopAction: Hashable, Sendable {
    case rest
    case refuel(gallons: Double, pricePerGallon: Double)
    case overnight(nightlyRate: Double)
}

/// A stop chosen by the optimizer, with its schedule.
public struct ScheduledStop: Hashable, Sendable {
    public var candidate: StopCandidate
    public var action: StopAction
    public var arrival: Date
    public var departure: Date
    public var fuelOnArrival: Double
    public var fuelOnDeparture: Double
    /// Travel day on which the driver arrives at this stop.
    public var dayIndex: Int
}

/// The optimizer's output.
public struct OptimizedSchedule: Sendable {
    public var stops: [ScheduledStop]
    public var arrival: Date
    public var fuelOnArrival: Double
    public var finalDayIndex: Int
    public var fuelCost: Double
    public var lodgingCost: Double
    public var tollCost: Double
    public var drivingDuration: TimeInterval
    /// Gallons burned on the trip.
    public var fuelGallonsUsed: Double
    /// Price used to value fuel already in the tank or left over at the end.
    public var referenceFuelPrice: Double
    /// Objective value (lower is better); only comparable for the same goal.
    public var score: Double

    public var totalCost: Double { fuelCost + lodgingCost + tollCost }
}

/// Why no schedule satisfies the constraints.
public enum InfeasibilityReason: Hashable, Sendable, Error {
    /// The arrival deadline cannot be met.
    case deadline
    /// A stretch of road longer than the usable fuel range has no fuel stop.
    case fuelRange(atMeters: Double)
    /// Daily driving limits / time windows cannot be met with the known lodging.
    case drivingLimits
}

/// A single optimization problem: one route, one goal.
public struct OptimizationProblem: Sendable {
    public var routeDistance: Double
    public var routeDuration: TimeInterval
    public var tollCostUSD: Double
    /// Candidate stops (any order).
    public var candidates: [StopCandidate]
    public var vehicle: Vehicle
    public var departure: Date
    public var arriveBy: Date?
    public var originUTCOffset: Int
    public var destinationUTCOffset: Int
    public var goal: OptimizationGoal
    /// Price per gallon used to value fuel already in the tank (or left over). Defaults to the
    /// median station price along the route, then to the national default.
    public var referenceFuelPrice: Double?

    public init(
        routeDistance: Double,
        routeDuration: TimeInterval,
        tollCostUSD: Double = 0,
        candidates: [StopCandidate],
        vehicle: Vehicle,
        departure: Date,
        arriveBy: Date? = nil,
        originUTCOffset: Int,
        destinationUTCOffset: Int,
        goal: OptimizationGoal,
        referenceFuelPrice: Double? = nil
    ) {
        self.routeDistance = routeDistance
        self.routeDuration = routeDuration
        self.tollCostUSD = tollCostUSD
        self.candidates = candidates
        self.vehicle = vehicle
        self.departure = departure
        self.arriveBy = arriveBy
        self.originUTCOffset = originUTCOffset
        self.destinationUTCOffset = destinationUTCOffset
        self.goal = goal
        self.referenceFuelPrice = referenceFuelPrice
    }

    public init(profile: RouteProfile, candidates: [StopCandidate], request: TripRequest, goal: OptimizationGoal) {
        self.init(
            routeDistance: profile.totalDistance,
            routeDuration: profile.totalDuration,
            tollCostUSD: profile.tollCostUSD,
            candidates: candidates,
            vehicle: request.vehicle,
            departure: request.departure,
            arriveBy: request.arriveBy,
            originUTCOffset: request.origin.utcOffsetSeconds,
            destinationUTCOffset: request.destination.utcOffsetSeconds,
            goal: goal,
            referenceFuelPrice: OptimizationProblem.medianFuelPrice(of: candidates)
        )
    }

    /// Median price of fuel-capable candidates (robust against a few very cheap or pricey stations).
    public static func medianFuelPrice(of candidates: [StopCandidate]) -> Double? {
        let prices = candidates.compactMap { $0.capabilities.contains(.fuel) ? $0.fuelPricePerGallon : nil }.sorted()
        guard !prices.isEmpty else { return nil }
        return prices.count.isMultiple(of: 2)
            ? (prices[prices.count / 2 - 1] + prices[prices.count / 2]) / 2
            : prices[prices.count / 2]
    }
}

/// Tunables for the optimizer. `policy` may be a relaxed copy of the user's policy.
public struct OptimizerSettings: Hashable, Sendable {
    public var policy: DrivingPolicy
    /// Ignore the end-of-day cutoff (daily driving and rest limits still apply).
    public var allowNightDriving = false
    /// Allow placeholder lodging areas (last resort when no lodging is known).
    public var allowLodgingSearchAreas = false
    /// Allow refuelling at generated pull-offs (last resort for fuel gaps).
    public var allowFuelAtPullOffs = false
    /// Treat `arriveBy` as a hard constraint.
    public var enforceDeadline = true
    /// Pareto labels kept per node; bounds run time.
    public var maxLabelsPerNode = 40
    /// Comfort penalty for a generic roadside break versus a real facility.
    public var pullOffPenaltyMinutes = 5.0
    public var pullOffPenaltyDollars = 2.0
    /// Penalty for using a lodging search area instead of a known property.
    public var lodgingAreaPenaltyMinutes = 120.0
    public var lodgingAreaPenaltyDollars = 60.0
    /// Penalty for an emergency fuel stop at a pull-off.
    public var emergencyFuelPenaltyMinutes = 60.0
    public var emergencyFuelPenaltyDollars = 50.0
    /// Smallest fuel purchase worth a stop.
    public var minimumPurchaseGallons = 1.0
    /// A fill-up must buy at least this fraction of the tank (avoids pointless top-offs).
    public var minimumFillUpFraction = 0.25
    /// A late departure gets at least this much driving before the day's cutoff.
    public var lateStartGrace: TimeInterval = 2 * 3_600
    /// Overnight stops are only planned for arrivals from this local time (or after midnight,
    /// before the day starts). Prevents "check in at 9 AM, leave tomorrow at 8 AM" plans.
    public var earliestOvernightArrival = LocalTime(hour: 14)
    public var pricing: PricingDefaults = .standard

    public init(policy: DrivingPolicy) {
        self.policy = policy
    }
}

extension OptimizationGoal {
    /// Dollars per hour used to combine time and money into one score.
    ///
    /// * fastest: time dominates; money only breaks ties.
    /// * cheapest: money dominates; a small time value avoids pointless detours.
    /// * balanced: the user's value of time.
    public func valueOfTimePerHour(policy: DrivingPolicy) -> Double {
        switch self {
        case .fastest: 10_000
        case .cheapest: 2
        case .balanced: max(0, policy.valueOfTimePerHour)
        }
    }
}

/// Finds the best sequence of rest, fuel and overnight stops for one route.
///
/// The search is a resource-constrained shortest path over candidate stops ordered along
/// the route (a DAG). Each label carries the clock time, fuel in the tank, driving time
/// since the last overnight, the current day's cutoff, cost and penalties. A label is
/// discarded when another label at the same stop is at least as good in every resource
/// (Pareto dominance), which keeps the search exact in practice and fast.
///
/// Hard constraints enforced on every driving segment:
/// * non-stop driving ≤ `policy.maxContinuousDriving` (every stop is a break),
/// * fuel never below the reserve,
/// * daily driving ≤ `policy.maxDailyDriving`,
/// * arrival at a stop no later than the day's cutoff (unless night driving is allowed),
/// * arrival at the destination by `arriveBy` (when enforced).
public struct ItineraryOptimizer: Sendable {
    public var settings: OptimizerSettings

    public init(settings: OptimizerSettings) {
        self.settings = settings
    }

    public func optimize(_ problem: OptimizationProblem) -> Result<OptimizedSchedule, InfeasibilityReason> {
        var search = Search(problem: problem, settings: settings)
        return search.run()
    }
}

// MARK: - Search implementation

private struct Search {
    struct Node {
        var candidateIndex: Int? // nil for origin/destination
        var distance: Double
        var time: Double
        var halfDetourTime: Double
        var halfDetourDistance: Double
        var capabilities: StopCapabilities
        var fuelPrice: Double
        var nightlyRate: Double
        var utcOffset: Double
        var restPenalty: Double
        var fuelPenalty: Double
        var lodgingPenalty: Double
    }

    enum Action {
        case start, rest, refuel(gallons: Double, price: Double), overnight(rate: Double), arrive
    }

    struct Label {
        var node: Int
        var parent: Int
        var action: Action
        var arrival: Double
        var departure: Double
        var cost: Double
        var penalty: Double
        var score: Double
        var fuelOnArrival: Double
        var fuel: Double
        var drivenToday: Double
        var drivingTotal: Double
        var cutoffLocal: Double
        var dayIndex: Int
    }

    let problem: OptimizationProblem
    let settings: OptimizerSettings
    let policy: DrivingPolicy
    let nodes: [Node]
    let start: Double
    let valueOfTime: Double
    let tank: Double
    let reserve: Double
    let originReserve: Double
    let deadline: Double?
    let initialFuel: Double
    let referenceFuelPrice: Double

    var labels: [Label] = []
    var fronts: [[Int]]
    var bestFinal: Label?
    var prunedByDeadline = false

    init(problem: OptimizationProblem, settings: OptimizerSettings) {
        self.problem = problem
        self.settings = settings
        self.policy = settings.policy
        self.start = problem.departure.timeIntervalSince1970
        self.valueOfTime = problem.goal.valueOfTimePerHour(policy: settings.policy)
        self.tank = problem.vehicle.tankCapacityGallons
        self.reserve = tank * max(0, settings.policy.fuelReserveFraction)
        let initialFuel = tank * problem.vehicle.initialFuelFraction
        // If the car starts low on fuel, allow dipping into the reserve to reach the first station.
        self.originReserve = min(reserve, initialFuel * 0.25)
        self.deadline = settings.enforceDeadline ? problem.arriveBy?.timeIntervalSince1970 : nil
        self.initialFuel = initialFuel
        self.referenceFuelPrice = problem.referenceFuelPrice ?? settings.pricing.fuelPrice(for: problem.vehicle.fuelType)
        self.nodes = Search.makeNodes(problem: problem, settings: settings, valueOfTime: valueOfTime)
        self.fronts = Array(repeating: [], count: nodes.count)
    }

    static func makeNodes(problem: OptimizationProblem, settings: OptimizerSettings, valueOfTime: Double) -> [Node] {
        func dollars(minutes: Double, dollars: Double) -> Double { minutes / 60 * valueOfTime + dollars }
        let defaultFuelPrice = settings.pricing.fuelPrice(for: problem.vehicle.fuelType)
        var nodes: [Node] = [Node(
            candidateIndex: nil, distance: 0, time: 0, halfDetourTime: 0, halfDetourDistance: 0,
            capabilities: [], fuelPrice: 0, nightlyRate: 0, utcOffset: Double(problem.originUTCOffset),
            restPenalty: 0, fuelPenalty: 0, lodgingPenalty: 0
        )]
        let ordered = problem.candidates.indices.sorted {
            (problem.candidates[$0].distanceAlong, problem.candidates[$0].id)
                < (problem.candidates[$1].distanceAlong, problem.candidates[$1].id)
        }
        for index in ordered {
            let candidate = problem.candidates[index]
            guard candidate.distanceAlong > 0, candidate.distanceAlong < problem.routeDistance else { continue }
            var capabilities = candidate.capabilities
            var fuelPenalty = 0.0
            if candidate.isLodgingSearchArea && !settings.allowLodgingSearchAreas { capabilities.remove(.lodging) }
            if candidate.isRoadsidePullOff && settings.allowFuelAtPullOffs {
                capabilities.insert(.fuel)
                fuelPenalty = dollars(minutes: settings.emergencyFuelPenaltyMinutes, dollars: settings.emergencyFuelPenaltyDollars)
            }
            guard !capabilities.isEmpty else { continue }
            nodes.append(Node(
                candidateIndex: index,
                distance: candidate.distanceAlong,
                time: candidate.timeAlong,
                halfDetourTime: candidate.detourDuration / 2,
                halfDetourDistance: candidate.detourDistance / 2,
                capabilities: capabilities,
                fuelPrice: candidate.fuelPricePerGallon ?? defaultFuelPrice,
                nightlyRate: candidate.nightlyRate ?? settings.pricing.unknownNightlyRate,
                utcOffset: Double(candidate.place.utcOffsetSeconds),
                restPenalty: candidate.isRoadsidePullOff
                    ? dollars(minutes: settings.pullOffPenaltyMinutes, dollars: settings.pullOffPenaltyDollars) : 0,
                fuelPenalty: fuelPenalty,
                lodgingPenalty: candidate.isLodgingSearchArea
                    ? dollars(minutes: settings.lodgingAreaPenaltyMinutes, dollars: settings.lodgingAreaPenaltyDollars) : 0
            ))
        }
        nodes.append(Node(
            candidateIndex: nil, distance: problem.routeDistance, time: problem.routeDuration,
            halfDetourTime: 0, halfDetourDistance: 0, capabilities: [], fuelPrice: 0, nightlyRate: 0,
            utcOffset: Double(problem.destinationUTCOffset), restPenalty: 0, fuelPenalty: 0, lodgingPenalty: 0
        ))
        return nodes
    }

    mutating func run() -> Result<OptimizedSchedule, InfeasibilityReason> {
        let initialFuel = tank * problem.vehicle.initialFuelFraction
        let origin = Label(
            node: 0, parent: -1, action: .start, arrival: start, departure: start,
            cost: 0, penalty: 0, score: 0, fuelOnArrival: initialFuel, fuel: initialFuel,
            drivenToday: 0, drivingTotal: 0,
            cutoffLocal: cutoff(forDayStartingAtLocal: start + nodes[0].utcOffset),
            dayIndex: 0
        )
        labels.append(origin)
        fronts[0] = [0]

        for nodeIndex in 0..<(nodes.count - 1) {
            for labelIndex in fronts[nodeIndex] {
                expand(labelIndex)
            }
        }

        guard let final = bestFinal else { return .failure(diagnose()) }
        return .success(reconstruct(final))
    }

    // MARK: Expansion

    private mutating func expand(_ labelIndex: Int) {
        let label = labels[labelIndex]
        let from = nodes[label.node]
        let isOrigin = label.node == 0
        let legReserve = isOrigin ? originReserve : reserve
        let destinationIndex = nodes.count - 1
        let maxContinuous = policy.maxContinuousDriving

        for target in (label.node + 1)..<nodes.count {
            let to = nodes[target]
            let baseTime = to.time - from.time
            if baseTime > maxContinuous || label.drivenToday + baseTime > policy.maxDailyDriving { break }
            let baseDistance = to.distance - from.distance
            if label.fuel - problem.vehicle.gallons(forMeters: baseDistance) < legReserve { break }

            let exitTime = isOrigin ? 0 : from.halfDetourTime
            let exitDistance = isOrigin ? 0 : from.halfDetourDistance
            let driveTime = baseTime + exitTime + to.halfDetourTime
            guard driveTime <= maxContinuous, label.drivenToday + driveTime <= policy.maxDailyDriving else { continue }

            let fuelOnArrival = label.fuel
                - problem.vehicle.gallons(forMeters: baseDistance + exitDistance + to.halfDetourDistance)
            guard fuelOnArrival >= legReserve else { continue }

            let arrival = label.departure + driveTime
            if !settings.allowNightDriving && arrival + to.utcOffset > label.cutoffLocal { continue }

            let isDestination = target == destinationIndex
            if let deadline, lowerBoundArrival(arrivingAt: to, at: arrival, isDestination: isDestination) > deadline {
                prunedByDeadline = true
                continue
            }

            var next = label
            next.node = target
            next.parent = labelIndex
            next.arrival = arrival
            next.fuelOnArrival = fuelOnArrival
            next.fuel = fuelOnArrival
            next.drivenToday = label.drivenToday + driveTime
            next.drivingTotal = label.drivingTotal + driveTime

            if isDestination {
                next.action = .arrive
                next.departure = arrival
                // Charge the trip for all gas it burns: fuel already in the tank is valued at the
                // reference price, and fuel left over at the end is credited.
                next.cost += (initialFuel - fuelOnArrival) * referenceFuelPrice
                next.score = score(cost: next.cost, penalty: next.penalty, time: arrival)
                if bestFinal == nil || next.score < bestFinal!.score { bestFinal = next }
                continue
            }
            addActions(at: to, base: next)
        }
    }

    private mutating func addActions(at node: Node, base: Label) {
        if node.capabilities.contains(.rest) {
            var rest = base
            rest.action = .rest
            rest.departure = base.arrival + policy.restStopDuration
            rest.penalty += node.restPenalty
            insert(rest)
        }
        if node.capabilities.contains(.fuel) {
            let fillUp = tank - base.fuelOnArrival
            if fillUp >= max(settings.minimumPurchaseGallons, tank * settings.minimumFillUpFraction) {
                insert(refuel(base, at: node, gallons: fillUp))
            }
            // Buy only what is needed to reach the destination (avoids paying for leftover fuel).
            let remaining = problem.routeDistance - node.distance + node.halfDetourDistance
            let toDestination = problem.vehicle.gallons(forMeters: remaining) + reserve + 0.25 - base.fuelOnArrival
            if toDestination >= settings.minimumPurchaseGallons && toDestination < fillUp - 0.5 {
                insert(refuel(base, at: node, gallons: toDestination))
            }
        }
        if node.capabilities.contains(.lodging) && isReasonableCheckIn(base.arrival + node.utcOffset) {
            insert(overnight(base, at: node))
        }
    }

    private func refuel(_ base: Label, at node: Node, gallons: Double) -> Label {
        var label = base
        label.action = .refuel(gallons: gallons, price: node.fuelPrice)
        label.departure = base.arrival + policy.fuelStopDuration
        label.fuel = base.fuelOnArrival + gallons
        label.cost += gallons * node.fuelPrice
        label.penalty += node.fuelPenalty
        return label
    }

    private func overnight(_ base: Label, at node: Node) -> Label {
        let arrivalLocal = base.arrival + node.utcOffset
        var nextStart = floor(arrivalLocal / Units.secondsPerDay) * Units.secondsPerDay + policy.dayStart.secondsFromMidnight
        if nextStart <= arrivalLocal { nextStart += Units.secondsPerDay }
        let departureLocal = max(arrivalLocal + policy.minimumOvernightRest, nextStart)

        var label = base
        label.action = .overnight(rate: node.nightlyRate)
        label.departure = departureLocal - node.utcOffset
        label.cost += node.nightlyRate
        label.penalty += node.lodgingPenalty
        label.drivenToday = 0
        label.cutoffLocal = cutoff(forDayStartingAtLocal: departureLocal)
        label.dayIndex += 1
        return label
    }

    // MARK: Helpers

    /// Afternoon/evening arrivals, or arrivals after midnight but before the driving day starts.
    private func isReasonableCheckIn(_ arrivalLocal: Double) -> Bool {
        let timeOfDay = arrivalLocal - floor(arrivalLocal / Units.secondsPerDay) * Units.secondsPerDay
        return timeOfDay >= settings.earliestOvernightArrival.secondsFromMidnight
            || timeOfDay < policy.dayStart.secondsFromMidnight
    }

    private func cutoff(forDayStartingAtLocal local: Double) -> Double {
        if settings.allowNightDriving { return .infinity }
        let midnight = floor(local / Units.secondsPerDay) * Units.secondsPerDay
        return max(midnight + policy.dayEnd.secondsFromMidnight, local + settings.lateStartGrace)
    }

    private func score(cost: Double, penalty: Double, time: Double) -> Double {
        cost + penalty + (time - start) / Units.secondsPerHour * valueOfTime
    }

    /// Optimistic arrival time at the destination after reaching `node` at `arrival`.
    private func lowerBoundArrival(arrivingAt node: Node, at arrival: Double, isDestination: Bool) -> Double {
        if isDestination { return arrival }
        let remaining = problem.routeDuration - node.time + node.halfDetourTime
        let breaksNeeded = max(0, (remaining / policy.maxContinuousDriving).rounded(.up) - 1)
        let minimumDwell = min(policy.restStopDuration, policy.fuelStopDuration)
        return arrival + minimumDwell + remaining + breaksNeeded * minimumDwell
    }

    private mutating func insert(_ candidate: Label) {
        var label = candidate
        label.score = score(cost: label.cost, penalty: label.penalty, time: label.departure)
        var front = fronts[label.node]
        for existing in front where dominates(labels[existing], label) { return }
        front.removeAll { dominates(label, labels[$0]) }
        labels.append(label)
        front.append(labels.count - 1)
        if front.count > settings.maxLabelsPerNode { front = truncated(front) }
        fronts[label.node] = front
    }

    /// Pareto dominance. Money and time are compared separately (not via the blended score):
    /// an overnight stop erases time advantages, so an earlier-but-pricier label must not
    /// prune a cheaper one.
    private func dominates(_ a: Label, _ b: Label) -> Bool {
        a.cost + a.penalty <= b.cost + b.penalty + 1e-9
            && a.departure <= b.departure + 1e-6
            && a.fuel >= b.fuel - 1e-6
            && a.drivenToday <= b.drivenToday + 1e-6
            && a.cutoffLocal >= b.cutoffLocal - 1e-6
    }

    /// Keeps the best labels by score, plus the fullest tanks and earliest departures for diversity.
    private func truncated(_ front: [Int]) -> [Int] {
        let limit = settings.maxLabelsPerNode
        let byScore = front.sorted { labels[$0].score < labels[$1].score }
        let byFuel = front.sorted { labels[$0].fuel > labels[$1].fuel }
        let byDeparture = front.sorted { labels[$0].departure < labels[$1].departure }
        var kept: [Int] = []
        var seen = Set<Int>()
        for index in byScore.prefix(limit * 3 / 4) + byFuel.prefix(limit / 8) + byDeparture.prefix(limit / 8)
        where seen.insert(index).inserted {
            kept.append(index)
        }
        return kept
    }

    private func diagnose() -> InfeasibilityReason {
        let usableRangeMeters = Units.meters(fromMiles: (tank - reserve) * problem.vehicle.effectiveMilesPerGallon)
        let initialRangeMeters = Units.meters(
            fromMiles: max(0, tank * problem.vehicle.initialFuelFraction - originReserve) * problem.vehicle.effectiveMilesPerGallon
        )
        var previous = 0.0
        var range = initialRangeMeters
        for node in nodes.dropFirst() where node.capabilities.contains(.fuel) || node.candidateIndex == nil {
            if node.distance - previous > range { return .fuelRange(atMeters: previous) }
            previous = node.distance
            range = usableRangeMeters
        }
        if deadline != nil && prunedByDeadline { return .deadline }
        return .drivingLimits
    }

    private func reconstruct(_ final: Label) -> OptimizedSchedule {
        var chain: [Label] = []
        var cursor = final.parent
        while cursor > 0 {
            chain.append(labels[cursor])
            cursor = labels[cursor].parent
        }
        chain.reverse()

        var fuelCost = 0.0, lodgingCost = 0.0
        var previousDay = 0
        let stops: [ScheduledStop] = chain.map { label in
            let candidate = problem.candidates[nodes[label.node].candidateIndex!]
            let action: StopAction
            let arrivalDay = previousDay
            switch label.action {
            case let .refuel(gallons, price):
                action = .refuel(gallons: gallons, pricePerGallon: price)
                fuelCost += gallons * price
            case let .overnight(rate):
                action = .overnight(nightlyRate: rate)
                lodgingCost += rate
            default:
                action = .rest
            }
            previousDay = label.dayIndex
            return ScheduledStop(
                candidate: candidate,
                action: action,
                arrival: Date(timeIntervalSince1970: label.arrival),
                departure: Date(timeIntervalSince1970: label.departure),
                fuelOnArrival: label.fuelOnArrival,
                fuelOnDeparture: label.fuel,
                dayIndex: arrivalDay
            )
        }
        let gallonsBought = stops.reduce(0.0) { total, stop in
            if case let .refuel(gallons, _) = stop.action { return total + gallons }
            return total
        }
        fuelCost += (initialFuel - final.fuelOnArrival) * referenceFuelPrice
        return OptimizedSchedule(
            stops: stops,
            arrival: Date(timeIntervalSince1970: final.arrival),
            fuelOnArrival: final.fuelOnArrival,
            finalDayIndex: final.dayIndex,
            fuelCost: fuelCost,
            lodgingCost: lodgingCost,
            tollCost: problem.tollCostUSD,
            drivingDuration: final.drivingTotal,
            fuelGallonsUsed: initialFuel + gallonsBought - final.fuelOnArrival,
            referenceFuelPrice: referenceFuelPrice,
            score: final.score + problem.tollCostUSD
        )
    }
}
