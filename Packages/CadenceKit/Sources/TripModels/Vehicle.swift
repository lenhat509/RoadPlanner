import Foundation

/// Fuel grades the planner can price. Raw values are stable identifiers used in persistence.
public enum FuelType: String, Codable, CaseIterable, Sendable, Identifiable {
    case regular
    case midgrade
    case premium
    case diesel

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .regular: "Regular"
        case .midgrade: "Midgrade"
        case .premium: "Premium"
        case .diesel: "Diesel"
        }
    }
}

/// The car being driven.
public struct Vehicle: Codable, Hashable, Sendable {
    /// Combined fuel economy in miles per US gallon.
    public var milesPerGallon: Double
    /// Usable tank capacity in US gallons.
    public var tankCapacityGallons: Double
    /// Fraction of the tank that is full at departure, `0...1`.
    public var initialFuelFraction: Double
    public var fuelType: FuelType

    public static let defaultTankCapacityGallons = 14.0

    public init(
        milesPerGallon: Double,
        tankCapacityGallons: Double = Vehicle.defaultTankCapacityGallons,
        initialFuelFraction: Double = 1,
        fuelType: FuelType = .regular
    ) {
        self.milesPerGallon = milesPerGallon
        self.tankCapacityGallons = tankCapacityGallons
        self.initialFuelFraction = initialFuelFraction
        self.fuelType = fuelType
    }

    /// Range on a full tank, in miles.
    public var fullTankRangeMiles: Double { milesPerGallon * tankCapacityGallons }

    /// Gallons needed to drive `meters`.
    public func gallons(forMeters meters: Double) -> Double {
        guard milesPerGallon > 0 else { return .infinity }
        return Units.miles(fromMeters: meters) / milesPerGallon
    }
}
