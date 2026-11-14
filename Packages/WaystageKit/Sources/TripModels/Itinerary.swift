import Foundation

/// The purpose of a stop on the itinerary.
public enum StopKind: String, Codable, CaseIterable, Sendable {
    case origin
    /// A short break (rest area, gas station without fueling, or a safe exit).
    case rest
    /// Refuel; also counts as a rest break.
    case fuel
    /// Overnight stay.
    case lodging
    case destination

    public var displayName: String {
        switch self {
        case .origin: "Start"
        case .rest: "Rest stop"
        case .fuel: "Fuel stop"
        case .lodging: "Overnight stay"
        case .destination: "Destination"
        }
    }
}

/// Planned fuel purchase at a fuel stop.
public struct FuelPurchase: Codable, Hashable, Sendable {
    public var gallons: Double
    public var pricePerGallon: Double
    /// `true` when the price is a regional or default estimate rather than the station's price.
    public var isPriceEstimated: Bool

    public init(gallons: Double, pricePerGallon: Double, isPriceEstimated: Bool) {
        self.gallons = gallons
        self.pricePerGallon = pricePerGallon
        self.isPriceEstimated = isPriceEstimated
    }

    public var cost: Double { gallons * pricePerGallon }
}

/// Planned overnight stay.
public struct LodgingStay: Codable, Hashable, Sendable {
    public var nightlyRate: Double
    /// `true` when the rate is an estimate (no live rate available).
    public var isRateEstimated: Bool
    /// Rate source, e.g. "Expedia" or "Google".
    public var provider: String?
    public var bookingURL: URL?

    public init(nightlyRate: Double, isRateEstimated: Bool, provider: String? = nil, bookingURL: URL? = nil) {
        self.nightlyRate = nightlyRate
        self.isRateEstimated = isRateEstimated
        self.provider = provider
        self.bookingURL = bookingURL
    }
}

/// One stop of an itinerary, including the start and the destination.
public struct ItineraryStop: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: StopKind
    public var place: Place
    /// Planned arrival (nil for the origin).
    public var arrival: Date?
    /// Planned departure (nil for the destination).
    public var departure: Date?
    /// Distance along the route from the start, in meters.
    public var distanceFromStartMeters: Double
    /// Fuel in the tank on arrival, in gallons.
    public var fuelOnArrivalGallons: Double?
    public var fuelPurchase: FuelPurchase?
    public var lodging: LodgingStay?
    /// `true` for a generic "take the next safe exit" break where no facility was found.
    public var isRoadsidePullOff: Bool
    /// Zero-based travel day.
    public var dayIndex: Int

    public init(
        id: String = UUID().uuidString,
        kind: StopKind,
        place: Place,
        arrival: Date?,
        departure: Date?,
        distanceFromStartMeters: Double,
        fuelOnArrivalGallons: Double? = nil,
        fuelPurchase: FuelPurchase? = nil,
        lodging: LodgingStay? = nil,
        isRoadsidePullOff: Bool = false,
        dayIndex: Int
    ) {
        self.id = id
        self.kind = kind
        self.place = place
        self.arrival = arrival
        self.departure = departure
        self.distanceFromStartMeters = distanceFromStartMeters
        self.fuelOnArrivalGallons = fuelOnArrivalGallons
        self.fuelPurchase = fuelPurchase
        self.lodging = lodging
        self.isRoadsidePullOff = isRoadsidePullOff
        self.dayIndex = dayIndex
    }

    /// Time spent at the stop.
    public var dwellDuration: TimeInterval? {
        guard let arrival, let departure else { return nil }
        return departure.timeIntervalSince(arrival)
    }
}

/// Maneuver at the start of a navigation step (mirrors the Google Routes API `Maneuver` enum).
public enum Maneuver: String, Codable, CaseIterable, Sendable {
    case depart
    case straight
    case turnLeft, turnRight
    case turnSlightLeft, turnSlightRight
    case turnSharpLeft, turnSharpRight
    case uturnLeft, uturnRight
    case rampLeft, rampRight
    case merge
    case forkLeft, forkRight
    case roundaboutLeft, roundaboutRight
    case ferry
    case nameChange
    case arrive
    case unknown

    /// Maps a Google Routes API maneuver string (e.g. `TURN_SLIGHT_LEFT`).
    public init(googleValue: String?) {
        switch googleValue {
        case "DEPART": self = .depart
        case "STRAIGHT": self = .straight
        case "TURN_LEFT": self = .turnLeft
        case "TURN_RIGHT": self = .turnRight
        case "TURN_SLIGHT_LEFT": self = .turnSlightLeft
        case "TURN_SLIGHT_RIGHT": self = .turnSlightRight
        case "TURN_SHARP_LEFT": self = .turnSharpLeft
        case "TURN_SHARP_RIGHT": self = .turnSharpRight
        case "UTURN_LEFT": self = .uturnLeft
        case "UTURN_RIGHT": self = .uturnRight
        case "RAMP_LEFT": self = .rampLeft
        case "RAMP_RIGHT": self = .rampRight
        case "MERGE": self = .merge
        case "FORK_LEFT": self = .forkLeft
        case "FORK_RIGHT": self = .forkRight
        case "ROUNDABOUT_LEFT": self = .roundaboutLeft
        case "ROUNDABOUT_RIGHT": self = .roundaboutRight
        case "FERRY", "FERRY_TRAIN": self = .ferry
        case "NAME_CHANGE": self = .nameChange
        default: self = .unknown
        }
    }
}

/// One turn-by-turn instruction.
public struct NavigationStep: Codable, Hashable, Sendable {
    public var instruction: String
    public var maneuver: Maneuver
    public var distanceMeters: Double
    public var duration: TimeInterval
    /// Google-encoded polyline of the step geometry.
    public var encodedPolyline: String

    public init(
        instruction: String,
        maneuver: Maneuver,
        distanceMeters: Double,
        duration: TimeInterval,
        encodedPolyline: String
    ) {
        self.instruction = instruction
        self.maneuver = maneuver
        self.distanceMeters = distanceMeters
        self.duration = duration
        self.encodedPolyline = encodedPolyline
    }
}

/// Driving directions between two consecutive stops.
public struct RouteLeg: Codable, Hashable, Sendable {
    public var distanceMeters: Double
    public var duration: TimeInterval
    public var encodedPolyline: String
    public var steps: [NavigationStep]
    /// Estimated tolls for this leg in USD, when known.
    public var tollCostUSD: Double?

    public init(
        distanceMeters: Double,
        duration: TimeInterval,
        encodedPolyline: String,
        steps: [NavigationStep],
        tollCostUSD: Double? = nil
    ) {
        self.distanceMeters = distanceMeters
        self.duration = duration
        self.encodedPolyline = encodedPolyline
        self.steps = steps
        self.tollCostUSD = tollCostUSD
    }
}

/// Cost estimate in US dollars.
public struct CostBreakdown: Codable, Hashable, Sendable {
    /// Cost of all gas the trip burns: purchases, plus fuel already in the tank, minus fuel left over.
    public var fuel: Double
    public var lodging: Double
    public var tolls: Double

    public init(fuel: Double, lodging: Double, tolls: Double) {
        self.fuel = fuel
        self.lodging = lodging
        self.tolls = tolls
    }

    public static let zero = CostBreakdown(fuel: 0, lodging: 0, tolls: 0)

    public var total: Double { fuel + lodging + tolls }
}

/// Aggregate numbers for an itinerary.
public struct TripTotals: Codable, Hashable, Sendable {
    public var distanceMeters: Double
    /// Time spent moving.
    public var drivingDuration: TimeInterval
    /// Departure to arrival, including all stops.
    public var elapsedDuration: TimeInterval
    public var cost: CostBreakdown
    /// Gallons burned on the trip (including fuel that was already in the tank).
    public var fuelGallonsUsed: Double?
    /// Price per gallon used to value fuel that was already in the tank (or left over).
    public var referenceFuelPrice: Double?

    public init(
        distanceMeters: Double,
        drivingDuration: TimeInterval,
        elapsedDuration: TimeInterval,
        cost: CostBreakdown,
        fuelGallonsUsed: Double? = nil,
        referenceFuelPrice: Double? = nil
    ) {
        self.distanceMeters = distanceMeters
        self.drivingDuration = drivingDuration
        self.elapsedDuration = elapsedDuration
        self.cost = cost
        self.fuelGallonsUsed = fuelGallonsUsed
        self.referenceFuelPrice = referenceFuelPrice
    }
}

/// Something the user should know about a plan (relaxed preferences, estimates, …).
public struct PlanWarning: Codable, Hashable, Sendable, Identifiable {
    public enum Code: String, Codable, Sendable, CaseIterable {
        /// The deadline cannot be met; the plan arrives as early as possible instead.
        case deadlineMissed
        /// Driving days start earlier / end later than preferred.
        case extendedDrivingDay
        /// Breaks were shortened to the minimum.
        case shorterBreaks
        /// Some driving happens after the preferred end of day.
        case nightDriving
        /// No lodging found near the end of a day; the stop is an area to search.
        case lodgingAreaOnly
        /// A stretch longer than the car's range has no known gas station.
        case fuelGap
        /// Some prices are estimates.
        case estimatedPrices
        /// Live directions were unavailable; times are estimates.
        case estimatedDirections
        /// Some stop searches failed; generic breaks are used in those sections.
        case incompleteStopData
    }

    public var code: Code
    public var message: String
    public var id: String { code.rawValue + message }

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}

/// A day of travel, used to present the itinerary.
public struct ItineraryDay: Hashable, Sendable, Identifiable {
    public var index: Int
    public var stops: [ItineraryStop]
    public var id: Int { index }
}

/// A complete, schedulable trip plan.
public struct Itinerary: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var goal: OptimizationGoal
    public var request: TripRequest
    /// Ordered stops: the origin first, the destination last.
    public var stops: [ItineraryStop]
    /// `legs[i]` connects `stops[i]` to `stops[i + 1]`. May be empty when directions are
    /// fetched lazily during the drive.
    public var legs: [RouteLeg]
    public var totals: TripTotals
    public var warnings: [PlanWarning]
    /// Short route description, e.g. "I-80 E".
    public var routeSummary: String
    /// Encoded overview polyline of the whole route.
    public var overviewPolyline: String
    /// The driving policy actually applied (the requested one, possibly relaxed for feasibility).
    public var appliedPolicy: DrivingPolicy
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        goal: OptimizationGoal,
        request: TripRequest,
        stops: [ItineraryStop],
        legs: [RouteLeg],
        totals: TripTotals,
        warnings: [PlanWarning] = [],
        routeSummary: String = "",
        overviewPolyline: String = "",
        appliedPolicy: DrivingPolicy? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.goal = goal
        self.request = request
        self.stops = stops
        self.legs = legs
        self.totals = totals
        self.warnings = warnings
        self.routeSummary = routeSummary
        self.overviewPolyline = overviewPolyline
        self.appliedPolicy = appliedPolicy ?? request.policy
        self.createdAt = createdAt
    }

    /// Stops grouped by travel day.
    public var days: [ItineraryDay] {
        let grouped = Dictionary(grouping: stops, by: \.dayIndex)
        return grouped.keys.sorted().map { ItineraryDay(index: $0, stops: grouped[$0] ?? []) }
    }

    /// Number of overnight stays.
    public var nights: Int { stops.filter { $0.kind == .lodging }.count }

    public var arrival: Date? { stops.last?.arrival }

    /// Leg geometry for `stops[index] → stops[index + 1]`, if available.
    public func leg(after index: Int) -> RouteLeg? {
        legs.indices.contains(index) ? legs[index] : nil
    }
}
