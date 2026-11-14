import Foundation
import TripModels

/// Whether a gas station sells the grade the car needs, and at what price.
///
/// * A station that lists its grades (Google Places fuel prices) sells exactly those.
/// * A station that lists none is assumed to sell the gasoline grades (practically every US
///   station does); diesel only at truck stops; E85 never (it must be listed).
public enum FuelOffer: Equatable, Sendable {
    /// The station lists the grade, at this price.
    case confirmed(pricePerGallon: Double)
    /// The station lists no grades, but nearly every station sells this one.
    case assumed
    /// The station doesn't sell the grade (it lists others), or it can't be told.
    case unavailable

    public static func at(_ station: FoundPlace, for grade: FuelType) -> FuelOffer {
        let listed = station.fuelPrices.filter { $0.value > 0 }
        if !listed.isEmpty {
            if grade == .any {
                // Any grade: the cheapest gasoline it sells.
                let gasoline = listed.filter { $0.key.isGasoline }.map(\.value)
                return gasoline.min().map { .confirmed(pricePerGallon: $0) } ?? .unavailable
            }
            return listed[grade].map { .confirmed(pricePerGallon: $0) } ?? .unavailable
        }
        if grade.isSoldAlmostEverywhere { return .assumed }
        if grade == .diesel, isTruckStop(station.place.name) { return .assumed }
        return .unavailable
    }

    /// Truck stops and travel centers always sell diesel.
    static func isTruckStop(_ name: String) -> Bool {
        let name = name.lowercased()
        return ["pilot", "flying j", "love's", "loves travel", "travel center", "travel centre", "travelcenter",
                "travel plaza", "truck stop", "petro stopping", "sapp bros", "road ranger", "bosselman"]
            .contains { name.contains($0) }
    }
}
