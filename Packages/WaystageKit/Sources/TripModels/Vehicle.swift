import Foundation

/// The fuel the car should get, as sold at US pumps: its octane and ethanol level. A plan only
/// refuels at stations that sell it. Raw values are stable identifiers used in persistence.
///
/// Ethanol-free (E0) and E15 aren't offered: station data doesn't say which stations sell them,
/// so a plan couldn't make sure they're available.
public enum FuelType: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Any gasoline the station sells (the cheapest, usually regular); any gas station works.
    case any
    /// Regular unleaded, 87 octane, up to 10 % ethanol.
    case regular
    /// Midgrade, 89 octane, up to 10 % ethanol.
    case midgrade
    /// Premium, 91–93 octane, up to 10 % ethanol.
    case premium
    /// Flex fuel, 51–83 % ethanol, for flex-fuel vehicles.
    case e85
    case diesel

    public var id: String { rawValue }

    /// "Regular 87".
    public var displayName: String {
        switch self {
        case .any: "Any gasoline"
        case .regular: "Regular 87"
        case .midgrade: "Midgrade 89"
        case .premium: "Premium 91+"
        case .e85: "Flex fuel"
        case .diesel: "Diesel"
        }
    }

    /// The ethanol level as pumps label it ("E10"), empty for any grade.
    public var ethanolLabel: String {
        switch self {
        case .any: ""
        case .regular, .midgrade, .premium: "E10"
        case .e85: "E85"
        case .diesel: "no ethanol"
        }
    }

    /// "Regular 87 · E10".
    public var title: String { ethanolLabel.isEmpty ? displayName : "\(displayName) · \(ethanolLabel)" }

    /// What the ethanol level means.
    public var ethanolDescription: String {
        switch self {
        case .any: "Whatever the pump offers; in the US usually up to 10% ethanol."
        case .regular, .midgrade, .premium: "Up to 10% ethanol, the standard US blend."
        case .e85: "51–83% ethanol, for flex-fuel vehicles only. About 25% fewer miles per gallon."
        case .diesel: "Diesel engines only."
        }
    }

    /// What a plan does with this grade.
    public var planningNote: String {
        switch self {
        case .any:
            "Any gas station works; each stop is priced at its cheapest gasoline."
        case .regular, .midgrade, .premium:
            "Fuel stops sell \(displayName). A station that lists its grades without it is skipped."
        case .e85:
            "Fuel stops are stations known to sell E85. If there are too few, the plan uses regular gasoline and says so."
        case .diesel:
            "Fuel stops are stations known to sell diesel, including truck stops."
        }
    }

    /// A gasoline grade (diesel and E85 aren't).
    public var isGasoline: Bool { [.any, .regular, .midgrade, .premium].contains(self) }

    /// Sold at practically every US gas station, so assumed where a station lists no grades.
    public var isSoldAlmostEverywhere: Bool { isGasoline }

    /// Energy per gallon compared with E10 gasoline: E85 goes about 25 % fewer miles per gallon.
    public var relativeEnergy: Double { self == .e85 ? 0.75 : 1 }
}

/// The car being driven.
public struct Vehicle: Codable, Hashable, Sendable {
    /// Combined fuel economy in miles per US gallon, on gasoline (or diesel for a diesel car).
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
        fuelType: FuelType = .any
    ) {
        self.milesPerGallon = milesPerGallon
        self.tankCapacityGallons = tankCapacityGallons
        self.initialFuelFraction = initialFuelFraction
        self.fuelType = fuelType
    }

    /// Miles per gallon on the chosen fuel (E85 has less energy per gallon than gasoline).
    public var effectiveMilesPerGallon: Double { milesPerGallon * fuelType.relativeEnergy }

    /// Range on a full tank, in miles.
    public var fullTankRangeMiles: Double { effectiveMilesPerGallon * tankCapacityGallons }

    /// Gallons of the chosen fuel needed to drive `meters`.
    public func gallons(forMeters meters: Double) -> Double {
        guard effectiveMilesPerGallon > 0 else { return .infinity }
        return Units.miles(fromMeters: meters) / effectiveMilesPerGallon
    }
}
