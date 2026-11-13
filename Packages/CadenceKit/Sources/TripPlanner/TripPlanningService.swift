import Foundation
import TripModels

/// Progress reported while a plan is computed.
public enum PlanningPhase: Equatable, Sendable {
    case findingRoute
    case findingStops(completed: Int, total: Int)
    case optimizing
    case finalizing
}

/// Plans for every optimization goal; the UI lets the user compare and pick one.
public struct PlanResult: Sendable {
    public var itineraries: [OptimizationGoal: Itinerary]
    public var recommendedGoal: OptimizationGoal

    public init(itineraries: [OptimizationGoal: Itinerary], recommendedGoal: OptimizationGoal) {
        self.itineraries = itineraries
        self.recommendedGoal = recommendedGoal
    }

    public var recommended: Itinerary? { itineraries[recommendedGoal] }

    /// Options in display order (fastest, cheapest, balanced).
    public var options: [Itinerary] { OptimizationGoal.allCases.compactMap { itineraries[$0] } }
}

public enum PlanningError: Error, Equatable, Sendable {
    case invalidRequest([TripRequestError])
    case noRoute
    case routingFailed(String)

    public var message: String {
        switch self {
        case let .invalidRequest(errors): errors.map(\.message).joined(separator: "\n")
        case .noRoute: "No driving route was found between these places."
        case let .routingFailed(reason): "Couldn't get directions: \(reason)"
        }
    }
}

/// The planning use case, abstracted for view models and tests.
public protocol TripPlanning: Sendable {
    func plan(_ request: TripRequest, progress: @escaping @Sendable (PlanningPhase) -> Void) async throws -> PlanResult
}

public struct TripPlanningConfiguration: Sendable {
    /// Route sections searched per Places request.
    public var searchChunkDuration: TimeInterval = 2 * 3_600
    /// Route alternatives evaluated (each costs extra place searches).
    public var maxRoutes = 2
    public var maxConcurrentRequests = 4
    public var lodgingSearchRadiusMeters = 25_000.0
    /// Google Routes API limit on intermediate waypoints per request.
    public var maxIntermediatesPerRequest = 25
    public var candidateBuilder = CandidateBuilder()
    public var pricing = PricingDefaults.standard

    public init() {}
}

/// Orchestrates routing, place search, pricing, optimization and final directions.
public final class TripPlanningService: TripPlanning, Sendable {
    private let routing: any RoutingProvider
    private let places: any PlaceSearchProvider
    private let lodging: (any LodgingRateProvider)?
    private let fuelPrices: (any RegionalFuelPriceProvider)?
    private let configuration: TripPlanningConfiguration

    public init(
        routing: any RoutingProvider,
        places: any PlaceSearchProvider,
        lodging: (any LodgingRateProvider)? = nil,
        fuelPrices: (any RegionalFuelPriceProvider)? = nil,
        configuration: TripPlanningConfiguration = TripPlanningConfiguration()
    ) {
        self.routing = routing
        self.places = places
        self.lodging = lodging
        self.fuelPrices = fuelPrices
        self.configuration = configuration
    }

    /// Everything known about one candidate route.
    struct RouteAnalysis: Sendable {
        var route: ComputedRoute
        var profile: RouteProfile
        var candidates: [StopCandidate]
        var warnings: [PlanWarning]
    }

    public func plan(
        _ request: TripRequest,
        progress: @escaping @Sendable (PlanningPhase) -> Void = { _ in }
    ) async throws -> PlanResult {
        let errors = request.validationErrors()
        guard errors.isEmpty else { throw PlanningError.invalidRequest(errors) }

        progress(.findingRoute)
        let routes = try await candidateRoutes(for: request)

        var analyses: [RouteAnalysis] = []
        for (index, route) in routes.enumerated() {
            try Task.checkCancellation()
            analyses.append(await analyze(route, request: request, routeIndex: index, routeCount: routes.count, progress: progress))
        }

        progress(.optimizing)
        var drafts: [OptimizationGoal: (Itinerary, RouteAnalysis)] = [:]
        for goal in OptimizationGoal.allCases {
            try Task.checkCancellation()
            drafts[goal] = bestDraft(for: goal, request: request, analyses: analyses)
        }

        progress(.finalizing)
        var finalized: [OptimizationGoal: Itinerary] = [:]
        var cache: [String: Itinerary] = [:]
        for goal in OptimizationGoal.allCases {
            guard let (draft, analysis) = drafts[goal] else { continue }
            let signature = draft.stops.map(\.id).joined(separator: "|") + "#\(analysis.route.summary)"
            if let cached = cache[signature] {
                var copy = cached
                copy.id = UUID()
                copy.goal = goal
                finalized[goal] = copy
                continue
            }
            let itinerary = await finalize(draft, goal: goal, request: request, analysis: analysis)
            cache[signature] = itinerary
            finalized[goal] = itinerary
        }
        return PlanResult(
            itineraries: Self.consistentOptions(finalized, valueOfTimePerHour: request.policy.valueOfTimePerHour),
            recommendedGoal: request.goal
        )
    }

    /// Re-timing with real directions can reorder plans slightly, so each option is replaced by
    /// whichever finalized plan is best for *its* goal. This guarantees that "Fastest" arrives no
    /// later and "Cheapest" costs no more than any other option shown. Feasibility still comes
    /// first: a plan that meets the deadline with fewer relaxed preferences always ranks higher.
    static func consistentOptions(
        _ itineraries: [OptimizationGoal: Itinerary],
        valueOfTimePerHour: Double
    ) -> [OptimizationGoal: Itinerary] {
        let all = itineraries.values.sorted { $0.goal.rawValue < $1.goal.rawValue }
        var result: [OptimizationGoal: Itinerary] = [:]
        for (goal, own) in itineraries {
            func rank(_ itinerary: Itinerary) -> (Int, Int, Double, Int) {
                let hours = itinerary.totals.elapsedDuration / Units.secondsPerHour
                let cost = itinerary.totals.cost.total
                let objective: Double = switch goal {
                case .fastest: hours + cost * 1e-6
                case .cheapest: cost + hours * 1e-6
                case .balanced: cost + hours * valueOfTimePerHour
                }
                let missedDeadline = itinerary.warnings.contains { $0.code == .deadlineMissed } ? 1 : 0
                let relaxations = itinerary.warnings.filter { relaxationCodes.contains($0.code) }.count
                return (missedDeadline, relaxations, objective, itinerary.goal == goal ? 0 : 1)
            }
            let best = all.min { rank($0) < rank($1) } ?? own
            if best.goal == goal {
                result[goal] = best
            } else {
                var copy = best
                copy.id = UUID()
                copy.goal = goal
                result[goal] = copy
            }
        }
        return result
    }

    private static let relaxationCodes: Set<PlanWarning.Code> = [
        .extendedDrivingDay, .shorterBreaks, .nightDriving, .lodgingAreaOnly, .fuelGap,
    ]

    // MARK: - Routing

    private func candidateRoutes(for request: TripRequest) async throws -> [ComputedRoute] {
        var routes: [ComputedRoute]
        do {
            routes = try await routing.computeRoutes(RouteQuery(
                origin: request.origin.coordinate,
                destination: request.destination.coordinate,
                departure: request.departure,
                computeAlternatives: true
            ))
        } catch {
            throw PlanningError.routingFailed(String(describing: error))
        }
        guard !routes.isEmpty else { throw PlanningError.noRoute }

        // Tolls matter to cost-conscious goals: also consider a toll-free alternative.
        if routes.contains(where: { ($0.tollCostUSD ?? 0) > 0 }),
           let tollFree = try? await routing.computeRoutes(RouteQuery(
               origin: request.origin.coordinate,
               destination: request.destination.coordinate,
               departure: request.departure,
               avoidTolls: true
           )).first {
            routes.insert(tollFree, at: min(1, routes.count))
        }
        var unique: [ComputedRoute] = []
        for route in routes where !unique.contains(where: { Self.isSameRoute($0, route) }) {
            unique.append(route)
        }
        return Array(unique.prefix(configuration.maxRoutes))
    }

    /// Alternatives within 1 km and 2 minutes of each other are treated as the same route.
    private static func isSameRoute(_ lhs: ComputedRoute, _ rhs: ComputedRoute) -> Bool {
        abs(lhs.distanceMeters - rhs.distanceMeters) < 1_000 && abs(lhs.duration - rhs.duration) < 120
    }

    // MARK: - Candidate discovery

    private func analyze(
        _ route: ComputedRoute,
        request: TripRequest,
        routeIndex: Int,
        routeCount: Int,
        progress: @escaping @Sendable (PlanningPhase) -> Void
    ) async -> RouteAnalysis {
        let profile = route.profile()
        let chunks = profile.chunks(maxDuration: configuration.searchChunkDuration)
        let windows = LodgingWindowEstimator().windows(
            routeDuration: profile.totalDuration,
            departure: request.departure,
            utcOffset: request.origin.utcOffsetSeconds,
            policy: request.policy
        )

        var searches: [(AlongRouteSearch, ClosedRange<Double>)] = []
        for chunk in chunks where chunk.coordinates.count >= 2 {
            let polyline = PolylineCodec.encode(GeoMath.simplify(chunk.coordinates, minimumSpacingMeters: 250))
            let range = chunk.startDistance...chunk.endDistance
            let duration = chunk.endTime - chunk.startTime
            let origin = chunk.coordinates[0]
            searches.append((AlongRouteSearch(category: .fuel, encodedPolyline: polyline, origin: origin, sectionDuration: duration), range))
            searches.append((AlongRouteSearch(category: .rest, encodedPolyline: polyline, origin: origin, sectionDuration: duration), range))
            let needsLodging = windows.contains { $0.routeTimeRange.overlaps(chunk.startTime...chunk.endTime) }
            if needsLodging {
                searches.append((AlongRouteSearch(category: .lodging, encodedPolyline: polyline, origin: origin, sectionDuration: duration), range))
            }
        }

        let total = searches.count + windows.count + chunks.count
        let counter = ProgressCounter(total: total * routeCount, offset: total * routeIndex, report: progress)
        let placesProvider = places
        let placeResults: [Result<[FoundPlace], Error>] = await concurrentMap(searches, limit: configuration.maxConcurrentRequests) { search, range in
            defer { counter.increment() }
            do {
                let found = try await placesProvider.searchAlongRoute(search)
                return .success(found.map { place in
                    var place = place
                    place.searchRange = range
                    return place
                })
            } catch {
                return .failure(error)
            }
        }

        var offers: [LodgingOffer] = []
        if let lodging {
            let queries = windows.map { window in
                LodgingQuery(
                    center: profile.coordinate(atTime: (window.routeTimeRange.lowerBound + window.routeTimeRange.upperBound) / 2),
                    radiusMeters: configuration.lodgingSearchRadiusMeters,
                    checkIn: window.checkIn,
                    checkOut: window.checkIn.addingTimeInterval(Units.secondsPerDay),
                    adults: request.travelers
                )
            }
            let results = await concurrentMap(queries, limit: configuration.maxConcurrentRequests) { query in
                defer { counter.increment() }
                return (try? await lodging.offers(for: query)) ?? []
            }
            offers = results.flatMap { $0 }
        }

        var regionalPrices: [(GeoCoordinate, Double)] = []
        if let fuelPrices {
            let midpoints = chunks.map { profile.geometry.coordinate(atDistance: ($0.startDistance + $0.endDistance) / 2) }
            let fuelType = request.vehicle.fuelType
            let prices = await concurrentMap(midpoints, limit: configuration.maxConcurrentRequests) { point in
                defer { counter.increment() }
                return try? await fuelPrices.averagePrice(near: point, fuelType: fuelType)
            }
            regionalPrices = zip(midpoints, prices).compactMap { point, price in price.map { (point, $0) } }
        }

        var warnings: [PlanWarning] = []
        let failures = placeResults.filter { if case .failure = $0 { return true } else { return false } }.count
        if failures > 0 {
            warnings.append(PlanWarning(
                code: .incompleteStopData,
                message: "Stop information is incomplete for parts of the route; generic breaks are planned there."
            ))
        }
        let found = placeResults.flatMap { (try? $0.get()) ?? [] }
        let candidates = configuration.candidateBuilder.build(
            profile: profile,
            places: found,
            lodgingOffers: offers,
            fuelType: request.vehicle.fuelType,
            regionalFuelPrice: { coordinate in
                regionalPrices.min { GeoMath.distance($0.0, coordinate) < GeoMath.distance($1.0, coordinate) }?.1
            }
        )
        return RouteAnalysis(route: route, profile: profile, candidates: candidates, warnings: warnings)
    }

    // MARK: - Optimization

    private func bestDraft(
        for goal: OptimizationGoal,
        request: TripRequest,
        analyses: [RouteAnalysis],
        safetyMargin: Double = 1
    ) -> (Itinerary, RouteAnalysis)? {
        var best: (FeasibleSchedule, RouteAnalysis)?
        for analysis in analyses {
            let feasible = solve(goal: goal, request: request, analysis: analysis, safetyMargin: safetyMargin)
            guard let current = best else { best = (feasible, analysis); continue }
            if isBetter(feasible, than: current.0) { best = (feasible, analysis) }
        }
        guard let (feasible, analysis) = best else { return nil }
        let itinerary = ItineraryAssembler().assemble(
            request: request,
            goal: goal,
            profile: analysis.profile,
            feasible: feasible,
            overviewPolyline: analysis.route.encodedPolyline,
            additionalWarnings: analysis.warnings
        )
        return (itinerary, analysis)
    }

    /// Feasibility first: fewer relaxations and a met deadline beat a better score.
    private func isBetter(_ lhs: FeasibleSchedule, than rhs: FeasibleSchedule) -> Bool {
        if lhs.deadlineMet != rhs.deadlineMet { return lhs.deadlineMet }
        if lhs.level != rhs.level { return lhs.level < rhs.level }
        return lhs.schedule.score < rhs.schedule.score
    }

    private func solve(goal: OptimizationGoal, request: TripRequest, analysis: RouteAnalysis, safetyMargin: Double) -> FeasibleSchedule {
        var policy = request.policy
        policy.maxContinuousDriving *= safetyMargin
        policy.maxDailyDriving *= safetyMargin
        let planner = FeasibilityPlanner(policy: policy, pricing: configuration.pricing)
        let problem = OptimizationProblem(profile: analysis.profile, candidates: analysis.candidates, request: request, goal: goal)
        var feasible = planner.solve(problem)
        // Report against the user's limits, not the internal safety margin.
        feasible.appliedPolicy.maxContinuousDriving = request.policy.maxContinuousDriving
        feasible.appliedPolicy.maxDailyDriving = max(request.policy.maxDailyDriving, feasible.appliedPolicy.maxDailyDriving / safetyMargin)
        return feasible
    }

    // MARK: - Final directions

    private func finalize(_ draft: Itinerary, goal: OptimizationGoal, request: TripRequest, analysis: RouteAnalysis) async -> Itinerary {
        guard let legs = await directions(for: draft) else {
            var estimated = draft
            estimated.warnings.append(PlanWarning(
                code: .estimatedDirections,
                message: "Turn-by-turn directions will be loaded during the drive; times are estimates."
            ))
            return estimated
        }
        let retimed = ScheduleRetimer().retime(draft, legs: legs)
        let validator = ScheduleValidator()
        if validator.violations(in: retimed).isEmpty { return retimed }

        // Real directions took longer than estimated (detours, traffic). Re-plan once with a margin.
        guard let (corrected, _) = bestDraft(for: goal, request: request, analyses: [analysis], safetyMargin: 0.9),
              let correctedLegs = await directions(for: corrected) else { return retimed }
        let correctedRetimed = ScheduleRetimer().retime(corrected, legs: correctedLegs)
        let before = validator.violations(in: retimed).count
        let after = validator.violations(in: correctedRetimed).count
        return after <= before ? correctedRetimed : retimed
    }

    /// Directions for every leg, batching waypoints to respect the API limit.
    private func directions(for itinerary: Itinerary) async -> [RouteLeg]? {
        let stops = itinerary.stops
        guard stops.count >= 2 else { return nil }
        let batchSize = configuration.maxIntermediatesPerRequest + 1
        var legs: [RouteLeg] = []
        var start = 0
        while start < stops.count - 1 {
            let end = min(stops.count - 1, start + batchSize)
            let batch = Array(stops[start...end])
            let query = RouteQuery(
                origin: batch[0].place.coordinate,
                destination: batch[batch.count - 1].place.coordinate,
                intermediates: batch.dropFirst().dropLast().map(\.place.coordinate),
                departure: batch[0].departure
            )
            guard let route = try? await routing.computeRoutes(query).first, route.legs.count == batch.count - 1 else {
                return nil
            }
            legs += route.legs
            start = end
        }
        return legs
    }
}

/// Thread-safe progress counter for concurrent searches.
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: Int
    private let total: Int
    private let report: @Sendable (PlanningPhase) -> Void

    init(total: Int, offset: Int, report: @escaping @Sendable (PlanningPhase) -> Void) {
        self.total = max(1, total)
        self.completed = offset
        self.report = report
    }

    func increment() {
        lock.lock()
        completed += 1
        let value = completed
        lock.unlock()
        report(.findingStops(completed: value, total: total))
    }
}

/// Maps `items` concurrently with at most `limit` tasks in flight, preserving order.
func concurrentMap<Item: Sendable, Output: Sendable>(
    _ items: [Item],
    limit: Int,
    _ transform: @escaping @Sendable (Item) async -> Output
) async -> [Output] {
    guard !items.isEmpty else { return [] }
    return await withTaskGroup(of: (Int, Output).self) { group in
        var results = [Output?](repeating: nil, count: items.count)
        var next = 0
        for _ in 0..<min(max(1, limit), items.count) {
            let index = next
            group.addTask { (index, await transform(items[index])) }
            next += 1
        }
        while let (index, output) = await group.next() {
            results[index] = output
            if next < items.count {
                let index = next
                group.addTask { (index, await transform(items[index])) }
                next += 1
            }
        }
        return results.compactMap { $0 }
    }
}
