import Foundation
import TripModels

/// Fallback prices used when no live price is available. All values are USD and are
/// clearly flagged as estimates in the resulting itinerary.
public struct PricingDefaults: Hashable, Sendable {
    /// National average retail price per gallon by grade.
    public var fuelPricePerGallon: [FuelType: Double]
    /// Typical nightly rate by Google price level.
    public var nightlyRateByPriceLevel: [PriceLevel: Double]
    /// Nightly rate when nothing is known about a property.
    public var unknownNightlyRate: Double

    public init(
        fuelPricePerGallon: [FuelType: Double] = [
            .any: 3.35, .regular: 3.35, .midgrade: 3.85, .premium: 4.25, .e85: 2.95, .diesel: 3.85,
        ],
        nightlyRateByPriceLevel: [PriceLevel: Double] = [
            .free: 0, .inexpensive: 95, .moderate: 145, .expensive: 225, .veryExpensive: 360,
        ],
        unknownNightlyRate: Double = 135
    ) {
        self.fuelPricePerGallon = fuelPricePerGallon
        self.nightlyRateByPriceLevel = nightlyRateByPriceLevel
        self.unknownNightlyRate = unknownNightlyRate
    }

    public static let standard = PricingDefaults()

    public func fuelPrice(for fuelType: FuelType) -> Double {
        fuelPricePerGallon[fuelType] ?? fuelPricePerGallon[.regular] ?? 3.5
    }

    public func nightlyRate(for priceLevel: PriceLevel?) -> Double {
        guard let priceLevel, priceLevel != .free else { return unknownNightlyRate }
        return nightlyRateByPriceLevel[priceLevel] ?? unknownNightlyRate
    }
}
