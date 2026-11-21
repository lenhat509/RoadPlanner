import Foundation

/// What the optimizer minimizes.
public enum OptimizationGoal: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Minimize total elapsed trip time.
    case fastest
    /// Minimize fuel + lodging + tolls.
    case cheapest

    /// Plans and settings saved before 1.2.0 can say "balanced", no longer offered: they open as
    /// the fastest.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OptimizationGoal(rawValue: raw) ?? .fastest
    }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fastest: "Fastest"
        case .cheapest: "Cheapest"
        }
    }
}

/// Problems that make a `TripRequest` unplannable.
public enum TripRequestError: String, Error, Codable, CaseIterable, Sendable {
    case invalidOrigin
    case invalidDestination
    case originEqualsDestination
    case invalidFuelEconomy
    case invalidTankCapacity
    case invalidFuelLevel
    case deadlineBeforeDeparture
    case invalidRestInterval
    case invalidDailyDriving
    case invalidFuelReserve
    /// More than `RequiredStop.maximumCount` places to visit.
    case tooManyStops
    /// More stops to keep than one Google route can go through.
    case tooManyKeptStops
    case invalidStop
    case invalidStay

    public var message: String {
        switch self {
        case .invalidOrigin: "Choose a starting point."
        case .invalidDestination: "Choose a destination."
        case .originEqualsDestination: "Start and destination must be different."
        case .invalidFuelEconomy: "Enter your car's fuel economy (1–150 MPG)."
        case .invalidTankCapacity: "Tank size must be between 2 and 60 gallons."
        case .invalidFuelLevel: "Starting fuel level must be between 0% and 100%."
        case .deadlineBeforeDeparture: "Arrival time must be after the departure time."
        case .invalidRestInterval: "Rest interval must be between 30 minutes and 5 hours."
        case .invalidDailyDriving: "Daily driving must be at least as long as the rest interval."
        case .invalidFuelReserve: "Minimum fuel level must be between 5% and 50% of the tank."
        case .tooManyStops: "You can add up to \(RequiredStop.maximumCount) places to visit on the way."
        case .tooManyKeptStops: "A trip can keep up to \(RequiredStop.maximumRouted) stops. Remove a few, or stop keeping them."
        case .invalidStop: "Choose a place for each stop on the way."
        case .invalidStay: "A stop on the way can last 5 minutes to 12 hours."
        }
    }
}

/// A stop the plan has to include, in route order: a place the traveler wants to visit, or a stop
/// kept from an earlier plan (a break, a fuel stop, tonight's hotel).
public struct RequiredStop: Codable, Hashable, Sendable, Identifiable {
    public enum Purpose: String, Codable, Sendable {
        /// A place to visit, for `stay`.
        case visit
        /// A kept break, fuel stop or hotel.
        case rest, fuel, lodging
    }

    /// Places to visit a trip can have (the plan form's limit).
    public static let maximumCount = 10
    /// Stops of any kind a trip can keep: one Google route goes through at most 25.
    public static let maximumRouted = 25
    /// How long a visit can last.
    public static let allowedStay: ClosedRange<TimeInterval> = 5 * 60...12 * 3_600

    public var id: String
    public var place: Place
    public var purpose: Purpose
    /// How long to stay (visits); kept breaks and fuel stops use the driving policy's stop length.
    public var stay: TimeInterval?
    /// A kept hotel's rate and booking details, as known when it was chosen.
    public var lodging: LodgingStay?
    /// A kept fuel stop's price, as known when it was chosen (not stored for Google prices).
    public var fuelPricePerGallon: Double?

    public init(
        id: String = UUID().uuidString,
        place: Place,
        purpose: Purpose,
        stay: TimeInterval? = nil,
        lodging: LodgingStay? = nil,
        fuelPricePerGallon: Double? = nil
    ) {
        self.id = id
        self.place = place
        self.purpose = purpose
        self.stay = stay
        self.lodging = lodging
        self.fuelPricePerGallon = fuelPricePerGallon
    }

    /// A place to visit.
    public static func visit(_ place: Place, stay: TimeInterval) -> RequiredStop {
        RequiredStop(place: place, purpose: .visit, stay: stay)
    }
}

/// Where a trip starts when it is planned again during a drive.
public struct StartState: Codable, Hashable, Sendable {
    /// Driving already done today, which counts toward the daily limit.
    public var drivenToday: TimeInterval

    public init(drivenToday: TimeInterval) {
        self.drivenToday = drivenToday
    }
}

/// Everything the planner needs to build an itinerary.
public struct TripRequest: Codable, Hashable, Sendable {
    public var origin: Place
    public var destination: Place
    public var departure: Date
    /// Optional hard deadline for arriving at the destination.
    public var arriveBy: Date?
    public var vehicle: Vehicle
    public var policy: DrivingPolicy
    public var goal: OptimizationGoal
    /// Number of adult travellers (used for lodging availability).
    public var travelers: Int
    /// Stops the plan must include, in route order (nil: none). Optional so trips saved before
    /// 1.2.0 still decode.
    public var stops: [RequiredStop]?
    /// Places the traveler removed from an earlier plan (Google place IDs).
    public var avoidedPlaceIDs: [String]?
    /// Driving already done today, when the rest of a trip is planned again during a drive.
    public var startState: StartState?

    /// The stops the plan must include, in route order.
    public var requiredStops: [RequiredStop] { stops ?? [] }

    public init(
        origin: Place,
        destination: Place,
        departure: Date,
        arriveBy: Date? = nil,
        vehicle: Vehicle,
        policy: DrivingPolicy = .standard,
        goal: OptimizationGoal = .fastest,
        travelers: Int = 2,
        stops: [RequiredStop]? = nil,
        avoidedPlaceIDs: [String]? = nil,
        startState: StartState? = nil
    ) {
        self.origin = origin
        self.destination = destination
        self.departure = departure
        self.arriveBy = arriveBy
        self.vehicle = vehicle
        self.policy = policy
        self.goal = goal
        self.travelers = travelers
        self.stops = stops.flatMap { $0.isEmpty ? nil : $0 }
        self.avoidedPlaceIDs = avoidedPlaceIDs.flatMap { $0.isEmpty ? nil : $0 }
        self.startState = startState
    }

    /// Validates the request. An empty result means the request can be planned.
    public func validationErrors() -> [TripRequestError] {
        var errors: [TripRequestError] = []
        if !origin.coordinate.isValid { errors.append(.invalidOrigin) }
        if !destination.coordinate.isValid { errors.append(.invalidDestination) }
        if GeoMath.distance(origin.coordinate, destination.coordinate) < 100 { errors.append(.originEqualsDestination) }
        if !(vehicle.milesPerGallon > 0 && vehicle.milesPerGallon <= 150) { errors.append(.invalidFuelEconomy) }
        if !(2...60).contains(vehicle.tankCapacityGallons) { errors.append(.invalidTankCapacity) }
        if !(0...1).contains(vehicle.initialFuelFraction) { errors.append(.invalidFuelLevel) }
        if let arriveBy, arriveBy <= departure { errors.append(.deadlineBeforeDeparture) }
        if !DrivingPolicy.allowedContinuousDriving.contains(policy.maxContinuousDriving) {
            errors.append(.invalidRestInterval)
        }
        if policy.maxDailyDriving < policy.maxContinuousDriving { errors.append(.invalidDailyDriving) }
        if !DrivingPolicy.allowedFuelReserve.contains(policy.fuelReserveFraction) { errors.append(.invalidFuelReserve) }
        let stops = requiredStops
        if stops.count(where: { $0.purpose == .visit }) > RequiredStop.maximumCount { errors.append(.tooManyStops) }
        if stops.count > RequiredStop.maximumRouted { errors.append(.tooManyKeptStops) }
        if stops.contains(where: { !$0.place.coordinate.isValid }) { errors.append(.invalidStop) }
        if stops.contains(where: { $0.purpose == .visit && !RequiredStop.allowedStay.contains($0.stay ?? 0) }) {
            errors.append(.invalidStay)
        }
        return errors
    }
}
