import Foundation
import TripModels

/// Progress reported while a plan is computed.
public enum PlanningPhase: Equatable, Sendable {
    case findingRoute
    case findingStops(completed: Int, total: Int)
    case optimizing
    case finalizing
}

/// One way to drive the trip, planned for every optimization goal.
public struct RoutePlan: Sendable, Identifiable {
    public var id: String
    /// "via Salt Lake City"; nil when it is the only route (or no place sets it apart).
    public var name: String?
    /// The routing provider's description of the route, e.g. "I-80 E".
    public var summary: String
    /// Where to label the route on a map: where it is farthest from the other routes.
    public var labelCoordinate: GeoCoordinate
    public var itineraries: [OptimizationGoal: Itinerary]

    public init(
        id: String, name: String?, summary: String, labelCoordinate: GeoCoordinate,
        itineraries: [OptimizationGoal: Itinerary]
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.labelCoordinate = labelCoordinate
        self.itineraries = itineraries
    }

    /// Plans in display order (fastest, cheapest, balanced).
    public var options: [Itinerary] { OptimizationGoal.allCases.compactMap { itineraries[$0] } }

    /// The middle of an itinerary's route (its start when it has no geometry).
    static func middle(of itinerary: Itinerary) -> GeoCoordinate? {
        let geometry = PolylineGeometry(coordinates: (try? PolylineCodec.decode(itinerary.overviewPolyline)) ?? [])
        guard geometry.totalLength > 0 else { return itinerary.stops.first?.place.coordinate }
        return geometry.coordinate(atDistance: geometry.totalLength / 2)
    }
}

/// A search's outcome: one to three different routes, best first, each planned for every goal.
/// The UI shows them all and the user picks one route and one plan; only that plan is saved.
public struct PlanResult: Sendable {
    public var routes: [RoutePlan]
    public var recommendedGoal: OptimizationGoal

    public init(routes: [RoutePlan], recommendedGoal: OptimizationGoal) {
        self.routes = routes
        self.recommendedGoal = recommendedGoal
    }

    /// A single route's plans (e.g. a saved plan reopened).
    public init(itineraries: [OptimizationGoal: Itinerary], recommendedGoal: OptimizationGoal) {
        let shown = itineraries[recommendedGoal] ?? OptimizationGoal.allCases.compactMap { itineraries[$0] }.first
        let label = shown.flatMap(RoutePlan.middle) ?? GeoCoordinate(latitude: 0, longitude: 0)
        self.init(
            routes: [RoutePlan(id: "route-1", name: nil, summary: "", labelCoordinate: label, itineraries: itineraries)],
            recommendedGoal: recommendedGoal
        )
    }

    /// The best route's plans.
    public var itineraries: [OptimizationGoal: Itinerary] { routes.first?.itineraries ?? [:] }

    public var recommended: Itinerary? { itineraries[recommendedGoal] }

    /// The best route's plans in display order (fastest, cheapest, balanced).
    public var options: [Itinerary] { routes.first?.options ?? [] }
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
    /// Which different routes are offered (each costs extra place searches).
    public var alternatives = RouteAlternatives()
    /// Requests in flight per route, and routes analysed at once.
    public var maxConcurrentRequests = 4
    public var maxConcurrentRoutes = 3
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
        let corridors = try await candidateCorridors(for: request)

        // Stops along every route (each corridor's route and any toll-free version), in parallel.
        let prepared = corridors.flatMap(\.routes).map { prepare($0, request: request) }
        let counter = ProgressCounter(total: prepared.reduce(0) { $0 + $1.requestCount }, offset: 0, report: progress)
        let analyses = await concurrentMap(prepared, limit: configuration.maxConcurrentRoutes) { [self] route in
            await analyze(route, request: request, counter: counter)
        }
        try Task.checkCancellation()

        progress(.optimizing)
        var groups: [[RouteAnalysis]] = []
        var next = 0
        for corridor in corridors {
            groups.append(Array(analyses[next..<next + corridor.routes.count]))
            next += corridor.routes.count
        }

        progress(.finalizing)
        let planned = await concurrentMap(groups, limit: configuration.maxConcurrentRoutes) { [self] group in
            await plans(along: group, request: request)
        }
        try Task.checkCancellation()

        let shapes = corridors.map { RouteAlternatives.coordinates(of: $0.primary) }
        let names = Self.routeNames(
            places: configuration.alternatives.names(for: shapes), summaries: corridors.map(\.primary.summary)
        )
        let labels = configuration.alternatives.labelPoints(for: shapes)
        let routes = planned.enumerated().compactMap { index, itineraries -> RoutePlan? in
            guard !itineraries.isEmpty else { return nil }
            return RoutePlan(
                id: "route-\(index + 1)",
                name: names[index],
                summary: corridors[index].primary.summary,
                labelCoordinate: labels.indices.contains(index) ? labels[index] : (shapes[index].first ?? request.origin.coordinate),
                itineraries: itineraries
            )
        }
        guard !routes.isEmpty else { throw PlanningError.noRoute }
        // Best first, for the plan style the user prefers (ties keep the quicker route first).
        let goal = request.goal
        let value = request.policy.valueOfTimePerHour
        let ranked = routes.enumerated().sorted { lhs, rhs in
            let left = lhs.element.itineraries[goal].map { Self.rank($0, for: goal, valueOfTimePerHour: value) }
            let right = rhs.element.itineraries[goal].map { Self.rank($0, for: goal, valueOfTimePerHour: value) }
            switch (left, right) {
            case let (left?, right?): return left != right ? left < right : lhs.offset < rhs.offset
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.offset < rhs.offset
            }
        }.map(\.element)
        return PlanResult(routes: ranked, recommendedGoal: goal)
    }

    /// Names for the routes shown together: a place only that route passes ("via Las Vegas"),
    /// else the provider's description if no other route shares it ("via I-80 E"), else its
    /// number. A single route needs no name.
    static func routeNames(places: [String?], summaries: [String]) -> [String?] {
        guard summaries.count > 1 else { return summaries.map { _ in nil } }
        return summaries.indices.map { index in
            if places.indices.contains(index), let place = places[index] { return place }
            let summary = summaries[index].trimmingCharacters(in: .whitespaces)
            if !summary.isEmpty, summaries.filter({ $0.trimmingCharacters(in: .whitespaces) == summary }).count == 1 {
                return "via \(summary)"
            }
            return "Route \(index + 1)"
        }
    }

    /// Every goal's plan along one corridor (its route, or its toll-free version where cheaper).
    private func plans(along analyses: [RouteAnalysis], request: TripRequest) async -> [OptimizationGoal: Itinerary] {
        var drafts: [OptimizationGoal: (Itinerary, RouteAnalysis)] = [:]
        for goal in OptimizationGoal.allCases {
            drafts[goal] = bestDraft(for: goal, request: request, analyses: analyses)
        }
        var finalized: [OptimizationGoal: Itinerary] = [:]
        var cache: [String: Itinerary] = [:]
        for goal in OptimizationGoal.allCases {
            guard let (draft, analysis) = drafts[goal] else { continue }
            let signature = draft.stops.map(\.id).joined(separator: "|") + "#\(analysis.route.summary)#\(analysis.route.distanceMeters)"
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
        return Self.consistentOptions(finalized, valueOfTimePerHour: request.policy.valueOfTimePerHour)
    }

    /// How good a plan is for `goal`: a met deadline first, then fewer relaxed preferences, then
    /// the goal's objective. Lower is better.
    static func rank(_ itinerary: Itinerary, for goal: OptimizationGoal, valueOfTimePerHour: Double) -> PlanRank {
        let hours = itinerary.totals.elapsedDuration / Units.secondsPerHour
        let cost = itinerary.totals.cost.total
        let objective: Double = switch goal {
        case .fastest: hours + cost * 1e-6
        case .cheapest: cost + hours * 1e-6
        case .balanced: cost + hours * valueOfTimePerHour
        }
        return PlanRank(
            missedDeadline: itinerary.warnings.contains { $0.code == .deadlineMissed } ? 1 : 0,
            relaxations: itinerary.warnings.filter { relaxationCodes.contains($0.code) }.count,
            objective: objective
        )
    }

    struct PlanRank: Comparable {
        var missedDeadline: Int
        var relaxations: Int
        var objective: Double

        static func < (lhs: PlanRank, rhs: PlanRank) -> Bool {
            (lhs.missedDeadline, lhs.relaxations, lhs.objective) < (rhs.missedDeadline, rhs.relaxations, rhs.objective)
        }
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
            func isBetter(_ lhs: Itinerary, _ rhs: Itinerary) -> Bool {
                let left = rank(lhs, for: goal, valueOfTimePerHour: valueOfTimePerHour)
                let right = rank(rhs, for: goal, valueOfTimePerHour: valueOfTimePerHour)
                if left != right { return left < right }
                return lhs.goal == goal && rhs.goal != goal
            }
            let best = all.min(by: isBetter) ?? own
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

    /// The routes worth planning: the provider's route and alternatives, a toll-free version, and
    /// routes through highway hubs off those, narrowed to a few different, reasonable corridors.
    private func candidateCorridors(for request: TripRequest) async throws -> [RouteAlternatives.Corridor] {
        let origin = request.origin.coordinate, destination = request.destination.coordinate
        var routes: [ComputedRoute]
        do {
            routes = try await routing.computeRoutes(RouteQuery(
                origin: origin, destination: destination, departure: request.departure, computeAlternatives: true
            ))
        } catch {
            throw PlanningError.routingFailed(String(describing: error))
        }
        guard !routes.isEmpty else { throw PlanningError.noRoute }

        // Tolls matter to cost-conscious goals: also consider a toll-free version.
        if routes.contains(where: { ($0.tollCostUSD ?? 0) > 0 }),
           let tollFree = try? await routing.computeRoutes(RouteQuery(
               origin: origin, destination: destination, departure: request.departure, avoidTolls: true
           )).first {
            routes.append(tollFree)
        }

        // Other corridors: through highway hubs away from the routes found so far.
        let alternatives = configuration.alternatives
        let hubs = alternatives.viaHubs(from: origin, to: destination, avoiding: routes.map(RouteAlternatives.coordinates(of:)))
        let routing = routing
        let departure = request.departure
        let viaRoutes = await concurrentMap(hubs, limit: configuration.maxConcurrentRequests) { hub in
            try? await routing.computeRoutes(RouteQuery(origin: origin, destination: destination, vias: [hub.coordinate], departure: departure)).first
        }
        routes += viaRoutes.compactMap { $0 }

        let corridors = alternatives.select(routes)
        return corridors.isEmpty ? [RouteAlternatives.Corridor(primary: routes[0])] : corridors
    }

    // MARK: - Candidate discovery

    /// A route with the searches its stops need.
    struct PreparedRoute: Sendable {
        var route: ComputedRoute
        var profile: RouteProfile
        var chunks: [RouteProfile.Chunk]
        var windows: [LodgingWindow]
        var searches: [(AlongRouteSearch, ClosedRange<Double>)]
        /// Requests the analysis will make (for progress).
        var requestCount: Int
    }

    private func prepare(_ route: ComputedRoute, request: TripRequest) -> PreparedRoute {
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
        let requestCount = searches.count + (lodging == nil ? 0 : windows.count) + (fuelPrices == nil ? 0 : chunks.count)
        return PreparedRoute(route: route, profile: profile, chunks: chunks, windows: windows, searches: searches, requestCount: requestCount)
    }

    private func analyze(_ prepared: PreparedRoute, request: TripRequest, counter: ProgressCounter) async -> RouteAnalysis {
        let route = prepared.route, profile = prepared.profile, chunks = prepared.chunks, windows = prepared.windows
        let searches = prepared.searches
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
