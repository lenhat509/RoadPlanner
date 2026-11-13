import Foundation

/// What the optimizer minimizes.
public enum OptimizationGoal: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Minimize total elapsed trip time.
    case fastest
    /// Minimize fuel + lodging + tolls.
    case cheapest
    /// Minimize cost + time × value-of-time.
    case balanced

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fastest: "Fastest"
        case .cheapest: "Cheapest"
        case .balanced: "Balanced"
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
        }
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

    public init(
        origin: Place,
        destination: Place,
        departure: Date,
        arriveBy: Date? = nil,
        vehicle: Vehicle,
        policy: DrivingPolicy = .standard,
        goal: OptimizationGoal = .balanced,
        travelers: Int = 2
    ) {
        self.origin = origin
        self.destination = destination
        self.departure = departure
        self.arriveBy = arriveBy
        self.vehicle = vehicle
        self.policy = policy
        self.goal = goal
        self.travelers = travelers
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
        return errors
    }
}
